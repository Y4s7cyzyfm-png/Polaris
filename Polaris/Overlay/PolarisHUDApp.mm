//
//  PolarisHUDApp.mm
//  手工安装 UIEventFetcher/Dispatcher（网易云 HUDApplication 同款）
//

#import "PolarisHUDApp.h"
#import "UIEventFetcher.h"
#import "UIEventDispatcher.h"
#import "UIApplication+Private.h"
#import "pac_helper.h"
#import <objc/runtime.h>

@implementation PolarisHUDApp

- (instancetype)init {
    if (!(self = [super init])) return nil;

    do {
        UIEventDispatcher *dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
        if (!dispatcher) break;

        if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) {
            [dispatcher _installEventRunLoopSources:CFRunLoopGetMain()];
        } else {
            IMP runIMP = class_getMethodImplementation([self class], @selector(_run));
            if (!runIMP) break;

            uint32_t *ptr = (uint32_t *)make_sym_readable((void *)runIMP);
            void (*installFn)(id, SEL, CFRunLoopRef) = NULL;

            // 在 -[UIApplication _run] 里找 _installEventRunLoopSources: 的调用点
            for (int i = 0; i < 0x140; i++) {
                if (ptr[i] != 0xaa0003e2 || (ptr[i+1] & 0xff000000) != 0xaa000000) continue;
                uint32_t bl = ptr[i+2];
                uint32_t *blPtr = &ptr[i+2];
                if ((bl & 0xfc000000) != 0x94000000) continue;
                int32_t off = bl & 0x03ffffff;
                if (off & 0x02000000) off |= 0xfc000000;
                off <<= 2;
                uint64_t target = (uint64_t)blPtr + off;
                uint32_t cbz = *((uint32_t *)make_sym_readable((void *)target));
                if ((cbz & 0xff000000) != 0xb4000000) continue;
                installFn = (void (*)(id, SEL, CFRunLoopRef))make_sym_callable((void *)target);
                break;
            }
            if (!installFn) break;
            installFn(dispatcher, @selector(_installEventRunLoopSources:), CFRunLoopGetMain());
        }

        UIEventFetcher *fetcher = [[objc_getClass("UIEventFetcher") alloc] init];
        [dispatcher setValue:fetcher forKey:@"eventFetcher"];
        if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)])
            [fetcher setEventFetcherSink:dispatcher];
        else
            [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
        [self setValue:fetcher forKey:@"eventFetcher"];
    } while (NO);

    return self;
}

@end
