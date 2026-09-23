# Polaris · 北极星

> iOS 内核工具箱 · **UI 预览版**（纯界面，暂无实际功能，后续迭代添加）
>
> SwiftUI · iOS 16.0+ · Xcode 16+ · 强制深色模式

## 页面结构

**Tab 1 · 功能**
- 状态卡：设备型号 / 系统版本 / 引擎信息 / 激活状态徽标（含模拟进度条与触感反馈）
- 主按钮：启动内核利用（点击播放模拟流程，完成后可一键重置）
- 利用选项：利用模式（自动选择 / 经典模式 / 实验模式）、自动修复环境、详细日志
- 功能开关：Tweak 注入、文件系统读写、守护进程补丁、自动注销

**Tab 2 · 设置**
- 加入官方 Telegram 频道（打开链接）
- 关于：版本 / 项目代号 / 构建环境

## 快速开始

```bash
open Polaris.xcodeproj   # Xcode 16+ 打开，⌘R 运行
```

## 需要替换的占位符

| 位置 | 内容 | 当前占位值 |
|---|---|---|
| `Polaris/SettingsView.swift` | `telegramURL` | `https://t.me/polaris_channel` |
| `Polaris.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER`（Debug/Release 两处） | `com.polaris.toolkit` |
| `codemagic.yaml` | `BUNDLE_ID` / `APP_VERSION` | `com.polaris.toolkit` / `0.1.0` |

## CI（Codemagic）

`codemagic.yaml` 借鉴了 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的流水线结构：

1. `xcodebuild` 无签名编译（`CODE_SIGNING_ALLOWED=NO`，arm64 单架构）
2. `lipo -info` 校验产物架构
3. 打包 `Polaris.tipa`（TrollStore 可直接安装），并复制一份 `Polaris.ipa`（侧载工具可用）

推送任意分支自动触发构建，产物在构建页 Artifacts 下载。

## 目录结构

```
Polaris/
├── Polaris.xcodeproj/         # Xcode 16 同步组格式工程（含共享 Scheme）
├── Polaris/
│   ├── PolarisApp.swift       # 入口 + 双 Tab
│   ├── Theme.swift            # 主题 / 通用卡片组件
│   ├── DeviceInfo.swift       # 设备与系统信息
│   ├── FunctionView.swift     # 功能页
│   ├── SettingsView.swift     # 设置页
│   └── Assets.xcassets/       # 图标与强调色
├── codemagic.yaml             # CI 配置
└── README.md
```
