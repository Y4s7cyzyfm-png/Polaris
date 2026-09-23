# Polaris · 北极星

> iOS 内核工具箱 · DarkSword 内核读写（TrollStore 环境专用）
>
> SwiftUI + Objective-C++ · iOS 16.0+ · Xcode 16+ · arm64e · 强制深色模式

## 功能

**Tab 1 · 功能**
- 状态卡：设备型号 / 系统版本 / 引擎信息 / 激活状态徽标 / 实时进度与阶段
- 主按钮：启动内核利用（DarkSword 链路：内核缓存准备 → offsets 初始化 → `ds_run()`）
- 副按钮：**获取游戏进程**（按钮样式与主按钮区分，位于主按钮正下方；内核就绪后可点，解析 `smoba` 主二进制进程）
- 就绪后展示 Kernel Base / Kernel Slide（内核读写原语已建立）
- 利用选项：利用引擎（DarkSword，固定）、详细日志（实时控制台）
- 控制台日志：环形缓冲实时滚动，同步落盘 `Documents/polaris.log`（write+fsync，闪退不丢）
- 功能开关：开启内透（占位，暂无实际逻辑）

**Tab 2 · 设置**
- 加入官方 Telegram 频道（打开链接）
- 关于：版本 / 项目代号 / 构建环境

## 获取游戏进程

「获取游戏进程」读取的是游戏主二进制 `smoba` 的进程，实现方式与 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的
`ReinReadGameProcess()` 一致（`Vendor/gameproc.m`）：

```objc
uint64_t proc = proc_find_by_name("smoba");          // 遍历 allproc/kernproc
uint32_t pid  = ds_kread32(proc + off_proc_p_pid);   // 读内核 proc 结构体取 pid
```

- 纯内核态链表遍历，不依赖 `task_for_pid` / `sysctl`（TrollStore 环境无 debug 授权，只有 krw 原语）
- **必须先「启动内核利用」**，内核未就绪时按钮置灰；点击后会提示「请先启动内核利用」
- 成功后在按钮上显示 pid 与「smoba · 已附加」，阶段栏同步显示「游戏进程已找到（smoba · pid N）」
- 未找到时（游戏未启动）给出「未找到游戏进程 smoba，请确认游戏已启动」，可在游戏启动后再次点击重试

接口位于 `Polaris/Kernel/Vendor/gameproc.{h,m}`，经 `PolarisBridge` 暴露给 SwiftUI：

| C 接口 | 说明 |
|---|---|
| `PolarisAcquireGameProcess()` | 同步查找 `smoba`，返回是否成功 |
| `PolarisGameProcessIsReady()` | 是否已成功获取 |
| `PolarisGameProcessPID()` | 进程 pid（0 = 未获取） |
| `PolarisGameProcessProcAddress()` | 内核 proc 结构体地址 |
| `PolarisGameProcessStatus()` | 状态文案 |

## 内核部分

DarkSword 内核利用代码来自 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的 Vendor 目录（`darksword-kexploit`），仅保留内核读写所需闭包：

- 核心：`darksword.m`（漏洞利用 + krw 原语）、`offsets.m`（内核偏移）、`utils.m`
- 支撑：`pe/`（vfs / sbx / vnode / xpaci）、`fileport.h`
- 游戏进程：`gameproc.m`（按进程名解析 `smoba`，见上一节）
- 预编译库：`libxpf.dylib`、`libgrabkernel2.dylib`（arm64e thin，运行时从 `Frameworks/` 加载）
- persistence 使用 stub（`transfer_krw_to_launchd` 不启用）
- 不含：RemoteCall、TaskRop、choma、decrypt/ota/screentime 等非必需模块

SwiftUI 通过 `Polaris-Bridging-Header.h` 调用 `PolarisBridge.mm`（精简自 ReinBridge）暴露的 C 接口。

## 快速开始

```bash
open Polaris.xcodeproj   # Xcode 16+ 打开，⌘R 运行（真机 arm64e）
```

## 需要替换的占位符

| 位置 | 内容 | 当前占位值 |
|---|---|---|
| `Polaris/SettingsView.swift` | `telegramURL` | `https://t.me/polaris_channel` |
| `Polaris.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER`（Debug/Release 两处） | `com.polaris.toolkit` |
| `codemagic.yaml` | `BUNDLE_ID` / `APP_VERSION` | `com.polaris.toolkit` / `0.2.0` |

## CI（Codemagic）

`codemagic.yaml` 借鉴了 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的流水线结构：

1. `xcodebuild` 无签名编译（`CODE_SIGNING_ALLOWED=NO`，**arm64e 单架构**）
2. `lipo -info` 校验产物架构
3. `ldid` 伪签主二进制与嵌入 dylib（`supports/entitlements-polaris.plist`）
4. dylib 统一收入 `Frameworks/` 并校验进包
5. 打包 `Polaris.tipa`（TrollStore 可直接安装），并复制一份 `Polaris.ipa`（侧载工具可用）

推送任意分支自动触发构建，产物在构建页 Artifacts 下载。

## 目录结构

```
Polaris/
├── Polaris.xcodeproj/         # Xcode 16 同步组格式工程（含共享 Scheme）
├── Polaris/
│   ├── PolarisApp.swift       # 入口 + 双 Tab
│   ├── Polaris-Bridging-Header.h
│   ├── Theme.swift            # 主题 / 通用卡片组件
│   ├── DeviceInfo.swift       # 设备与系统信息
│   ├── FunctionView.swift     # 功能页（DarkSword 引导 + 控制台日志）
│   ├── SettingsView.swift     # 设置页
│   ├── Assets.xcassets/       # 图标与强调色
│   └── Kernel/                # DarkSword 桥接与 Vendor 闭包
│       ├── PolarisBridge.h/.mm
│       └── Vendor/            # darksword-kexploit 精简闭包 + arm64e dylib
├── supports/
│   └── entitlements-polaris.plist
├── codemagic.yaml             # CI 配置
└── README.md
```
