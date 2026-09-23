//
//  gameproc.m
//  Polaris · 游戏进程解析
//
//  与 Rein 的 ReinReadGameProcess() 同源流程：
//    1. 校验 DarkSword 是否就绪（ds_is_ready）
//    2. proc_find_by_name("smoba")  → 内核 proc 结构体地址
//    3. ds_kread32(proc + off_proc_p_pid) → pid
//
//  这里是纯内核态读取，不依赖 task_for_pid / sysctl——Polaris 在
//  TrollStore 环境下没有 debug 相关授权，只有内核读写原语可用。
//

#import "gameproc.h"

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <string.h>

#import "darksword.h"
#import "offsets.h"
#import "utils.h"

// 上一次查找结果（供 UI 轮询读取）
static bool gGameFound = false;
static int gGamePid = 0;
static uint64_t gGameProcAddr = 0;
static char gGameMessage[256] = {0};

static void gp_set_message(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void gp_set_message(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gGameMessage, sizeof(gGameMessage), fmt, ap);
    va_end(ap);
}

bool polaris_find_game_process(int *outPid, uint64_t *outProcAddr) {
    gGameFound = false;
    gGamePid = 0;
    gGameProcAddr = 0;

    if (!ds_is_ready()) {
        gp_set_message("请先启动内核利用，再获取游戏进程");
        if (outPid) *outPid = 0;
        if (outProcAddr) *outProcAddr = 0;
        return false;
    }

    // 与 Rein 一致：按进程名在内核进程链表中精确查找
    uint64_t proc = proc_find_by_name(POLARIS_GAME_PROCESS_NAME);
    if (!proc || !ds_isvalid(proc)) {
        gp_set_message("未找到游戏进程 " POLARIS_GAME_PROCESS_NAME "，请确认游戏已启动");
        if (outPid) *outPid = 0;
        if (outProcAddr) *outProcAddr = 0;
        return false;
    }

    uint32_t pid = ds_kread32(proc + off_proc_p_pid);
    if (pid == 0 || pid == 1) {
        gp_set_message("游戏进程 " POLARIS_GAME_PROCESS_NAME " 的 pid 异常（%u）", pid);
        if (outPid) *outPid = 0;
        if (outProcAddr) *outProcAddr = 0;
        return false;
    }

    gGameFound = true;
    gGamePid = (int)pid;
    gGameProcAddr = proc;
    gp_set_message("游戏进程已找到（" POLARIS_GAME_PROCESS_NAME " · pid %u）", pid);

    if (outPid) *outPid = gGamePid;
    if (outProcAddr) *outProcAddr = gGameProcAddr;
    return true;
}

void polaris_describe_game_process(char *buffer, int bufferSize) {
    if (!buffer || bufferSize <= 0) return;
    if (gGameMessage[0] == '\0') {
        strlcpy(buffer, "尚未获取游戏进程", (size_t)bufferSize);
        return;
    }
    strlcpy(buffer, gGameMessage, (size_t)bufferSize);
}
