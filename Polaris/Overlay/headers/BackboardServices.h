#import <Foundation/Foundation.h>

#if __cplusplus
extern "C" {
#endif

void UIApplicationInstantiateSingleton(Class aClass);
void UIApplicationInitialize(void);
void BKSDisplayServicesStart(void);
void GSInitialize(void);
void GSEventInitialize(Boolean registerPurple);
void GSEventPopRunLoopMode(CFStringRef mode);
void GSEventPushRunLoopMode(CFStringRef mode);

#if __cplusplus
}
#endif
