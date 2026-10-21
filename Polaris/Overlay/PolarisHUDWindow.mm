//
//  PolarisHUDWindow.mm
//  系统级 HUD 窗口（网易云 HUDWindow 同款私有覆盖）
//

#import "PolarisHUDWindow.h"

@implementation PolarisHUDWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

@end
