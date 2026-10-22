//
//  PolarisMain.mm
//  Polaris · 程序入口（替代 @main）
//
//  argv[1] == "-hud" → 悬浮窗子进程（PolarisHUDMainEntry）
//  否则 → SwiftUI 主界面（UIHostingController）
//

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <string.h>

extern int PolarisHUDMainEntry(int argc, char *argv[]);

@interface PolarisMainAppDelegate : NSObject <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation PolarisMainAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [self makeRootVC];
    [self.window makeKeyAndVisible];
    return YES;
}

- (UIViewController *)makeRootVC {
    // SwiftUI 主界面：FunctionView/SettingsView 双 Tab
    //
    // SwiftUI 的 View 是 struct，运行时没有 ObjC 类名，NSClassFromString 拿不到，
    // 因此由 Swift 侧的 PolarisRootPresenter 提供真正的 ObjC 工厂方法。
    Class presenter = NSClassFromString(@"PolarisRootPresenter");
    if (presenter) {
        SEL sel = @selector(makeRootViewController);
        if ([presenter respondsToSelector:sel]) {
            UIViewController *vc = ((UIViewController *(*)(id, SEL))objc_msgSend)(presenter, sel);
            if (vc) return vc;
        }
    }

    // 兜底：绝不返回 nil，否则 UIKit 会以
    // "Application windows are expected to have a root view controller"
    // 断言直接 abort。
    UIViewController *fallback = [[UIViewController alloc] init];
    fallback.view.backgroundColor = [UIColor blackColor];
    UILabel *label = [[UILabel alloc] initWithFrame:fallback.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = @"界面加载失败：未找到 PolarisRootPresenter";
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [fallback.view addSubview:label];
    return fallback;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) {
            return PolarisHUDMainEntry(argc, argv);
        }
        return UIApplicationMain(argc, argv, nil,
                                  NSStringFromClass([PolarisMainAppDelegate class]));
    }
}
