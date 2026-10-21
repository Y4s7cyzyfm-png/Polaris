//
//  PolarisHUDLog.mm
//

#import "PolarisHUDLog.h"
#import <os/log.h>

static os_log_t hud_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.polaris.toolkit", "hud"); });
    return log;
}

void PolarisHUDLogImpl(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[PolarisHUD] %@", msg);
    os_log(OS_LOG_DEFAULT, "[PolarisHUD] %{public}@", msg);
}
