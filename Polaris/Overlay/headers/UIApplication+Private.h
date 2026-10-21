#import <UIKit/UIKit.h>
#import "IOKit+SPI.h"

@interface UIApplication (Private)
- (UIEvent *)_touchesEvent;
- (void)_run;
- (void)suspend;
- (void)_accessibilityInit;
- (void)terminateWithSuccess;
- (void)__completeAndRunAsPlugin;
- (void)_enqueueHIDEvent:(IOHIDEventRef)event;
@end
