
#import "PlayerDataReader.h"

#include <pthread.h>
#include <thread>
#include <vector>
#include <set>
#include <string.h>
#include <math.h>

#import "HWVideoDecoder.h"
#import "NSUserDefaultsUnit.h"
#import <VideoToolbox/VideoToolbox.h>
#include "VideoDecode.h"
#include "EasyAudioDecoder.h"

#include "Muxer.h"

#import "EasyRTSPEventCode.h"
#import "PlayerResultCode.h"
#import <QuartzCore/QuartzCore.h>

struct FrameInfo {
    FrameInfo() : pBuf(NULL), frameLen(0), type(0), timeStamp(0), width(0), height(0){}

    unsigned char *pBuf;
    int frameLen;
    int type;
    CGFloat timeStamp;// 毫秒为单位(1秒=1000毫秒 1秒=1000000微秒)
    int width;
    int height;
};

class compare {
public:
    bool operator ()(FrameInfo *lhs, FrameInfo *rhs) const {
        return lhs->timeStamp < rhs->timeStamp;
    }
};

pthread_mutex_t mutexRecordVideoFrame;
pthread_mutex_t mutexRecordAudioFrame;

std::multiset<FrameInfo *, compare> recordVideoFrameSet;
std::multiset<FrameInfo *, compare> recordAudioFrameSet;

int isKeyFrame = 0; // 是否到了I帧
int *stopRecord = (int *)malloc(sizeof(int));// 停止录像
static int sDecodePathLogCount = 0;
static int sCodecDiagLogCount = 0;

static const char *EasyVideoCodecLabel(unsigned int codec) {
    switch (codec) {
        case EASY_SDK_VIDEO_CODEC_H264: return "H264";
        case EASY_SDK_VIDEO_CODEC_H265: return "H265";
        case AV_CODEC_ID_HEVC: return "HEVC";
        case EASY_SDK_VIDEO_CODEC_MJPEG: return "MJPEG";
        case EASY_SDK_VIDEO_CODEC_MPEG4: return "MPEG4";
        default: return "UNKNOWN";
    }
}

static const char *FFmpegCodecLabel(enum AVCodecID codecID) {
    switch (codecID) {
        case AV_CODEC_ID_NONE: return "NONE";
        case AV_CODEC_ID_H264: return "H264";
        case AV_CODEC_ID_HEVC: return "HEVC";
        case AV_CODEC_ID_MJPEG: return "MJPEG";
        case AV_CODEC_ID_MPEG4: return "MPEG4";
        default: return "OTHER";
    }
}

static enum AVCodecID EasyVideoCodecToAVCodecID(unsigned int easyCodec) {
    switch (easyCodec) {
        case EASY_SDK_VIDEO_CODEC_H264:
            return AV_CODEC_ID_H264;
        case EASY_SDK_VIDEO_CODEC_H265:
        case AV_CODEC_ID_HEVC: // 新库直接传 FFmpeg codecID，0xAE=174
            return AV_CODEC_ID_HEVC;
        case EASY_SDK_VIDEO_CODEC_MJPEG:
            return AV_CODEC_ID_MJPEG;
        case EASY_SDK_VIDEO_CODEC_MPEG4:
            return AV_CODEC_ID_MPEG4;
        default:
            return AV_CODEC_ID_NONE;
    }
}

static void LogCodecDiag(NSString *source, unsigned int easyCodec, enum AVCodecID codecID) {
    if (sCodecDiagLogCount >= 20) {
        return;
    }
    sCodecDiagLogCount++;
    NSLog(@"[CodecDiag] %@ easyCodec=0x%08X(%u,%s) -> ffmpeg codecID=%d(%s)",
          source,
          easyCodec,
          easyCodec,
          EasyVideoCodecLabel(easyCodec),
          codecID,
          FFmpegCodecLabel(codecID));
}

static BOOL DeviceSupportsHEVCHardwareDecode(void) {
    if (@available(iOS 11.0, *)) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    return NO;
}

@interface PlayerDataReader()<HWVideoDecoderDelegate> {
    // RTSP拉流句柄
    Easy_Handle rtspHandle;

    // 互斥锁
    pthread_mutex_t mutexVideoFrame;
    pthread_mutex_t mutexAudioFrame;

    pthread_mutex_t mutexCloseAudio;
    pthread_mutex_t mutexCloseVideo;

    pthread_mutex_t mutexInit;
    pthread_mutex_t mutexStop;

    void *_videoDecHandle;  // 视频解码句柄
    void *_audioDecHandle;  // 音频解码句柄

    EASY_MEDIA_INFO_T _mediaInfo;   // 媒体信息

    std::multiset<FrameInfo *, compare> videoFrameSet;
    std::multiset<FrameInfo *, compare> audioFrameSet;

    // 单位全用毫秒
    long previousStampUs;
    long lastFrameStampUs;
    long decodeBegin;
    long hwSleepTime;
    CGFloat mNewestStample;

    CGFloat _lastVideoFramePosition;

    // 视频硬解码器
    HWVideoDecoder *_hwDec;

    std::thread _videoThread;
    std::thread _audioThread;

    CFTimeInterval _connectStartTime;
    CFTimeInterval _reconnectStartTime;
    BOOL _hasReconnected;
    BOOL _hasReportedFirstFrame;
    BOOL _hasReportedDecodeError;
    BOOL _hasReportedDecodeMode;
    BOOL _hasReportedVideoCodec;
    BOOL _lastReportedHWDecode;
    BOOL _isPlayAttemptInFlight;
    NSInteger _playAttemptTotal;
    NSInteger _playSuccessCount;
    enum AVCodecID _lastReportedCodecID;
}
  
@property (nonatomic, readwrite) BOOL running;

@property (nonatomic, assign) int lastWidth;
@property (nonatomic, assign) int lastHeight;

// EASY_SDK_VIDEO_CODEC_H265/EASY_SDK_VIDEO_CODEC_H264编码方式
@property (nonatomic) enum AVCodecID codecID;

- (void)pushFrame:(char *)pBuf frameInfo:(EASY_FRAME_INFO *)info type:(int)type;
- (void)recvMediaInfo:(EASY_MEDIA_INFO_T *)info;
- (void)resetFirstFrameTiming;
- (void)markConnectStart;
- (void)markReconnectStart;
- (void)markReconnectStartForceNewAttempt:(BOOL)forceNewAttempt;
- (void)handleVideoFirstFrameMarker;
- (BOOL)hasReportedFirstFrame;
- (BOOL)hasReconnected;
- (BOOL)awaitingFirstFrameAfterReconnect;
- (void)notifyDecodeError:(NSString *)message;
- (BOOL)resolvedShouldUseHWDecoder;
- (void)reportDecodeInfoIfNeeded;
- (void)beginPlayAttemptIfNeeded;
- (void)forceBeginPlayAttempt;
- (void)endPlayAttemptWithoutSuccess;
- (void)reportPlaySuccessRate;

@end

#pragma mark - 拉流后的回调

/*
 _channelId:    通道号,暂时不用
 _channelPtr:   通道对应对象
 _frameType:    EASY_SDK_VIDEO_FRAME_FLAG/EASY_SDK_AUDIO_FRAME_FLAG/EASY_SDK_EVENT_FRAME_FLAG/...
 _pBuf:         回调的数据部分，具体用法看Demo
 _frameInfo:    帧结构数据
 */
int RTSPDataCallBack(int channelId, void *channelPtr, int frameType, char *pBuf, EASY_FRAME_INFO *frameInfo) {
    
    if (frameType == EASY_SDK_EVENT_FRAME_FLAG) {
        if (channelPtr != NULL && frameInfo != NULL) {
            PlayerDataReader *reader = (__bridge PlayerDataReader *)channelPtr;
            if (reader.running) {
                NSInteger eventCode = frameInfo->codec;
                NSString *msg = pBuf ? [NSString stringWithUTF8String:pBuf] : @"";
                NSInteger data = frameInfo->length;
                NSInteger count = frameInfo->reserved1;
                NSInteger total = frameInfo->reserved2;
                if (eventCode == EVENT_CODEC_CONNECTING) {
                    if (reader.hasReportedFirstFrame || reader.hasReconnected) {
                        // 出过首帧后再 connecting，或已在重连流程中再次 connecting：算一次新的请求
                        [reader markReconnectStart];
                    } else {
                        [reader markConnectStart];
                    }
                } else if (eventCode == EVENT_CODEC_RECONN) {
                    // 每次重连事件都计一次请求（即使上一轮还没出首帧）
                    [reader markReconnectStartForceNewAttempt:YES];
                } else if (eventCode == EVENT_CODEC_STREAM_ABORT ||
                           eventCode == EVENT_CODEC_CONNECT_FAIL ||
                           eventCode == EVENT_CODEC_CONNECT_TIMEOUT ||
                           eventCode == EVENT_CODEC_NO_DATA) {
                    // 当前这次请求失败，结束 inFlight，便于后续 connecting/reconn 正确计入下一次
                    [reader endPlayAttemptWithoutSuccess];
                }
                void (^block)(NSInteger, NSString *, NSInteger, NSInteger, NSInteger) = reader.rtspEventBlock;
                NSLog(@"[RTSPCallBack] EVENT: code=0x%lX msg=%@ data=%ld count=%ld total=%ld",
                      (long)eventCode, msg, (long)data, (long)count, (long)total);
                if (block) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        block(eventCode, msg, data, count, total);
                    });
                }
            }
        } else {
            NSLog(@"[RTSPCallBack] EVENT: channelPtr=%p frameInfo=%p", channelPtr, frameInfo);
        }
        return 0;
    }
    
    if (channelPtr == NULL) {
        return 0;
    }

    if (pBuf == NULL) {
        return 0;
    }

    PlayerDataReader *reader = (__bridge PlayerDataReader *)channelPtr;
    if (!reader.running) {
        return 0;
    }
   
    if (frameInfo != NULL) {
        if (frameType == EASY_SDK_AUDIO_FRAME_FLAG) {// EASY_SDK_AUDIO_FRAME_FLAG音频帧标志
            [reader pushFrame:pBuf frameInfo:frameInfo type:frameType];
        } else if (frameType == EASY_SDK_VIDEO_FRAME_FLAG ) {   // EASY_SDK_VIDEO_FRAME_FLAG视频帧标志
            [reader pushFrame:pBuf frameInfo:frameInfo type:frameType];

            enum AVCodecID mappedCodecID = EasyVideoCodecToAVCodecID(frameInfo->codec);
            if (mappedCodecID != AV_CODEC_ID_NONE) {
                reader.codecID = mappedCodecID;
                [reader reportDecodeInfoIfNeeded];
            }
            if (frameInfo->sample_rate == 1 || [reader awaitingFirstFrameAfterReconnect]) {
                [reader handleVideoFirstFrameMarker];
            }
            LogCodecDiag(@"VIDEO_FRAME", frameInfo->codec, reader.codecID);
        }
    } else {
        if (frameType == EASY_SDK_MEDIA_INFO_FLAG) {// EASY_SDK_MEDIA_INFO_FLAG媒体类型标志
            EASY_MEDIA_INFO_T mediaInfo = *((EASY_MEDIA_INFO_T *)pBuf);

            NSLog(@"\n Media Info:video:%u fps:%u audio:%u channel:%u sampleRate:%u \n",
                  mediaInfo.u32VideoCodec,
                  mediaInfo.u32VideoFps,
                  mediaInfo.u32AudioCodec,
                  mediaInfo.u32AudioChannel,
                  mediaInfo.u32AudioSamplerate);
            LogCodecDiag(@"MEDIA_INFO",
                         mediaInfo.u32VideoCodec,
                         EasyVideoCodecToAVCodecID(mediaInfo.u32VideoCodec));

            if (mediaInfo.u32AudioChannel <= 0 || mediaInfo.u32AudioChannel > 2) {
                mediaInfo.u32AudioChannel = 1;
            }

            [reader recvMediaInfo:&mediaInfo];
        }
    }

    return 0;
}

@implementation PlayerDataReader

+ (void)startUp {
    DecodeRegiestAll();
}

#pragma mark - init

- (id)initWithUrl:(NSString *)url {
    if (self = [super init]) {
        // 动态方式是采用pthread_mutex_init()函数来初始化互斥锁
        pthread_mutex_init(&mutexVideoFrame, 0);
        pthread_mutex_init(&mutexAudioFrame, 0);

        pthread_mutex_init(&mutexRecordVideoFrame, 0);
        pthread_mutex_init(&mutexRecordAudioFrame, 0);

        pthread_mutex_init(&mutexCloseAudio, 0);
        pthread_mutex_init(&mutexCloseVideo, 0);

        pthread_mutex_init(&mutexInit, 0);
        pthread_mutex_init(&mutexStop, 0);

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

    mNewestStample = 0;
    _lastVideoFramePosition = 0;
    _running = YES;
    [self resetFirstFrameTiming];

    _videoThread = std::thread([self] { [self videoThreadFunc]; });
    _audioThread = std::thread([self] { [self audioThreadFunc]; });
}

- (void)stop {
    pthread_mutex_lock(&mutexStop);

    if (!_running) {
        pthread_mutex_unlock(&mutexStop);
        return;
    }

    if (rtspHandle != NULL) {
        _running = false;
        EasyRTSP_SetCallback(rtspHandle, NULL);
        EasyRTSP_CloseStream(rtspHandle);// 关闭网络流
        EasyRTSP_Deinit(&rtspHandle);
        rtspHandle = NULL;
    } else {
        _running = false;
    }

    mNewestStample = 0;
    sDecodePathLogCount = 0;
    sCodecDiagLogCount = 0;
    [self resetFirstFrameTiming];

    pthread_mutex_unlock(&mutexStop);

    if (_videoThread.joinable()) _videoThread.join();
    if (_audioThread.joinable()) _audioThread.join();
}

#pragma mark - dealloc

- (void)dealloc {

    [self stop];

    [self removeVideoFrameSet];
    [self removeAudioFrameSet];
    [self removeRecordFrameSet];

    // 注销互斥锁
    pthread_mutex_destroy(&mutexVideoFrame);
    pthread_mutex_destroy(&mutexAudioFrame);
    pthread_mutex_destroy(&mutexInit);
    pthread_mutex_destroy(&mutexRecordVideoFrame);
    pthread_mutex_destroy(&mutexRecordAudioFrame);

    pthread_mutex_destroy(&mutexCloseVideo);
    pthread_mutex_destroy(&mutexCloseAudio);
    pthread_mutex_destroy(&mutexStop);
}

#pragma mark - 首帧耗时

- (void)resetFirstFrameTiming {
    _connectStartTime = 0;
    _reconnectStartTime = 0;
    _hasReconnected = NO;
    _hasReportedFirstFrame = NO;
    _hasReportedDecodeError = NO;
    _hasReportedDecodeMode = NO;
    _hasReportedVideoCodec = NO;
    _lastReportedCodecID = AV_CODEC_ID_NONE;
    _isPlayAttemptInFlight = NO;
    _playAttemptTotal = 0;
    _playSuccessCount = 0;
}

- (void)resetDecodeInfoReporting {
    _hasReportedDecodeMode = NO;
    _hasReportedVideoCodec = NO;
    _lastReportedCodecID = AV_CODEC_ID_NONE;
}

- (void)beginPlayAttemptIfNeeded {
    if (_isPlayAttemptInFlight) {
        return;
    }
    [self forceBeginPlayAttempt];
}

- (void)forceBeginPlayAttempt {
    _playAttemptTotal += 1;
    _isPlayAttemptInFlight = YES;
    NSLog(@"[PlaySuccess] attempt +1 => total=%ld inFlight=1", (long)_playAttemptTotal);
}

- (void)endPlayAttemptWithoutSuccess {
    if (_isPlayAttemptInFlight) {
        _isPlayAttemptInFlight = NO;
        NSLog(@"[PlaySuccess] attempt failed, total stays %ld inFlight=0", (long)_playAttemptTotal);
    }
}

- (void)markConnectStart {
    if (!_hasReconnected) {
        _connectStartTime = CACurrentMediaTime();
        _hasReportedFirstFrame = NO;
        [self beginPlayAttemptIfNeeded];
    }
}

- (void)markReconnectStart {
    [self markReconnectStartForceNewAttempt:NO];
}

- (void)markReconnectStartForceNewAttempt:(BOOL)forceNewAttempt {
    // forceNewAttempt=YES：SDK 每次 RECONN 都算一次请求（907 total）
    // forceNewAttempt=NO：仅在「上一轮已结束」或「刚出过首帧」时算新请求，避免与 CONNECTING 重复计数
    BOOL wasSuccessfulBefore = _hasReportedFirstFrame;
    BOOL shouldCount = forceNewAttempt || _hasReportedFirstFrame || !_isPlayAttemptInFlight;
    if (shouldCount) {
        [self forceBeginPlayAttempt];
    }

    // 首帧耗时：从「本轮第一次重连」起算，直到播放成功；后续重连不刷新起点
    if (wasSuccessfulBefore) {
        _reconnectStartTime = 0;
    }
    if (_reconnectStartTime <= 0) {
        _reconnectStartTime = CACurrentMediaTime();
        NSLog(@"[CodecDiag] reconnect first-frame timing start");
    }

    _hasReconnected = YES;
    _hasReportedFirstFrame = NO;
    _hasReportedDecodeError = NO;
    [self resetDecodeInfoReporting];
}

- (BOOL)hasReportedFirstFrame {
    return _hasReportedFirstFrame;
}

- (BOOL)hasReconnected {
    return _hasReconnected;
}

- (BOOL)awaitingFirstFrameAfterReconnect {
    return _hasReconnected && !_hasReportedFirstFrame;
}

- (void)reportPlaySuccessRate {
    if (_playAttemptTotal <= 0) {
        return;
    }
    _playSuccessCount += 1;
    _isPlayAttemptInFlight = NO;

    NSInteger rate = (_playSuccessCount * 100) / _playAttemptTotal;
    NSString *msg = [NSString stringWithFormat:@"{success:%ld%%,s_count:%ld,total:%ld}",
                     (long)rate, (long)_playSuccessCount, (long)_playAttemptTotal];
    NSLog(@"[PlaySuccess] %@", msg);

    void (^block)(NSInteger, NSString *, NSInteger, NSInteger, NSInteger) = self.rtspEventBlock;
    if (block) {
        NSInteger successCount = _playSuccessCount;
        NSInteger attemptTotal = _playAttemptTotal;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.running) {
                block(PLAYER_RESULT_PLAY_SUCCESS_RATE, msg, rate, successCount, attemptTotal);
            }
        });
    }
}

- (void)handleVideoFirstFrameMarker {
    if (_hasReportedFirstFrame) {
        return;
    }
    _hasReportedFirstFrame = YES;

    CFTimeInterval baseTime = _hasReconnected ? _reconnectStartTime : _connectStartTime;
    if (baseTime <= 0) {
        baseTime = _connectStartTime;
    }
    NSInteger ms = 0;
    if (baseTime > 0) {
        ms = (NSInteger)((CACurrentMediaTime() - baseTime) * 1000.0);
        if (ms < 0) {
            ms = 0;
        }
    }

    NSLog(@"[CodecDiag] receive video first frame, cost=%ldms reconn=%d",
          (long)ms, _hasReconnected);

    void (^block)(NSInteger, NSString *, NSInteger, NSInteger, NSInteger) = self.rtspEventBlock;
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.running) {
                block(EVENT_CODEC_FIRST_FRAME, @"", ms, 0, 0);
            }
        });
    }

    // 本轮结束：清掉重连计时起点，下次重连再从头累计
    _reconnectStartTime = 0;

    // 首帧成功 → 907 播放成功率（仅成功时回调）
    [self reportPlaySuccessRate];
}

- (void)notifyDecodeError:(NSString *)message {
    if (_hasReportedDecodeError || !_running) {
        return;
    }
    _hasReportedDecodeError = YES;

    NSString *msg = message.length ? message : @"解码失败";
    NSLog(@"[DecodeError] %@", msg);

    void (^block)(NSInteger, NSString *, NSInteger, NSInteger, NSInteger) = self.rtspEventBlock;
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.running) {
                block(EVENT_CODEC_ERROR, msg, 0, 0, 0);
            }
        });
    }
}

- (BOOL)resolvedShouldUseHWDecoder {
    BOOL shouldUseHWDecoder = self.useHWDecoder;
    if (self.codecID == AV_CODEC_ID_HEVC && !DeviceSupportsHEVCHardwareDecode()) {
        shouldUseHWDecoder = NO;
    }
    return shouldUseHWDecoder;
}

- (void)notifyPlayerResult:(NSInteger)resultCode message:(NSString *)message data:(NSInteger)data {
    void (^block)(NSInteger, NSString *, NSInteger, NSInteger, NSInteger) = self.rtspEventBlock;
    if (!block || !_running) {
        return;
    }
    NSString *msg = message ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.running) {
            block(resultCode, msg, data, 0, 0);
        }
    });
}

- (void)reportDecodeInfoIfNeeded {
    if (!_running || self.codecID == AV_CODEC_ID_NONE) {
        return;
    }

    BOOL useHW = [self resolvedShouldUseHWDecoder];
    if (!_hasReportedDecodeMode || _lastReportedHWDecode != useHW) {
        _hasReportedDecodeMode = YES;
        _lastReportedHWDecode = useHW;
        [self notifyPlayerResult:PLAYER_RESULT_DECODE_MODE
                         message:useHW ? @"解码方式 硬解" : @"解码方式 软解"
                            data:useHW ? PLAYER_DECODE_MODE_HW : PLAYER_DECODE_MODE_SW];
    }

    if (!_hasReportedVideoCodec || _lastReportedCodecID != self.codecID) {
        _hasReportedVideoCodec = YES;
        _lastReportedCodecID = self.codecID;

        NSString *codecMsg = @"未知";
        NSInteger codecData = 0;
        if (self.codecID == AV_CODEC_ID_H264) {
            codecMsg = @"编码方式 H264";
            codecData = PLAYER_VIDEO_CODEC_H264;
        } else if (self.codecID == AV_CODEC_ID_HEVC) {
            codecMsg = @"编码方式 H265";
            codecData = PLAYER_VIDEO_CODEC_H265;
        }

        [self notifyPlayerResult:PLAYER_RESULT_VIDEO_CODEC message:codecMsg data:codecData];
    }
}

#pragma mark - 子线程方法

- (void) initRtspHandle {
    // ------------ 加锁mutexInit ------------
    pthread_mutex_lock(&mutexInit);
    if (rtspHandle == NULL) {
        int ret = EasyRTSP_Init(&rtspHandle);
        if (ret != 0) {
            NSLog(@"EasyRTSP_Init err %d", ret);
        } else {
            /* 设置数据回调 */
            EasyRTSP_SetCallback(rtspHandle, RTSPDataCallBack);

            [self markConnectStart];

            /* 打开网络流 */
            ret = EasyRTSP_OpenStream(rtspHandle,
                                      1,
                                      (char *)[self.url UTF8String],
                                      self.transportMode,
                                      EASY_SDK_VIDEO_FRAME_FLAG | EASY_SDK_AUDIO_FRAME_FLAG,// 视频帧标|音频帧标志
                                      0,
                                      0,
                                      (__bridge void *)self,
                                      1000,     // 1000表示长连接,即如果网络断开自动重连, 其它值为连接次数
                                      0,        // 默认为0,即回调输出完整的帧, 如果为1,则输出RTP包
                                      self.sendOption,// 0x00:不发送心跳 0x01:OPTIONS 0x02:GET_PARAMETER
                                      3);       // 日志打印输出等级，0表示不输出
            NSLog(@"EasyRTSP_OpenStream ret = %d", ret);
        }
    }
    pthread_mutex_unlock(&mutexInit);
    // ------------ 解锁mutexInit ------------
}

- (void)audioThreadFunc {
    // 在播放中 该线程一直运行
    while (_running) {
        if (rtspHandle == NULL) {
            continue;
        }

        // ------------ 加锁mutexAudioFrame ------------
        pthread_mutex_lock(&mutexAudioFrame);

        int count = (int) audioFrameSet.size();
        if (count == 0) {
            pthread_mutex_unlock(&mutexAudioFrame);
            usleep(5 * 1000);
            continue;
        }

        FrameInfo *frame = *(audioFrameSet.begin());
        audioFrameSet.erase(audioFrameSet.begin());// erase()函数的功能是用来删除容器中的元素

        pthread_mutex_unlock(&mutexAudioFrame);
        // ------------ 解锁mutexAudioFrame ------------

        if (self.enableAudio) {
            [self decodeAudioFrame:frame];
        }

        delete []frame->pBuf;
        delete frame;
    }

    [self removeAudioFrameSet];

    pthread_mutex_lock(&mutexCloseAudio);
    if (_audioDecHandle != NULL) {
        EasyAudioDecodeClose((EasyAudioHandle *)_audioDecHandle);
        _audioDecHandle = NULL;
    }
    pthread_mutex_unlock(&mutexCloseAudio);
}

- (void)videoThreadFunc {
    // 在播放中 该线程一直运行
    while (_running) {
        [self initRtspHandle];

        // ------------ 加锁mutexVideoFrame ------------
        pthread_mutex_lock(&mutexVideoFrame);

        int count = (int) videoFrameSet.size();
        if (count == 0) {
            pthread_mutex_unlock(&mutexVideoFrame);
            usleep(5 * 1000);
            continue;
        }

        FrameInfo *frame = *(videoFrameSet.begin());
        videoFrameSet.erase(videoFrameSet.begin());// erase()函数的功能是用来删除容器中的元素

        lastFrameStampUs = frame->timeStamp;

        pthread_mutex_unlock(&mutexVideoFrame);
        // ------------ 解锁mutexVideoFrame ------------

        // 视频的分辨率改变了，则需要重新初始化解码器
        BOOL isInit = NO;
        if (frame->type == EASY_SDK_VIDEO_FRAME_I && (self.lastWidth != frame->width || self.lastHeight != frame->height)) {// 视频帧类型
            isInit = YES;

            self.lastWidth = frame->width;
            self.lastHeight = frame->height;
        }

        // 仅在设备不支持 HEVC 硬解时，H265 自动回退软解。
        BOOL shouldUseHWDecoder = [self resolvedShouldUseHWDecoder];
        [self reportDecodeInfoIfNeeded];
        if (isInit || sDecodePathLogCount < 5) {
            NSLog(@"[PlayerDataReader] useHWDecoder=%d, codecID=%d, hevcHW=%d, isFFMpeg(设置)=%d -> %@",
                  self.useHWDecoder,
                  self.codecID,
                  DeviceSupportsHEVCHardwareDecode(),
                  [NSUserDefaultsUnit isFFMpeg],
                  shouldUseHWDecoder ? @"硬解 VideoToolbox" : @"软解 FFmpeg");
            sDecodePathLogCount++;
        }

        if (shouldUseHWDecoder) {
            if (hwSleepTime > 0) {
                usleep((unsigned int) hwSleepTime);
            }

            decodeBegin = (long) [[NSDate dateWithTimeIntervalSinceNow:0] timeIntervalSince1970] * 1000;// 毫秒数
            @try {
                int hwRet = [_hwDec decodeVideoData:frame->pBuf len:frame->frameLen isInit:isInit];
                if (hwRet < 0) {
                    [self notifyDecodeError:@"硬件解码失败"];
                }
            } @catch (NSException *exception) {
                [self notifyDecodeError:[NSString stringWithFormat:@"硬件解码异常:%@", exception.reason ?: @"unknown"]];
            }
        } else {
            decodeBegin = (long) [[NSDate dateWithTimeIntervalSinceNow:0] timeIntervalSince1970] * 1000;// 毫秒数

            [self decodeVideoFrame:frame isInit:isInit];

            // 帧里面有个timestamp 是当前帧的时间戳， 先获取下系统时间A，然后解码播放，解码后获取系统时间B， B-A就是本次的耗时。sleep的时长就是 当期帧的timestamp  减去 上一个视频帧的timestamp 再减去 这次的耗时
            long decodeSpend = (long) [[NSDate dateWithTimeIntervalSinceNow:0] timeIntervalSince1970] * 1000 - decodeBegin;

            if (previousStampUs != 0) {
                long sleepTime = (frame->timeStamp - previousStampUs - decodeSpend) * 1000;
                if (sleepTime > 100000) {
                    NSLog(@"sleep time.too long:%ld", sleepTime);
                    sleepTime = 100000;
                }

                if (sleepTime > 0) {
                    sleepTime %= 100000;

                    // 设置缓存的时间戳
                    long cache = (mNewestStample - frame->timeStamp) * 1000;

                    sleepTime = [self fixSleepTime:sleepTime totalTimestampDifferUs:cache delayUs:0];

                    // usleep((unsigned int) sleepTime);
                }
            }

            previousStampUs = frame->timeStamp;
        }

        delete []frame->pBuf;
        delete frame;
    }

    [self removeVideoFrameSet];

    pthread_mutex_lock(&mutexCloseVideo);
    if (_videoDecHandle != NULL) {
        DecodeClose(_videoDecHandle);
        _videoDecHandle = NULL;
    }
    pthread_mutex_unlock(&mutexCloseVideo);

    BOOL shouldUseHWDecoder = [self resolvedShouldUseHWDecoder];
    if (shouldUseHWDecoder) {
        pthread_mutex_lock(&mutexCloseVideo);
        [_hwDec closeDecoder];
        pthread_mutex_unlock(&mutexCloseVideo);
    }
}

#pragma mark - 解码视频帧

- (void)decodeVideoFrame:(FrameInfo *)video isInit:(BOOL)isInit {
    @try {
        if (isInit && _videoDecHandle != NULL) {
            DecodeClose(_videoDecHandle);
            _videoDecHandle = NULL;
        }

        if (_videoDecHandle == NULL || isInit) {
            DEC_CREATE_PARAM param;
            param.nMaxImgWidth = video->width;
            param.nMaxImgHeight = video->height;
            param.coderID = CODER_H264;
            param.method = IDM_SW;
            param.avCodecID = self.codecID;
//            param.avCodecID = AV_CODEC_ID_NONE; //测试播放器解码异常情况的回调
            LogCodecDiag(@"DecodeCreate", 0, self.codecID);

            _videoDecHandle = DecodeCreate(&param);
            if (_videoDecHandle == NULL) {
                [self notifyDecodeError:@"FFmpeg解码器创建失败"];
                return;
            }
        }

        DEC_DECODE_PARAM param;
        param.pStream = video->pBuf;
        param.nLen = video->frameLen;
        param.need_sps_head = false;
        param.skip_rgb_convert = true;

        DVDVideoPicture picture;
        memset(&picture, 0, sizeof(picture));
        picture.iDisplayWidth = video->width;
        picture.iDisplayHeight = video->height;

        int nRet = DecodeVideo(_videoDecHandle, &param, &picture);

        if (nRet < 0) {
            [self notifyDecodeError:@"FFmpeg解码失败"];
            return;
        }

        if (nRet) {
            @autoreleasepool {
                if (_lastVideoFramePosition == 0) {
                    _lastVideoFramePosition = video->timeStamp;
                }

                CGFloat duration = (video->timeStamp - _lastVideoFramePosition) / 1000.0;
                if (duration >= 1.0 || duration <= -1.0) {
                    duration = 0.02;
                }

                KxVideoFrameYUV *frame = [KxVideoFrameYUV handleVideoFrame:param.pFrame videoCodecCtx:param.pCodecCtx];
                frame.width = param.nOutWidth;
                frame.height = param.nOutHeight;
                frame.position = video->timeStamp / 1000.0;
                frame.duration = duration;

                _lastVideoFramePosition = video->timeStamp;

                if (self.frameOutputBlock) {
                    self.frameOutputBlock(frame, (Easy_U32)(video->frameLen));
                }
            }
        }
    } @catch (NSException *exception) {
        [self notifyDecodeError:[NSString stringWithFormat:@"FFmpeg解码异常:%@", exception.reason ?: @"unknown"]];
    }
}

#pragma mark - 解码音频帧

- (void)decodeAudioFrame:(FrameInfo *)audio {
    if (_audioDecHandle == NULL) {
        _audioDecHandle = EasyAudioDecodeCreate(_mediaInfo.u32AudioCodec,
                                                _mediaInfo.u32AudioSamplerate,
                                                _mediaInfo.u32AudioChannel,
                                                16);
    }

    if (_audioDecHandle == NULL) {
        return;
    }

    std::vector<unsigned char> pcmBuf(256 * 1024);
    int pcmLen = 0;
    int ret = EasyAudioDecode((EasyAudioHandle *)_audioDecHandle,
                              audio->pBuf,
                              0,
                              audio->frameLen,
                              pcmBuf.data(),
                              (int)pcmBuf.size(),
                              &pcmLen);
    if (ret == 0 && pcmLen > 0) {
        @autoreleasepool {
            KxAudioFrame *frame = [[KxAudioFrame alloc] init];
            frame.samples = [NSData dataWithBytes:pcmBuf.data() length:pcmLen];
            frame.position = audio->timeStamp / 1000.0;
            if (self.frameOutputBlock) {
                self.frameOutputBlock(frame, (Easy_U32)frame.samples.length);
            }
        }
    }
}

- (void)removeVideoFrameSet {
    // ------------------ frameSet ------------------
    pthread_mutex_lock(&mutexVideoFrame);

    std::set<FrameInfo *>::iterator videoItem = videoFrameSet.begin();
    while (videoItem != videoFrameSet.end()) {
        FrameInfo *frameInfo = *videoItem;
        delete []frameInfo->pBuf;
        delete frameInfo;

        videoItem++;   // 很关键, 主动前移指针
    }
    videoFrameSet.clear();

    pthread_mutex_unlock(&mutexVideoFrame);
}

- (void)removeAudioFrameSet {
    pthread_mutex_lock(&mutexAudioFrame);

    std::set<FrameInfo *>::iterator it = audioFrameSet.begin();
    while (it != audioFrameSet.end()) {
        FrameInfo *frameInfo = *it;
        delete []frameInfo->pBuf;
        delete frameInfo;

        it++;   // 很关键, 主动前移指针
    }
    audioFrameSet.clear();

    pthread_mutex_unlock(&mutexAudioFrame);
}

- (void) removeRecordFrameSet {
    // ------------------ recordVideoFrameSet ------------------
    pthread_mutex_lock(&mutexRecordVideoFrame);
    std::set<FrameInfo *>::iterator videoItem = recordVideoFrameSet.begin();
    while (videoItem != recordVideoFrameSet.end()) {
        FrameInfo *frameInfo = *videoItem;
        delete []frameInfo->pBuf;
        delete frameInfo;
        videoItem++;
    }
    recordVideoFrameSet.clear();
    pthread_mutex_unlock(&mutexRecordVideoFrame);

    // ------------------ recordAudioFrameSet ------------------
    pthread_mutex_lock(&mutexRecordAudioFrame);
    std::set<FrameInfo *>::iterator audioItem = recordAudioFrameSet.begin();
    while (audioItem != recordAudioFrameSet.end()) {
        FrameInfo *frameInfo = *audioItem;
        delete []frameInfo->pBuf;
        delete frameInfo;
        audioItem++;
    }
    recordAudioFrameSet.clear();
    pthread_mutex_unlock(&mutexRecordAudioFrame);
}

#pragma mark - 录像

/**
 注册av_read_frame的回调函数

 @param opaque URLContext结构体
 @param buf buf
 @param buf_size buf_size
 @return 0
 */
int read_video_packet(void *opaque, uint8_t *buf, int buf_size) {
    pthread_mutex_lock(&mutexRecordVideoFrame);

    int count = (int) recordVideoFrameSet.size();
    if (count == 0) {
        pthread_mutex_unlock(&mutexRecordVideoFrame);
        return 0;
    }

    FrameInfo *frame = *(recordVideoFrameSet.begin());
    recordVideoFrameSet.erase(recordVideoFrameSet.begin());

    pthread_mutex_unlock(&mutexRecordVideoFrame);

    int frameLen = frame->frameLen;
    memcpy(buf, frame->pBuf, frameLen);

    delete []frame->pBuf;
    delete frame;

    return frameLen;
}

/**
 注册av_read_frame的回调函数

 @param opaque URLContext结构体
 @param buf buf
 @param buf_size buf_size
 @return 0
 */
int read_audio_packet(void *opaque, uint8_t *buf, int buf_size) {
    pthread_mutex_lock(&mutexRecordAudioFrame);

    int count = (int) recordAudioFrameSet.size();
    if (count == 0) {
        pthread_mutex_unlock(&mutexRecordAudioFrame);
        return 0;
    }

    FrameInfo *frame = *(recordAudioFrameSet.begin());
    recordAudioFrameSet.erase(recordAudioFrameSet.begin());

    pthread_mutex_unlock(&mutexRecordAudioFrame);

    int frameLen = frame->frameLen;
    memcpy(buf, frame->pBuf, frameLen);

    delete []frame->pBuf;
    delete frame;

    return frameLen;
}

#pragma mark - private method

// 获得媒体类型
- (void)recvMediaInfo:(EASY_MEDIA_INFO_T *)info {
    _mediaInfo = *info;

    enum AVCodecID mappedCodecID = EasyVideoCodecToAVCodecID(info->u32VideoCodec);
    if (mappedCodecID != AV_CODEC_ID_NONE) {
        self.codecID = mappedCodecID;
    }
    [self reportDecodeInfoIfNeeded];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.fetchMediaInfoSuccessBlock) {
            self.fetchMediaInfoSuccessBlock();
        }
    });
}

- (void)pushFrame:(char *)pBuf frameInfo:(EASY_FRAME_INFO *)info type:(int)type {
    if (!_running || pBuf == NULL || info->length == 0) {
        return;
    }

    FrameInfo *frameInfo = (FrameInfo *)malloc(sizeof(FrameInfo));
    frameInfo->type = type;
    frameInfo->frameLen = info->length;
    frameInfo->pBuf = new unsigned char[info->length];
    frameInfo->width = info->width;
    frameInfo->height = info->height;
    // 毫秒为单位(1秒=1000毫秒 1秒=1000000微秒)
    frameInfo->timeStamp = info->timestamp_sec * 1000 + info->timestamp_usec / 1000.0;
    mNewestStample = frameInfo->timeStamp;

    memcpy(frameInfo->pBuf, pBuf, info->length);

    // 根据时间戳排序
    if (type == EASY_SDK_AUDIO_FRAME_FLAG) {
        pthread_mutex_lock(&mutexAudioFrame);    // 加锁
        audioFrameSet.insert(frameInfo);
        pthread_mutex_unlock(&mutexAudioFrame);  // 解锁
    } else {
        pthread_mutex_lock(&mutexVideoFrame);    // 加锁
        videoFrameSet.insert(frameInfo);
        pthread_mutex_unlock(&mutexVideoFrame);  // 解锁
    }

    // 录像：保存视频的内容
    if (_recordFilePath) {

        if (isKeyFrame == 0) {
            if (info->type == EASY_SDK_VIDEO_FRAME_I) {// 视频帧类型
                isKeyFrame = 1;

                dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
                dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, NULL);
                dispatch_after(time, queue, ^{
                    // 开始录像
                    *stopRecord = 0;
                    muxer([self.recordFilePath UTF8String], stopRecord, read_video_packet, read_audio_packet);
                });
            }
        }

        if (isKeyFrame == 1) {
            FrameInfo *frame = (FrameInfo *)malloc(sizeof(FrameInfo));
            frame->type = type;
            frame->frameLen = info->length;
            frame->pBuf = new unsigned char[info->length];
            frame->width = info->width;
            frame->height = info->height;
            frame->timeStamp = info->timestamp_sec * 1000 + info->timestamp_usec / 1000.0;

            memcpy(frame->pBuf, pBuf, info->length);

            if (type == EASY_SDK_AUDIO_FRAME_FLAG) {
                pthread_mutex_lock(&mutexRecordAudioFrame);    // 加锁
                recordAudioFrameSet.insert(frame);// 根据时间戳排序
                pthread_mutex_unlock(&mutexRecordAudioFrame);  // 解锁
            }

            if (type == EASY_SDK_VIDEO_FRAME_FLAG &&    // EASY_SDK_VIDEO_FRAME_FLAG视频帧标志
                info->codec == EASY_SDK_VIDEO_CODEC_H264) { // H264视频编码
                pthread_mutex_lock(&mutexRecordVideoFrame);    // 加锁
                recordVideoFrameSet.insert(frame);// 根据时间戳排序
                pthread_mutex_unlock(&mutexRecordVideoFrame);  // 解锁
            }
        }
    }
}

#pragma mark - HWVideoDecoderDelegate

- (void)hwVideoDecoder:(HWVideoDecoder *)decoder didFailWithMessage:(NSString *)message {
    [self notifyDecodeError:message.length ? message : @"硬件解码失败"];
}

-(void) getDecodePictureData:(KxVideoFrame *)frame  length:(unsigned int) length {
    if (previousStampUs > 0) {
        CGFloat tsDuration = (lastFrameStampUs - previousStampUs) / 1000.0;
        if (tsDuration > 0 && tsDuration < 1.0) {
            frame.duration = tsDuration;
        }
    }

    if (self.frameOutputBlock) {
        frame.position = lastFrameStampUs / 1000.0;
        self.frameOutputBlock(frame, length);
    }

    // 帧里面有个timestamp 是当前帧的时间戳， 先获取下系统时间A，然后解码播放，解码后获取系统时间B， B-A就是本次的耗时。sleep的时长就是 当期帧的timestamp  减去 上一个视频帧的timestamp 再减去 这次的耗时
    long decodeSpend = (long) [[NSDate dateWithTimeIntervalSinceNow:0] timeIntervalSince1970] * 1000 - decodeBegin;

    if (previousStampUs != 0) {
        long sleepTime = (lastFrameStampUs - previousStampUs - decodeSpend) * 1000;
        if (sleepTime > 100000) {
            NSLog(@"sleep time.too long:%ld", sleepTime);
            sleepTime = 100000;
        }

        if (sleepTime > 0) {
            sleepTime %= 100000;

            // 设置缓存的时间戳
            long cache = (mNewestStample - lastFrameStampUs) * 1000;

            hwSleepTime = [self fixSleepTime:sleepTime totalTimestampDifferUs:cache delayUs:0];
        }
    }

    previousStampUs = lastFrameStampUs;
}

-(void) getDecodePixelData:(CVImageBufferRef)frame {
    NSLog(@"--> %@", frame);
}

#pragma mark - getter/setter

- (EASY_MEDIA_INFO_T)mediaInfo {
    return _mediaInfo;
}

// 设置录像的路径
- (void) setRecordFilePath:(NSString *)recordFilePath {
    if ((_recordFilePath) && (!recordFilePath)) {
        _recordFilePath = recordFilePath;

        *stopRecord = 1;
        muxer(NULL, stopRecord, read_video_packet, read_audio_packet);
        isKeyFrame = 0;
    }

    _recordFilePath = recordFilePath;
}

/**
 该方法主要是播放器上层用于缓存流媒体数据，使播放更加的平滑(https://blog.csdn.net/jinlong0603/article/details/85041569)

 @param sleepTimeUs 当前帧时间戳与前一帧时间戳的差值并去除了解码的耗时（单位是微秒）
 @param total 当前中缓存的时间长度（单位是微秒）
 @param delayUs 个人设置的缓存的总大小：
 硬解码，设置的默认缓存为100000微秒，软解码，设置的是50000微秒。
 如果想将延迟降到极限，就调整第三个参数为0，这样即不希望上层缓存数据，尽快的解码上屏显示。
 @return 延迟时间戳
 */
- (float) fixSleepTime:(float)sleepTimeUs totalTimestampDifferUs:(float)total delayUs:(float)delayUs {
    if (total < 0) {
        NSLog(@"totalTimestampDifferUs is:%f, this should not be happen.", total);
        total = 0;
    }

    double dValue = ((double) (delayUs - total)) / 1000000;
    double radio = exp(dValue);
    double r = sleepTimeUs * radio + 0.5f;

    // NSLog(@"===>> %ff, %f, %f->%f微秒", sleepTimeUs, total, delayUs, r);

    return (long) r;
}

@end
