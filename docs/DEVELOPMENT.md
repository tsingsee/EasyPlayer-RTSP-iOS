# EasyPlayer-RTSP iOS 开发文档

本文档面向需要在本地编译、二次开发或集成 EasyPlayer-RTSP iOS 播放能力的开发者。  
**架构总览与模块职责**见 [架构说明.md](架构说明.md)。

## 1. 项目概述

EasyPlayer-RTSP iOS 是由 [EasyDarwin](http://www.easydarwin.org) 团队维护的 RTSP 流媒体播放器示例应用，支持：

| 类别 | 支持项 |
|------|--------|
| 视频编码 | H.264、H.265、MPEG4、MJPEG |
| 音频编码 | G711A、G711U、G726、AAC |
| 传输 | RTSP over TCP / UDP |
| 解码 | VideoToolbox 硬解、FFmpeg 软解 |
| 业务 | 直播、多路分屏、录像、截图、静音 |

- **应用版本**：1.9.1（`MARKETING_VERSION`）
- **最低系统**：iOS 12.0
- **Bundle ID**：`org.easydarwin.easyplayer`
- **RTSP SDK**：`libEasyRTSPClient` v3.0.19.0415

## 2. 环境要求

| 工具 | 说明 |
|------|------|
| macOS | 建议与 Xcode 版本匹配的系统 |
| Xcode | 能编译 iOS 12+ 的版本（建议 Xcode 14+） |
| CocoaPods | 依赖管理，`pod install` 必需 |
| 真机 / 模拟器 | 播放 RTSP 需网络；硬解建议在真机验证 |

## 3. 快速开始

### 3.1 克隆与依赖

```bash
git clone <仓库地址>
cd EasyPlayer-RTSP-iOS
pod install
```

> `Podfile` 的 `post_install` 会为 iOS 18 自动修补 YYKit 的 SQLite 关闭崩溃（`YYKVStorage.m`）。若 `pod install` 后看到 `Applied YYKit sqlite finalize fix.` 属正常。

### 3.2 打开工程

**务必使用 Workspace，不要直接打开 `.xcodeproj`：**

```bash
open EasyPlayerRTSP.xcworkspace
```

在 Xcode 中选择 Scheme **`EasyPlayerRTSP`**，连接设备或模拟器后 **Run**。

### 3.3 首次运行

- `AppDelegate` 会在无本地流地址时写入一条默认 RTSP URL（可按需修改或删除）。
- 启动时调用 `EasyRTSP_Activate` 激活 RTSP 库；导航栏图标反映授权剩余天数。
- `NSAppTransportSecurity` 已允许任意 HTTP/RTSP 加载，便于内网调试。

## 4. 工程结构

```
EasyPlayer-RTSP-iOS/
├── EasyPlayerRTSP.xcworkspace    # 主入口（含 Pods）
├── EasyPlayerRTSP.xcodeproj
├── Podfile                       # 第三方依赖
├── Pods/
└── EasyPlayer/                   # 应用与播放核心源码
    ├── Main/                     # AppDelegate、Info.plist、main.m
    ├── ViewController/           # UI 页面
    │   ├── RootViewController    # 首页流列表
    │   ├── Play/                 # 单路播放、分屏
    │   ├── Record/               # 录像/截图列表与回放
    │   └── Setting/              # 设置、关于
    ├── View/                     # VideoPanel、VideoCell 等
    ├── Player/                   # VideoView、AudioManager
    ├── EasyPlayerReader/         # PlayerDataReader（拉流+解码调度）
    ├── EasyVideoDecoder/         # FFmpeg 软解 + VideoToolbox 硬解
    ├── EasyAudioDecoder/         # G711 等音频解码
    ├── kxmovie/                  # OpenGL 渲染（KxMovieGLView）
    ├── MuxerToVideo/             # 录像封装 MP4
    ├── Model/                    # URLModel、持久化、路径
    ├── libEasyRTSPClient/        # RTSP 静态库与头文件
    │   ├── libEasyRTSPClient.a
    │   └── include/
    │       ├── EasyRTSPClientAPI.h
    │       └── EasyTypes.h
    └── ffmpeg/                   # 预编译 FFmpeg 静态库与头文件
        ├── lib/*.a
        └── include/
```

### 4.1 `libEasyRTSPClient.a`（RTSP 拉流静态库）

与 CocoaPods **无关**，源码在仓库内以**预编译 `.a`** 形式提供，负责 RTSP 连接、收流、解复用，通过回调把**未解码**的音视频帧交给上层；**解码与渲染不在此库内**。

| 项 | 说明 |
|----|------|
| 路径 | `EasyPlayer/libEasyRTSPClient/libEasyRTSPClient.a` |
| 头文件 | `EasyPlayer/libEasyRTSPClient/include/EasyRTSPClientAPI.h`、`EasyTypes.h` |
| 版本 | `libEasyRTSPClient v3.0.19.0415`（见 `EasyRTSPClientAPI.h` 中 `RTSP_PROG_NAME`） |
| 体积 / 架构 | 约 21MB；Fat 库：**arm64**、**armv7**（真机）；**不含 x86_64 模拟器切片** |
| 链接方式 | Target → **Frameworks** 链入 `libEasyRTSPClient.a`；`LIBRARY_SEARCH_PATHS` 含 `$(PROJECT_DIR)/EasyPlayer/libEasyRTSPClient` |

**导出的 C API（库内符号）：**

| 函数 | 本工程调用位置 |
|------|----------------|
| `EasyRTSP_Activate` | `AppDelegate.m`（启动时授权） |
| `EasyRTSP_Init` | `PlayerDataReader.mm` → `initRtspHandle` |
| `EasyRTSP_SetCallback` | 同上 / `stop` 时置 `NULL` |
| `EasyRTSP_OpenStream` | 同上（URL、`transportMode`、`sendOption` 来自 `VideoView`） |
| `EasyRTSP_CloseStream` | `PlayerDataReader` → `stop` |
| `EasyRTSP_Deinit` | 头文件有声明；当前工程 **未调用**（只 `CloseStream`） |
| `EasyRTSP_GetErrCode` | 头文件有声明；当前工程 **未调用** |

**回调类型** `RTSPSourceCallBack`：在 `PlayerDataReader.mm` 中实现为 `RTSPDataCallBack`，处理 `EASY_SDK_VIDEO_FRAME_FLAG`、`EASY_SDK_AUDIO_FRAME_FLAG`、`EASY_SDK_MEDIA_INFO_FLAG` 等（常量定义在 `EasyTypes.h`）。

**与播放栈的关系：**

```
libEasyRTSPClient.a  →  编码帧 + 媒体信息
        ↓
PlayerDataReader.mm  →  队列、线程、录像缓存
        ↓
VideoDecode.c / HWVideoDecoder / EasyAudioDecoder  →  解码
        ↓
VideoView + KxMovieGLView + AudioManager  →  显示与播放
```

**集成到新 Target 时需同步：**

1. 将 `libEasyRTSPClient/` 目录（含 `.a` 与 `include/`）加入工程；
2. `LIBRARY_SEARCH_PATHS`：`$(PROJECT_DIR)/EasyPlayer/libEasyRTSPClient`；
3. `HEADER_SEARCH_PATHS`：`$(PROJECT_DIR)/EasyPlayer/libEasyRTSPClient/include`（本工程 Target 通过 Xcode 工程组引用头文件；若 `#include "EasyRTSPClientAPI.h"` 报找不到，请显式加上此项）；
4. 链入 `libEasyRTSPClient.a`，并保留与 FFmpeg 等相同的系统库（网络相关依赖由静态库内部链接，一般无需额外 `-l`）。

**注意：** 库为闭源二进制，升级需向 EasyDarwin 获取新 `.a` 替换；授权 Key 在 `EasyRTSP_Activate` 中配置。模拟器若链接失败，多为架构不匹配，请用 **真机** 调试 RTSP。

### 4.2 `Pods-EasyPlayerRTSP`（CocoaPods 聚合 Target）

`Pods-EasyPlayerRTSP` **不是**第三方 SDK 名称，而是 CocoaPods 为 `Podfile` 里 `target 'EasyPlayerRTSP'` 自动生成的**聚合 Target**，产物为 `Pods_EasyPlayerRTSP.framework`（几乎无业务代码，用于统一链接与拷贝 Pod）。

| 项 | 说明 |
|----|------|
| 配置 | `Pods/Target Support Files/Pods-EasyPlayerRTSP/Pods-EasyPlayerRTSP.debug.xcconfig`（Release 同理） |
| 主 App 引用 | `EasyPlayerRTSP` Target 的 Base Configuration 指向上述 xcconfig；Frameworks 里链入 `Pods_EasyPlayerRTSP.framework` |
| 构建脚本 | Build Phases → `[CP] Embed Pods Frameworks` 执行 `Pods-EasyPlayerRTSP-frameworks.sh`，把各 Pod 的 `.framework` 打进 App |

**实际包含的 Pod（见 `Podfile.lock`）：**

| Pod | 版本 | 工程中的主要用途 |
|-----|------|------------------|
| Masonry | 1.1.0 | `VideoView`、`VideoPanel`、`VideoCell` 等布局 |
| YYKit | 1.0.9 | `URLUnit` 持久化、`BaseModel` 字典转模型 |
| RTRootNavigationController | 0.8.1 | `AppDelegate` 根导航、`BaseViewController` |
| IQKeyboardManager | 6.5.19 | `AppDelegate` 全局键盘 |
| WHToast | 0.1.0 | `VideoView`、`EditURLViewController` 提示 |
| Bugly | 2.6.1 | `AppDelegate` 崩溃上报（预编译 Framework） |
| ReactiveCocoa | 2.5.2 | `ScanViewController`、`EditURLViewController`、`RecordViewController` |

播放器核心（`libEasyRTSPClient`、`ffmpeg`、`PlayerDataReader`）**不在** `Pods-EasyPlayerRTSP` 内，而在 `EasyPlayer/` 目录由主 Target 直接编译、链接。

维护：修改依赖后执行 `pod install`；不要手改 `Pods-EasyPlayerRTSP` 生成文件。

### 4.3 CocoaPods 依赖一览

与 4.2 相同，完整列表见 `Podfile` / `Podfile.lock`。

## 5. 架构与数据流

### 5.1 分层示意

```mermaid
flowchart TB
    subgraph UI
        VC[ViewController]
        VP[VideoPanel]
        VV[VideoView]
    end
    subgraph Core
        PDR[PlayerDataReader]
        RTSP[libEasyRTSPClient]
        VDec[VideoDecode / HWVideoDecoder]
        ADec[EasyAudioDecoder]
    end
    subgraph Render
        GL[KxMovieGLView]
        AM[AudioManager]
    end
    VC --> VP --> VV
    VV --> PDR
    PDR --> RTSP
    RTSP -->|回调帧| PDR
    PDR --> VDec
    PDR --> ADec
    VDec -->|KxMovieFrame| VV
    ADec -->|PCM| AM
    VV --> GL
```

### 5.2 播放链路（核心）

1. **`VideoView`**：对外播放控件，管理 UI 状态（连接中 / 播放中 / 停止）、录像路径、截图路径。
2. **`PlayerDataReader`**（`PlayerDataReader.mm`）：
   - `EasyRTSP_Init` → `EasyRTSP_SetCallback` → `EasyRTSP_OpenStream` 拉流；
   - 回调 `RTSPDataCallBack` 接收 `EASY_SDK_VIDEO_FRAME_FLAG` / `EASY_SDK_AUDIO_FRAME_FLAG` / `EASY_SDK_MEDIA_INFO_FLAG`；
   - 视频、音频各用独立线程从队列取帧并解码；
   - 通过 `frameOutputBlock` 把 `KxMovieFrame` 交给 `VideoView`。
3. **视频解码**：
   - 硬解：`HWVideoDecoder`（VideoToolbox），默认当设置里 **未** 勾选 FFmpeg 时启用；
   - 软解：`VideoDecode.c`（FFmpeg `libavcodec`），设置中开启「FFmpeg 软解码」时启用。
4. **音频解码**：`EasyAudioDecoder`（G711 等），经 `AudioManager` 播放。
5. **渲染**：`KxMovieGLView`（OpenGL）显示 YUV/RGB 帧；`VideoView` 内定时器做音画同步与追帧。

### 5.3 页面与模块对应

| 页面 | 类 | 说明 |
|------|-----|------|
| 首页流列表 | `RootViewController` | CollectionView 展示已保存的 `URLModel` |
| 单路播放 | `VideoPlayerController` + `VideoPanel` | 1 分屏，`IVL_One` |
| 多分屏 | `SplitScreenViewController` | 4 / 9 分屏，`IVL_Four` / `IVL_Nine` |
| 编辑地址 | `EditURLViewController` | TCP/UDP、心跳等 |
| 扫码 | `ScanViewController` | 添加 RTSP URL |
| 设置 | `SettingViewController` | 自动音频、自动录像、软/硬解 |
| 录像/截图 | `RecordViewController` 等 | 按 URL 分目录存储 |

## 6. 播放器初始化（本仓库实际流程）

**通俗版流程图与参数总表**见 [架构说明.md §2.5](架构说明.md)。本节保留带代码摘录的细查手册。

本工程**不会**在业务层直接调用 `EasyRTSP_Init` / `EasyRTSP_OpenStream`。播放由 **`VideoView` → `PlayerDataReader`** 完成；UI 层通过 **`VideoPanel` + `URLModel`** 触发。下面按本地调用顺序说明。

### 6.1 应用启动：全局只执行一次

在 `AppDelegate` 的 `application:didFinishLaunchingWithOptions:` 中：

| 步骤 | 本地代码 | 作用 |
|------|----------|------|
| 1 | `[PlayerDataReader startUp]` | 调用 `DecodeRegiestAll()`，注册 FFmpeg 软解 |
| 2 | `EasyRTSP_Activate(@"EasyPlayer key is free!")` | 激活 RTSP 库，天数写入 `NSUserDefaultsUnit` |
| 3 | 首次无地址时 `URLUnit addURLModel:` | 写入默认 `URLModel`（可改 `AppDelegate.m` 里的 url） |
| 4 | 首次安装默认 `setFFMpeg:YES`、`setAutoAudio:YES` | 影响后续 `VideoView` 硬解与自动出声 |

```21:36:EasyPlayer/Main/AppDelegate.m
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    if (![URLUnit urlModels]) {
        URLModel *model = [[URLModel alloc] initDefault];
        model.url = @"rtsp://admin:xf1234567@36.34.0.68:19524/Streaming/Channels/101";
        [URLUnit addURLModel:model];
        
        [NSUserDefaultsUnit setFFMpeg:YES];     // 默认软解码
        [NSUserDefaultsUnit setAutoAudio:YES];  // 默认自动播放音频
    }
    
    [PlayerDataReader startUp];
    
    int days = EasyRTSP_Activate("EasyPlayer key is free!");
    // ...
}
```

> 二次开发若自建 `AppDelegate`，**必须在首次 `startPlay` 之前**调用 `[PlayerDataReader startUp]` 和 `EasyRTSP_Activate`。

### 6.2 流地址模型 `URLModel`（播放参数来源）

新建地址应使用 `initDefault`，与编辑页一致：

```13:19:EasyPlayer/Model/URLModel.m
- (instancetype) initDefault {
    if (self = [super init]) {
        self.transportMode = EASY_RTP_OVER_TCP;  // 默认tcp
        self.sendOption = 0x01;     // 默认发送心跳
    }
    return self;
}
```

| 属性 | 写入 `VideoView` 的时机 |
|------|-------------------------|
| `url` | `VideoPanel` 的 `startAll:` 或全屏 `setLayout:currentURL:` |
| `transportMode` / `sendOption` | 同上，见 `VideoPanel.mm` |

列表持久化：`URLUnit`（首页 `RootViewController` 读取）。

### 6.3 页面层：如何挂上播放器

**单路播放（首页点一条流）**

```181:188:EasyPlayer/ViewController/RootViewController.m
-(void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // ...
    VideoPlayerController* pvc = [[VideoPlayerController alloc] init];
    pvc.model = _dataArray[indexPath.row];
    [self.navigationController pushViewController:pvc animated:YES];
}
```

`VideoPlayerController` 在 `viewDidLoad` 里创建 `VideoPanel` 并 **自动开播**（`setLayout` 内部会 `startAll`）：

```35:41:EasyPlayer/ViewController/Play/VideoPlayerController.m
    [[AudioManager sharedInstance] activateAudioSession];
    
    self.panelFrame = CGRectMake(0, 0, EasyScreenWidth, EasyScreenWidth);
    self.panel = [[VideoPanel alloc] initWithFrame:self.panelFrame];
    self.panel.delegate = self;
    [self.view addSubview:self.panel];
    [self.panel setLayout:IVL_One currentURL:nil URLs:_urlModels];
```

**多分屏**：`SplitScreenViewController` 同样创建 `VideoPanel`，`setLayout:IVL_Four` / `IVL_Nine`，预置 9 个 `initDefault` 的 `URLModel`，有 `url` 的格子会开播。

**离开页面停止**：`viewDidDisappear` 中 `[self.panel stopAll]`（单路、分屏一致）。

### 6.4 `VideoPanel`：多路与单路的统一入口

`setLayout:currentURL:URLs:` 布局完成后：

- `currentURL != nil`：全屏单路，只给第一个 `VideoView` 赋 `url` 并激活；
- `currentURL == nil`：调用 **`startAll:`**，对每个有地址的 `VideoView` 赋值并 `startPlay`。

```66:80:EasyPlayer/View/VideoPanel.mm
- (void)startAll:(NSArray<URLModel *> *)urlModels {
    for (int i = 0; i < [_resuedViews count]; i++) {
        URLModel *model = urlModels[i];
        if (!model.url) {
            continue;
        }
        VideoView *videoView = [_resuedViews objectAtIndex:i];
        videoView.url = model.url;
        videoView.transportMode = model.transportMode;
        videoView.sendOption = model.sendOption;
        [videoView startPlay];
    }
}
```

```218:226:EasyPlayer/View/VideoPanel.mm
    if (url) {
        VideoView *view = [_resuedViews firstObject];
        view.landspaceButton.selected = YES;
        view.url = url;
        [self videoViewBeginActive:view];
    } else {
        [self startAll:urlModels];
    }
```

前台恢复：`[panel restore]` 会对状态为 `Stopped` 的 `VideoView` 再次 `startPlay`（`VideoPlayerController` 的 `viewWillAppear`）。

### 6.5 `VideoView`：真正的「开始播放」

`VideoView` 在 `initWithFrame:` 里根据设置决定硬解，**不**在此处拉流：

```81:82:EasyPlayer/Player/VideoView.m
        self.useHWDecoder = ![NSUserDefaultsUnit isFFMpeg];
        self.audioPlaying = YES;
```

业务上调用 **`startPlay`**（面板、播放按钮、恢复播放均走此方法）：

```363:410:EasyPlayer/Player/VideoView.m
- (void)startPlay {
    if (!self.url || self.url.length == 0) {
        return;
    }
    // ... 重置状态、stopPlay、Connecting、显示 loading ...
    _reader = [[PlayerDataReader alloc] initWithUrl:self.url];
    _reader.useHWDecoder = self.useHWDecoder;
    _reader.transportMode = self.transportMode;
    _reader.sendOption = self.sendOption;
    
    if ([NSUserDefaultsUnit isAutoRecord]) {
        _reader.recordFilePath = [PathUnit recordWithURL:_url];
        _recordButton.selected = YES;
    }
    
    _reader.fetchMediaInfoSuccessBlock = ^(void){
        weakSelf.videoStatus = Rendering;
        [weakSelf updateUI];
        [weakSelf presentFrame];
        if ([NSUserDefaultsUnit isAutoAudio]) {
            [weakSelf startAudio];
        }
    };
    
    _reader.frameOutputBlock = ^(KxMovieFrame *frame, unsigned int length) {
        [weakSelf addFrame:frame];
        [weakSelf sendPacket:length];
    };
    [_reader start];
}
```

停止播放：`stopPlay` 异步 `[oldReader stop]` 并清空帧队列（`VideoView.m`）。

### 6.6 `PlayerDataReader`：拉流与解码（内部）

`start` 只启动两个线程，**不在主线程调 RTSP**：

```194:207:EasyPlayer/EasyPlayerReader/PlayerDataReader.mm
- (void)start {
    // ...
    _running = YES;
    self.videoThread = [[NSThread alloc] initWithTarget:self selector:@selector(videoThreadFunc) object:nil];
    [self.videoThread start];
    self.audioThread = [[NSThread alloc] initWithTarget:self selector:@selector(audioThreadFunc) object:nil];
    [self.audioThread start];
}
```

视频线程循环里调用 `initRtspHandle`，此处才对接 `libEasyRTSPClient`（参数来自 `VideoView` 传入的 `url` / `transportMode` / `sendOption`）：

```256:279:EasyPlayer/EasyPlayerReader/PlayerDataReader.mm
- (void) initRtspHandle {
    pthread_mutex_lock(&mutexInit);
    if (rtspHandle == NULL) {
        int ret = EasyRTSP_Init(&rtspHandle);
        // ...
            EasyRTSP_SetCallback(rtspHandle, RTSPDataCallBack);
            ret = EasyRTSP_OpenStream(rtspHandle,
                                      1,
                                      (char *)[self.url UTF8String],
                                      self.transportMode,
                                      EASY_SDK_VIDEO_FRAME_FLAG | EASY_SDK_AUDIO_FRAME_FLAG,
                                      0, 0,
                                      (__bridge void *)self,
                                      1000,     // 长连接自动重连
                                      0,        // 完整帧回调
                                      self.sendOption,
                                      3);
    }
    pthread_mutex_unlock(&mutexInit);
}
```

回调 `RTSPDataCallBack` 入队 → 音视频线程解码 → `frameOutputBlock` 回 `VideoView` → `KxMovieGLView` 渲染 / `AudioManager` 出声。

H265 在设备不支持硬解时会于 `videoThreadFunc` 内强制走软解（见 `PlayerDataReader.mm` 中 `shouldUseHWDecoder` 判断）。

### 6.7 初始化流程总览

```mermaid
sequenceDiagram
    participant App as AppDelegate
    participant VC as VideoPlayerController
    participant Panel as VideoPanel
    participant VV as VideoView
    participant PDR as PlayerDataReader
    participant RTSP as libEasyRTSPClient

    App->>App: startUp + Activate
    VC->>Panel: initWithFrame + setLayout(IVL_One, URLs)
    Panel->>VV: url / transportMode / sendOption
    Panel->>VV: startPlay
    VV->>PDR: alloc initWithUrl + 设置 block
    VV->>PDR: start
    PDR->>PDR: videoThread / audioThread
    PDR->>RTSP: Init + OpenStream
    RTSP-->>PDR: RTSPDataCallBack
    PDR-->>VV: frameOutputBlock
    PDR-->>VV: fetchMediaInfoSuccessBlock
    VV->>VV: presentFrame / startAudio
```

### 6.8 用户设置（影响初始化行为）

| `NSUserDefaultsUnit` | 影响 |
|----------------------|------|
| `isFFMpeg` | `VideoView.useHWDecoder = !isFFMpeg` |
| `isAutoAudio` | 收到媒体信息后是否 `startAudio` |
| `isAutoRecord` | `startPlay` 时是否设置 `reader.recordFilePath` |

设置页：`SettingViewController` 三个 Switch 直接写上述值。

### 6.9 底层 RTSP API（仅供对照，业务请走 6.5–6.6）

头文件：`EasyPlayer/libEasyRTSPClient/include/EasyRTSPClientAPI.h`。  
本仓库仅在 `PlayerDataReader.mm` 的 `initRtspHandle` / `stop` 中调用，**不要在 ViewController 里重复 Init/OpenStream**。

## 7. 录像与截图

| 功能 | 实现要点 | 存储 |
|------|----------|------|
| 截图 | `VideoView` 在播放过程中抓取当前帧 | `PathUnit` 按 URL 建目录 |
| 录像 | `PlayerDataReader` 缓存编码帧，`Muxer.c` 封装 MP4 | `PathUnit recordWithURL:` |
| 自动录像 | 设置页 `isAutoRecord` | 开播时自动写文件 |

临时 H264/AAC 路径：`PathUnit recordH264` / `recordAAC`。

## 8. 链接与编译配置

Xcode Target **EasyPlayerRTSP** 依赖两类本地库 + 一类 Pod 聚合：

| 类型 | 路径 / 产物 | 作用 |
|------|-------------|------|
| RTSP 拉流 | `EasyPlayer/libEasyRTSPClient/libEasyRTSPClient.a` | 仅 RTSP（见 [4.1](#41-libeasyrtspclientartsp-拉流静态库)） |
| 解码 / 封装 | `EasyPlayer/ffmpeg/lib/*.a` | FFmpeg 软解等 |
| UI / 工具 | `Pods_EasyPlayerRTSP.framework` | 聚合 Masonry、YYKit 等（见 [4.2](#42-podseasyplayerrtspcocoapods-聚合-target)） |

**Search Paths（主 Target）：**

- `LIBRARY_SEARCH_PATHS`：`EasyPlayer/ffmpeg/lib`、`EasyPlayer/libEasyRTSPClient`
- `HEADER_SEARCH_PATHS`：`EasyPlayer/ffmpeg/include`（RTSP 头文件见 4.1）
- **系统框架**：`VideoToolbox`、`OpenGLES`、`AudioToolbox`、`AVFoundation` 等（`OTHER_LDFLAGS` + Pods 继承）
- **Objective-C++**：`PlayerDataReader.mm`、`AudioManager.mm` 等需 C++ 运行时

若集成到新 Target，需同步上述路径，并单独链入 `libEasyRTSPClient.a` 与 ffmpeg 静态库，不能只依赖 `Pods_EasyPlayerRTSP.framework`。

## 9. 二次开发指南

### 9.1 与现有 UI 一致：新增/播放一路

与 `RootViewController` → `VideoPlayerController` 相同：

```objc
URLModel *model = [[URLModel alloc] initDefault];
model.url = @"rtsp://user:pass@host:554/stream";
// transportMode、sendOption 已在 initDefault 中设为 TCP + OPTIONS 心跳

VideoPlayerController *pvc = [[VideoPlayerController alloc] init];
pvc.model = model;
[self.navigationController pushViewController:pvc animated:YES];
// viewDidLoad 内 panel setLayout → startAll → startPlay，无需再调 RTSP API
```

多分屏：向 `SplitScreenViewController` 的 `urlModels` 填入 `URLModel` 后 `setLayout:IVL_Four currentURL:nil URLs:`。

### 9.2 不用整套 UI：只嵌一个 `VideoView`

与 `VideoPanel` 里单格逻辑一致：

```objc
// AppDelegate 中已做的全局初始化不能省略
[PlayerDataReader startUp];
EasyRTSP_Activate(@"your-license");

URLModel *model = [[URLModel alloc] initDefault];
model.url = @"rtsp://...";

VideoView *videoView = [[VideoView alloc] initWithFrame:rect];
videoView.url = model.url;
videoView.transportMode = model.transportMode;
videoView.sendOption = model.sendOption;
[parentView addSubview:videoView];

[[AudioManager sharedInstance] activateAudioSession];
[videoView startPlay];

// 销毁或离开界面时
[videoView stopPlay];
[[AudioManager sharedInstance] deactivateAudioSession];
```

不要跳过 `VideoView` 直接 `[[PlayerDataReader alloc] init]`，否则没有 OpenGL 渲染、追帧和工具栏逻辑。

### 9.3 直接改 `PlayerDataReader`（高级）

仅当需要改拉流参数（重连次数、RTP 包模式等）时，修改 `initRtspHandle` 里 `EasyRTSP_OpenStream` 的固定参数；`transportMode` / `sendOption` 仍应由 `VideoView` 传入，与 `EditURLViewController` 保存的 `URLModel` 一致。

### 9.4 修改默认流地址

编辑 `EasyPlayer/Main/AppDelegate.m` 中首次启动写入的 `URLModel`，或通过首页「添加地址」/扫码录入。

### 9.5 更换 Bugly / 授权 Key

- Bugly：`AppDelegate.m` 中 `[Bugly startWithAppId:...]`。
- RTSP：`EasyRTSP_Activate(...)`，商业授权请联系 EasyDarwin。

### 9.6 Storyboard 与资源

- 主界面：`EasyPlayer/Main/Base.lproj/Main.storyboard`
- 启动页：`LaunchScreen.storyboard`
- 图标：`NewIcon.xcassets`、`Assets.xcassets`

## 10. 调试建议

| 现象 | 排查方向 |
|------|----------|
| 黑屏无画面 | URL 是否可达；TCP/UDP 是否与相机一致；查看 `EasyRTSP_OpenStream ret` 日志 |
| 有画面无声音 | 设置里是否关闭自动音频；编码是否为 G711/AAC；`enableAudio` |
| H265 无法硬解 | iOS 11+ 且设备支持 HEVC；否则打开 FFmpeg 软解 |
| 延迟大 | `VideoView` 内追帧逻辑；可减小缓冲（需改 reader/播放器策略） |
| Pod 编译失败 | 删除 `Pods` 与 `Podfile.lock` 后重新 `pod install` |
| iOS 18 崩溃 | 确认 YYKit 补丁已应用（见 `Podfile` post_install） |

控制台关键字：`EasyRTSP_OpenStream`、`Media Info`、`key有效期`。

## 11. 权限说明（Info.plist）

| Key | 用途 |
|-----|------|
| `NSCameraUsageDescription` | 扫码等 |
| `NSMicrophoneUsageDescription` | 音频相关能力说明 |
| `NSPhotoLibraryUsageDescription` | 保存录像/截图到相册 |
| `NSAppTransportSecurity` | 允许非 HTTPS 访问（内网 RTSP） |

## 12. 常见问题

**Q：能否只用模拟器？**  
A：可以编译运行，但 RTSP 拉流、硬解、多路性能建议在真机与目标网络环境下测试。

**Q：`libEasyRTSPClient` 源码在哪？**  
A：仓库内为预编译静态库；完整 SDK 与授权见 [EasyDarwin](http://www.easydarwin.org)。

**Q：与 README 的关系？**  
A：`readme.md` 为产品简介；本文档为开发与架构说明。

## 13. 参考链接

- 项目 README：[readme.md](../readme.md)
- EasyDarwin 社区：http://www.easydarwin.org
- 技术支持：support@EasyDarwin.org
- QQ 交流群：544917793

---

*文档随工程版本更新，当前对应应用版本 1.9.1。*
