//
//  gameproc.h
//  Polaris · 游戏进程解析
//
//  在 DarkSword 内核读写就绪之后，从内核 allproc/kernproc 链表中按进程名
//  定位游戏主二进制进程，并解析出它对应的内核 proc 结构体地址。
//
//  目标进程名取自 Rein 的同款做法：smoba（游戏主二进制）。
//

#ifndef gameproc_h
#define gameproc_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 游戏主二进制进程名。
#define POLARIS_GAME_PROCESS_NAME "smoba"

/// 定位游戏进程（smoba）。
///
/// 必须先完成内核引导（ds_run + offsets_init），否则直接返回 false。
/// 查找路径与 Rein 完全一致：proc_find_by_name() 遍历 allproc → kernproc，
/// 再以 ds_kread32(proc + off_proc_p_pid) 取出 pid。
///
/// @param outPid      可选，回传解析到的 pid
/// @param outProcAddr 可选，回传内核 proc 结构体地址
/// @return 找到返回 true
bool polaris_find_game_process(int *outPid, uint64_t *outProcAddr);

/// 把上一次查找的结果格式化成一行可读文本（供日志/界面使用）。
/// 失败时给出原因（内核未就绪 / 进程未找到）。
void polaris_describe_game_process(char *buffer, int bufferSize);

#ifdef __cplusplus
}
#endif

#endif /* gameproc_h */
