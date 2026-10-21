#import <UIKit/UIKit.h>

@interface UIWindow (Private)
- (unsigned int)_contextId;
+ (BOOL)_isSystemWindow;
- (BOOL)_isWindowServerHostingManaged;
- (BOOL)_ignoresHitTest;
- (BOOL)_isSecure;
- (BOOL)_shouldCreateContextAsSecure;
@end
