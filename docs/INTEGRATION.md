# EasyPlayer-RTSP 最简集成（仅播放）

只保留 **拉流 + 解码 + 画面 + 声音** 所需内容。架构说明见 [架构说明.md](架构说明.md)，开发细节见 [DEVELOPMENT.md](DEVELOPMENT.md)。

**要求：** iOS 12.0+、**真机**（`libEasyRTSPClient.a` 无模拟器架构）。

---

## 1. 静态库 `.a` 与头文件

### 1.1 链接 8 个 `.a`

| 文件 | 路径 |
|------|------|
| `libEasyRTSPClient.a` | `EasyPlayer/libEasyRTSPClient/` |
| `libavcodec.a` | `EasyPlayer/ffmpeg/lib/` |
| `libavformat.a` | 同上 |
| `libavutil.a` | 同上 |
| `libavfilter.a` | 同上 |
| `libavdevice.a` | 同上 |
| `libswresample.a` | 同上 |
| `libswscale.a` | 同上 |

Xcode：**Target → Build Phases → Link Binary With Libraries** 全部加入。

### 1.2 头文件路径（不必逐个拷 `.h`）

**Header Search Paths：**

```
$(PROJECT_DIR)/EasyPlayer/libEasyRTSPClient/include
$(PROJECT_DIR)/EasyPlayer/ffmpeg/include
```

**Library Search Paths：**

```
$(PROJECT_DIR)/EasyPlayer/libEasyRTSPClient
$(PROJECT_DIR)/EasyPlayer/ffmpeg/lib
```

业务代码只需在 AppDelegate 里用到：`EasyRTSPClientAPI.h`（内含 `EasyTypes.h` 的 `EASY_RTP_OVER_TCP` 等常量）。

---

## 2. 加入工程的源码（播放最小集）

从 `EasyPlayer/` 拷入并加入 **Compile Sources**：

```
EasyPlayerReader/PlayerDataReader.mm、PlayerDataReader.h
EasyVideoDecoder/VideoDecode.c、VideoDecode.h、HWVideoDecoder.m、HWVideoDecoder.h
EasyAudioDecoder/EasyAudioDecoder.c、EasyAudioDecoder.h、g711.c、g711.h、AACDecoder.c、AACDecoder.h
kxmovie/KxMovieGLView.m、KxMovieGLView.h、KxMovieDecoder.m、KxMovieDecoder.h
Player/VideoView.m、VideoView.h、AudioManager.mm、AudioManager.h、UIColor+HexColor.m、UIColor+HexColor.h
MuxerToVideo/Muxer.c、Muxer.h、MuxerToMP4.c、MuxerToMP4.h
Model/NSUserDefaultsUnit.m、NSUserDefaultsUnit.h、PathUnit.m、PathUnit.h
```

不要拷：`ViewController/`、`Main.storyboard`、扫码/录像列表等 Demo 页面。

---

## 3. 依赖（仅播放相关）

### 3.1 CocoaPods：**不是播放能力必需**

| Pod | 播放是否需要 | 说明 |
|-----|--------------|------|
| **Masonry** | 不改源码则要装 | `VideoView.m` 里按钮/标签布局用了 `mas_makeConstraints` |
| **WHToast** | **不需要** | 只在「截图保存成功」时弹 Toast；与拉流/解码无关 |

若**直接拷贝仓库里的 `VideoView.m` 不改**，Xcode 仍会因 `#import "Masonry.h"`、`#import "WHToast.h"` 报错，此时最少要：

```ruby
pod 'Masonry'
pod 'WHToast'   # 仅为通过编译；不用截图功能也不会用到
```

若希望 **零 CocoaPods**：在 `VideoView.m` 去掉 `WHToast` 的 import 与那一行 `showMessage`；布局改为 `frame` / Auto Layout 代码，去掉 `Masonry` 即可。**最简集成可以不配任何 Pod。**

### 3.2 系统 Framework / 库

在 Target 中链接：

`VideoToolbox`、`CoreMedia`、`CoreVideo`、`OpenGLES`、`AudioToolbox`、`AVFoundation`、`QuartzCore`、`UIKit`、`Foundation`

以及：`libc++.tbd`、`libz.tbd`、`libiconv.tbd`、`libbz2.tbd`

### 3.3 Build Settings

```
IPHONEOS_DEPLOYMENT_TARGET = 12.0
CLANG_CXX_LIBRARY = libc++
ENABLE_BITCODE = NO
OTHER_LDFLAGS 含 -ObjC
```

---

## 4. Info.plist（仅播放）

只加 ATS，允许访问 RTSP（内网常用）：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

**不需要** 相机、相册、麦克风权限（纯播放不申请这些）。

---

## 5. 最简播放代码

### 5.1 AppDelegate（启动时一次）

```objc
#import "PlayerDataReader.h"
#import "EasyRTSPClientAPI.h"
#import "NSUserDefaultsUnit.h"

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [PlayerDataReader startUp];
    EasyRTSP_Activate("EasyPlayer key is free!");

    [NSUserDefaultsUnit setAutoAudio:YES];  // 收到流后自动出声
    return YES;
}
```

### 5.2 播放页

```objc
#import "VideoView.h"
#import "AudioManager.h"
#import "EasyRTSPClientAPI.h"

@interface PlayerVC ()
@property (nonatomic, strong) VideoView *player;
@end

@implementation PlayerVC

- (void)viewDidLoad {
    [super viewDidLoad];

    self.player = [[VideoView alloc] initWithFrame:CGRectMake(0, 100, self.view.bounds.size.width, 300)];
    self.player.url = @"rtsp://user:pass@192.168.1.100:554/stream";
    self.player.transportMode = EASY_RTP_OVER_TCP;
    self.player.sendOption = 0x01;
    self.player.useHWDecoder = YES;
    [self.view addSubview:self.player];

    [[AudioManager sharedInstance] activateAudioSession];
    [self.player startPlay];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player stopPlay];
}

- (void)dealloc {
    [[AudioManager sharedInstance] deactivateAudioSession];
}

@end
```

### 5.3 常用参数

| 属性 | 说明 |
|------|------|
| `url` | RTSP 地址 |
| `transportMode` | `EASY_RTP_OVER_TCP` 或 `EASY_RTP_OVER_UDP` |
| `sendOption` | `0x01` OPTIONS 心跳；`0x00` 不发 |
| `useHWDecoder` | `YES` 硬解，`NO` 软解 |

离开页面务必 `[player stopPlay]`。

---

## 检查清单

- [ ] 8 个 `.a` + 上节源码已加入 Target  
- [ ] Header / Library Search Paths 已设  
- [ ] 未改 `VideoView` 时已装 Masonry（+ WHToast 仅过编译）；或已去掉二者依赖  
- [ ] Info.plist 已加 ATS  
- [ ] `startUp` + `Activate` 在 `startPlay` 之前  
- [ ] 真机测试  

---

*对应 libEasyRTSPClient v3.0.19.0415 / iOS 12.0+*
