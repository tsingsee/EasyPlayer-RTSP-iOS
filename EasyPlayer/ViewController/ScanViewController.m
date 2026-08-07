//
//  ScanViewController.m
//  EasyPlayerRTSP
//
//  Created by leo on 2019/4/26.
//  Copyright © 2019年 cs. All rights reserved.
//

#import "ScanViewController.h"
#import <AVFoundation/AVFoundation.h>

@interface ScanViewController ()<AVCaptureMetadataOutputObjectsDelegate>

@property (weak, nonatomic) IBOutlet UIView *contentView;
@property (weak, nonatomic) IBOutlet UIView *scanFrameView;

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *videoPreviewLayer;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, strong) CALayer *scanLayer;

@property (nonatomic, strong) NSTimer *timer;

@property (nonatomic, assign) BOOL isReading;

@end

@implementation ScanViewController

- (instancetype) initWithStoryboard {
    return [[UIStoryboard storyboardWithName:@"Main" bundle:nil] instantiateViewControllerWithIdentifier:@"ScanViewController"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.contentView.backgroundColor = [UIColor clearColor];
    self.contentView.hidden = YES;
    
    [self loadScanView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updatePreviewLayout];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [self stopRunning];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (void)loadScanView {
    //1.初始化捕捉设备（AVCaptureDevice），类型为AVMediaTypeVideo
    AVCaptureDevice *captureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    //2.用captureDevice创建输入流
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:nil];
    //3.创建媒体数据输出流
    _metadataOutput = [[AVCaptureMetadataOutput alloc] init];
    //4.实例化捕捉会话
    _captureSession = [[AVCaptureSession alloc] init];
    //4.1.将输入流添加到会话
    [_captureSession addInput:input];
    //4.2.将媒体输出流添加到会话中
    [_captureSession addOutput:_metadataOutput];
    //5.设置代理 在主线程里刷新
    [_metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    //5.2.设置输出媒体数据类型为QRCode
    [_metadataOutput setMetadataObjectTypes:@[AVMetadataObjectTypeQRCode]];
    //6.实例化预览图层，铺满整页（勿用 16x16 的 contentView）
    _videoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_captureSession];
    [_videoPreviewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    [self.view.layer insertSublayer:_videoPreviewLayer atIndex:0];
    
    _scanLayer = [[CALayer alloc] init];
    _scanLayer.frame = CGRectMake(0, 0, 1, 1);
    _scanLayer.backgroundColor = UIColorFromRGB(SelectBtnColor).CGColor;
    [self.scanFrameView.layer addSublayer:_scanLayer];
    
    [self updatePreviewLayout];
    [self startRunning];
}

- (void)updatePreviewLayout {
    if (!_videoPreviewLayer) {
        return;
    }
    
    _videoPreviewLayer.frame = self.view.layer.bounds;
    
    UIView *scanBox = self.scanFrameView;
    if (scanBox.bounds.size.width > 0 && scanBox.bounds.size.height > 0) {
        CGRect scanRectInView = [scanBox convertRect:scanBox.bounds toView:self.view];
        if (_metadataOutput && _videoPreviewLayer) {
            _metadataOutput.rectOfInterest = [_videoPreviewLayer metadataOutputRectOfInterestForRect:scanRectInView];
        }
        if (_scanLayer) {
            _scanLayer.frame = CGRectMake(0, 0, scanBox.bounds.size.width, 1);
        }
    }
}

- (void)startRunning {
    if (self.captureSession) {
        self.isReading = YES;
        [self.captureSession startRunning];
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(moveUpAndDownLine) userInfo:nil repeats: YES];
    }
}

- (void)stopRunning {
    if ([_timer isValid]) {
        [_timer invalidate];
        _timer = nil ;
    }
    
    [self.captureSession stopRunning];
    [_scanLayer removeFromSuperlayer];
    [_videoPreviewLayer removeFromSuperlayer];
}

- (void)moveUpAndDownLine {
    CGFloat scanHeight = self.scanFrameView.bounds.size.height;
    if (scanHeight <= 0) {
        return;
    }
    
    CGRect frame = self.scanLayer.frame;
    if (frame.origin.y >= scanHeight - 1) {
        frame.origin.y = 0;
        self.scanLayer.frame = frame;
    } else {
        frame.origin.y += 5;
        [UIView animateWithDuration:0.2 animations:^{
            self.scanLayer.frame = frame;
        }];
    }
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    // 判断是否有数据
    if (!_isReading) {
        return;
    }
    if (metadataObjects.count > 0) {
        _isReading = NO;
        AVMetadataMachineReadableCodeObject *metadataObject = metadataObjects[0];
        NSString *result = metadataObject.stringValue;
        
        [self.subject sendNext:result];
        
        [self close:nil];
    }
}


- (IBAction)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (RACSubject *) subject {
    if (!_subject) {
        _subject = [RACSubject subject];
    }
    
    return _subject;
}

@end
