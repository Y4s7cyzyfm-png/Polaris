//
//  unitypatch.m
//  Polaris · 王者荣耀内透
//
//  跨进程（smoba）定位 UnityFramework 主映像，并写入 / 还原内透指令。
//
//  链路：
//    proc_find_by_name("smoba") -> proc_task() -> task_get_vm_map()
//      -> 遍历 vm_map 条目 -> 读首页 Mach-O 头 -> 匹配 UnityFramework
//      -> UnityFrameworkBase + 0x09E3F824
//
//  dylib 插件版本用的是 dyld_get_image_vmaddr_slide()（进程内视角），
//  Polaris 没有这个便利，改成内核 vm_map 扫描 + Mach-O 头校验。
//

#import "unitypatch.h"

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <string.h>

#import "darksword.h"
#import "gameproc.h"
#import "offsets.h"
#import "utils.h"

// ---------------------------------------------------------------------------
// Mach-O 常量（内核侧读取，不依赖 <mach-o/loader.h> 的平台头）
// ---------------------------------------------------------------------------

#define MH_MAGIC_64     0xFEEDFACFU   // 主机字节序（小端存储时为 CF FA ED FE）

#define CPU_TYPE_ARM64  0x0100000CU
#define MH_DYLIB        0x6U          // 动态库
#define MH_EXECUTE      0x2U          // 主可执行

#define LC_ID_DYLIB     0x0DU

/// vm_map 头部 / 条目字段偏移（与 pe/vfs.m 保持一致）
#define UP_VM_MAP_HDR        0x10
#define UP_HDR_FIRST         0x08
#define UP_HDR_NENTRIES      0x20
#define UP_ENTRY_NEXT        0x08
#define UP_ENTRY_START       0x10
#define UP_ENTRY_END         0x18

/// UnityFramework 所在的 app 映像区窗口（共享缓存之下）
#define UP_IMAGE_MIN         0x100000000ULL
#define UP_IMAGE_MAX         0x800000000ULL

/// 保守上限：条目的 Mach-O 头扫描数量
#define UP_MAX_ENTRIES       8192

/// 搜索结果缓存（进程重启前有效）
static uint64_t gUnityBase = 0;
static uint64_t gTargetAddr = 0;

/// 内透状态
static bool gEnabled = false;
static bool gHaveBackup = false;
static uint32_t gOriginalInstruction = 0;

static char gMessage[256] = {0};

static void up_set_message(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void up_set_message(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gMessage, sizeof(gMessage), fmt, ap);
    va_end(ap);
}

static inline bool up_is_user_pointer(uint64_t p) {
    return p >= UP_IMAGE_MIN && p < UP_IMAGE_MAX;
}

// ---------------------------------------------------------------------------
// Mach-O 头解析
// ---------------------------------------------------------------------------

/// 读取 Mach-O 头，判断是否是 arm64 的某个映像，并尝试取出 LC_ID_DYLIB 里的名字。
/// @param installedName 若取到库名则写入（可为 NULL）
static bool up_probe_macho(uint64_t base, uint32_t *outFileType,
                           char *installedName, size_t installedNameSize) {
    uint32_t magic_le = 0;
    ds_kreadbuf(base, &magic_le, sizeof(magic_le));
    if (magic_le != MH_MAGIC_64) return false;

    uint32_t cputype = 0;
    uint32_t filetype = 0;
    uint32_t ncmds = 0;
    uint32_t sizeofcmds = 0;
    ds_kreadbuf(base + 0x04, &cputype, sizeof(cputype));
    ds_kreadbuf(base + 0x0C, &filetype, sizeof(filetype));
    ds_kreadbuf(base + 0x10, &ncmds, sizeof(ncmds));
    ds_kreadbuf(base + 0x14, &sizeofcmds, sizeof(sizeofcmds));

    if (cputype != CPU_TYPE_ARM64) return false;
    if (filetype != MH_DYLIB && filetype != MH_EXECUTE) return false;

    if (outFileType) *outFileType = filetype;
    if (installedName && installedNameSize > 0) installedName[0] = '\0';

    // 遍历 load commands，找 LC_ID_DYLIB 取安装名（UnityFramework）
    if (!installedName || installedNameSize == 0) return true;
    if (ncmds == 0 || ncmds > 4096 || sizeofcmds > 0x400000) return true;

    uint64_t lc = base + 0x20; // 64 位 Mach-O 头大小
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        ds_kreadbuf(lc, &cmd, sizeof(cmd));
        ds_kreadbuf(lc + 4, &cmdsize, sizeof(cmdsize));
        if (cmdsize < 8 || cmdsize > 0x10000) break;

        if (cmd == LC_ID_DYLIB) {
            // dylib_command: cmd, cmdsize, dylib.name.offset (uint32 @ +8)
            uint32_t nameoff = 0;
            ds_kreadbuf(lc + 8, &nameoff, sizeof(nameoff));
            if (nameoff > 8 && nameoff < cmdsize) {
                char buf[256] = {0};
                size_t want = sizeof(buf) - 1;
                if (want > cmdsize - nameoff) want = cmdsize - nameoff;
                ds_kreadbuf(lc + nameoff, buf, want);
                buf[want] = '\0';
                strlcpy(installedName, buf, installedNameSize);
            }
            break;
        }

        lc += cmdsize;
    }
    return true;
}

// ---------------------------------------------------------------------------
// UnityFramework 基址定位
// ---------------------------------------------------------------------------

uint64_t polaris_find_unity_framework_base(void) {
    if (gUnityBase != 0 && ds_isvalid(gUnityBase)) return gUnityBase;
    gUnityBase = 0;
    gTargetAddr = 0;

    if (!ds_is_ready()) {
        up_set_message("请先启动内核利用");
        return 0;
    }

    // 游戏进程
    uint64_t proc = proc_find_by_name(POLARIS_GAME_PROCESS_NAME);
    if (!proc || !ds_isvalid(proc)) {
        up_set_message("未找到游戏进程 " POLARIS_GAME_PROCESS_NAME "，请确认游戏已启动");
        return 0;
    }

    uint64_t task = proc_task(proc);
    if (!task || !ds_isvalid(task)) {
        up_set_message("取不到游戏进程 task");
        return 0;
    }

    uint64_t vmMap = task_get_vm_map(task);
    if (!vmMap || !ds_isvalid(vmMap)) {
        up_set_message("取不到游戏进程 vm_map");
        return 0;
    }

    // 遍历 vm_map 条目，找 UnityFramework 映像
    uint64_t header = vmMap + UP_VM_MAP_HDR;
    uint64_t entry = ds_kread64(header + UP_HDR_FIRST);
    uint32_t nentries = ds_kread32(header + UP_HDR_NENTRIES);

    uint64_t fallbackBase = 0;  // 备选：最大的 arm64 MH_DYLIB（未读到库名时用）
    uint64_t fallbackSize = 0;
    int scanned = 0;

    while (entry != 0 && nentries > 0 && scanned < UP_MAX_ENTRIES) {
        scanned++;

        uint64_t start = 0, end = 0;
        ds_kreadbuf(entry + UP_ENTRY_START, &start, sizeof(start));
        ds_kreadbuf(entry + UP_ENTRY_END, &end, sizeof(end));

        if (up_is_user_pointer(start) && end > start) {
            uint32_t filetype = 0;
            char name[256] = {0};
            if (up_probe_macho(start, &filetype, name, sizeof(name))) {
                // 首选：安装名里含 UnityFramework
                if (strstr(name, "UnityFramework") != NULL) {
                    gUnityBase = start;
                    break;
                }
                // 备选：体积最大的 arm64 dylib（UnityFramework 通常是最大那个）
                if (filetype == MH_DYLIB && (end - start) > fallbackSize) {
                    fallbackSize = end - start;
                    fallbackBase = start;
                }
            }
        }

        entry = ds_kread64(entry + UP_ENTRY_NEXT);
        nentries--;
    }

    if (gUnityBase == 0) {
        if (fallbackBase != 0) {
            gUnityBase = fallbackBase;
            up_set_message("已按最大 Mach-O 映像定位基址（未读到库名，请核对）");
        } else {
            up_set_message("未找到 UnityFramework 映像，请确认游戏已进入对局");
            return 0;
        }
    }

    gTargetAddr = gUnityBase + UNITY_PATCH_OFFSET;
    return gUnityBase;
}

// ---------------------------------------------------------------------------
// 内透开关
// ---------------------------------------------------------------------------

bool polaris_enable_transparent_wall(void) {
    if (gEnabled) return true;

    if (!ds_is_ready()) {
        up_set_message("请先启动内核利用");
        return false;
    }

    if (gTargetAddr == 0 && polaris_find_unity_framework_base() == 0) {
        return false; // 文案已在定位函数里写好
    }
    if (!ds_isvalid(gTargetAddr)) {
        up_set_message("内透目标地址无效（0x%llx）", gTargetAddr);
        return false;
    }

    // 备份原始指令（只备份一次，重复开启不会覆盖真原始值）
    if (!gHaveBackup) {
        uint32_t current = ds_kread32(gTargetAddr);
        if (current == 0) {
            up_set_message("目标地址读不到内容，映像可能未加载");
            return false;
        }
        gOriginalInstruction = current;
        gHaveBackup = true;
    }

    ds_kwrite32(gTargetAddr, UNITY_PATCH_VALUE);

    // 回读校验：内核写不生效时不要谎报成功
    uint32_t verify = ds_kread32(gTargetAddr);
    if (verify != UNITY_PATCH_VALUE) {
        gEnabled = false;
        up_set_message("内透写入未生效（回读 0x%08X，期望 0x%08X）",
                       verify, UNITY_PATCH_VALUE);
        return false;
    }

    gEnabled = true;
    up_set_message("内透已开启 · 0x%llx（原值 0x%08X → 0x%08X）",
                   gTargetAddr, gOriginalInstruction, UNITY_PATCH_VALUE);
    return true;
}

bool polaris_disable_transparent_wall(void) {
    if (!gHaveBackup) {
        gEnabled = false;
        up_set_message("内透已关闭（无备份，未做改动）");
        return true;
    }
    if (!ds_is_ready()) {
        up_set_message("请先启动内核利用");
        return false;
    }

    ds_kwrite32(gTargetAddr, gOriginalInstruction);
    gEnabled = false;

    up_set_message("内透已关闭 · 已还原 0x%08X", gOriginalInstruction);
    return true;
}

bool polaris_set_transparent_wall(bool enable) {
    return enable ? polaris_enable_transparent_wall()
                  : polaris_disable_transparent_wall();
}

bool polaris_transparent_wall_is_enabled(void) { return gEnabled; }

unity_patch_state_t polaris_transparent_wall_state(void) {
    if (gEnabled) return UNITY_PATCH_ON;
    if (gHaveBackup) return UNITY_PATCH_OFF;
    if (!ds_is_ready()) return UNITY_PATCH_UNSUPPORTED;
    return UNITY_PATCH_IDLE;
}

uint64_t polaris_transparent_wall_unity_base(void) { return gUnityBase; }

uint64_t polaris_transparent_wall_target(void) { return gTargetAddr; }

void polaris_describe_transparent_wall(char *buffer, int bufferSize) {
    if (!buffer || bufferSize <= 0) return;
    if (gMessage[0] == '\0') {
        strlcpy(buffer, "内透未开启", (size_t)bufferSize);
        return;
    }
    strlcpy(buffer, gMessage, (size_t)bufferSize);
}
