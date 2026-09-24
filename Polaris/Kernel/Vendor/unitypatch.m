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
//  ────────────────────────────────────────────────────────────────────────
//  安全须知（v0.4.1 修复 SIGABRT）
//
//  darksword 的 ds_kread* 系列内部走 set_target_kaddr()，该函数在地址
//  非 ds_isvalid() 时 **抛出 ObjC 异常**（@throw dsexception）。ObjC 异常
//  若从纯 C 函数里穿出到 Swift 边界而无人 catch，libc++abi 会直接
//  std::terminate() -> abort() -> SIGABRT（0x2.0 实机崩溃即此）。
//
//  因此本文件内**所有**内核读取一律走 up_safe_* 包装：
//    1) 先用 ds_isvalid() 过滤明显非法地址；
//    2) 再检查整段读取是否跨页（早期 krw 按页映射，跨页更易踩雷）；
//    3) 最后 @try/@catch 兜底，把异常就地吞掉换成 false 返回值。
//  遍历 vm_map 这类「内容来自不可信内核内存」的场景必须如此。
//  ────────────────────────────────────────────────────────────────────────
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

/// vm_map 头部 / 条目字段偏移默认值（offsets 未初始化时的兜底）
/// 运行期以 off_vm_map_* 为准（见 up_vm_offsets()）。
#define UP_VM_MAP_HDR_DEF        0x10
#define UP_HDR_FIRST_DEF         0x08
#define UP_HDR_NENTRIES_DEF      0x20
#define UP_ENTRY_NEXT_DEF        0x08
#define UP_ENTRY_START_DEF       0x10
#define UP_ENTRY_END_DEF         0x18

/// UnityFramework 所在的 app 映像区窗口（共享缓存之下）
#define UP_IMAGE_MIN         0x100000000ULL
#define UP_IMAGE_MAX         0x800000000ULL

/// 保守上限：条目遍历次数。
/// smoba 的 vm_map 条目实测在 300~800 量级，4096 留足余量；
/// 再往上多半说明链表已损坏，继续扫只会徒增反作弊敏感度。
#define UP_MAX_ENTRIES       4096

/// 保守上限：单条 load commands 扫描数量
#define UP_MAX_LC           1024

/// 环路检测表大小（覆盖正常条目数；溢出后靠 UP_MAX_ENTRIES 兜底）
#define UP_VISITED_CAP       512

/// 阶段 2 保留的候选映像数量上限（UnityFramework 必然在少数几个大映像里）
#define UP_MAX_CANDIDATES    16

/// 候选映像的最小体积门槛（UnityFramework 约 280MB，普通 framework 远小于此）
#define UP_CAND_MIN_SIZE     (8ULL * 1024 * 1024)

/// UnityFramework 映像基址特征（smoba 的 UnityFramework 位于此区间）
/// 用于在阶段 2 里优先尝试，进一步减少无效探测。
#define UP_UNITY_HINT_MIN    0x110000000ULL
#define UP_UNITY_HINT_MAX    0x140000000ULL

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

/// 整段 [addr, addr+len) 是否落在同一 4K 页内。
/// darksword 的 early_krw 以页为单位建立映射，跨页读取更容易触发
/// set_target_kaddr 的非法地址分支，这里主动规避。
static inline bool up_same_page(uint64_t addr, size_t len) {
    if (len == 0) return false;
    return ((addr) & ~0xFFFULL) == ((addr + len - 1) & ~0xFFFULL);
}

// ---------------------------------------------------------------------------
// 安全内核读取（永不抛异常）
//
// 目标：遍历任意（可能不可信）内核地址时，要么读到数据，要么返回 false，
// 绝不让 dsexception 穿过 C 调用链打崩进程。
// ---------------------------------------------------------------------------

/// 内核地址是否「看起来可读」：非 0 且落在内核/zone 区间。
static inline bool up_kaddr_ok(uint64_t addr) {
    return addr != 0 && ds_isvalid(addr);
}

static bool up_safe_kreadbuf(uint64_t addr, void *buf, size_t len) {
    if (!buf || len == 0) return false;
    if (!up_kaddr_ok(addr)) return false;
    if (!up_same_page(addr, len)) return false;

    @try {
        ds_kreadbuf(addr, buf, (uint64_t)len);
    } @catch (NSException *e) {
        return false;
    } @catch (...) {
        return false;
    }
    return true;
}

static uint64_t up_safe_kread64(uint64_t addr, bool *ok) {
    uint64_t v = 0;
    bool r = up_safe_kreadbuf(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

static uint32_t up_safe_kread32(uint64_t addr, bool *ok) {
    uint32_t v = 0;
    bool r = up_safe_kreadbuf(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

/// 读指针并剥离 PAC 签名（内核堆指针常带 PAC）。
/// @return 0 表示读失败或结果明显不是内核指针
static uint64_t up_safe_kreadptr(uint64_t addr) {
    bool ok = false;
    uint64_t raw = up_safe_kread64(addr, &ok);
    if (!ok) return 0;
    uint64_t p = raw;
    // PacStrip: 去掉高位 PAC。内核指针有效位在低 48 bit 附近。
    p &= 0x0000FFFFFFFFFFFFULL;
    // 回填 canonical 高 16 位（0xFFFF...）
    if (p & (1ULL << 47)) {
        p |= 0xFFFF000000000000ULL;
    }
    return up_kaddr_ok(p) ? p : 0;
}

/// 安全读取一段内核内存里的 C 字符串。
static bool up_safe_kreadstr(uint64_t addr, char *out, size_t outSize) {
    if (!out || outSize < 2) return false;
    if (!up_kaddr_ok(addr)) return false;

    // 逐页分段读，避免跨页被 up_same_page 拒绝
    size_t got = 0;
    uint64_t cur = addr;
    while (got + 1 < outSize) {
        size_t room = outSize - 1 - got;
        size_t chunk = 64;
        // 限制在本页内
        size_t pageLeft = 0x1000 - (size_t)(cur & 0xFFF);
        if (chunk > pageLeft) chunk = pageLeft;
        if (chunk > room) chunk = room;
        if (chunk == 0) break;

        char tmp[64];
        if (!up_safe_kreadbuf(cur, tmp, chunk)) break;

        bool done = false;
        for (size_t i = 0; i < chunk; i++) {
            if (tmp[i] == '\0') {
                out[got + i] = '\0';
                done = true;
                got += i;
                break;
            }
            out[got + i] = tmp[i];
        }
        if (done) return got > 0;

        got += chunk;
        cur += chunk;
    }
    out[got] = '\0';
    return got > 0;
}

// ---------------------------------------------------------------------------
// vm_map 偏移（运行期取 offsets，取不到用兜底默认值）
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t vmMapHdr;    ///< vm_map -> vm_map_header
    uint32_t hdrFirst;    ///< vm_map_header -> 第一条目（links.next）
    uint32_t hdrNentries; ///< vm_map_header -> nentries
    uint32_t entryNext;   ///< vm_map_entry -> links.next
    uint32_t entryStart;  ///< vm_map_entry -> links.start
    uint32_t entryEnd;    ///< vm_map_entry -> links.end
} up_offsets_t;

static up_offsets_t up_vm_offsets(void) {
    up_offsets_t o;
    o.vmMapHdr    = off_vm_map_hdr ? off_vm_map_hdr : UP_VM_MAP_HDR_DEF;
    o.hdrFirst    = off_vm_map_header_links_next ? off_vm_map_header_links_next : UP_HDR_FIRST_DEF;
    o.hdrNentries = off_vm_map_header_nentries ? off_vm_map_header_nentries : UP_HDR_NENTRIES_DEF;
    o.entryNext   = off_vm_map_entry_links_next ? off_vm_map_entry_links_next : UP_ENTRY_NEXT_DEF;
    // vm_map_entry 的 start/end 跟随 links.next 之后，固定 +8/+16
    o.entryStart  = o.entryNext + 0x8;
    o.entryEnd    = o.entryNext + 0x10;
    return o;
}

// ---------------------------------------------------------------------------
// Mach-O 头解析
// ---------------------------------------------------------------------------

/// 读取 Mach-O 头，判断是否是 arm64 的某个映像，并尝试取出 LC_ID_DYLIB 里的名字。
/// 全程走 up_safe_* —— 调用者传入的 base 来自内核条目，属于不可信数据。
static bool up_probe_macho(uint64_t base, uint32_t *outFileType,
                           char *installedName, size_t installedNameSize) {
    if (!up_is_user_pointer(base)) return false;

    uint32_t magic_le = 0;
    if (!up_safe_kreadbuf(base, &magic_le, sizeof(magic_le))) return false;
    if (magic_le != MH_MAGIC_64) return false;

    uint32_t cputype = 0;
    uint32_t filetype = 0;
    uint32_t ncmds = 0;
    uint32_t sizeofcmds = 0;
    if (!up_safe_kreadbuf(base + 0x04, &cputype, sizeof(cputype))) return false;
    if (!up_safe_kreadbuf(base + 0x0C, &filetype, sizeof(filetype))) return false;
    if (!up_safe_kreadbuf(base + 0x10, &ncmds, sizeof(ncmds))) return false;
    if (!up_safe_kreadbuf(base + 0x14, &sizeofcmds, sizeof(sizeofcmds))) return false;

    if (cputype != CPU_TYPE_ARM64) return false;
    if (filetype != MH_DYLIB && filetype != MH_EXECUTE) return false;

    if (outFileType) *outFileType = filetype;
    if (installedName && installedNameSize > 0) installedName[0] = '\0';

    // 遍历 load commands，找 LC_ID_DYLIB 取安装名（UnityFramework）
    if (!installedName || installedNameSize == 0) return true;
    if (ncmds == 0 || ncmds > 4096 || sizeofcmds > 0x400000) return true;

    uint64_t lc = base + 0x20; // 64 位 Mach-O 头大小
    uint32_t limit = (ncmds < UP_MAX_LC) ? ncmds : UP_MAX_LC;
    for (uint32_t i = 0; i < limit; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        bool ok1 = false, ok2 = false;
        cmd     = up_safe_kread32((uint64_t)lc, &ok1);
        cmdsize = up_safe_kread32((uint64_t)lc + 4, &ok2);
        if (!ok1 || !ok2) break;
        if (cmdsize < 8 || cmdsize > 0x10000) break;

        if (cmd == LC_ID_DYLIB) {
            // dylib_command: cmd, cmdsize, dylib.name.offset (uint32 @ +8)
            uint32_t nameoff = up_safe_kread32((uint64_t)lc + 8, NULL);
            if (nameoff > 8 && nameoff < cmdsize) {
                char buf[256] = {0};
                size_t want = sizeof(buf) - 1;
                if (want > cmdsize - nameoff) want = cmdsize - nameoff;
                if (up_safe_kreadstr((uint64_t)lc + nameoff, buf, want + 1)) {
                    strlcpy(installedName, buf, installedNameSize);
                }
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

    if (off_vm_map_hdr == 0 || off_vm_map_header_nentries == 0) {
        up_set_message("内核偏移未就绪，请重启内核利用后重试");
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

    up_offsets_t O = up_vm_offsets();

    // 遍历 vm_map 条目，找 UnityFramework 映像
    uint64_t header = vmMap + O.vmMapHdr;

    bool ok = false;
    uint64_t entry = up_safe_kreadptr(header + O.hdrFirst);
    uint32_t nentries = up_safe_kread32(header + O.hdrNentries, &ok);
    if (!ok) {
        up_set_message("vm_map 头读取失败，内核读写异常");
        return 0;
    }
    if (nentries == 0 || nentries > 1000000) {
        up_set_message("vm_map 条目数异常（%u），内核偏移可能不匹配", nentries);
        return 0;
    }

    // 已访问条目集合，防止环路死循环（内核链表损坏时可能出现自环）
    uint64_t visited[UP_VISITED_CAP] = {0};
    int visitedCount = 0;

    // ── 两阶段策略（降低对游戏内核内存的访问次数，减少反作弊敏感） ──
    //
    // 阶段 1：只读条目自身的 start/end/size，把「可能承载 UnityFramework」
    //         的候选记下来（地址落在映像区、且 size 足够大）。
    //         这一步每个条目只摸 2~3 个字段，不动映像内容。
    // 阶段 2：只对少数候选做 Mach-O 头校验（每个约 5~10 次读）。
    //
    // 对比旧版「看到条目就读 Mach-O」，读次数从 O(条目数 × 10)
    // 降到 O(条目数 × 3 + 候选数 × 10)。

    uint64_t candBase[UP_MAX_CANDIDATES];
    uint64_t candSize[UP_MAX_CANDIDATES];
    int candCount = 0;
    uint64_t maxDylibBase = 0;   // 备选：最大的映像（未读到库名时用）
    uint64_t maxDylibSize = 0;

    int scanned = 0;
    while (entry != 0 && scanned < UP_MAX_ENTRIES && scanned < (int)nentries + 1) {
        // ★ 关键守卫：条目地址必须先是合法内核指针，否则整条链已不可信
        if (!up_kaddr_ok(entry)) break;

        // 环路检测
        bool seen = false;
        for (int i = 0; i < visitedCount; i++) {
            if (visited[i] == entry) { seen = true; break; }
        }
        if (seen) break;
        if (visitedCount < (int)(sizeof(visited) / sizeof(visited[0]))) {
            visited[visitedCount++] = entry;
        }

        scanned++;

        bool okS = false, okE = false;
        uint64_t start = up_safe_kread64(entry + O.entryStart, &okS);
        uint64_t end   = up_safe_kread64(entry + O.entryEnd,   &okE);

        if (okS && okE && up_is_user_pointer(start) && end > start) {
            uint64_t size = end - start;

            // UnityFramework 是超大映像（实测约 280MB），
            // 远大于普通 framework。用体积门槛快速淘汰小映像。
            if (size >= UP_CAND_MIN_SIZE) {
                if (size > maxDylibSize) {
                    maxDylibSize = size;
                    maxDylibBase = start;
                }
                if (candCount < UP_MAX_CANDIDATES) {
                    candBase[candCount] = start;
                    candSize[candCount] = size;
                    candCount++;
                }
            }
        }

        uint64_t next = up_safe_kreadptr(entry + O.entryNext);
        if (next == 0) break;
        entry = next;
    }

    // ── 候选排序：先按「是否落在 UnityFramework 常见映像区间」，
    //    再按体积降序（UnityFramework 通常是最大那个）。
    //    排在最前的就是最可能命中的，通常第 1 次探测即中。 ──
    for (int i = 0; i < candCount; i++) {
        for (int j = i + 1; j < candCount; j++) {
            bool iInHint = (candBase[i] >= UP_UNITY_HINT_MIN && candBase[i] < UP_UNITY_HINT_MAX);
            bool jInHint = (candBase[j] >= UP_UNITY_HINT_MIN && candBase[j] < UP_UNITY_HINT_MAX);
            bool swap;
            if (iInHint != jInHint) {
                swap = jInHint;                // 区间内的排前面
            } else {
                swap = candSize[j] > candSize[i]; // 同区间内按体积降序
            }
            if (swap) {
                uint64_t tb = candBase[i], ts = candSize[i];
                candBase[i] = candBase[j]; candSize[i] = candSize[j];
                candBase[j] = tb;          candSize[j] = ts;
            }
        }
    }

    // ── 阶段 2：对候选做 Mach-O 校验（候选数 ≤ UP_MAX_CANDIDATES） ──
    uint64_t fallbackBase = 0;  // 备选：校验通过但未读到库名
    uint64_t fallbackSize = 0;

    for (int i = 0; i < candCount; i++) {
        uint32_t filetype = 0;
        char name[256] = {0};
        if (!up_probe_macho(candBase[i], &filetype, name, sizeof(name))) continue;

        // 首选：安装名里含 UnityFramework
        if (strstr(name, "UnityFramework") != NULL) {
            gUnityBase = candBase[i];
            break;
        }
        // 备选：体积最大的 arm64 dylib
        if (filetype == MH_DYLIB && candSize[i] > fallbackSize) {
            fallbackSize = candSize[i];
            fallbackBase = candBase[i];
        }
    }

    // 连候选都没校验出名字时，退回按最大映像定位（旧行为，给用户提示）
    if (gUnityBase == 0 && fallbackBase == 0 && maxDylibBase != 0) {
        fallbackBase = maxDylibBase;
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
    if (!up_kaddr_ok(gTargetAddr)) {
        up_set_message("内透目标地址无效（0x%llx）", gTargetAddr);
        return false;
    }

    // 备份原始指令（只备份一次，重复开启不会覆盖真原始值）
    if (!gHaveBackup) {
        bool ok = false;
        uint32_t current = up_safe_kread32(gTargetAddr, &ok);
        if (!ok) {
            up_set_message("目标地址读不到内容，映像可能未加载");
            return false;
        }
        if (current == 0) {
            up_set_message("目标地址内容为 0，映像可能未加载");
            return false;
        }
        gOriginalInstruction = current;
        gHaveBackup = true;
    }

    if (!gHaveBackup) {
        up_set_message("缺少原始指令备份，已中止写入");
        return false;
    }

    @try {
        ds_kwrite32(gTargetAddr, UNITY_PATCH_VALUE);
    } @catch (NSException *e) {
        gEnabled = false;
        const char *why = e.reason ? [e.reason UTF8String] : "unknown";
        up_set_message("内透写入异常：%s", why ? why : "unknown");
        return false;
    } @catch (...) {
        gEnabled = false;
        up_set_message("内透写入异常");
        return false;
    }

    // 回读校验：内核写不生效时不要谎报成功
    bool okV = false;
    uint32_t verify = up_safe_kread32(gTargetAddr, &okV);
    if (!okV || verify != UNITY_PATCH_VALUE) {
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
    if (!up_kaddr_ok(gTargetAddr)) {
        gEnabled = false;
        up_set_message("目标地址已失效，无法还原");
        return false;
    }

    @try {
        ds_kwrite32(gTargetAddr, gOriginalInstruction);
    } @catch (NSException *e) {
        const char *why = e.reason ? [e.reason UTF8String] : "unknown";
        up_set_message("内透还原异常：%s", why ? why : "unknown");
        return false;
    } @catch (...) {
        up_set_message("内透还原异常");
        return false;
    }

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
