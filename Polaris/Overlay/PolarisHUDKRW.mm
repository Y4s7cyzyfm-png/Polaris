//
//  PolarisHUDKRW.mm
//  Polaris · HUD 子进程 KRW 采用
//
//  与 DarkSpeed 的 DSBridgeAdoptFromEnvironment 完全一致的链路：
//  父进程把 control/rw 套接字 fd（非 CLOEXEC）与 kbase/kslide 通过
//  环境变量 DS_CTRL_FD / DS_RW_FD / DS_KBASE / DS_KSLIDE 传给子进程，
//  子进程用 ds_adopt_krw() 直接接管内核读写原语，不再重新跑利用。
//

#import "PolarisHUDKRW.h"
#import "PolarisBridge.h"

#include "darksword.h"
#include "offsets.h"
#include "utils.h"

#include <atomic>
#include <stdlib.h>

extern "C" {

static std::atomic_bool g_hudKrwReady(false);

static int hud_env_int(const char *name, int fallback) {
    const char *value = getenv(name);
    return value && value[0] ? (int)strtol(value, NULL, 0) : fallback;
}

static uint64_t hud_env_u64(const char *name) {
    const char *value = getenv(name);
    return value && value[0] ? strtoull(value, NULL, 0) : 0;
}

BOOL PolarisHUDAdoptKRW(void)
{
    if (g_hudKrwReady.load()) return YES;

    int control  = hud_env_int("DS_CTRL_FD", -1);
    int readWrite = hud_env_int("DS_RW_FD", -1);
    uint64_t kernelBase  = hud_env_u64("DS_KBASE");
    uint64_t kernelSlide = hud_env_u64("DS_KSLIDE");
    if (control < 0 || readWrite < 0 || !kernelBase) return NO;

    // 与 DarkSpeed 一致：跨进程锁放在容器 Documents 目录
    const char *lock = getenv("DS_HELPER_DOCS");
    if (lock && lock[0]) {
        NSString *path = @(lock);
        if (![path.pathExtension isEqualToString:@"lock"]) {
            path = [path stringByAppendingPathComponent:@".polaris-krw.lock"];
        }
        ds_set_xproc_lock_path(path.fileSystemRepresentation);
    }

    if (!ds_adopt_krw(control, readWrite, kernelBase, kernelSlide)) {
        return NO;
    }

    // 与 DarkSpeed 相同：采用后必须初始化 offsets，符号表走内置数据
    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();

    g_hudKrwReady.store(true);
    return YES;
}

BOOL PolarisHUDKernelIsReady(void)
{
    return g_hudKrwReady.load() && ds_is_ready();
}

} // extern "C"
