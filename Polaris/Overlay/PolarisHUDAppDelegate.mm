//
//  PolarisHUDAppDelegate.mm
//  HUD 窗口创建 + SpringBoard 跨 App 注册（网易云 HUDAppDelegate 同款）
//

#import "PolarisHUDAppDelegate.h"
#import "PolarisHUDWindow.h"
#import "PolarisHUDRootVC.h"
#import "ImGuiMetalView.h"
#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"
#import "UIApplication+Private.h"
#import "PolarisHUDLog.h"

#import <objc/runtime.h>
#import <notify.h>

#define POLARIS_NOTIF_DISMISS "com.polaris.toolkit.overlay.hide"
#define POLARIS_NOTIF_HUD_CTX "com.polaris.toolkit.hud.ctx"

@implementation PolarisHUDAppDelegate {
    SBSAccessibilityWindowHostingController *_hostingController;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    PolarisHUDLog(@"[HUDAppDelegate] didFinishLaunching 开始");

    // ── 系统级 HUD 窗口（竖屏固定尺寸，旋转由 RootVC 内部容器处理）──
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat pw = MIN(screenBounds.size.width, screenBounds.size.height);
    CGFloat ph = MAX(screenBounds.size.width, screenBounds.size.height);

    _window = [[PolarisHUDWindow alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    PolarisHUDRootVC *rootVC = [[PolarisHUDRootVC alloc] init];
    _window.rootViewController = rootVC;
    _window.windowLevel        = 10000000;
    _window.hidden = NO;
    [_window makeKeyAndVisible];
    PolarisHUDLog(@"  HUDWindow OK, rootVC=%@, metalView=%@",
                  rootVC ? @"OK" : @"NIL", rootVC.metalView ? @"OK" : @"NIL");

    // ── 向 SpringBoard 注册窗口 contextId，实现跨 App 合成 ──
    Class sbsCls = objc_getClass("SBSAccessibilityWindowHostingController");
    _hostingController = sbsCls ? [[sbsCls alloc] init] : nil;

    unsigned int ctxId = (unsigned int)[_window _contextId];
    double level = _window.windowLevel;
    PolarisHUDLog(@"  _contextId=%u, windowLevel=%.0f", ctxId, level);

    if (_hostingController && ctxId > 0) {
        [_hostingController registerWindowWithContextID:ctxId atLevel:level];
        PolarisHUDLog(@"  registerWindowWithContextID: OK");
    } else {
        PolarisHUDLog(@"  registerWindowWithContextID: SKIPPED! (窗口可能不可见)");
    }

    // ── 把 contextId 交给主进程，由它用 RemoteCall 让 SpringBoard 代为注册 ──
    // 自签环境下子进程没有 com.apple.springboard.accessibility-window-hosting
    // 权限，上面那次本地注册大概率被静默丢弃；SpringBoard 自己调用则一定通过。
    if (ctxId > 0) {
        NSArray<NSString *> *docs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *ctxPath = [docs.firstObject stringByAppendingPathComponent:@"polaris_hud_ctx"];
        NSString *payload = [NSString stringWithFormat:@"%u:%.0f", ctxId, level];
        [payload writeToFile:ctxPath atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
        PolarisHUDLog(@"  contextId 已写出: %@", payload);
        notify_post(POLARIS_NOTIF_HUD_CTX);
    }

    // ── 主 App 发送 dismiss 通知时退出悬浮窗进程 ──
    int token;
    notify_register_dispatch(POLARIS_NOTIF_DISMISS, &token, dispatch_get_main_queue(), ^(int t) {
        notify_cancel(t);
        [[UIApplication sharedApplication] terminateWithSuccess];
    });

    return YES;
}

@end
