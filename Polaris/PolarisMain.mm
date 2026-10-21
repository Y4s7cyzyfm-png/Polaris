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
    Class hostingClass = NSClassFromString(@"UIHostingController");
    NSAssert(hostingClass, @"UIHostingController 不可用");
    Class viewClass = NSClassFromString(@"PolarisMainHostView") ?: NSClassFromString(@"PolarisAppContent");
    NSAssert(viewClass, @"SwiftUI 根视图类缺失");
    id view = ((id (*)(id, SEL))objc_msgSend)((id)viewClass, @selector(alloc));
    view = ((id (*)(id, SEL))objc_msgSend)(view, @selector(init));
    UIViewController *vc = [[hostingClass alloc] initWithRootView:view];
    return vc;
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
