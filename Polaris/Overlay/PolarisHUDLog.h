//
//  PolarisHUDLog.h
//  Polaris · HUD 子进程日志（os_log + NSLog）
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// HUD 子进程日志：写入 os_log 与持久文件（Documents/polaris-hud.log），
/// 方便主 App 侧排查悬浮窗启动问题（参考网易云 DiagLog 的做法）。
void PolarisHUDLogImpl(NSString *format, ...);

#define PolarisHUDLog(...) PolarisHUDLogImpl(__VA_ARGS__)

#ifdef __cplusplus
}
#endif
