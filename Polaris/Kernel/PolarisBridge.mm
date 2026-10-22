//
//  PolarisBridge.mm
//  Polaris
//
//  Functional core for "启动内核利用" (DarkSword kernel bootstrap).
//  Trimmed down from Rein's ReinBridge: kernel read/write bootstrap and the
//  console-log machinery only.
//
//  The kernel bootstrap flow mirrors DarkSpeed's DSBridge:
//    1. prefetch/parse the kernelcache for symbol offsets (or use built-ins)
//    2. init_offsets() -> offsets_init() -> install_builtin_kernel_symbol_offsets()
//    3. ds_run() -> ds_is_ready()
//

#import "PolarisBridge.h"

#import <UIKit/UIKit.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Vendored DarkSword headers are plain C / Objective-C.
extern "C" {
#import "darksword.h"
#import "gameproc.h"
#import "offsets.h"
#import "unitypatch.h"
#import "utils.h"
}

NSString * const PolarisBridgeProgressNotification = @"com.polaris.bridge.progress";

static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_lastError = @"";
static NSString *g_stage = @"等待开始";

static std::atomic_bool g_kernelReady(false);
static std::atomic_bool g_kernelRunning(false);
static std::atomic<double> g_progress(0.0);

// 游戏进程（smoba）解析结果，由 PolarisAcquireGameProcess() 写入。
static std::atomic_bool g_gameReady(false);
static std::atomic<int> g_gamePid(0);
static std::atomic<uint64_t> g_gameProcAddr(0);
static NSString *g_gameStatus = @"尚未获取游戏进程";

// 内透（UnityFramework 指令补丁）状态文案
static NSString *g_wallStatus = @"内透未开启";

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// In-app console log ring buffer（功能页「详细日志」视图的数据源）
// DarkSword 的日志在写 os_log 的同时镜像到这里。
// ---------------------------------------------------------------------------

static NSUInteger const kPolarisConsoleLogHardCap = 1500; // 环形缓冲上限
static NSMutableArray<NSString *> *gConsoleLog = nil;

// ---------------------------------------------------------------------------
// 持久化日志文件（Documents/polaris.log）：App 被连带杀掉/闪退时来不及
// 复制控制台——文件里什么都在。与 darksword.log 同款做法：每行
// write+fsync，进程猝死前最后一条日志也必然落盘。沙盒文件可通过
// 「文件」App → 我的 iPhone → Polaris 查看，或 Xcode/idevice 工具导出。
// ---------------------------------------------------------------------------
static int polaris_log_file_fd(void) {
    static int fd = -2;
    if (fd != -2) return fd;

    fd = -1;
    @autoreleasepool {
        NSArray<NSString *> *dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject;
        if (docs.length == 0) return fd;

        NSString *path = [docs stringByAppendingPathComponent:@"polaris.log"];
        // 保留最近 ~4MB：防止长会话无限膨胀（重命名旧的，下次启动自然丢弃）
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (attrs.fileSize > 4ULL * 1024 * 1024) {
            NSString *old = [docs stringByAppendingPathComponent:@"polaris.log.1"];
            [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:old error:nil];
        }
        fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            const char *boot = "==== polaris.log session ====\n";
            write(fd, boot, (size_t)strlen(boot));
        }
    }
    return fd;
}

static NSObject *polaris_console_lock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDateFormatter *polaris_console_date_formatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return formatter;
}

void PolarisAppendConsoleLog(NSString *line) {
    if (line.length == 0) return;
    NSString *stamped = [NSString stringWithFormat:@"%@  %@",
        [polaris_console_date_formatter() stringFromDate:[NSDate date]], line];
    @synchronized (polaris_console_lock()) {
        if (!gConsoleLog) gConsoleLog = [NSMutableArray array];
        [gConsoleLog addObject:stamped];
        if (gConsoleLog.count > kPolarisConsoleLogHardCap) {
            [gConsoleLog removeObjectsInRange:
                NSMakeRange(0, gConsoleLog.count - kPolarisConsoleLogHardCap)];
        }
    }
    // 镜像到持久化文件：write+fsync 保证进程猝死（注销连带杀死/闪退）前
    // 的最后一行也已落盘。文件 IO 走 fd 直写，不依赖 App 存活。
    int fd = polaris_log_file_fd();
    if (fd >= 0) {
        const char *utf8 = stamped.UTF8String;
        if (utf8) {
            ssize_t len = (ssize_t)strlen(utf8);
            if (len > 0) {
                write(fd, utf8, (size_t)len);
                write(fd, "\n", 1);
                fsync(fd);
            }
        }
    }
}

NSArray<NSString *> *PolarisConsoleLogLines(void) {
    @synchronized (polaris_console_lock()) {
        return gConsoleLog ? [gConsoleLog copy] : @[];
    }
}

void PolarisClearConsoleLog(void) {
    @synchronized (polaris_console_lock()) {
        if (gConsoleLog) [gConsoleLog removeAllObjects];
    }
}

// 内部日志宏：os_log（Console.app 可见）+ 内存镜像（App 内查看器可见）
// 镜像前剔除 "{public}"（不带 %——"%{public}@" 剔成字面 "@" 会丢参数，真机已踩坑）。
static NSString *polaris_console_fmt(NSString *fmt) {
    return [fmt stringByReplacingOccurrencesOfString:@"{public}" withString:@""];
}

// 统一先把整行渲染成 NSString，再以常量格式 + %s 送 os_log：
// os_log 对 %@ 支持不可靠，且镜像与 os_log 用同一份渲染结果，杜绝两边不一致。
static NSString *polaris_console_vformat(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *out = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return out;
}

#define PB_LOG(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *pb_log_line = \
            polaris_console_vformat(polaris_console_fmt(@"[PolarisBridge] " fmt), ##__VA_ARGS__); \
        os_log(OS_LOG_DEFAULT, "[PolarisBridge] %{public}s", pb_log_line.UTF8String ?: "(null)"); \
        PolarisAppendConsoleLog(pb_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

#define PB_LOG_ERROR(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *pb_log_line = \
            polaris_console_vformat(polaris_console_fmt(@"[PolarisBridge] " fmt), ##__VA_ARGS__); \
        os_log_error(OS_LOG_DEFAULT, "[PolarisBridge] %{public}s", pb_log_line.UTF8String ?: "(null)"); \
        PolarisAppendConsoleLog(pb_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

// ---------------------------------------------------------------------------
// kernelcache prefetch (ported from DarkSpeed's DSBridge via Rein)
// ---------------------------------------------------------------------------

static std::atomic<int> g_kernelPrefetchState(0); // 0 idle, 1 running, 2 ready, 3 failed
static dispatch_group_t g_kernelPrefetchGroup = nil;
static std::atomic<int> g_networkWarmupState(0); // 0 idle, 1 waiting, 2 ready, 3 timed out
static dispatch_group_t g_networkWarmupGroup = nil;
static const NSTimeInterval kNetworkWarmupTimeout = 180.0;
static const NSTimeInterval kNetworkRetryDelay = 3.0;

static dispatch_queue_t polaris_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.polaris.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void polaris_set_stage(NSString *stage) {
    os_unfair_lock_lock(&g_stateLock);
    g_stage = [stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    PB_LOG("stage: %{public}@", g_stage);
}

static void polaris_set_error(NSString *message) {
    os_unfair_lock_lock(&g_stateLock);
    g_lastError = [message copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    if (g_lastError.length > 0) {
        PB_LOG_ERROR("%{public}@", g_lastError);
    }
}

static void polaris_post_progress(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PolarisBridgeProgressNotification object:nil];
    });
}

// RemoteCall（TaskRop）跨进程调用 —— 与 DarkSpeed 同源实现
// ---------------------------------------------------------------------------

#import "RemoteCall.h"

static NSObject *g_remoteCallsLock = nil;
static NSMutableDictionary<NSString *, RemoteCall *> *g_remoteCalls = nil;

static RemoteCall *polaris_remote_call_for(NSString *processName) {
    if (!g_remoteCallsLock) {
        @synchronized ([NSObject class]) {
            if (!g_remoteCallsLock) {
                g_remoteCallsLock = [NSObject new];
                g_remoteCalls = [NSMutableDictionary dictionary];
            }
        }
    }
    @synchronized (g_remoteCallsLock) {
        RemoteCall *call = g_remoteCalls[processName];
        if (call) return call;
        call = [[RemoteCall alloc] initWithProcess:processName useMigFilterBypass:NO];
        if (!call || !call.trojanMem || call.pid <= 1) return nil;
        g_remoteCalls[processName] = call;
        return call;
    }
}

BOOL PolarisRemoteCallAttach(NSString *processName) {
    if (!PolarisKernelIsReady()) {
        polaris_set_error(@"内核未就绪，无法建立 RemoteCall。");
        polaris_post_progress();
        return NO;
    }
    RemoteCall *call = polaris_remote_call_for(processName);
    if (!call) {
        NSString *detail = [RemoteCall lastInitError];
        polaris_set_error([NSString stringWithFormat:@"RemoteCall 连接 %@ 失败: %@",
                           processName, detail.length ? detail : @"未知原因"]);
        polaris_post_progress();
        return NO;
    }
    polaris_set_error(@"");
    polaris_post_progress();
    return YES;
}

NSString *PolarisRemoteCallLastInitError(void) {
    return [RemoteCall lastInitError] ?: @"";
}

BOOL PolarisRemoteRead(NSString *processName, uint64_t address, void *buffer, uint64_t size) {
    RemoteCall *call = polaris_remote_call_for(processName);
    if (!call) return NO;
    return [call remoteRead:address to:buffer size:size];
}

BOOL PolarisRemoteWrite(NSString *processName, uint64_t address, const void *buffer, uint64_t size) {
    RemoteCall *call = polaris_remote_call_for(processName);
    if (!call) return NO;
    return [call remote_write:address from:buffer size:size];
}


static void polaris_bridge_log(const char *message) {
    if (message && message[0]) {
        PB_LOG("%{public}s", message);
    }
}

// Feed DarkSword's native progress callback into the UI.
static void polaris_bridge_progress(double progress) {
    g_progress.store(progress);
    polaris_post_progress();
}

static BOOL polaris_has_symbol_offsets(void) {
    return kernel_symbol_offsets_are_current();
}

static dispatch_group_t polaris_kernel_prefetch_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_kernelPrefetchGroup = dispatch_group_create();
    });
    return g_kernelPrefetchGroup;
}

static dispatch_group_t polaris_network_warmup_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_networkWarmupGroup = dispatch_group_create();
    });
    return g_networkWarmupGroup;
}

static BOOL polaris_mark_network_warmup_ready(void) {
    int expected = 1;
    if (!g_networkWarmupState.compare_exchange_strong(expected, 2)) return NO;
    dispatch_group_leave(polaris_network_warmup_group());
    return YES;
}

static void polaris_start_kernel_prefetch(BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || polaris_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        polaris_set_stage(@"系统数据就绪");
        return;
    }

    int state = g_kernelPrefetchState.load();
    while (state != 1 && state != 2) {
        if (state == 3 && !retryFailed) return;
        if (g_kernelPrefetchState.compare_exchange_weak(state, 1)) break;
    }
    if (state == 1 || state == 2) return;

    polaris_set_error(@"");
    polaris_set_stage(@"正在缓存内核缓存");
    dispatch_group_t group = polaris_kernel_prefetch_group();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = dlkcache();
        g_kernelPrefetchState.store(ready ? 2 : 3);
        if (ready) {
            PB_LOG("kernelcache prefetch ready");
            polaris_mark_network_warmup_ready();
            polaris_set_error(@"");
            polaris_set_stage(@"内核缓存完成");
        } else {
            PB_LOG_ERROR("kernelcache prefetch failed");
            if (g_networkWarmupState.load() == 1) {
                polaris_set_stage(@"正在请求网络权限");
            } else {
                polaris_set_stage(@"内核缓存失败");
            }
        }
        dispatch_group_leave(group);
    });
}

static BOOL polaris_wait_for_kernel_attempt(CFAbsoluteTime deadline) {
    if (polaris_has_symbol_offsets()) return YES;
    if (g_kernelPrefetchState.load() != 1) return NO;

    NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
    if (remaining <= 0.0) return NO;
    long waitResult = dispatch_group_wait(
        polaris_kernel_prefetch_group(),
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    if (waitResult != 0) {
        PB_LOG_ERROR("kernelcache prefetch timed out");
        return NO;
    }
    return polaris_has_symbol_offsets();
}

static void polaris_probe_network_until_ready(CFAbsoluteTime startedAt, NSUInteger attempt) {
    if (g_networkWarmupState.load() != 1) return;

    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
    polaris_set_stage([NSString stringWithFormat:@"等待网络（%.0f 秒，第 %lu 次）",
                    elapsed, (unsigned long)attempt]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.appledb.dev/ios/main.json.xz"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8.0];
    request.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL httpOK = !httpResponse ||
                (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400);
            if (!error && response && httpOK) {
                if (!polaris_mark_network_warmup_ready()) return;
                PB_LOG("network access ready after %.0fs",
                       CFAbsoluteTimeGetCurrent() - startedAt);
                polaris_set_error(@"");
                polaris_set_stage(@"网络已连接，正在准备内核缓存");
                polaris_start_kernel_prefetch(YES);
                return;
            }

            NSTimeInterval totalElapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
            if (g_networkWarmupState.load() != 1) return;
            if (totalElapsed >= kNetworkWarmupTimeout) {
                int expected = 1;
                if (!g_networkWarmupState.compare_exchange_strong(expected, 3)) return;
                NSString *detail = error.localizedDescription;
                if (!detail.length && httpResponse) {
                    detail = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
                }
                if (!detail.length) detail = @"无有效响应";
                PB_LOG_ERROR("network warm-up timed out: %{public}@", detail);
                polaris_set_stage(@"等待网络超时");
                polaris_set_error([NSString stringWithFormat:
                    @"等待 %.0f 秒后仍无法连接：%@\n请检查网络权限与连接后重试。", totalElapsed, detail]);
                dispatch_group_leave(polaris_network_warmup_group());
                return;
            }

            polaris_set_stage([NSString stringWithFormat:
                @"网络未就绪，已等待 %.0f 秒，%.0f 秒后重试", totalElapsed, kNetworkRetryDelay]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                polaris_probe_network_until_ready(startedAt, attempt + 1);
            });
        }] resume];
}

static void polaris_warm_up_network_and_prefetch_kernel_cache(void) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || polaris_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        polaris_set_error(@"");
        polaris_set_stage(@"系统数据就绪");
        return;
    }

    BOOL shouldStartProbe = NO;
    int expected = 0;
    if (g_networkWarmupState.compare_exchange_strong(expected, 1)) {
        shouldStartProbe = YES;
    } else if (expected == 3) {
        expected = 3;
        shouldStartProbe = g_networkWarmupState.compare_exchange_strong(expected, 1);
    }

    if (shouldStartProbe) {
        polaris_set_error(@"");
        polaris_set_stage(@"正在请求网络权限");
        dispatch_group_enter(polaris_network_warmup_group());
        polaris_probe_network_until_ready(CFAbsoluteTimeGetCurrent(), 1);
    }

    // The real request is the source of truth; devices without a regional
    // network prompt can proceed immediately.
    polaris_start_kernel_prefetch(YES);
}

static BOOL polaris_wait_for_kernel_prefetch(NSTimeInterval timeout, BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || polaris_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        return YES;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    polaris_warm_up_network_and_prefetch_kernel_cache();
    polaris_start_kernel_prefetch(retryFailed);
    if (polaris_wait_for_kernel_attempt(deadline)) return YES;

    if (g_networkWarmupState.load() == 1) {
        NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
        if (remaining <= 0.0) return NO;
        long networkWaitResult = dispatch_group_wait(
            polaris_network_warmup_group(),
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if (networkWaitResult != 0) {
            PB_LOG_ERROR("network warm-up timed out");
            return NO;
        }
    }
    if (polaris_has_symbol_offsets()) return YES;
    if (g_networkWarmupState.load() != 2) return NO;

    polaris_start_kernel_prefetch(retryFailed);
    return polaris_wait_for_kernel_attempt(deadline);
}

// ---------------------------------------------------------------------------
// DarkSword kernel bootstrap (mirrors DSBridgeBootstrap)
// ---------------------------------------------------------------------------

static BOOL polaris_bootstrap_kernel(void) {
    if (g_kernelReady.load() && ds_is_ready()) return YES;

    ds_set_log_callback(polaris_bridge_log);
    ds_set_progress_callback(polaris_bridge_progress);
    PB_LOG("running DarkSword chain off-main-thread");

    // offsets_init() must run BEFORE ds_run() — the exploit needs the
    // socket/inpcb offsets to find the corrupted socket.
    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();

    polaris_set_stage(@"正在初始化 DarkSword");
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        polaris_set_error([NSString stringWithFormat:@"DarkSword 初始化失败（%d）", result]);
        return NO;
    }

    g_kernelReady.store(true);
    polaris_set_stage(@"DarkSword 初始化完成");
    polaris_set_error(@"");
    PB_LOG("DarkSword ready — kernel_base=0x%llx kernel_slide=0x%llx",
           (unsigned long long)ds_get_kernel_base(), (unsigned long long)ds_get_kernel_slide());
    return YES;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

BOOL PolarisKernelIsReady(void) { return g_kernelReady.load() && ds_is_ready(); }
BOOL PolarisKernelIsRunning(void) { return g_kernelRunning.load(); }

NSString *PolarisBridgeLastError(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *error = [g_lastError copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return error;
}

NSString *PolarisBridgeStage(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *stage = [g_stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return stage;
}

double PolarisBridgeProgress(void) { return g_progress.load(); }

uint64_t PolarisKernelBase(void) { return ds_get_kernel_base(); }
uint64_t PolarisKernelSlide(void) { return ds_get_kernel_slide(); }

// ---------------------------------------------------------------------------
// 游戏进程（smoba）— 对应功能页「获取游戏进程」按钮
// ---------------------------------------------------------------------------

BOOL PolarisAcquireGameProcess(void) {
    // 内核未就绪时直接失败：不要在没有 krw 原语的情况下碰内核内存。
    if (!PolarisKernelIsReady()) {
        g_gameReady.store(false);
        g_gamePid.store(0);
        g_gameProcAddr.store(0);
        os_unfair_lock_lock(&g_stateLock);
        g_gameStatus = @"内核未就绪，请先启动内核利用";
        os_unfair_lock_unlock(&g_stateLock);
        polaris_set_stage(@"内核未就绪");
        polaris_set_error(@"请先启动内核利用，再获取游戏进程。");
        polaris_post_progress();
        return NO;
    }

    polaris_set_error(@"");
    polaris_set_stage(@"正在读取游戏进程");

    // 同步执行：与 Rein 的 ReinReadGameProcess() 一致，纯内核链表遍历，耗时极短。
    int pid = 0;
    uint64_t procAddr = 0;
    bool found = polaris_find_game_process(&pid, &procAddr);

    char message[1024] = {0};
    polaris_describe_game_process(message, (int)sizeof(message));
    NSString *status = message[0] ? @(message) : @"获取游戏进程失败";

    os_unfair_lock_lock(&g_stateLock);
    g_gameStatus = status;
    os_unfair_lock_unlock(&g_stateLock);

    if (!found) {
        g_gameReady.store(false);
        g_gamePid.store(0);
        g_gameProcAddr.store(0);
        PB_LOG_ERROR("game process lookup failed: %{public}@", status);
        polaris_set_stage(status);
        polaris_set_error(status);
        polaris_post_progress();
        return NO;
    }

    g_gameReady.store(true);
    g_gamePid.store(pid);
    g_gameProcAddr.store(procAddr);
    PB_LOG("game process ready — %{public}s pid=%d proc=0x%llx",
           POLARIS_GAME_PROCESS_NAME, pid, (unsigned long long)procAddr);
    polaris_set_stage(status);
    polaris_post_progress();
    return YES;
}

BOOL PolarisGameProcessIsReady(void) { return g_gameReady.load(); }

int PolarisGameProcessPID(void) { return g_gamePid.load(); }

uint64_t PolarisGameProcessProcAddress(void) { return g_gameProcAddr.load(); }

NSString *PolarisGameProcessStatus(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *status = [g_gameStatus copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return status;
}

// ---------------------------------------------------------------------------
// 功能开关：开启内透（王者荣耀）
// ---------------------------------------------------------------------------

BOOL PolarisSetTransparentWall(BOOL enable) {
    if (!PolarisKernelIsReady()) {
        os_unfair_lock_lock(&g_stateLock);
        g_wallStatus = @"内核未就绪，请先启动内核利用";
        os_unfair_lock_unlock(&g_stateLock);
        polaris_set_error(@"请先启动内核利用，再开启内透。");
        polaris_post_progress();
        return NO;
    }

    if (!enable) {
        // 关闭：还原原始指令，不算错误路径
        polaris_set_error(@"");
        bool ok = polaris_set_transparent_wall(false);
        char message[1024] = {0};
        polaris_describe_transparent_wall(message, (int)sizeof(message));
        os_unfair_lock_lock(&g_stateLock);
        g_wallStatus = message[0] ? @(message) : @"内透已关闭";
        os_unfair_lock_unlock(&g_stateLock);
        polaris_set_stage(g_wallStatus);
        PB_LOG("transparent wall disable -> %{public}@", g_wallStatus);
        polaris_post_progress();
        return ok ? YES : NO;
    }

    polaris_set_error(@"");
    polaris_set_stage(@"正在定位 UnityFramework");

    // 同步执行：内核 vm_map 遍历 + 一次 4 字节写入，耗时极短。
    bool ok = polaris_set_transparent_wall(true);

    char message[1024] = {0};
    polaris_describe_transparent_wall(message, (int)sizeof(message));
    NSString *status = message[0] ? @(message) : @"内透操作失败";

    os_unfair_lock_lock(&g_stateLock);
    g_wallStatus = status;
    os_unfair_lock_unlock(&g_stateLock);
    polaris_set_stage(status);

    if (!ok) {
        PB_LOG_ERROR("transparent wall enable failed: %{public}@", status);
        polaris_set_error(status);
        polaris_post_progress();
        return NO;
    }

    PB_LOG("transparent wall ready — base=0x%llx target=0x%llx",
           (unsigned long long)polaris_transparent_wall_unity_base(),
           (unsigned long long)polaris_transparent_wall_target());
    polaris_post_progress();
    return YES;
}

BOOL PolarisTransparentWallIsEnabled(void) {
    return polaris_transparent_wall_is_enabled() ? YES : NO;
}

BOOL PolarisTransparentWallHasBackup(void) {
    // 有备份 == 定位并处理过目标，可以安全还原
    return polaris_transparent_wall_state() != UNITY_PATCH_IDLE &&
           polaris_transparent_wall_state() != UNITY_PATCH_UNSUPPORTED;
}

uint64_t PolarisTransparentWallUnityBase(void) {
    return polaris_transparent_wall_unity_base();
}

uint64_t PolarisTransparentWallTarget(void) {
    return polaris_transparent_wall_target();
}

NSString *PolarisTransparentWallStatus(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *status = [g_wallStatus copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return status;
}

void PolarisInitializeDarkSwordKernel(void) {
    if (PolarisKernelIsReady()) {
        polaris_set_stage(@"DarkSword 已就绪");
        polaris_post_progress();
        return;
    }
    if (g_kernelRunning.load()) return;

    g_kernelRunning.store(true);
    g_progress.store(0.0);
    polaris_set_error(@"");
    polaris_set_stage(@"正在准备启动");
    polaris_post_progress();

    dispatch_async(polaris_bridge_queue(), ^{
        @autoreleasepool {
            g_progress.store(0.03);
            polaris_set_stage(@"正在准备系统数据");
            polaris_post_progress();

            if (!polaris_wait_for_kernel_prefetch(240.0, YES)) {
                NSString *preparationError = PolarisBridgeLastError();
                g_kernelRunning.store(false);
                polaris_set_stage(@"启动失败");
                polaris_set_error(preparationError.length > 0 ? preparationError :
                    @"内核缓存下载或解析失败，网络权限可能仍在等待。请检查网络后重试。");
                polaris_post_progress();
                return;
            }

            if (!polaris_bootstrap_kernel()) {
                g_kernelRunning.store(false);
                polaris_set_stage(@"启动失败");
                polaris_post_progress();
                return;
            }

            g_kernelRunning.store(false);
            g_progress.store(1.0);
            polaris_set_stage(@"DarkSword 内核就绪");
            polaris_post_progress();
        }
    });
}

// ---------------------------------------------------------------------------
// 悬浮窗（载入悬浮窗按钮）：spawn 自身为 -hud 子进程（网易云 TXNH 架构），
// KRW 套接字 fd（非 CLOEXEC）+ kbase/kslide 通过环境变量传递，
// 子进程用 ds_adopt_krw 接管（与 DarkSpeed 的 adopt 链路一致）。
// ---------------------------------------------------------------------------

#include <spawn.h>

extern "C" char **environ;

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

static std::atomic<int> g_hudPid(0);

// ---------------------------------------------------------------------------
// 内核态自我提权（platformize）
//
// 自签环境下 entitlements 没有 provisioning profile 背书，内核里的
// current_proc_is_platform() 不会通过，persona spawn 直接返回 EPERM。
// 既然 KRW 已就绪，就直接改内核里的 proc_ro->p_csflags 与 ucred，
// 与 TrollStore 的 platformize 在内核层面做的事一致。
// ---------------------------------------------------------------------------

#define POLARIS_CS_PLATFORM_BINARY 0x04000000

// XNU struct ucred 固定字段偏移（arm64，与内核版本无关）
#define POLARIS_UCRED_CR_UID    0x14
#define POLARIS_UCRED_CR_GID    0x18
#define POLARIS_UCRED_CR_RUID   0x1c
#define POLARIS_UCRED_CR_RGID   0x20
#define POLARIS_UCRED_CR_SVUID  0x24
#define POLARIS_UCRED_CR_SVGID  0x28
#define POLARIS_UCRED_CR_LABEL  0x78

static BOOL polaris_platformize_self(void)
{
    if (!ds_is_ready()) {
        PB_LOG_ERROR("platformize: KRW 未就绪");
        return NO;
    }

    uint64_t proc = ds_get_our_proc();
    if (!ds_isvalid(proc)) {
        PB_LOG_ERROR("platformize: our_proc 无效 (0x%llx)", (unsigned long long)proc);
        return NO;
    }

    uint64_t procRo = ds_kreadptr(proc + off_proc_p_proc_ro);
    if (!ds_isvalid(procRo)) {
        PB_LOG_ERROR("platformize: proc_ro 无效 (0x%llx)", (unsigned long long)procRo);
        return NO;
    }

    // 1) p_csflags |= CS_PLATFORM_BINARY
    uint32_t before = ds_kread32(procRo + off_proc_ro_p_csflags);
    ds_kwrite32(procRo + off_proc_ro_p_csflags, before | POLARIS_CS_PLATFORM_BINARY);
    uint32_t after = ds_kread32(procRo + off_proc_ro_p_csflags);
    PB_LOG("platformize: p_csflags 0x%08x -> 0x%08x", before, after);
    if (!(after & POLARIS_CS_PLATFORM_BINARY)) {
        PB_LOG_ERROR("platformize: p_csflags 写入未生效");
        return NO;
    }

    // 2) ucred 提权到 root（persona-mgmt 检查同样要求 ruid/euid 为 0）
    uint64_t ucred = ds_kreadptr(procRo + off_proc_ro_p_ucred);
    if (!ds_isvalid(ucred)) {
        PB_LOG_ERROR("platformize: ucred 无效 (0x%llx)", (unsigned long long)ucred);
        return NO;
    }

    uint32_t oldUid = ds_kread32(ucred + POLARIS_UCRED_CR_UID);
    uint32_t oldGid = ds_kread32(ucred + POLARIS_UCRED_CR_GID);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_UID,   0);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_GID,   0);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_RUID,  0);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_RGID,  0);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_SVUID, 0);
    ds_kwrite32(ucred + POLARIS_UCRED_CR_SVGID, 0);
    PB_LOG("platformize: ucred uid/gid %u:%u -> 0:0 (ucred=0x%llx)",
           oldUid, oldGid, (unsigned long long)ucred);

    // 3) 去掉 sandbox 标签：让子进程继承的进程不再被容器限制束缚
    uint64_t label = ds_kreadptr(ucred + POLARIS_UCRED_CR_LABEL);
    PB_LOG("platformize: cr_label=0x%llx (保留, 由 app 自身 entitlement 决定)",
           (unsigned long long)label);

    PB_LOG("platformize: 完成 (getuid=%d geteuid=%d)", getuid(), geteuid());
    return YES;
}

BOOL PolarisSpawnHUD(void) {
    if (!PolarisKernelIsReady()) {
        polaris_set_error(@"内核未就绪，请先启动内核利用。");
        polaris_post_progress();
        return NO;
    }

    // 已在运行则不重复 spawn
    if (g_hudPid.load() > 0) {
        return YES;
    }

    // 自身可执行文件路径
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *execPath = (char *)calloc(1, size);
    _NSGetExecutablePath(execPath, &size);
    if (!execPath[0]) {
        free(execPath);
        polaris_set_error(@"无法定位自身可执行文件路径。");
        polaris_post_progress();
        return NO;
    }

    // KRW 描述符：darksword 套接字在 fork+exec 后依然有效（非 CLOEXEC）。
    // 内核读写完全由内核侧 socket pcb 驱动，与进程无关——这正是
    // DarkSpeed 的 DSBridgeAdoptFromEnvironment 同款共享方式。
    char ctrlFd[16]  = {0};
    char rwFd[16]    = {0};
    char kbase[32]   = {0};
    char kslide[32]  = {0};
    snprintf(ctrlFd,  sizeof(ctrlFd),  "%d", control_socket);
    snprintf(rwFd,    sizeof(rwFd),    "%d", rw_socket);
    snprintf(kbase,   sizeof(kbase),   "0x%llx", (unsigned long long)ds_get_kernel_base());
    snprintf(kslide,  sizeof(kslide),  "0x%llx", (unsigned long long)ds_get_kernel_slide());

    // 跨进程锁路径（ds_set_xproc_lock_path 同款文件）
    NSArray<NSString *> *docs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsPath = docs.firstObject ?: @"";

    setenv("DS_CTRL_FD", ctrlFd, 1);
    setenv("DS_RW_FD", rwFd, 1);
    setenv("DS_KBASE", kbase, 1);
    setenv("DS_KSLIDE", kslide, 1);
    setenv("DS_HELPER_DOCS", docsPath.fileSystemRepresentation, 1);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // ── 先做内核态 platformize ───────────────────────────────────────────
    // 自签环境 entitlement 不被内核认可的根因就在这里：persona spawn 要求
    // 调用进程是 platform binary。KRW 已就绪时直接改内核里的 csflags/ucred。
    BOOL platformized = polaris_platformize_self();
    if (!platformized) {
        PB_LOG_ERROR("platformize 失败，persona spawn 大概率仍返回 EPERM");
    }

    // 网易云 / DarkSpeed / TrollSpeed 同款 persona 提权 spawn：
    // 自签（非越狱非巨魔）环境内核利用后允许该路径。
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    const char *args[] = { execPath, "-hud", NULL };
    pid_t childPid = 0;
    int rc = posix_spawn(&childPid, execPath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    // ── 回退：persona 被拒时用普通 spawn ─────────────────────────────────
    // 若 platformize 已生效，普通 spawn 出来的子进程同样继承 root uid 与
    // platform 标记，HUD 仍能注册到 SpringBoard；退一步也比直接失败好。
    if (rc != 0) {
        PB_LOG_ERROR("persona spawn 失败 (%s)，尝试普通 spawn 回退", strerror(rc));

        posix_spawnattr_t attr2;
        posix_spawnattr_init(&attr2);
        posix_spawnattr_setpgroup(&attr2, 0);
        posix_spawnattr_setflags(&attr2, POSIX_SPAWN_SETPGROUP);

        int rc2 = posix_spawn(&childPid, execPath, NULL, &attr2, (char **)args, environ);
        posix_spawnattr_destroy(&attr2);

        if (rc2 == 0) {
            PB_LOG("普通 spawn 回退成功 pid=%d", childPid);
            rc = 0;
        } else {
            PB_LOG_ERROR("普通 spawn 回退也失败 (%s)", strerror(rc2));
            rc = rc2;
        }
    }

    free(execPath);

    if (rc != 0) {
        polaris_set_error([NSString stringWithFormat:@"悬浮窗进程启动失败: %s", strerror(rc)]);
        polaris_post_progress();
        return NO;
    }

    g_hudPid.store((int)childPid);
    polaris_set_stage([NSString stringWithFormat:@"悬浮窗已载入 (pid %d)", childPid]);
    polaris_set_error(@"");
    polaris_post_progress();
    PB_LOG("spawned HUD process pid=%d", childPid);
    return YES;
}

BOOL PolarisHUDIsRunning(void) {
    int pid = g_hudPid.load();
    if (pid <= 0) return NO;
    // 子进程存活检查
    if (kill((pid_t)pid, 0) == 0) return YES;
    g_hudPid.store(0);
    return NO;
}

BOOL PolarisDismissHUD(void) {
    int pid = g_hudPid.load();
    if (pid <= 0) return YES;
    notify_post("com.polaris.toolkit.overlay.hide");
    g_hudPid.store(0);
    return YES;
}

