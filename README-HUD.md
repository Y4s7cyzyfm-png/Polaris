# Polaris · DarkSword + 悬浮窗移植版

在 Polaris UI 基础上移植 DarkSpeed 的全部能力（内核读写 / RemoteCall / 跨进程），并加入网易云风格的 ImGui 悬浮窗。

## 架构

```
┌─────────────────────────────────────────────────┐
│ 主 App（SwiftUI，Polaris UI 不变）                │
│  1. 「启动内核利用」→ DarkSword ds_run()          │
│     （内核读写与 DarkSpeed 完全同源）              │
│  2. 「载入悬浮窗」→ posix_spawn 自身 "-hud"       │
│     · control/rw 套接字 fd（非 CLOEXEC）          │
│     · DS_KBASE / DS_KSLIDE 环境变量              │
└───────────────────┬─────────────────────────────┘
                    │ fork+exec（persona 提权，非越狱/非巨魔可用）
┌───────────────────▼─────────────────────────────┐
│ HUD 子进程（-hud 参数）                           │
│  · ds_adopt_krw() 接管内核读写（DarkSpeed 同款）   │
│  · UIKit 插件运行时手工引导（网易云 TXNH 同款）     │
│  · HUDWindow + SBSAccessibilityWindowHosting     │
│    → SpringBoard 注册 contextId 跨 App 显示       │
│  · IOHIDEventSystemClient 触摸监听                │
│  · ImGui Metal 渲染：悬浮球 ⇄ 展开菜单            │
└─────────────────────────────────────────────────┘
```

## 悬浮窗交互（网易云风格）

- 平时只有一个可拖拽悬浮球（非横条）
- **单击悬浮球 / 音量+**：展开 ImGui 菜单页面
- **音量-**：收起菜单
- 菜单内显示内核 KRW 状态与游戏进程（smoba）信息

## RemoteCall（跨进程）

`PolarisBridge.h` 暴露 C 接口（与 DarkSpeed 的 TaskRop 同源）：

```c
BOOL PolarisRemoteCallAttach(NSString *processName);   // 附加目标进程
BOOL PolarisRemoteRead(NSString *name, uint64_t addr, void *buf, uint64_t size);
BOOL PolarisRemoteWrite(NSString *name, uint64_t addr, const void *buf, uint64_t size);
```

TaskRop 完整源码在 `Polaris/Kernel/Vendor/TaskRop/`（RemoteCall.m 3800+ 行，
含线程劫持 ROP、PAC 绕过、异常处理、共享内存缓存），与 DarkSpeed 编译单元一致。

## 自签环境说明（非越狱 / 非巨魔）

- entitlements（`supports/entitlements-polaris.plist`）包含悬浮窗所需全部私有权限：
  HID event-monitor、persona-mgmt、accessibility-window-hosting、backboard 等
  （自签证书 + profile 可带任意 entitlement，与 DarkSpeed 同理）
- libxpf / libgrabkernel2 由 build phase 复制到 Frameworks/ 并用签名身份重签
- 私有框架（BackBoardServices / GraphicsServices / SpringBoardServices / IOKit /
  AssertionServices）以 tbd 形式链接（`libraries/`）

## 文件布局

```
Polaris/
├── PolarisMain.mm            # 程序入口：-hud 分流 / SwiftUI 主界面
├── PolarisApp.swift          # 主界面 SwiftUI（@main 已移除）
├── FunctionView.swift        # 功能页（「载入悬浮窗」按钮）
├── Kernel/
│   ├── PolarisBridge.mm/.h   # 内核引导 + spawn HUD + RemoteCall 封装
│   └── Vendor/
│       ├── TaskRop/          # ← DarkSpeed 移植：RemoteCall 跨进程调用
│       └── (darksword.m 等内核利用，与 DarkSpeed 同源)
└── Overlay/                  # ← 网易云架构悬浮窗
    ├── PolarisHUDMain.mm     # 子进程入口（UIKit 插件引导 + HID 监听）
    ├── PolarisHUDApp.mm      # UIApplication 子类（事件 fetcher 安装）
    ├── PolarisHUDAppDelegate.mm  # HUDWindow + SB 注册
    ├── PolarisHUDRootVC.mm   # 旋转容器 + 方向跟踪 + ImGui drawBlock
    ├── PolarisHUDMenu.mm     # 悬浮球 + ImGui 菜单
    ├── PolarisHUDKRW.mm      # ds_adopt_krw 子进程采用
    ├── imgui/                # Dear ImGui + Metal 后端
    └── headers/              # 私有 API 头
```

## 构建

Xcode 打开 `Polaris.xcodeproj`，配置开发者证书（需支持自签 entitlements 的
Apple Development / 企业证书），直接 Archive 或 Run。

## 已知边界

- 内核利用支持范围与 DarkSpeed/DarkSword 相同（iOS 17.0–18.7.1、26.0–26.0.1 等，
  不支持 MTE 设备）
- 悬浮窗进程依赖父进程存活（父进程退出自动退出）
