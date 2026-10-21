//
//  PolarisHUDKRW.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 采用父进程传来的 KRW（DS_CTRL_FD / DS_RW_FD / DS_KBASE / DS_KSLIDE）。
/// 成功后 HUD 子进程与 DarkSpeed HUD 一样具备完整内核读写。
BOOL PolarisHUDAdoptKRW(void);

/// KRW 是否已在子进程就绪。
BOOL PolarisHUDKernelIsReady(void);

NS_ASSUME_NONNULL_END
