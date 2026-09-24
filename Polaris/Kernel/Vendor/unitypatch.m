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
#import "remotepage.h"
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

/// 阶段 2 保留的候选映像数量上限。
/// 不按体积裁剪候选——smoba 里有 ~9.8GB 的未知大映射，体积排序会把
/// 真正的 UnityFramework（280MB）挤出去。全部收下，交给 Mach-O 校验判定。
/// smoba 里满足「≥8MB 且页对齐」的条目通常在个位数到二十出头。
#define UP_MAX_CANDIDATES    64

/// 候选映像的最小体积门槛（UnityFramework 约 280MB，普通 framework 远小于此）
#define UP_CAND_MIN_SIZE     (8ULL * 1024 * 1024)

/// UnityFramework 映像基址特征（smoba 的 UnityFramework 位于此区间）
/// 用于在阶段 2 里优先尝试，进一步减少无效探测。
#define UP_UNITY_HINT_MIN    0x110000000ULL
#define UP_UNITY_HINT_MAX    0x140000000ULL

/// 「合理库大小」上限。超过此值的映射基本是 Unity 的堆/图形缓冲，
/// 不可能是 Mach-O 库（UnityFramework 约 280MB）。
#define UP_LIB_SIZE_MAX      (2ULL * 1024 * 1024 * 1024)

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
///
/// ⚠️ 这里**只能**用于内核对象（vm_map / vm_map_entry / vm_object / proc / task）。
/// ds_isvalid 只认 0xffffff.. / 0xfffffe.. 开头的内核地址，
/// smoba 的用户态地址（如 0x117620000）传进来必然被判非法。
/// 读游戏进程自己的内存请用 up_user_read* 那一组。
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

// ---------------------------------------------------------------------------
// 用户态读取（读 smoba 自己的内存）
//
// ★ 这是整个内透功能的**关键转折点**。
//
// ds_kread* / ds_kwrite* 只认内核地址（见 up_kaddr_ok 的注释），
// 所以「读 smoba 的 Mach-O 头」「改 smoba 的 UnityFramework 代码」
// 都不可能直接用 ds_*。
//
// 走 remotepage 的 vm_object 共享映射：把目标页映射进本进程，
// 然后直接 memcpy —— 读写都退化成普通用户态内存访问。
// ---------------------------------------------------------------------------

/// 从游戏进程读 len 字节（走 vm_object 共享映射，永不抛异常）。
static bool up_user_read(uint64_t addr, void *buf, size_t len) {
    if (!buf || len == 0) return false;
    if (!up_is_user_pointer(addr)) return false;
    // 溢出保护：addr + len 不能越过映像窗口上界
    if (addr + (uint64_t)len < addr) return false;
    if (addr + (uint64_t)len > UP_IMAGE_MAX) return false;

    return polaris_remote_read(addr, buf, len);
}

/// 向游戏进程写 len 字节。
static bool up_user_write(uint64_t addr, const void *src, size_t len) {
    if (!src || len == 0) return false;
    if (!up_is_user_pointer(addr)) return false;
    if (addr + (uint64_t)len < addr) return false;
    if (addr + (uint64_t)len > UP_IMAGE_MAX) return false;

    return polaris_remote_write(addr, src, len);
}

static uint64_t up_user_read64(uint64_t addr, bool *ok) {
    uint64_t v = 0;
    bool r = up_user_read(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

static uint32_t up_user_read32(uint64_t addr, bool *ok) {
    uint32_t v = 0;
    bool r = up_user_read(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

/// 读取用户态内存里的 C 字符串（逐页分段，不要求同页）。
static bool up_user_readstr(uint64_t addr, char *out, size_t outSize) {
    if (!out || outSize < 2) return false;
    if (!up_is_user_pointer(addr)) return false;

    size_t got = 0;
    uint64_t cur = addr;
    while (got + 1 < outSize) {
        size_t room = outSize - 1 - got;
        size_t chunk = 64;
        // 限本页内（remotepage 自己能跨页，但按页切更省映射）
        size_t pageLeft = 0x1000 - (size_t)(cur & 0xFFF);
        if (chunk > pageLeft) chunk = pageLeft;
        if (chunk > room) chunk = room;
        if (chunk == 0) break;

        char tmp[64];
        if (!up_user_read(cur, tmp, chunk)) break;

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
///
/// ★ base 是 **smoba 的用户态地址**，必须走 up_user_*（vm_object 共享映射）；
/// 用 up_safe_* 会被 ds_isvalid 直接拒掉，表现就是「探测全失败 → 36ms 报未找到」。
static bool up_probe_macho(uint64_t base, uint32_t *outFileType,
                           char *installedName, size_t installedNameSize) {
    if (!up_is_user_pointer(base)) return false;

    uint32_t magic_le = 0;
    if (!up_user_read(base, &magic_le, sizeof(magic_le))) return false;
    if (magic_le != MH_MAGIC_64) return false;

    uint32_t cputype = 0;
    uint32_t filetype = 0;
    uint32_t ncmds = 0;
    uint32_t sizeofcmds = 0;
    if (!up_user_read(base + 0x04, &cputype, sizeof(cputype))) return false;
    if (!up_user_read(base + 0x0C, &filetype, sizeof(filetype))) return false;
    if (!up_user_read(base + 0x10, &ncmds, sizeof(ncmds))) return false;
    if (!up_user_read(base + 0x14, &sizeofcmds, sizeof(sizeofcmds))) return false;

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
        cmd     = up_user_read32((uint64_t)lc, &ok1);
        cmdsize = up_user_read32((uint64_t)lc + 4, &ok2);
        if (!ok1 || !ok2) break;
        if (cmdsize < 8 || cmdsize > 0x10000) break;

        if (cmd == LC_ID_DYLIB) {
            // dylib_command: cmd, cmdsize, dylib.name.offset (uint32 @ +8)
            uint32_t nameoff = up_user_read32((uint64_t)lc + 8, NULL);
            if (nameoff > 8 && nameoff < cmdsize) {
                char buf[256] = {0};
                size_t want = sizeof(buf) - 1;
                if (want > cmdsize - nameoff) want = cmdsize - nameoff;
                if (up_user_readstr((uint64_t)lc + nameoff, buf, want + 1)) {
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
    // 命中缓存：注意 gUnityBase 是**用户态**地址，不能用 ds_isvalid 校验
    if (gUnityBase != 0 && up_is_user_pointer(gUnityBase) && up_is_user_pointer(gTargetAddr)) {
        return gUnityBase;
    }
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

    // ★★ 关键一步：把目标 vm_map 登记给跨进程访问层。
    // 之后所有 up_user_*（读 Mach-O 头、写内透指令）都靠它做
    // vm_object 共享映射。不登记的话 up_user_read 全部返回 false，
    // 表现就是「候选全被否 → 未找到 UnityFramework」。
    polaris_remote_set_target(vmMap);

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
    // 阶段 1：只读条目自身的 start/end/size，把「可能承载 Mach-O 头」
    //         的候选记下来（地址落在映像区、且体积够大、且首地址页对齐）。
    //         这一步每个条目只摸 2~3 个字段，不动映像内容。
    // 阶段 2：只对少数候选做 Mach-O 头校验（每个约 5~10 次读），
    //         且**只接受校验通过的候选**。
    //
    // 对比旧版「看到条目就读 Mach-O」，读次数从 O(条目数 × 10)
    // 降到 O(条目数 × 3 + 候选数 × 10)。

    uint64_t candBase[UP_MAX_CANDIDATES];
    uint64_t candSize[UP_MAX_CANDIDATES];
    int candCount = 0;

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

            // 候选筛选条件（三条同时满足才收）：
            //   1. 体积 >= UP_CAND_MIN_SIZE —— 排除海量小框架/段映射
            //   2. start 页对齐 —— Mach-O 头必须落在页首，
            //      能把 __DATA / 堆这类「非页首」的大映射挡在外面
            //   3. 落在用户态映像窗口（前面已判）
            //
            // 注意：这里**不做**「只留最大的几个」这类裁剪，
            // 否则真目标可能被更大的未知映射挤掉（踩过这个坑）。
            // 候选全收，由阶段 2 的 Mach-O 校验做最终判定。
            if (size >= UP_CAND_MIN_SIZE && (start & 0xFFF) == 0) {
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

    // ── 候选排序（决定探测顺序，只影响效率不影响正确性） ──
    //
    // 排序键（优先级从高到低）：
    //   1. 是否落在 UnityFramework 常见映像区间 [0x110000000, 0x140000000)
    //   2. 体积是否在「合理库大小」内（<= 2GB）—— 排除 Unity 的巨型堆映射
    //   3. 体积降序（UnityFramework 是最大的库）
    //
    // 第 2 条是踩坑加的：smoba 有个 ~9.8GB 的映射，单看体积它碾压
    // 一切；加上「合理库大小」这一档后，它会被推到末尾，第 1 次探测
    // 就命中真目标的概率大幅提升。
    for (int i = 0; i < candCount; i++) {
        for (int j = i + 1; j < candCount; j++) {
            bool iInHint = (candBase[i] >= UP_UNITY_HINT_MIN && candBase[i] < UP_UNITY_HINT_MAX);
            bool jInHint = (candBase[j] >= UP_UNITY_HINT_MIN && candBase[j] < UP_UNITY_HINT_MAX);
            bool iSane   = (candSize[i] <= UP_LIB_SIZE_MAX);
            bool jSane   = (candSize[j] <= UP_LIB_SIZE_MAX);

            bool swap;
            if (iInHint != jInHint) {
                swap = jInHint;                    // 1. 区间内优先
            } else if (iSane != jSane) {
                swap = jSane;                      // 2. 合理库大小优先
            } else {
                swap = candSize[j] > candSize[i];  // 3. 体积降序
            }
            if (swap) {
                uint64_t tb = candBase[i], ts = candSize[i];
                candBase[i] = candBase[j]; candSize[i] = candSize[j];
                candBase[j] = tb;          candSize[j] = ts;
            }
        }
    }

    // ── 阶段 2：对候选做 Mach-O 校验（候选数 ≤ UP_MAX_CANDIDATES） ──
    //
    // 注意：这里只接受「真的被 up_probe_macho 认出是 arm64 Mach-O」的候选。
    // 曾经有个「校验全失败时退回体积最大的条目」的兜底，那个兜底会返回
    // **完全未经校验**的地址（smoba 有个 ~9.8GB 的匿名映射，体积碾压
    // UnityFramework 的 280MB，于是被选中 → 基址错到 0x274000000）。
    // 宁可明确失败，也不返回未验证的地址。
    uint64_t fallbackBase = 0;  // 备选：Mach-O 校验通过但没读到库名
    uint64_t fallbackSize = 0;
    uint64_t maxVerifiedSize = 0;
    const char *maxVerifiedName = NULL;
    char maxVerifiedNameBuf[256] = {0};

    for (int i = 0; i < candCount; i++) {
        uint32_t filetype = 0;
        char name[256] = {0};
        // ★ 必须通过 Mach-O 校验，否则这个候选直接作废
        if (!up_probe_macho(candBase[i], &filetype, name, sizeof(name))) continue;

        // 首选：安装名里含 UnityFramework（最可靠，直接返回）
        if (strstr(name, "UnityFramework") != NULL) {
            gUnityBase = candBase[i];
            break;
        }

        // 备选：记录体积最大的「已校验通过的 arm64 dylib」
        if (filetype == MH_DYLIB) {
            if (candSize[i] > fallbackSize) {
                fallbackSize = candSize[i];
                fallbackBase = candBase[i];
            }
            if (candSize[i] > maxVerifiedSize) {
                maxVerifiedSize = candSize[i];
                strlcpy(maxVerifiedNameBuf, name, sizeof(maxVerifiedNameBuf));
                maxVerifiedName = maxVerifiedNameBuf;
            }
        }
    }

    // 没读到库名时，退回「已通过 Mach-O 校验的最大 dylib」，并在文案里说明
    if (gUnityBase == 0 && fallbackBase != 0) {
        gUnityBase = fallbackBase;
        up_set_message("已定位最大 arm64 映像（%s，未读到库名，请核对）",
                       maxVerifiedName ? maxVerifiedName : "名称未知");
    }

    if (gUnityBase == 0) {
        up_set_message("未找到 UnityFramework 映像，请确认游戏已进入对局");
        return 0;
    }

    // ★ 最终闸门：基址必须落在用户态映像窗口内。
    // 任何内核地址 / 异常地址在这里被拦下，绝不让它流到写入路径。
    if (!up_is_user_pointer(gUnityBase)) {
        uint64_t bad = gUnityBase;
        gUnityBase = 0;
        gTargetAddr = 0;
        up_set_message("定位到的基址越界（0x%llx），已放弃以免写错内存", bad);
        return 0;
    }

    gTargetAddr = gUnityBase + UNITY_PATCH_OFFSET;

    // 目标地址也要做同样的窗口校验（偏移较大，防溢出到内核地址空间）
    if (!up_is_user_pointer(gTargetAddr)) {
        uint64_t bad = gTargetAddr;
        gTargetAddr = 0;
        gUnityBase = 0;
        up_set_message("内透目标地址越界（0x%llx），已放弃以免写错内存", bad);
        return 0;
    }

    // 定位成功：把基址/目标地址/页内偏移都记下来，方便真机排错。
    // （日志里能一眼看出目标页离基址有多远，以及是否跨了 vm_map_entry）
    up_set_message("已定位 UnityFramework：base=0x%llx target=0x%llx（偏移 0x%llx，页 0x%llx+0x%llx）",
                   (unsigned long long)gUnityBase,
                   (unsigned long long)gTargetAddr,
                   (unsigned long long)UNITY_PATCH_OFFSET,
                   (unsigned long long)(gTargetAddr & ~0xFFFULL),
                   (unsigned long long)(gTargetAddr & 0xFFFULL));

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
    // 目标地址是 smoba 的用户态地址，必须走用户态窗口校验
    if (!up_is_user_pointer(gTargetAddr)) {
        up_set_message("内透目标地址无效（0x%llx）", gTargetAddr);
        return false;
    }

    // 自愈：正常情况下 polaris_find_unity_framework_base() 里已经登记过 vm_map，
    // 但如果走的是「命中缓存」那条早返回分支（gTargetAddr 已存在），
    // 或者游戏重启过导致旧 vm_map 失效，这里必须重新登记。
    if (!polaris_remote_target()) {
        uint64_t proc = proc_find_by_name(POLARIS_GAME_PROCESS_NAME);
        uint64_t task = (proc && ds_isvalid(proc)) ? proc_task(proc) : 0;
        uint64_t vmMap = (task && ds_isvalid(task)) ? task_get_vm_map(task) : 0;
        if (!vmMap || !ds_isvalid(vmMap)) {
            up_set_message("跨进程访问未就绪，请先点「获取游戏进程」");
            return false;
        }
        polaris_remote_set_target(vmMap);
    }

    // 备份原始指令（只备份一次，重复开启不会覆盖真原始值）
    if (!gHaveBackup) {
        bool ok = false;
        uint32_t current = up_user_read32(gTargetAddr, &ok);
        if (!ok) {
            // 把 remotepage 记录的**真实失败原因**带出来，
            // 否则只能瞎猜「映像未加载」——上一版就是这么误判的。
            char why[192] = {0};
            polaris_remote_describe(why, (int)sizeof(why));
            up_set_message("读目标地址 0x%llx 失败（基址 0x%llx）· %s",
                           (unsigned long long)gTargetAddr,
                           (unsigned long long)gUnityBase,
                           why[0] ? why : "无法映射目标页");
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

    // ★ 写入走 vm_object 共享映射（目标页已映射进本进程），不是 ds_kwrite32。
    // ds_kwrite32 只认内核地址，写用户态地址会被 ds_isvalid 拒掉。
    if (!up_user_write(gTargetAddr, &(uint32_t){ UNITY_PATCH_VALUE }, sizeof(uint32_t))) {
        gEnabled = false;
        char detail[192] = {0};
        polaris_remote_describe(detail, (int)sizeof(detail));
        up_set_message("内透写入失败（%s）", detail[0] ? detail : "无法映射目标页");
        return false;
    }

    // 回读校验：写不生效时不要谎报成功
    bool okV = false;
    uint32_t verify = up_user_read32(gTargetAddr, &okV);
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
    if (!up_is_user_pointer(gTargetAddr)) {
        gEnabled = false;
        up_set_message("目标地址已失效，无法还原");
        return false;
    }
    if (!polaris_remote_target()) {
        up_set_message("跨进程访问未就绪，无法还原");
        return false;
    }

    if (!up_user_write(gTargetAddr, &gOriginalInstruction, sizeof(gOriginalInstruction))) {
        char detail[192] = {0};
        polaris_remote_describe(detail, (int)sizeof(detail));
        up_set_message("内透还原失败（%s）", detail[0] ? detail : "无法映射目标页");
        return false;
    }

    // 回读校验还原结果。注意：目标页可能已被游戏重新映射（换了 vm_object），
    // 所以「读失败」不算还原失败——写已经发出去了，读不到只是映射变了。
    // 只有「读到了但值不对」才报错。
    bool okV = false;
    uint32_t verify = up_user_read32(gTargetAddr, &okV);
    if (okV && verify != gOriginalInstruction) {
        up_set_message("内透还原未生效（回读 0x%08X，期望 0x%08X）",
                       verify, gOriginalInstruction);
        return false;
    }

    gEnabled = false;
    // 还原完成后释放本地映射，避免长期占用 smoba 页的引用
    polaris_remote_flush_cache();
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
