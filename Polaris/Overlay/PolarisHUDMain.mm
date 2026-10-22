//
//  PolarisHUDMain.mm
//  Polaris · 悬浮窗子进程入口（-hud 参数模式）
//
//  架构与网易云 TXNH 完全一致：主 App 通过 posix_spawn 以 "-hud" 参数
//  重新启动自身，本文件在子进程里手工引导 UIKit 插件运行时：
//    1. DSBridgeAdoptFromEnvironment 式的 KRW 采用（ds_adopt_krw）
//    2. UIScreen / GSInitialize / BKSDisplayServicesStart / UIApplicationInitialize
//    3. HUDApplication 单例 + IOHIDEventSystemClient 触摸监听
//    4. __completeAndRunAsPlugin 进入运行循环
//
//  跨 App 显示：HUDWindow 的 contextId 通过
//  SBSAccessibilityWindowHostingController 注册到 SpringBoard。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <sys/types.h>
#import <unistd.h>

#import "BackboardServices.h"
#import "UIApplication+Private.h"
#import "IOKit+SPI.h"

#import "PolarisBridge.h"
#import "PolarisHUDApp.h"
#import "PolarisHUDAppDelegate.h"
#import "PolarisHUDKRW.h"
#import "PolarisHUDLog.h"

// 供 HUDRootVC 读取的 HID 数据（触摸归一化坐标）
HIDDebugInfo g_polarisHid = {};

// HID 回调（定义在文件末尾，这里前置声明）
void PolarisHIDEventCallback(void *target, void *refcon,
                            IOHIDEventSystemClientRef sender, IOHIDEventRef event);

// 供 ImGuiMetalView 的 DiagLog 弱实现（本工程用 os_log + 环形日志）
extern "C" void DiagLog(NSString *fmt, ...);

int PolarisHUDMainEntry(int argc, char *argv[])
{
    @autoreleasepool {
        PolarisHUDLog(@"HUD 子进程启动, pid=%d, iOS %@",
                      getpid(), [UIDevice currentDevice].systemVersion);

        // ── 1. 采用父进程传来的 KRW（DS_RW_FD / DS_KBASE / DS_KSLIDE）──
        if (PolarisHUDAdoptKRW()) {
            PolarisHUDLog(@"KRW 采用成功 (kernel_base=0x%llx)",
                          (unsigned long long)PolarisKernelBase());
        } else {
            PolarisHUDLog(@"[WARN] KRW 采用失败: %@ — ESP/内核功能不可用, 悬浮窗继续",
                          PolarisBridgeLastError());
        }

        // ── 2. 父进程退出时自动退出（悬浮窗不残留）──
        pid_t ppid = getppid();
        if (ppid > 1) {
            dispatch_source_t src = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)ppid,
                DISPATCH_PROC_EXIT, dispatch_get_main_queue());
            dispatch_source_set_event_handler(src, ^{ exit(0); });
            dispatch_resume(src);
        }

        // ── 3. 引导 UIKit 插件运行时（网易云 TXNH 同款步骤）──
        PolarisHUDLog(@"[1/7] UIScreen initialize...");
        [UIScreen initialize];
        CFRunLoopGetCurrent();

        PolarisHUDLog(@"[2/7] GSInitialize + BKSDisplayServicesStart...");
        GSInitialize();
        BKSDisplayServicesStart();

        PolarisHUDLog(@"[3/7] UIApplicationInitialize...");
        UIApplicationInitialize();

        PolarisHUDLog(@"[4/7] UIApplicationInstantiateSingleton(PolarisHUDApp)...");
        Class hudAppCls = objc_getClass("PolarisHUDApp");
        UIApplicationInstantiateSingleton(hudAppCls);

        PolarisHUDLog(@"[5/7] PolarisHUDAppDelegate init + setDelegate...");
        id<UIApplicationDelegate> delegate =
            [[objc_getClass("PolarisHUDAppDelegate") alloc] init];
        [UIApplication.sharedApplication setDelegate:delegate];

        PolarisHUDLog(@"[6/7] _accessibilityInit...");
        [UIApplication.sharedApplication _accessibilityInit];
        [NSRunLoop currentRunLoop];

        // ── 4. IOHIDEventSystemClient：IOKit 层直接监听 HID（触摸+音量键）──
        {
            IOHIDEventSystemClientRef client = NULL;
            // 优先 monitor(type=1)，需 event-monitor entitlement（自签已带）
            client = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, NULL);
            if (!client) client = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 0, NULL);
            if (!client) client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);

            if (client) {
                IOHIDEventSystemClientScheduleWithRunLoop(
                    client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
                IOHIDEventSystemClientRegisterEventCallback(
                    client, (void *)PolarisHIDEventCallback, NULL, NULL);
                PolarisHUDLog(@"  IOHIDEventSystemClient: OK");
            } else {
                PolarisHUDLog(@"  IOHIDEventSystemClient: FAILED! 触摸将不可用");
            }
        }

        if (@available(iOS 15.0, *)) {
            GSEventInitialize(0);
            GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
        }

        PolarisHUDLog(@"[7/7] __completeAndRunAsPlugin...");
        [UIApplication.sharedApplication __completeAndRunAsPlugin];

        CFRunLoopRun();
        return EXIT_SUCCESS;
    }
}

// ── HID 回调：触摸归一化坐标 + 音量键脉冲（网易云 TXNH 同款字段偏移）──
void PolarisHIDEventCallback(void *target, void *refcon,
                             IOHIDEventSystemClientRef sender, IOHIDEventRef event)
{
    (void)target; (void)refcon; (void)sender;
    uint32_t type = IOHIDEventGetType(event);

    // 触摸事件: kIOHIDEventTypeDigitizer = 11
    if (type == 11) {
        CFArrayRef children = IOHIDEventGetChildren(event);
        IOHIDEventRef src = (children && CFArrayGetCount(children) > 0)
            ? (IOHIDEventRef)CFArrayGetValueAtIndex(children, 0)
            : event;
        g_polarisHid.childNormX = (float)IOHIDEventGetFloatValue(src, 0xB0000);
        g_polarisHid.childNormY = (float)IOHIDEventGetFloatValue(src, 0xB0001);
        g_polarisHid.isTouching = (IOHIDEventGetIntegerValue(src, 0xB0009) != 0);
        return;
    }

    // 键盘事件: 音量键 UsagePage=0x0C, VolUp=0xE9 / VolDown=0xEA
    if (type == 3) {
        CFIndex usagePage = IOHIDEventGetIntegerValue(event, 0x50000);
        CFIndex usage     = IOHIDEventGetIntegerValue(event, 0x50001);
        CFIndex down      = IOHIDEventGetIntegerValue(event, 0x50003);
        if (usagePage == 0x0C && down == 1) {
            if (usage == 0xE9)  g_polarisHid.volumeUpPressed = true;
            if (usage == 0xEA)  g_polarisHid.volumeDownPressed = true;
        }
    }
}

extern "C" void DiagLog(NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    PolarisHUDLog(@"%@", msg);
}
