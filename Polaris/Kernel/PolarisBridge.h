//
//  PolarisBridge.h
//  Polaris
//
//  C interface exposed to Swift through Polaris-Bridging-Header.h.
//  Wraps the vendored DarkSword kernel exploit (kernel read/write only).
//
//  NOTE: definitions live in PolarisBridge.mm (Objective-C++). The
//  extern "C" wrapper below is mandatory — without it the symbols get
//  C++-mangled and the linker reports "Undefined symbols" from Swift.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Kick off the DarkSword bootstrap on the bridge queue.
// Safe to call multiple times; re-entrant calls are ignored while running.
void PolarisInitializeDarkSwordKernel(void);

BOOL PolarisKernelIsReady(void);
BOOL PolarisKernelIsRunning(void);

NSString *PolarisBridgeStage(void);
NSString *PolarisBridgeLastError(void);
double PolarisBridgeProgress(void);

uint64_t PolarisKernelBase(void);
uint64_t PolarisKernelSlide(void);

// ---------------------------------------------------------------------------
// 游戏进程（smoba）
// ---------------------------------------------------------------------------

/// 读取游戏主二进制进程（smoba）。内核未就绪时失败并给出提示。
/// 查找方式与 Rein 一致：proc_find_by_name() + ds_kread32(proc + off_proc_p_pid)。
/// 同步执行，失败原因写入 PolarisBridgeLastError()。
BOOL PolarisAcquireGameProcess(void);

/// 是否已经成功获取过游戏进程。
BOOL PolarisGameProcessIsReady(void);

/// 游戏进程 pid（0 表示尚未获取）。
int PolarisGameProcessPID(void);

/// 游戏进程在内核中的 proc 结构体地址（0 表示尚未获取）。
uint64_t PolarisGameProcessProcAddress(void);

/// 游戏进程状态文案（例如「游戏进程已找到（smoba · pid 1234）」）。
NSString *PolarisGameProcessStatus(void);

// ---------------------------------------------------------------------------
// 功能开关：开启内透（王者荣耀 · UnityFramework 指令补丁）
// ---------------------------------------------------------------------------

/// 设置内透开关。开启时定位 UnityFramework、备份原指令并写入 0xD2800021；
/// 关闭时写回原始指令。失败原因写入 PolarisBridgeLastError()。
BOOL PolarisSetTransparentWall(BOOL enable);

/// 内透是否已开启。
BOOL PolarisTransparentWallIsEnabled(void);

/// 是否已备份原始指令（用于判断能否还原，以及是否已定位过目标）。
BOOL PolarisTransparentWallHasBackup(void);

/// 已定位的 UnityFrameworkBase（0 = 尚未定位）。
uint64_t PolarisTransparentWallUnityBase(void);

/// 目标补丁地址 UnityFrameworkBase + 0x09E3F824（0 = 尚未定位）。
uint64_t PolarisTransparentWallTarget(void);

/// 内透状态文案。
NSString *PolarisTransparentWallStatus(void);

// ---------------------------------------------------------------------------
// 悬浮窗（网易云架构：spawn -hud 子进程 + ImGui 悬浮球/菜单）
// ---------------------------------------------------------------------------

/// 载入悬浮窗：内核就绪后以 -hud 参数 spawn 自身，跨 App 显示 ImGui 悬浮球/菜单。
BOOL PolarisSpawnHUD(void);

/// 悬浮窗子进程是否仍在运行。
BOOL PolarisHUDIsRunning(void);

/// 关闭悬浮窗（notify 子进程退出）。
BOOL PolarisDismissHUD(void);

// In-app console log ring buffer (also mirrored to Documents/polaris.log).
NSArray<NSString *> *PolarisConsoleLogLines(void);
void PolarisClearConsoleLog(void);

// ---------------------------------------------------------------------------
// RemoteCall（TaskRop，与 DarkSpeed 同源）
// ---------------------------------------------------------------------------

/// 附加到目标进程建立 RemoteCall（任务线程 ROP 远程调用）。
/// 内核未就绪或连接失败时返回 NO，原因见 PolarisBridgeLastError()。
BOOL PolarisRemoteCallAttach(NSString *processName);

/// RemoteCall 最近一次初始化失败的原因（可能为空）。
NSString *PolarisRemoteCallLastInitError(void);

/// 跨进程读内存。
BOOL PolarisRemoteRead(NSString *processName, uint64_t address, void *buffer, uint64_t size);

/// 跨进程写内存。
BOOL PolarisRemoteWrite(NSString *processName, uint64_t address, const void *buffer, uint64_t size);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
