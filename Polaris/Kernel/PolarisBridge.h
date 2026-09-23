//
//  PolarisBridge.h
//  Polaris
//
//  C interface exposed to Swift through Polaris-Bridging-Header.h.
//  Wraps the vendored DarkSword kernel exploit (kernel read/write only).
//
//  NOTE: definitions live in PolarisBridge.mm (Objective-C++). The
//  extern "C" wrapper below is mandatory — without it the symbols get
//  C++-mangled and the linker reports "Undefined symbols" from Swift.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Kick off the DarkSword bootstrap on the bridge queue.
// Safe to call multiple times; re-entrant calls are ignored while running.
void PolarisInitializeDarkSwordKernel(void);

BOOL PolarisKernelIsReady(void);
BOOL PolarisKernelIsRunning(void);

NSString *PolarisBridgeStage(void);
NSString *PolarisBridgeLastError(void);
double PolarisBridgeProgress(void);

uint64_t PolarisKernelBase(void);
uint64_t PolarisKernelSlide(void);

// In-app console log ring buffer (also mirrored to Documents/polaris.log).
NSArray<NSString *> *PolarisConsoleLogLines(void);
void PolarisClearConsoleLog(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
