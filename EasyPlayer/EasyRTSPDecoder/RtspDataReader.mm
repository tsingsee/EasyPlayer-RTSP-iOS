
#import "RtspDataReader.h"
#include <pthread.h>
#include <vector>
#import <string.h>
#include "VideoDecode.h"
#include "EasyAudioDecoder.h"
#import "HWVideoDecoder.h"

struct FrameInfo {
    FrameInfo() : pBuf(NULL), frameLen(0), type(0), timeStamp(0), width(0), height(0){}
    unsigned char *pBuf;
    int frameLen;
    int type;
    CGFloat timeStamp;
    int width;
    int height;
};

@interface RtspDataReader()<HWVideoDecoderDelegate> {
    // RTSP拉流句柄
    Easy_RTSP_Handle rtspHandle;
    
    // 互斥锁
    pthread_mutex_t mutexFrame;
    pthread_mutex_t mutexChan;
    
    void *_videoDecHandle;  // 视频解码句柄
    void *_audioDecHandle;  // 音频解码句柄
    
    EASY_MEDIA_INFO_T _mediaInfo;   // 媒体信息
    
    std::vector<FrameInfo *> vctFrame;
    CGFloat _lastVideoFramePosition;
    
    // 视频硬解码器
    HWVideoDecoder *_hwDec;
}

@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, strong) NSThread *thread;

- (void)pushFrame:(char *)pBuf frameInfo:(RTSP_FRAME_INFO *)info type:(int)type;
- (void)recvMediaInfo:(EASY_MEDIA_INFO_T *)info;

@end

#pragma mark - 拉流后的回调

/*
 _channelId:    通道号,暂时不用
 _channelPtr:   通道对应对象
 _frameType:    EASY_SDK_VIDEO_FRAME_FLAG/EASY_SDK_AUDIO_FRAME_FLAG/EASY_SDK_EVENT_FRAME_FLAG/...
 _pBuf:         回调的数据部分，具体用法看Demo
 _frameInfo:    帧结构数据
 */
int __RTSPDataCallBack(int channelId, void *channelPtr, int frameType, char *pBuf, RTSP_FRAME_INFO *frameInfo) {
    if (channelPtr == NULL) {
        return 0;
    }
    
    if (pBuf == NULL) {
        return 0;
    }
    
    RtspDataReader *reader = (__bridge RtspDataReader *)channelPtr;
    
    if (frameInfo != NULL) {
        if (frameType == EASY_SDK_AUDIO_FRAME_FLAG) {// EASY_SDK_AUDIO_FRAME_FLAG音频帧标志
            [reader pushFrame:pBuf frameInfo:frameInfo type:frameType];
        } else if (frameType == EASY_SDK_VIDEO_FRAME_FLAG &&    // EASY_SDK_VIDEO_FRAME_FLAG视频帧标志
                   frameInfo->codec == EASY_SDK_VIDEO_CODEC_H264) { // H264视频编码
            [reader pushFrame:pBuf frameInfo:frameInfo type:frameType];
        }
    } else {
        if (frameType == EASY_SDK_MEDIA_INFO_FLAG) {// EASY_SDK_MEDIA_INFO_FLAG媒体类型标志
            EASY_MEDIA_INFO_T mediaInfo = *((EASY_MEDIA_INFO_T *)pBuf);
            NSLog(@"RTSP DESCRIBE Get Media Info: video:%u fps:%u audio:%u channel:%u sampleRate:%u \n",
                  mediaInfo.u32VideoCodec,
                  mediaInfo.u32VideoFps,
                  mediaInfo.u32AudioCodec,
                  mediaInfo.u32AudioChannel,
                  mediaInfo.u32AudioSamplerate);
            [reader recvMediaInfo:&mediaInfo];
        }
    }
    
    return 0;
}

@implementation RtspDataReader

+ (void)startUp {
    DecodeRegiestAll();
}

#pragma mark - init

- (id)initWithUrl:(NSString *)url {
    if (self = [super init]) {
        // 动态方式是采用pthread_mutex_init()函数来初始化互斥锁
        pthread_mutex_init(&mutexFrame, 0);
        pthread_mutex_init(&mutexChan, 0);
        
        _videoDecHandle = NULL;
        _audioDecHandle = NULL;

        self.url = url;
        
        // 初始化硬解码器
        _hwDec = [[HWVideoDecoder alloc] initWithDelegate:self];
    }
    
    return self;
}

#pragma mark - public method

- (void)start {
    if (self.url.length == 0) {
        return;
    }
    
    _lastVideoFramePosition = 0;
    _running = YES;
    
    self.thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadFunc) object:nil];
    [self.thread start];
}

- (void)stop {
    pthread_mutex_lock(&mutexChan);
    if (rtspHandle != NULL) {
        EasyRTSP_SetCallback(rtspHandle, NULL);
        EasyRTSP_CloseStream(rtspHandle);// 关闭网络流
    }
    pthread_mutex_unlock(&mutexChan);
    
    _running = false;
    [self.thread cancel];
}

#pragma mark - 子线程方法

- (void)threadFunc {
    // 在播放中 该线程一直运行
    while (_running) {
        
        // ------------ 加锁mutexChan ------------
        pthread_mutex_lock(&mutexChan);
        if (rtspHandle == NULL) {
            int ret = EasyRTSP_Init(&rtspHandle);
            if (ret != 0) {
                NSLog(@"EasyRTSP_Init err %d", ret);
            } else {
                /* 设置数据回调 */
                EasyRTSP_SetCallback(rtspHandle, __RTSPDataCallBack);
                
                /* 打开网络流 */
                ret = EasyRTSP_OpenStream(rtspHandle,
                                          1,
                                          (char *)[self.url UTF8String],
                                          EASY_RTP_OVER_TCP,
                                          EASY_SDK_VIDEO_FRAME_FLAG | EASY_SDK_AUDIO_FRAME_FLAG,// 视频帧标|音频帧标志
                                          0,
                                          0,
                                          (__bridge void *)self,
                                          1000,     // 1000表示长连接,即如果网络断开自动重连, 其它值为连接次数
                                          0,        // 默认为0,即回调输出完整的帧, 如果为1,则输出RTP包
                                          0x01,     // 0x00:不发送心跳 0x01:OPTIONS 0x02:GET_PARAMETER
                                          3);       // 日志打印输出等级，0表示不输出
                NSLog(@"EasyRTSP_OpenStream ret = %d", ret);
            }
        }
        pthread_mutex_unlock(&mutexChan);
        // ------------ 解锁mutexChan ------------
        
        // ------------ 加锁mutexFrame ------------
        pthread_mutex_lock(&mutexFrame);
        int count = (int)vctFrame.size();
        if (count == 0) {
            pthread_mutex_unlock(&mutexFrame);
            usleep(5 * 1000);
            continue;
        }
        
        FrameInfo *frame = vctFrame[0];
        vctFrame.erase(vctFrame.begin());
        pthread_mutex_unlock(&mutexFrame);
        // ------------ 解锁mutexFrame ------------
        
        if (frame->type == EASY_SDK_VIDEO_FRAME_FLAG) {
            if (self.useHWDecoder) {
                [_hwDec decodeVideoData:frame->pBuf len:frame->frameLen];
            } else {
                [self decodeVideoFrame:frame];
            }
        } else {
            if (self.enableAudio) {
                [self decodeAudioFrame:frame];
            }
        }
        
        delete []frame->pBuf;
        delete frame;
    }
    
    [self removeCach];
    
    if (_videoDecHandle != NULL) {
        DecodeClose(_videoDecHandle);
        _videoDecHandle = NULL;
    }
    
    if (_audioDecHandle != NULL) {
        EasyAudioDecodeClose((EasyAudioHandle *)_audioDecHandle);
        _audioDecHandle = NULL;
    }
    
    if (self.useHWDecoder) {
        [_hwDec closeDecoder];
    }
}

// 解码视频帧
- (void)decodeVideoFrame:(FrameInfo *)video {
    if (_videoDecHandle == NULL) {
        DEC_CREATE_PARAM param;
        param.nMaxImgWidth = video->width;
        param.nMaxImgHeight = video->height;
        param.coderID = CODER_H264;
        param.method = IDM_SW;
        _videoDecHandle = DecodeCreate(&param);
    }
    
    DEC_DECODE_PARAM param;
    param.pStream = video->pBuf;
    param.nLen = video->frameLen;
    param.need_sps_head = false;
    
    DVDVideoPicture picture;
    memset(&picture, 0, sizeof(picture));
    picture.iDisplayWidth = video->width;
    picture.iDisplayHeight = video->height;
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    int nRet = DecodeVideo(_videoDecHandle, &param, &picture);
    NSTimeInterval decodeInterval = [NSDate timeIntervalSinceReferenceDate] - now;
    if (nRet) {
        @autoreleasepool {
            KxVideoFrameRGB *frame = [[KxVideoFrameRGB alloc] init];
            frame.width = param.nOutWidth;
            frame.height = param.nOutHeight;
            frame.linesize = param.nOutWidth * 3;;
            frame.hasAlpha = NO;
            frame.rgb = [NSData dataWithBytes:param.pImgRGB length:param.nLineSize  * param.nOutHeight];
            frame.position = video->timeStamp;
            
            if (_lastVideoFramePosition == 0) {
                _lastVideoFramePosition = video->timeStamp;
            }
            
            CGFloat duration = video->timeStamp - _lastVideoFramePosition - decodeInterval;
            if (duration >= 1.0 || duration <= -1.0) {
                duration = 0.02;
            }
            
            frame.duration = duration;
            _lastVideoFramePosition = video->timeStamp;
            
            if (self.frameOutputBlock) {
                self.frameOutputBlock(frame);
            }
        }
    }
}

// 解码音频帧
- (void)decodeAudioFrame:(FrameInfo *)audio {
    if (_audioDecHandle == NULL) {
        _audioDecHandle = EasyAudioDecodeCreate(_mediaInfo.u32AudioCodec,
                                                _mediaInfo.u32AudioSamplerate,
                                                _mediaInfo.u32AudioChannel,
                                                16);
    }
    
    unsigned char pcmBuf[10 * 1024] = { 0 };
    int pcmLen = 0;
    int ret = EasyAudioDecode((EasyAudioHandle *)_audioDecHandle,
                              audio->pBuf,
                              0,
                              audio->frameLen,
                              pcmBuf,
                              &pcmLen);
    if (ret == 0) {
        @autoreleasepool {
            KxAudioFrame *frame = [[KxAudioFrame alloc] init];
            frame.samples = [NSData dataWithBytes:pcmBuf length:pcmLen];
            frame.position = audio->timeStamp;
            if (self.frameOutputBlock) {
                self.frameOutputBlock(frame);
            }
        }
    }
}

- (void)removeCach {
    pthread_mutex_lock(&mutexFrame);
    
    std::vector<FrameInfo *>::iterator it = vctFrame.begin();
    while (it != vctFrame.end()) {
        FrameInfo *frameInfo = *it;
        delete []frameInfo->pBuf;
        delete frameInfo;
        it++;
    }
    vctFrame.clear();
    
    pthread_mutex_unlock(&mutexFrame);
    
    NSLog(@"Reader %8@ removeCach", self);
}

#pragma mark - private method

// 获得媒体类型
- (void)recvMediaInfo:(EASY_MEDIA_INFO_T *)info {
    _mediaInfo = *info;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.fetchMediaInfoSuccessBlock) {
            self.fetchMediaInfoSuccessBlock();
        }
    });
}

- (void)pushFrame:(char *)pBuf frameInfo:(RTSP_FRAME_INFO *)info type:(int)type {
    if (!_running) {
        return;
    }
    
    if (type == EASY_SDK_AUDIO_FRAME_FLAG && !self.enableAudio) {
        return;
    }
    
    FrameInfo *frameInfo = (FrameInfo *)malloc(sizeof(FrameInfo));
    frameInfo->type = type;
    frameInfo->frameLen = info->length;
    frameInfo->pBuf = new unsigned char[info->length];
    frameInfo->width = info->width;
    frameInfo->height = info->height;
    frameInfo->timeStamp = info->timestamp_sec + (float)(info->timestamp_usec / 1000) / 1000.0;
    
    memcpy(frameInfo->pBuf, pBuf, info->length);
    
    pthread_mutex_lock(&mutexFrame);    // 加锁
    vctFrame.push_back(frameInfo);
    pthread_mutex_unlock(&mutexFrame);  // 解锁
}

#pragma mark - HWVideoDecoderDelegate

-(void) getDecodePictureData:(KxVideoFrame *)frame {
    if (self.frameOutputBlock) {
        self.frameOutputBlock(frame);
    }
}

-(void) getDecodePixelData:(CVImageBufferRef)frame {
    NSLog(@" --> %@", frame);
}

#pragma mark - dealloc

- (void)dealloc {
    [self removeCach];
    
    // 注销互斥锁
    pthread_mutex_destroy(&mutexFrame);
    pthread_mutex_destroy(&mutexChan);
    
    if (rtspHandle != NULL) {
        /* 释放RTSPClient 参数为RTSPClient句柄 */
        EasyRTSP_Deinit(&rtspHandle);
        rtspHandle = NULL;
    }
}

#pragma mark - getter

- (EASY_MEDIA_INFO_T)mediaInfo {
    return _mediaInfo;
}

@end