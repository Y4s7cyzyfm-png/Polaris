//
//  unitypatch.h
//  Polaris · 王者荣耀内透
//
//  通过 DarkSword 内核读写，跨进程（smoba）定位 UnityFramework 主映像基址，
//  并在 UnityFrameworkBase + 0x09E3F824 处打入内透指令 0xD2800021。
//
//  与 dylib 插件的区别：插件跑在游戏进程内，可以直接用
//  dyld_get_image_vmaddr_slide()；Polaris 是独立进程，只能靠内核遍历
//  smoba 的 vm_map 条目来还原 UnityFramework 的 Mach-O 基址。
//

#ifndef unitypatch_h
#define unitypatch_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 内透目标偏移（UnityFrameworkBase + 该偏移）
#define UNITY_PATCH_OFFSET   0x09E3F824ULL

/// 内透写入后的指令（arm64: mov w1, #1 —— CFSwapInt32(0x210080D2)）
#define UNITY_PATCH_VALUE    0xD2800021U

/// 当前内透开关状态
typedef enum {
    UNITY_PATCH_IDLE = 0,   ///< 未处理，未找到目标
    UNITY_PATCH_ON,         ///< 内透已开启（指令已写入）
    UNITY_PATCH_OFF,        ///< 内透已关闭（已还原原始指令）
    UNITY_PATCH_UNSUPPORTED ///< 不支持（内核未就绪 / 未找到基址）
} unity_patch_state_t;

/// 定位 UnityFramework 主映像基址（进程 smoba）。
/// 复用内核 vm_map 遍历：在 smoba 的映射条目里找 Mach-O 头部，
/// 校验 CPU 类型为 arm64 且文件类型为 MH_DYLIB（UnityFramework.framework）。
/// @return 找到返回基址，失败返回 0
uint64_t polaris_find_unity_framework_base(void);

/// 开启内透：备份原始指令，写入 UNITY_PATCH_VALUE。
/// @return 成功返回 true
bool polaris_enable_transparent_wall(void);

/// 关闭内透：把原始指令写回目标地址。
/// @return 成功返回 true（没有备份时视为已还原）
bool polaris_disable_transparent_wall(void);

/// 设置内透开关（幂等）。
bool polaris_set_transparent_wall(bool enable);

/// 查询内透是否已开启。
bool polaris_transparent_wall_is_enabled(void);

/// 当前状态。
unity_patch_state_t polaris_transparent_wall_state(void);

/// 已定位的 UnityFrameworkBase（0 = 尚未定位）。
uint64_t polaris_transparent_wall_unity_base(void);

/// 目标补丁地址 = UnityFrameworkBase + UNITY_PATCH_OFFSET（0 = 尚未定位）。
uint64_t polaris_transparent_wall_target(void);

/// 状态描述文案。
void polaris_describe_transparent_wall(char *buffer, int bufferSize);

#ifdef __cplusplus
}
#endif

#endif /* unitypatch_h */
