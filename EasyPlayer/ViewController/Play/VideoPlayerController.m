
#import "VideoPlayerController.h"
#import "RecordViewController.h"
#import "UIColor+HexColor.h"
#import "VideoPanel.h"
#import "AudioManager.h"
#import "EasyRTSPEventCode.h"
#import "PlayerResultCode.h"

@interface VideoPlayerController () <VideoPanelDelegate>

@property (nonatomic, retain) NSArray *urlModels;
@property (nonatomic, strong) VideoPanel *panel;

@property (nonatomic, assign) BOOL statusBarHidden;
@property (nonatomic, assign) CGRect panelFrame;
@property (nonatomic, assign) BOOL didLogFirstFrameCost;

@end

@implementation VideoPlayerController

#pragma mark - init

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 最多是9分屏，最多9个URL
    _urlModels = @[ self.model ];
    
    if ([[UIDevice currentDevice].systemVersion floatValue] >=7.0) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    
    self.navigationItem.title = self.model.url;
    self.view.backgroundColor = [UIColor colorFromHex:0xfefefe];
    
    [[AudioManager sharedInstance] activateAudioSession];
    
    self.panelFrame = CGRectMake(0, 0, EasyScreenWidth, EasyScreenWidth);
    
    [self createStatusView];
    [self addStatus:@"页面就绪"];
    
    self.panel = [[VideoPanel alloc] initWithFrame:self.panelFrame];
    self.panel.delegate = self;
    [self.view addSubview:self.panel];
    [self.panel setLayout:IVL_One currentURL:nil URLs:_urlModels];
    
    [self regestAppStatusNotification];
    
    // 监听屏幕方向
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    // 当手机的重力感应打开的时候, 如果用户旋转手机, 系统会抛发UIDeviceOrientationDidChangeNotification 事件
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
    
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"flie"] style:UIBarButtonItemStyleDone target:self action:@selector(fileList)];
    self.navigationItem.rightBarButtonItem = btn;
}

- (void)createStatusView{

    CGFloat y =
    CGRectGetMaxY(self.panelFrame) + 10;


    self.statusView =[[UITextView alloc] initWithFrame:
     CGRectMake(10, y, EasyScreenWidth - 20, 200)];


    self.statusView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];


    self.statusView.textColor = UIColor.greenColor;


    self.statusView.font = [UIFont systemFontOfSize:14];


    self.statusView.editable = NO;


    [self.view addSubview:self.statusView];

}

- (void)addStatusCode:(NSInteger)code msg:(NSString *)msg
{
    [self addStatus:[NSString stringWithFormat:@"code:%ld mag:%@", (long)code, msg ?: @""]];
}

- (void)addStatus:(NSString *)msg
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];

    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

    NSString *time =
    [formatter stringFromDate:[NSDate date]];


    NSString *line =
    [NSString stringWithFormat:@"%@ %@", time, msg];


    NSString *old = self.statusView.text ?: @"";
    if (old.length == 0) {
        self.statusView.text = line;
    } else {
        self.statusView.text = [old stringByAppendingFormat:@"\n%@", line];
    }


    // 自动滚动到底部
    NSRange range =
    NSMakeRange(self.statusView.text.length, 0);

    [self.statusView scrollRangeToVisible:range];
}

- (void) viewWillAppear:(BOOL)animated {
    [self.panel restore];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [self normalScreenWithDuration:0];// 回归竖屏
    
    [self.panel stopAll];
}

- (void)dealloc {
    [[AudioManager sharedInstance] deactivateAudioSession];
    [self removeAppStutusNotification];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void) fileList {
    RecordViewController *controllr = [[RecordViewController alloc] initWithStoryborad];
    controllr.url = self.model.url;
    [self.navigationController pushViewController:controllr animated:YES];
}

#pragma mark - 根据屏幕状态，旋转UI

- (void)orientationChanged:(NSNotification *)notification {
    // 获取屏幕的方向
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (orientation == UIDeviceOrientationLandscapeRight) {// 右横屏
        [self crossScreenWithDuration:0.5 isLeftCrossScreen:NO];
        [self.panel changeHorizontalScreen:YES];
    } else if (orientation == UIDeviceOrientationLandscapeLeft) {// 左横屏
        [self crossScreenWithDuration:0.5 isLeftCrossScreen:YES];
        [self.panel changeHorizontalScreen:YES];
    } else if (orientation == UIDeviceOrientationPortrait) {// 正竖屏
        [self normalScreenWithDuration:0.5];
        [self.panel changeHorizontalScreen:NO];
    }
}

#pragma mark - 横竖屏设置

- (void) crossScreenWithDuration:(NSTimeInterval)duration isLeftCrossScreen:(BOOL)isLeft {
    [UIView animateWithDuration:duration animations:^{
        [self.navigationController setNavigationBarHidden:YES];
        
        [[UIApplication sharedApplication] setStatusBarHidden:YES];
        self.statusBarHidden = NO;
        [self prefersStatusBarHidden];
        
        self.panel.frame = CGRectMake(0, 0, EasyScreenHeight, EasyScreenWidth);
        self.panel.center = self.view.center;
        
        if (isLeft) {
            self.panel.transform = CGAffineTransformMakeRotation(M_PI_2);
        } else {
            self.panel.transform = CGAffineTransformMakeRotation(-M_PI_2);
        }
    }];
}

- (void) normalScreenWithDuration:(NSTimeInterval)duration {
    [UIView animateWithDuration:duration animations:^{
        [self.navigationController setNavigationBarHidden:NO];
        
        [[UIApplication sharedApplication] setStatusBarHidden:NO];
        self.statusBarHidden = YES;
        [self prefersStatusBarHidden];
        
        self.panel.frame = self.panelFrame;
        self.panel.transform = CGAffineTransformIdentity;
    }];
    
    for (VideoView *v in self.panel.resuedViews) {
        v.landspaceButton.selected = NO;
    }
}

#pragma mark - click event

- (void)goBack:(id)sender {
    [self.panel stopAll];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)enterBackground {
    [[AudioManager sharedInstance] deactivateAudioSession];
    [self.panel stopAll];
}

#pragma mark - VideoPanelDelegate

- (void)activeViewDidiUpdateStream:(VideoView *)view {
    
}

- (void)didSelectVideoView:(VideoView *)view {
    BOOL enable = view.videoStatus == Rendering;
    NSLog(@"%d", enable);
}

- (void)activeVideoViewRendStatusChanged:(VideoView *)view {
    // 状态日志由 RTSP 事件回调驱动，见 activeVideoView:didReceiveRTSPEvent:message:
}

- (void)activeVideoView:(VideoView *)view didReceiveRTSPEvent:(NSInteger)eventCode message:(NSString *)message data:(NSInteger)data count:(NSInteger)count total:(NSInteger)total {
    switch (eventCode) {
        case EVENT_CODEC_CONNECTING:
            self.didLogFirstFrameCost = NO;
            [self addStatusCode:PLAYER_RESULT_CONNECTING msg:@"连接中"];
            break;
        case EVENT_CODEC_CONNECTED:
            [self addStatusCode:PLAYER_RESULT_CONNECTED msg:@"连接成功"];
            break;
        case EVENT_CODEC_CONNECT_FAIL:
            [self addStatusCode:PLAYER_RESULT_CONNECT_FAIL msg:message.length ? message : @"连接失败"];
            break;
        case EVENT_CODEC_CHANGE_RESOLUTION:
            [self addStatusCode:PLAYER_RESULT_CHANGE_RESOLUTION msg:message.length ? message : @"切换分辨率"];
            break;
        case EVENT_CODEC_STREAM_ABORT:
            [self addStatusCode:PLAYER_RESULT_STREAM_ABORT msg:message.length ? message : @"流中断"];
            break;
        case EVENT_CODEC_RECONN:
            self.didLogFirstFrameCost = NO;
            [self addStatusCode:PLAYER_RESULT_RECONN msg:message.length ? message : @"重连中"];
            break;
        case EVENT_CODEC_NO_DATA:
            [self addStatusCode:PLAYER_RESULT_NO_DATA msg:message.length ? message : @"无数据"];
            break;
        case EVENT_CODEC_CONNECT_TIMEOUT:
            [self addStatusCode:PLAYER_RESULT_TIMEOUT msg:message.length ? message : @"超时"];
            break;
        case EVENT_CODEC_EXIT:
            self.didLogFirstFrameCost = NO;
            [self addStatusCode:PLAYER_RESULT_EXIT msg:message.length ? message : @"连接退出"];
            break;
        case EVENT_CODEC_FIRST_FRAME:
            if (!self.didLogFirstFrameCost) {
                self.didLogFirstFrameCost = YES;
                NSInteger ms = data > 0 ? data : (NSInteger)view.firstFrameCostMs;
                [self addStatusCode:PLAYER_RESULT_FIRST_FRAME_TIME
                                msg:[NSString stringWithFormat:@"首帧:%ldms", (long)ms]];
            }
            break;
        case EVENT_CODEC_ERROR:
            [self addStatusCode:PLAYER_RESULT_DECODE_FAIL msg:message.length ? message : @"解码失败"];
            break;
        case EVENT_CODEC_FILE_INFO:
            [self addStatusCode:PLAYER_RESULT_VIDEO_RESOLUTION msg:message.length ? message : @"视频分辨率"];
            break;
        default:
            if (eventCode == PLAYER_RESULT_DECODE_MODE) {
                [self addStatusCode:PLAYER_RESULT_DECODE_MODE msg:message.length ? message : @"解码方式"];
            } else if (eventCode == PLAYER_RESULT_VIDEO_CODEC) {
                [self addStatusCode:PLAYER_RESULT_VIDEO_CODEC msg:message.length ? message : @"视频编码"];
            } else if (eventCode == PLAYER_RESULT_RECONN_COST) {
                [self addStatusCode:PLAYER_RESULT_RECONN_COST
                                msg:[NSString stringWithFormat:@"%ldms 第%ld次", (long)data, (long)count]];
            } else if (eventCode == PLAYER_RESULT_VIDEO_CODEC_UNSUPPORTED) {
                [self addStatusCode:PLAYER_RESULT_VIDEO_CODEC_UNSUPPORTED msg:message.length ? message : @"不支持该视频编码"];
            } else if (eventCode == PLAYER_RESULT_AUDIO_CODEC_UNSUPPORTED) {
                [self addStatusCode:PLAYER_RESULT_AUDIO_CODEC_UNSUPPORTED msg:message.length ? message : @"不支持该音频格式"];
            } else if (eventCode == PLAYER_RESULT_PLAY_SUCCESS_RATE) {
                NSString *msg = message.length
                    ? message
                    : [NSString stringWithFormat:@"{success:%ld%%,s_count:%ld,total:%ld}",
                       (long)data, (long)count, (long)total];
                [self addStatusCode:PLAYER_RESULT_PLAY_SUCCESS_RATE msg:msg];
            }
            break;
    }
}

- (void)videoViewWillAddNewRes:(VideoView *)view index:(int)index {
    
}

- (void)videoViewWillAnimateToFullScreen:(VideoView *)view {
    [self.panel setLayout:IVL_One currentURL:view.url URLs:_urlModels];// 先转成1分频
    [self crossScreenWithDuration:0.5 isLeftCrossScreen:YES];// 再全屏
}

- (void)videoViewWillAnimateToNomarl:(VideoView *)view {
    [self normalScreenWithDuration:0.5];
}

- (void) back {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Notification

- (void)regestAppStatusNotification {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(enterBackground)
                                                 name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(becomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)removeAppStutusNotification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - Notification 实现方法

- (void)becomeActive {
    [[AudioManager sharedInstance] activateAudioSession];
    [self.panel restore];
}

#pragma mark - StatusBar

- (BOOL)prefersStatusBarHidden {
    return self.statusBarHidden;
}

@end
