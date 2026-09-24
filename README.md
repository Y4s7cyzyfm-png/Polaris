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
- 功能开关：**开启内透**（王者荣耀 · UnityFramework 指令补丁，可开关还原）

**Tab 2 · 设置**
- 加入官方 Telegram 频道（打开链接）
- 关于：版本 / 项目代号 / 构建环境

## 开启内透（王者荣耀）

把内核读写直接作用到游戏进程的 UnityFramework 映像上，补丁地址：

```
target = UnityFrameworkBase + 0x09E3F824      // 开启写入
value  = 0xD2800021                           // arm64: mov w1, #1
                                              // 等价于 CFSwapInt32(0x210080D2)
```

做法与常见 dylib 插件一致（插件版见 `Patchoffset.h` 的 `write_mem<T>`），
区别只在**跨进程**：

| | dylib 插件 | Polaris |
|---|---|---|
| 运行位置 | 游戏进程内 | 独立 App |
| 基址来源 | `dyld_get_image_vmaddr_slide()` | 内核遍历 smoba 的 `vm_map` 条目 |
| 写内存 | `vm_protect` + `vm_write`（本进程） | `ds_kwrite32()`（内核原语，无需改页权限） |

**基址定位**（`Vendor/unitypatch.m`）：

1. `proc_find_by_name("smoba")` → `proc_task()` → `task_get_vm_map()`
2. **阶段 1**：遍历 vm_map 条目，只读条目自身 `start`/`end`，
   筛出体积 ≥ 8 MB 的映像作为候选（UnityFramework 实测约 280 MB，普通 framework 远小于此）
3. **阶段 2**：候选按「UnityFramework 常见映像区间优先 + 体积降序」排序，
   逐个校验 `MH_MAGIC_64` + `CPU_TYPE_ARM64`，解析 `LC_ID_DYLIB` 取安装名
4. 命中名含 `UnityFramework` 的映像即为基址；取不到库名时退回「最大的 arm64 dylib」

> 两阶段策略的意义不只是省时间：旧版「每个条目都读 Mach-O 头」会对游戏内核内存
> 发起大量探测，容易被游戏的反作弊（tersafe / owl）注意到。改成候选制后，
> 内核读次数下降约 57%~85%（普通 framework 一个都不会碰）。

**开关语义**（与逆向源码一致）：

- 开启：先备份目标地址原始指令，再写入 `0xD2800021`，然后**回读校验**
- 关闭：把备份的原始指令写回
- 备份只做一次，重复开关不会把补丁值当成原始值
- 写不生效（回读不符）会明确报错，不会谎报成功

**注意**：合入对局后 UnityFramework 才加载完成，请在游戏内进入对局后再开启内透。

## 稳定性：内核读取一律走安全包装

`darksword` 的 `ds_kread*` 内部会调用 `set_target_kaddr()`，而该函数在地址不合法时
**会抛 ObjC 异常**（`@throw dsexception`）：

```objc
static void set_target_kaddr(uint64_t where) {
    if (!ds_isvalid(where)) {
        ...
        @throw [NSException exceptionWithName:@"dsexception" ...];   // ← 这里
    }
    ...
}
```

这个异常从 `ds_kreadbuf` → `early_kread` 一路都是纯 C 函数，中间没有任何 `@try/@catch`。
ObjC 异常穿出 C 边界到 Swift 时，libc++abi 只能 `std::terminate()` → `abort()` → **SIGABRT**。

**v0.2.0 实机崩溃即由此而来**（`lastExceptionBacktrace` 顶到
`polaris_find_unity_framework_base` → `ds_kreadbuf` → `early_kread` → `set_target_kaddr`
→ `objc_exception_throw` → `abort()`）：遍历 vm_map 时把内核链表里的垃圾值
当成了条目指针，直接去读 `entry + 0x10`，地址非法 → 抛异常 → 打崩。

**修复**（v0.4.1）：本文件内**所有**内核读取都改走 `up_safe_*` 包装：

```objc
static bool up_safe_kreadbuf(uint64_t addr, void *buf, size_t len) {
    if (!buf || len == 0) return false;
    if (!up_kaddr_ok(addr)) return false;        // 先用 ds_isvalid() 挡掉明显非法地址
    if (!up_same_page(addr, len)) return false;  // 再拒绝跨页读（early_krw 按页映射）
    @try {
        ds_kreadbuf(addr, buf, len);
    } @catch (NSException *e) {
        return false;                            // 兜底：异常就地吞掉，绝不外泄
    } @catch (...) {
        return false;
    }
    return true;
}
```

配套加固：

| 措施 | 说明 |
|---|---|
| 循环入口守卫 | `if (!up_kaddr_ok(entry)) break;` —— 条目指针非法即中止，不再往下摸 |
| 环路检测 | `visited[512]` 记录已访问条目，内核链表自环时不会死循环 |
| 遍历上限 | `UP_MAX_ENTRIES 4096`，异常链表不会无限扫 |
| load commands 上限 | `UP_MAX_LC 1024` + `cmdsize` 合法性检查 |
| 偏移自检 | `off_vm_map_*` 未装载时直接报错返回，不用错偏移乱读 |
| 写入也加护栏 | `ds_kwrite32` 同样包在 `@try/@catch` 里 |
| kernel 指针剥离 PAC | `up_safe_kreadptr()` 读指针后清 PAC 并回填 canonical 高位 |

设计目标：**遍历任意（可能不可信）内核地址时永不抛异常**——要么返回数据，
要么返回 0，绝不让 `dsexception` 穿过 C 调用链。

## 跨进程访问：为什么不能直接 `ds_kwrite32`

这是 v0.4.3 的核心修复。`ds_kread*` / `ds_kwrite*` **只能读写内核地址**：

```objc
static void set_target_kaddr(uint64_t where) {
    if (!ds_isvalid(where)) @throw dsexception;   // ds_isvalid 只认 0xffffff.. / 0xfffffe..
    ...
}
```

`where` 在底层被当成**内核虚拟地址**塞进 `icmp6filter` 指针里做读写，
所以用户态地址**永远不可能**被 `ds_*` 直接访问。

而内透目标是 `UnityFrameworkBase + 0x09E3F824` —— 这是 **smoba 的用户态地址**
（实测 `0x12145F824`）。于是 v0.4.2 的表现是：

```
09:10:18.992  stage: 正在定位 UnityFramework
09:10:19.028  stage: 未找到 UnityFramework 映像，请确认游戏已进入对局
```

**只用了 36ms** —— 因为 `up_probe_macho()` 走的还是 `up_safe_kreadbuf()`
（带 `ds_isvalid` 预检），每个候选都在第一字节就被拒，一轮下来秒退。

### vtop 为什么也不行

最直觉的方案是 vtop（遍历页表把虚拟地址翻成物理地址）。但 [Rein](https://github.com/Y4s7cyzyfm-png/Rein)
作者在 iOS 18.6 真机上实测后写下了结论：

> 读取——不再走 `ptov_table` / `pmap` 页表遍历（iOS 18.6 上两者语义均与预期不符）。

### 采用的方案：vm_object 共享映射

`Vendor/remotepage.{h,m}`，移植自 Rein 的 `TaskRop/vm.m`（原作者真机验证过）：

1. 在目标 `vm_map` 里找到目标地址所属的 `vm_map_entry`
2. 从 entry 解出该页的 `vm_object`（`vme_object_or_delta` 是**压缩指针**）
3. 把 `vm_object` 引用计数 `+1`（否则映射建立后对象可能被回收）
4. 在本进程造一个 `memory entry`，篡改其 backing `vm_map_entry`，
   让 `vme_object` 指向目标对象、`vme_offset` 指向目标页
5. `mach_vm_map` 把这一页映射进**本进程**地址空间
6. 之后直接 `memcpy` —— 读写都退化成普通用户态内存访问

关键点：

| 项 | 值 / 说明 |
|---|---|
| `VM_PAGE_PACKED_PTR_BITS` | 31 |
| `VM_PAGE_PACKED_PTR_SHIFT` | 6 |
| 压缩指针基准 | `VM_MIN_KERNEL_ADDRESS`（base-relative 当 `bits+shift <= 38`） |
| `vme_offset` 单位 | **4KB**（`VME_OFFSET(x) = x << 12`），不是设备页大小 |
| 页大小 | iPhone13,4（A14）16KB；`host_page_size()` 探测，`gPageShift` 兜底 14 |
| 页缓存 | `PR_PAGE_CACHE_CAP 64` 条正向缓存 + 64 条负缓存（记住映射失败的页） |
| 跨页读写 | 自动分段递归，按页边界切开 |

### 读取路径的分层

修复后 `unitypatch.m` 的读取分成明确两层：

| 函数族 | 目标 | 底层 |
|---|---|---|
| `up_safe_kread*` | **内核对象**（`vm_map` / `vm_map_entry` / `vm_object` / `proc` / `task`） | `ds_kreadbuf` + `ds_isvalid` 预检 + `@try/@catch` |
| `up_user_read*` | **smoba 用户态**（Mach-O 头、UnityFramework 指令） | `polaris_remote_*` → vm_object 共享映射 + `memcpy` |

内透写入同理走 `up_user_write()`（== `polaris_remote_write()`），
不再是 `ds_kwrite32`——后者写用户态地址会被 `ds_isvalid` 直接拒掉。

> **踩坑记录**：`up_safe_kreadstr()` 已删除。它只在读内核字符串时有用，
> 而 Mach-O 的 `LC_ID_DYLIB` 名字在 smoba 用户态，必须走 `up_user_readstr()`。

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
- 内透补丁：`unitypatch.m`（跨进程定位 UnityFramework + 指令补丁，见上一节）
- 跨进程内存：`remotepage.m`（vm_object 共享映射 + 页缓存，见上一节）
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
| `codemagic.yaml` | `BUNDLE_ID` / `APP_VERSION` | `com.polaris.toolkit` / `0.4.3` |

> CI 里 `MARKETING_VERSION` 现在取 `${APP_VERSION}`（此前被硬编码成 `0.2.0`，
> 会导致 pbxproj 里的版本号在 CI 构建时被覆盖——崩溃日志里 `app_version: 0.2.0`
> 与工程里的 `0.4.x` 对不上就是这个原因）。

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

## 版本变更

| 版本 | 变更 |
|---|---|
| 0.4.3 | **修复「未找到 UnityFramework 映像」（36ms 秒退）**：根因是 `ds_kread*`/`ds_kwrite*` 只认内核地址，而 UnityFramework 基址与内透目标都是 smoba 用户态地址，被 `ds_isvalid` 全数拒掉。新增 `remotepage.{h,m}` 跨进程访问层——移植 Rein `TaskRop/vm.m` 的 **vm_object 共享映射**（vtop 在 iOS 18.6 上语义不符，已排除），把目标页映射进本进程后用 `memcpy` 读写；读取路径按目标分成 `up_safe_kread*`（内核对象）/ `up_user_read*`（smoba 用户态）两层；内透写入改走 `up_user_write()` 而非 `ds_kwrite32`；定位前先 `polaris_remote_set_target(vmMap)` 登记目标进程，开启/关闭路径带自愈重登记 |
| 0.4.2 | **修复内透定位到错误基址**：去掉「校验失败时退回体积最大条目」的危险兜底（smoba 有个 ~9.8GB 匿名映射，体积碾压 UnityFramework 的 280MB，导致基址错到 `0x274000000`）；阶段 1 增加页对齐筛选，候选上限提到 64 且不再按体积裁剪；排序改为「特征区间 → 合理库大小（≤2GB）→ 体积降序」；新增基址/目标地址的最终窗口闸门，越界即放弃 |
| 0.4.1 | **修复开启内透导致的 Polaris SIGABRT 崩溃**：`unitypatch.m` 全部内核读取改走 `up_safe_*`（`ds_isvalid` 预检 + `@try/@catch` 兜底），vm_map 遍历加指针守卫 / 环路检测 / 上限；定位改为两阶段候选制，内核读次数大幅下降；CI `MARKETING_VERSION` 不再被硬编码覆盖 |
| 0.4.0 | 新增「开启内透」开关（King of Glory / UnityFramework 指令补丁，支持开关还原） |
| 0.3.0 | 新增「获取游戏进程」按钮（`smoba` 主二进制，Rein 同款 `proc_find_by_name`） |
| 0.2.0 | DarkSword 内核利用链路打通 |
