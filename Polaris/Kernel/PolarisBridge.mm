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
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Vendored DarkSword headers are plain C / Objective-C.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

NSString * const PolarisBridgeProgressNotification = @"com.polaris.bridge.progress";

static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_lastError = @"";
static NSString *g_stage = @"等待开始";

static std::atomic_bool g_kernelReady(false);
static std::atomic_bool g_kernelRunning(false);
static std::atomic<double> g_progress(0.0);

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
