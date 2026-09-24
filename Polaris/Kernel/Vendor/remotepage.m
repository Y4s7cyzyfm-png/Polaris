//
//  remotepage.m
//  Polaris · 跨进程内存访问（vm_object 共享映射）
//
//  原理与设计说明见 remotepage.h。
//  核心移植自 Rein 的 TaskRop/vm.m（原作者已在 iOS 18.6 真机验证），
//  在其上补了页缓存、跨页分段、异常兜底与状态上报。
//

#import "remotepage.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/vm_map.h>
#import <mach/vm_page_size.h>
#import <string.h>
#import <stdio.h>
#import <stdarg.h>

// ⚠️ 绝对不要 #import <mach/mach_vm.h>。
// Apple 的 iOS SDK 里这个头文件是一个**刻意的报错占位**，整个文件只有一行：
//     #error mach_vm.h unsupported.
// 引入它必然编译失败。mach_vm_allocate / mach_vm_deallocate / mach_vm_map
// 的正确做法是在下面手写 extern（Rein TaskRop/vm.m:20-22 就是这么做的）。

#import "darksword.h"
#import "offsets.h"
#import "utils.h"

// ---------------------------------------------------------------------------
// vm 结构体定义（移植自 Rein TaskRop/vm.h，仅保留本文件需要的部分）
// ---------------------------------------------------------------------------

/// vm_map_entry —— 内核里描述一段虚拟地址区间
struct pr_vmmaplinks {
    uint64_t prev;
    uint64_t tnext;
    uint64_t start;
    uint64_t end;
};

struct pr_vmmapstore {
    uint64_t rbe_left;
    uint64_t rbe_right;
    uint64_t rbe_parent;
};

struct pr_vmmapentry {
    struct pr_vmmaplinks links;
    struct pr_vmmapstore store;

    // 注意：这个 union 的三个成员**必须**与内核 xnu 的 vm_map_entry 完全对齐。
    // 我们只用到 vme_object_or_delta 与 is_sub_map，但少写一个成员会导致
    // 后面的 vme_alias / vme_offset 位域整体错位——那不是编译错误而是静默算错，
    // 所以这里把原版三个变体一个不落地照抄（见 Rein TaskRop/vm.h）。
    union {
        uint32_t vme_object_value;
        struct {
            uint32_t vme_atomic   : 1;
            uint32_t is_sub_map   : 1;
            uint32_t vme_submap   : 30;
        };
        struct {
            uint32_t vme_ctx_atomic      : 1;
            uint32_t vme_ctx_is_sub_map  : 1;
            uint32_t vme_context         : 30;
            union {
                uint32_t vme_object_or_delta;   ///< 压缩后的 vm_object 指针
                uint32_t vme_tag_btref;
            };
        };
    };

    // 下面这一大串位域必须与内核 vm_map_entry 布局严格一致。
    // 我们只关心 vme_offset（对象内偏移）与几个标志位，但**布局不能改**，
    // 否则后续字段会错位。移植时保持原样最安全。
    unsigned long long vme_alias        : 12;
    unsigned long long vme_offset       : 52;
    unsigned long long is_shared        : 1;
    unsigned long long __unused1        : 1;
    unsigned long long in_transition    : 1;
    unsigned long long needs_wakeup     : 1;
    unsigned long long behavior         : 2;
    unsigned long long needs_copy       : 1;
    unsigned long long protection       : 3;
    unsigned long long used_for_tpro    : 1;
    unsigned long long max_protection   : 4;
    unsigned long long inheritance      : 2;
    unsigned long long use_pmap         : 1;
    unsigned long long no_cache         : 1;
    unsigned long long vme_permanent    : 1;
    unsigned long long superpage_size   : 1;
    unsigned long long map_aligned      : 1;
    unsigned long long zero_wired_pages : 1;
    unsigned long long used_for_jit     : 1;
    unsigned long long csm_associated   : 1;
    unsigned long long iokit_acct       : 1;
    unsigned long long vme_resilient_codesign : 1;
    unsigned long long vme_resilient_media    : 1;
    unsigned long long vme_xnu_user_debug     : 1;
    unsigned long long vme_no_copy_on_read    : 1;
    unsigned long long translated_allow_execute : 1;
    unsigned long long vme_kernel_object      : 1;
    unsigned short wired_count;
    unsigned short user_wired_count;
};

/// 压缩指针参数（arm64 iOS 用 base-relative 形式）
struct pr_vmpackingparams {
    uint64_t vmpp_base;
    uint8_t  vmpp_bits;
    uint8_t  vmpp_shift;
    uint8_t  vmpp_base_relative;
};

/// 描述「某虚拟地址 → 它的 vm_object」
struct pr_vmobj {
    uint64_t vmAddress;    ///< 目标进程里的虚拟地址
    uint64_t address;      ///< vm_object 内核地址
    uint64_t objectOffset; ///< vm_object 内偏移（页对齐）
    uint64_t entryOffset;  ///< 目标页在对象内的偏移

    /// ★ v0.4.8：entryOffset 的两个**原始输入**。
    ///
    /// entryOffset = (address - entry.start) + (vme_offset << 12)
    /// 只记录结果的话，一旦数值反常就无法判断是「找错了 entry」
    /// 还是「vme_offset 太大」。带上这两个原始值就能直接验算。
    uint64_t entryStart;   ///< 命中的 vm_map_entry 的 links.start
    uint64_t rawVmeOffset; ///< vme_offset 的原始（未 <<12）值
};

#define PR_PACKED_PTR_BITS                31
#define PR_PACKED_PTR_SHIFT               6
#define PR_KERNEL_POINTER_SIGNIFICANT_BITS 38

// mach_vm_allocate / mach_vm_deallocate / mach_vm_map 这三个**必须**手写 extern。
//
// 它们由 libsystem_kernel 导出，但 Apple 的 iOS SDK 里**没有任何头文件**声明它们：
//   - <mach/vm_map.h>     只提供 vm_map_t / vm_prot_t 这些类型和宏，不声明函数
//   - <mach/mach_vm.h>    是刻意的报错占位（整个文件只有 #error），不能 include
// 不手写声明就会：
//   error: call to undeclared function 'mach_vm_allocate'
//   [-Wimplicit-function-declaration]（CI 上 -Werror=implicit-function-declaration 直接挂）
//
// 签名与 Rein TaskRop/vm.m:20-22 完全一致 —— 那边在同一个 SDK 上已验证可编译。
extern kern_return_t mach_vm_allocate(task_t task, mach_vm_address_t *addr,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address,
                                 mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                                 mem_entry_name_port_t object,
                                 memory_object_offset_t offset, boolean_t copy,
                                 vm_prot_t cur_protection, vm_prot_t max_protection,
                                 vm_inherit_t inheritance);

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

static uint64_t gRemoteVmMap = 0;     ///< 目标进程（smoba）的 vm_map
static uint32_t gPageShift  = 0;      ///< 页大小 shift（iOS 16KB → 14）

/// 最近一次消息。
///
/// ★ v0.4.8 从 256 扩到 1024：失败信息现在要带**逐档明细**
/// （每档 `off/size/prot -> ret` 约 45 字节 × 最多 12 档 ≈ 540 字节），
/// 256 会把最关键的后半段截掉 —— 那正是排查要看的东西。
static char     gMessage[1024] = {0};

/// 最近一次成功映射用的档位标签（写进 describe 输出）。
/// 这一项直接回答「阶梯第几档生效」——是排查 offset 语义的关键证据。
static char gLastGoodLabel[96] = {0};

/// vm_object / entry 的现场数值（在 pr_create_shmem_with_obj 里填）。
/// pr_set_message 会被后续覆盖，所以单独留一份，供 describe 输出。
///
/// ★ v0.4.8 扩容 192→512：现在还要追加 named_entry->offset / size
///   两个此前从未观测过的字段（见 pr_create_shmem_with_obj 的追加逻辑）。
static char gEntryTrace[512] = {0};

/// ★ v0.4.8：**逐档**的失败明细。
///
/// 起因：v0.4.7 的失败信息只报「末档」，前面几档的返回码全部被循环
/// 覆盖。真机日志里只看到 `末档 off=0 size=0x8000000 prot=0x7 (17)`，
/// 于是既不知道第 1 档（`prot=ALL|IS_MASK`）报的是哪个错，也不知道
/// 第 1/2/3 档的 offset 究竟是 0 还是 `0x9e3c000` —— 排查完全靠猜。
///
/// 这里累积每一档的 `off/size/prot -> ret` 摘要，失败时一次性打出。
///
/// ★ v0.4.9 扩容 512→1024：v0.4.8 实测单档摘要最长约 83 字节，而
///   阶梯最多可展到 8 档（2 个 offset 候选 × 3 个 prot，再加 2 个整块档）。
///   8 × 83 = 664 > 512，会被截断 —— 而「截断」正是本项目反复踩的坑，
///   这次提前留够余量。
static char gTierTrace[1024] = {0};

static void pr_set_message(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void pr_set_message(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gMessage, sizeof(gMessage), fmt, ap);
    va_end(ap);
}

static uint64_t pr_page_size(void) {
    return (uint64_t)1 << (gPageShift ? gPageShift : 14);
}

/// 映射这一层**始终**使用 16KB 粒度。
///
/// 原因：`VME_OFFSET(x) = x << 12` 已经是 4KB 单位，而 arm64 iOS 的
/// vm_object / vm_map 都以 16KB 对齐；`mach_vm_map` 又要求 offset 是
/// size 的整数倍。若这里跟着运行时的 4KB 走，就会出现
/// 「size=16KB 而 offset 只按 4KB 对齐」→ 内核直接 KERN_INVALID_ADDRESS。
///
/// 所以映射粒度固定 16KB，与编译期 PAGE_SIZE 保持一致，
/// 消除「两个页大小来源打架」这个隐患。
#define PR_MAP_PAGE_SIZE  ((uint64_t)0x4000)

/// 探测页大小。iPhone 13,4（A14）为 16KB；老设备 4KB。
///
/// 注意：iOS 上 host_page_size() 返回的可能是 4096（部分虚拟化/兼容路径），
/// 但映射层必须按 16KB 走，因此这里**只接受 >= 16KB 的结果**，
/// 更小的值一律提升到 16KB，保证与 PR_MAP_PAGE_SIZE 自洽。
static void pr_detect_page_size(void) {
    if (gPageShift != 0) return;
    vm_size_t ps = 0;
    if (host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps >= 16384) {
        gPageShift = 14;
    }
    if (gPageShift == 0) gPageShift = 14; // 统一 16KB
}

// ---------------------------------------------------------------------------
// 安全内核读取（与 unitypatch.m 同策略：ds_isvalid 预检 + @try/@catch）
//
// 这里读的都是 vm_map / vm_object 这类**内核对象**，地址必然是内核地址，
// 所以 ds_isvalid 预检是合适的。
// ---------------------------------------------------------------------------

static bool pr_kok(uint64_t addr) {
    return addr != 0 && ds_isvalid(addr);
}

static bool pr_safe_kreadbuf(uint64_t addr, void *buf, size_t len) {
    if (!buf || len == 0) return false;
    if (!pr_kok(addr)) return false;
    // 不强制同页：vm_map_entry 等结构体可能跨页，
    // 而 ds_kreadbuf 内部按 8 字节分片，不会一次读过大。
    @try {
        ds_kreadbuf(addr, buf, (uint64_t)len);
    } @catch (NSException *e) {
        return false;
    } @catch (...) {
        return false;
    }
    return true;
}

static uint64_t pr_safe_kread64(uint64_t addr, bool *ok) {
    uint64_t v = 0;
    bool r = pr_safe_kreadbuf(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

static uint32_t pr_safe_kread32(uint64_t addr, bool *ok) {
    uint32_t v = 0;
    bool r = pr_safe_kreadbuf(addr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

static uint64_t pr_safe_kreadptr(uint64_t addr) {
    bool ok = false;
    uint64_t raw = pr_safe_kread64(addr, &ok);
    if (!ok) return 0;
    // 剥 PAC + 回填 canonical 高位（内核指针高 16 位恒为 1）
    uint64_t p = raw & 0x0000FFFFFFFFFFFFULL;
    if (p & (1ULL << 47)) p |= 0xFFFF000000000000ULL;
    return pr_kok(p) ? p : 0;
}

// ---------------------------------------------------------------------------
// 压缩指针解包（vm_object 指针在 entry 里是压缩存储的）
// ---------------------------------------------------------------------------

static bool pr_packing_is_base_relative(struct pr_vmpackingparams *p) {
    return (p->vmpp_bits + p->vmpp_shift) <= PR_KERNEL_POINTER_SIGNIFICANT_BITS;
}

static uint64_t pr_unpack_ptr(uint64_t packed, struct pr_vmpackingparams *params) {
    if (!params->vmpp_base_relative) {
        int64_t addr = (int64_t)packed;
        addr <<= (64 - params->vmpp_bits);
        addr >>= (64 - params->vmpp_bits - params->vmpp_shift);
        return (uint64_t)addr;
    }
    if (packed) {
        return (packed << params->vmpp_shift) + params->vmpp_base;
    }
    return 0;
}

static uint64_t pr_pack_ptr(uint64_t ptr, struct pr_vmpackingparams *params) {
    if (!params->vmpp_base_relative) {
        return ptr >> params->vmpp_shift;
    }
    if (ptr) {
        return (ptr - params->vmpp_base) >> params->vmpp_shift;
    }
    return 0;
}

static struct pr_vmpackingparams pr_make_packing_params(void) {
    struct pr_vmpackingparams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = PR_PACKED_PTR_BITS;
    params.vmpp_shift = PR_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = pr_packing_is_base_relative(&params) ? 1 : 0;
    return params;
}

// ---------------------------------------------------------------------------
// vm_map 遍历与 entry 查找
// ---------------------------------------------------------------------------

static uint64_t pr_vmmap_find_entry(uint64_t vmMap, uint64_t address) {
    if (!pr_kok(vmMap)) return 0;

    uint64_t header = vmMap + off_vm_map_hdr;
    if (!pr_kok(header)) return 0;

    uint64_t entry = pr_safe_kreadptr(header + off_vm_map_header_links_next);
    uint32_t nentries = pr_safe_kread32(header + off_vm_map_header_nentries, NULL);

    int scanned = 0;
    while (entry != 0 && scanned < 4096) {
        if (!pr_kok(entry)) break;
        scanned++;

        bool okS = false, okE = false;
        uint64_t start = pr_safe_kread64(entry + 0x10, &okS);
        uint64_t end   = pr_safe_kread64(entry + 0x18, &okE);
        if (okS && okE && address >= start && address < end) {
            return entry;
        }

        uint64_t next = pr_safe_kreadptr(entry + off_vm_map_entry_links_next);
        if (next == 0) break;
        entry = next;
    }
    (void)nentries;
    return 0;
}

/// 从虚拟地址解析出它的 vm_object 信息
static struct pr_vmobj pr_vm_get_object(uint64_t vmMap, uint64_t address) {
    struct pr_vmobj result = {0};

    uint64_t entryaddr = pr_vmmap_find_entry(vmMap, address);
    if (!entryaddr) {
        pr_set_message("目标页不在任何 vm_map 条目内（0x%llx）",
                       (unsigned long long)address);
        return result;
    }

    struct pr_vmmapentry entry = {0};
    if (!pr_safe_kreadbuf(entryaddr, &entry, sizeof(entry))) {
        pr_set_message("读取 vm_map_entry 失败");
        return result;
    }

    struct pr_vmpackingparams params = pr_make_packing_params();

    uint32_t vmeobject = entry.vme_object_or_delta;
    uint64_t vmeobj    = pr_unpack_ptr((uint64_t)vmeobject, &params);
    uint64_t vmeoffraw = entry.vme_offset;
    uint64_t objoffs   = (vmeoffraw << 12);                     // VME_OFFSET
    uint64_t entryoffs = address - entry.links.start + objoffs;

    if (!pr_kok(vmeobj)) {
        pr_set_message("解出的 vm_object 指针无效（0x%llx）", (unsigned long long)vmeobj);
        return result;
    }

    result.vmAddress    = address;
    result.address      = vmeobj;
    result.objectOffset = objoffs;
    result.entryOffset  = entryoffs;
    result.entryStart   = entry.links.start;
    result.rawVmeOffset = vmeoffraw;
    return result;
}

// ---------------------------------------------------------------------------
// 核心：把目标进程的一页映射进本进程
// ---------------------------------------------------------------------------

/// 按 vm 页大小向上取整。
///
/// 故意自己实现而不用 SDK 的 `mach_vm_round_page()`：那个函数同样没有任何
/// 可 include 的头文件声明它（见上方 extern 块的说明），直接用会触发
/// `-Werror=implicit-function-declaration` 编译失败。
/// 自己写一个，行为与 SDK 完全一致（按 PAGE_SIZE 进位）。
static inline uint64_t pr_round_page(uint64_t x) {
    const uint64_t page = (uint64_t)PAGE_SIZE;
    if (page == 0) return x;
    return (x + page - 1) & ~(page - 1);
}

static polaris_vmshmem_t pr_create_shmem_with_obj(struct pr_vmobj *object) {
    polaris_vmshmem_t shmem = {0};

    // 1) 读 vm_object 大小，算出要对齐的尺寸
    bool okSize = false;
    uint64_t size = pr_safe_kread64(object->address + off_vm_object_vo_un1_vou_size, &okSize);
    if (!okSize) {
        pr_set_message("读取 vm_object 大小失败 (obj=0x%llx off=0x%x)",
                       (unsigned long long)object->address,
                       off_vm_object_vo_un1_vou_size);
        return shmem;
    }
    size = pr_round_page(size);
    uint64_t roundedsize = pr_round_page(size);

    // ★ 诊断：把关键数值全报出来。
    //
    // 记入 gEntryTrace 单独保存（pr_set_message 会被后续覆盖）。
    //
    // ★ v0.4.8 扩充：加上 entryStart / rawVmeOffset 两个**原始输入**。
    //   验算式：entryOffset == (vmAddress - entryStart) + (rawVmeOffset << 12)
    //   只记结果的话，数值反常时无法区分是「entry 找错了」还是
    //   「vme_offset 过大」——v0.4.4 与 v0.4.6/7 的真机 entryOffset
    //   分别是 0x9e3c000 与 0x0，必须能一眼看出成因。
    snprintf(gEntryTrace, sizeof(gEntryTrace),
             "obj=0x%llx objsz=0x%llx entryOff=0x%llx objOff=0x%llx "
             "eStart=0x%llx vmeOffraw=0x%llx addr=0x%llx",
             (unsigned long long)object->address,
             (unsigned long long)roundedsize,
             (unsigned long long)object->entryOffset,
             (unsigned long long)object->objectOffset,
             (unsigned long long)object->entryStart,
             (unsigned long long)object->rawVmeOffset,
             (unsigned long long)object->vmAddress);

    // 把 entryOffset 的构成写进日志（会被后续覆盖，但 gEntryTrace 留底）。
    // 若 (addr - eStart) 恰好等于 entryOffset，说明 vme_offset 为 0，
    // 即这个 entry 不是「对象从段首开始」的常规情形。
    if (object->rawVmeOffset != 0) {
        pr_set_message("注意：vme_offset 非 0（raw=0x%llx），"
                       "entryOffset 含对象内偏移 0x%llx",
                       (unsigned long long)object->rawVmeOffset,
                       (unsigned long long)object->objectOffset);
    }

    // 目标偏移若越出 vm_object 覆盖范围，mach_vm_map 很可能失败。
    // 这里**只记录不拦截**：离线无法确证 vm_object 的 size 语义
    // （vo_un1.vou_size 到底是字节数还是页数、是否含整个 __TEXT），
    // 贸然 return 会把「本来能成的」也拒掉。先让它继续走，
    // 由 mach_vm_map 的真实返回值来判定，日志里留证据。
    if (object->entryOffset >= roundedsize) {
        pr_set_message("警告：目标偏移 0x%llx 越出 vm_object 尺寸 0x%llx",
                       (unsigned long long)object->entryOffset,
                       (unsigned long long)roundedsize);
        // 不 return —— 继续尝试
    }

    if (roundedsize == 0) {
        pr_set_message("vm_object 尺寸为 0 (obj=0x%llx)", (unsigned long long)object->address);
        return shmem;
    }

    // 2) 在本进程分配一块等大的匿名内存（仅作为造 memory entry 的载体）
    mach_vm_address_t localaddr = 0;
    kern_return_t ret = mach_vm_allocate(mach_task_self_, &localaddr, roundedsize,
                                         VM_FLAGS_ANYWHERE);
    if (ret != KERN_SUCCESS) {
        pr_set_message("mach_vm_allocate 失败：%s", mach_error_string(ret));
        return shmem;
    }

    // 3) 为这块内存造一个 memory entry
    //
    // ★ entrysize 是 in/out 参数：内核可能把它改小（例如按实际可共享范围钳制），
    //   所以调用后必须回读，不能继续用请求值。
    //
    // ★★ protection 直接申请 VM_PROT_ALL。
    //
    //   这是 v0.4.7 的关键修正。真机日志（v0.4.6）：
    //       mach_vm_map ... (os/kern) invalid right(0x11)
    //       off=0x0 size=0x4000 objsize=0x16584000 prot=0x7
    //
    //   0x11 = 17 = KERN_INVALID_RIGHT，对应 vm_map.c 的：
    //       if ((named_entry->protection & cur_protection) != cur_protection)
    //           return KERN_INVALID_RIGHT;
    //   我们原先建 entry 时只申请 READ|WRITE（0x3），
    //   而 map 时请求 VM_PROT_ALL（0x7）：
    //       0x3 & 0x7 = 0x3 != 0x7  → 被拒。
    //
    //   所以这里把 entry 的 protection 一步申请到 VM_PROT_ALL，
    //   让「请求权限 ⊆ entry 权限」恒成立。
    //   若内核拒绝 VM_PROT_ALL（对某些对象类型有限制），
    //   退回 READ|WRITE —— 那样下面的阶梯会靠
    //   VM_PROT_IS_MASK 的取交集机制兜底。
    mach_port_t memobj = MACH_PORT_NULL;
    memory_object_size_t entrysize = roundedsize;
    ret = mach_make_memory_entry_64(mach_task_self_, &entrysize,
                                    (memory_object_offset_t)localaddr,
                                    VM_PROT_ALL,
                                    &memobj, MACH_PORT_NULL);
    if (ret != KERN_SUCCESS) {
        // 退回最小可用权限，后面靠 VM_PROT_IS_MASK 取交集兜底
        entrysize = roundedsize;
        memobj    = MACH_PORT_NULL;
        ret = mach_make_memory_entry_64(mach_task_self_, &entrysize,
                                        (memory_object_offset_t)localaddr,
                                        VM_PROT_READ | VM_PROT_WRITE,
                                        &memobj, MACH_PORT_NULL);
    }
    if (ret != KERN_SUCCESS) {
        pr_set_message("mach_make_memory_entry_64 失败：%s", mach_error_string(ret));
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }
    // 回读内核实际给出的 entry 大小；若内核没回填（返回 0）则退回请求值，
    // 避免因为一个未定义的回填把正常路径也堵死。
    memory_object_size_t realEntrySize = entrysize ? entrysize : roundedsize;

    // 4) 顺着 memory entry 找到它内部那个待篡改的 vm_map_entry
    uint64_t shmemnamedentry = task_get_ipc_port_kobject(task_self(), memobj);
    if (!pr_kok(shmemnamedentry)) {
        pr_set_message("取 memory entry 内核对象失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    // ★★★ v0.4.8 关键修正：named_entry->offset 才是真正的对象内偏移。
    //
    //   XNU 证据链（逐条核对过源码）：
    //
    //   (1) mementry.c:4212
    //         if (named_entry->offset) {
    //             vm_map_enter_adjust_offset(&obj_offs, &obj_end,
    //                                        named_entry->offset);
    //         }
    //       而 vm_map_enter_adjust_offset (mementry.c:3966) 做的是
    //         *obj_offs += quantity;  —— 是**加法**，不是替换。
    //
    //   (2) mementry2.c:890（mach_make_memory_entry_64 内部）
    //         user_entry->offset = VME_OFFSET(vm_map_copy_first_entry(copy));
    //       即 offset 在**建 entry 那一刻**就从本地 entry 的 vme_offset
    //       快照下来，之后不再变。
    //
    //   (3) mementry.c:21519（vm_named_entry_to_vm_object）
    //         object = VME_OBJECT(copy_entry);
    //       取对象时**根本不看 vme_offset**。
    //
    //   结论：真正生效的对象内偏移是
    //         effective_offset = mach_vm_map 的 off  +  named_entry->offset
    //
    //   而我们建 entry 时 entry.vme_offset = object->objectOffset 有
    //   **单位错误**：objectOffset 是字节，vme_offset 是 4KB 页单位
    //   （VME_OFFSET(x) = x << 12）。因 (3) 它不影响取对象，但会让
    //   named_entry->offset 变成一个偏大的错值，进而把阶梯里
    //   所有 offset 候选都整体平移掉 —— 这正是 offset 维度"看起来无效"的原因。
    //
    //   修法：显式把 named_entry->offset **归零**，让偏移完全由
    //   mach_vm_map 的 off 决定。这样 O1/O2 才真正可分辨。
    bool     okNEOff       = false;
    uint64_t namedEntryOff = pr_safe_kread64(shmemnamedentry + off_vm_named_entry_offset,
                                             &okNEOff);
    bool     neOffZeroed   = false;
    if (okNEOff && namedEntryOff != 0) {
        @try {
            ds_kwrite64(shmemnamedentry + off_vm_named_entry_offset, 0);
            neOffZeroed = true;
        } @catch (NSException *e) {
            neOffZeroed = false;
        } @catch (...) {
            neOffZeroed = false;
        }
    }
    // 把 named_entry 的两个此前从未观测过的字段带进 trace
    snprintf(gEntryTrace + strlen(gEntryTrace),
             sizeof(gEntryTrace) - strlen(gEntryTrace),
             " neOff=0x%llx%s",
             (unsigned long long)namedEntryOff,
             (neOffZeroed ? "(已归零)" : (namedEntryOff ? "(归零失败)" : "")));

    // ★ 诊断：直接读内核里 vm_named_entry 的 size 字段。
    //   这是 vm_map.c:4155 守卫真正比对的那个值（named_entry->size），
    //   比 entrysize 回读值更权威。有它就能一眼断定是不是"entry 太小"。
    //
    //   注意：它**本来就不等于 vm_object 大小**。osfmk/mach/arm/vm_param.h 里
    //       #define ANON_CHUNK_SIZE (128ULL * 1024 * 1024)   /* 128MB */
    //   内核按 128MB 分块匿名对象，named_entry 只覆盖首块 —— 真机上
    //   观测到的 0x8000000 正是这个常量，属预期行为而非异常。
    bool okNEs = false;
    uint64_t namedEntrySize = pr_safe_kread64(shmemnamedentry + off_vm_named_entry_size, &okNEs);
    if (okNEs) {
        snprintf(gEntryTrace + strlen(gEntryTrace),
                 sizeof(gEntryTrace) - strlen(gEntryTrace),
                 " neSz=0x%llx", (unsigned long long)namedEntrySize);
    }

    // ★★★ v0.4.9 核心修复：把 named_entry->size 抬到足够大。
    //
    //   真机 v0.4.8 逐档日志给出了决定性证据：
    //       #1 off=0x9e3c000 sz=0x4000 prot=0x47 -> (4) invalid argument
    //       #2 off=0x9e3c000 sz=0x4000 prot=0x7  -> (0x11) invalid right
    //       #3 off=0x9e3c000 sz=0x4000 prot=0x3  -> (4) invalid argument
    //       #4 off=0x0       sz=0x8000000 prot=0x7 -> (0x11) invalid right
    //
    //   据此可把两道门**完全反推**出来（模型与真机 4/4 吻合）：
    //
    //   第一道「权限门」(mementry.c:4176-4189)：named_entry->protection = 0x3
    //     prot=0x7 被拒 -> protection 缺 EXECUTE
    //     prot=0x3 通过 -> protection 含 READ|WRITE
    //     prot=0x47 通过 -> mask 置位，请求权限被清零后取交集恒成立
    //
    //   第二道「尺寸门」(mementry.c:4198-4201)：
    //     if (named_entry->size < obj_offs + initial_size) return (4)
    //     named_entry->size = 0x8000000 (128MB = ANON_CHUNK_SIZE)
    //     obj_offs + size   = 0x9e3c000 + 0x4000 = 0x9e40000
    //     0x8000000 < 0x9e40000  ->  触发 -> (4)
    //
    //   ★ 为什么 #2 报 0x11 而 #1/#3 报 0x4：
    //     权限门在尺寸门**之前**。#2 的 prot=0x7 先被权限门拒掉，
    //     根本没机会走到尺寸门。#1/#3 通过了权限门，倒在尺寸门。
    //
    //   ★ 为什么 #4 报 0x11：它的 size 恰好等于 namedEntrySize，
    //     尺寸门**通过**了；但 prot=0x7 在权限门就被拒。
    //
    //   结论：**真正的拦路虎是尺寸门**。权限修好也没用。
    //   而 size 校验只是一个**纯数值比较**，没有任何硬件/MMU 约束——
    //   所以直接把 named_entry->size 抬到够用即可。
    //
    //   需要满足：named_entry->size >= off + size（对我们要用的每档）
    //   最小值就是 entryOffset + 一页，向上取整到页。
    //
    //   注意：named_entry 是本进程私有的对象，随 mach_vm_deallocate
    //   释放，且我们只映射一页，影响面可控。
    if (okNEs && namedEntrySize != 0) {
        // 目标下界：entryOffset + 一页（这是精度最高那一档所需的最小值）
        uint64_t needSize = pr_round_page(object->entryOffset + PR_MAP_PAGE_SIZE);
        if (needSize == 0) needSize = PR_MAP_PAGE_SIZE;

        if (namedEntrySize < needSize) {
            @try {
                ds_kwrite64(shmemnamedentry + off_vm_named_entry_size, needSize);
                snprintf(gEntryTrace + strlen(gEntryTrace),
                         sizeof(gEntryTrace) - strlen(gEntryTrace),
                         " neSz→0x%llx(抬高)", (unsigned long long)needSize);
                namedEntrySize = needSize;
            } @catch (NSException *e) {
                snprintf(gEntryTrace + strlen(gEntryTrace),
                         sizeof(gEntryTrace) - strlen(gEntryTrace),
                         " [neSz 抬高失败:需0x%llx]",
                         (unsigned long long)needSize);
            } @catch (...) {
                snprintf(gEntryTrace + strlen(gEntryTrace),
                         sizeof(gEntryTrace) - strlen(gEntryTrace),
                         " [neSz 抬高失败:需0x%llx]",
                         (unsigned long long)needSize);
            }
        }
    }

    bool okBC = false, okSZ = false;
    uint64_t shmemvmcopyaddr = pr_safe_kread64(shmemnamedentry + off_vm_named_entry_backing_copy, &okBC);
    uint64_t nextaddr        = pr_safe_kread64(shmemvmcopyaddr + off_vm_named_entry_size, &okSZ);
    if (!okBC || !okSZ || !pr_kok(nextaddr)) {
        pr_set_message("解析 named_entry backing copy 失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    struct pr_vmmapentry entry = {0};
    if (!pr_safe_kreadbuf(nextaddr, &entry, sizeof(entry))) {
        pr_set_message("读取本地 entry 失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    // 5) 安全检查：submap / kernel object 不能这样映射
    if (entry.vme_kernel_object || entry.is_sub_map) {
        pr_set_message("目标 entry 是 submap 或 kernel object，无法映射");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    // 6) 篡改本地 entry：把它的 vm_object 换成目标的，偏移也换成目标的
    struct pr_vmpackingparams params = pr_make_packing_params();
    uint64_t packedptr = pr_pack_ptr(object->address, &params);

    // vm_object 引用计数 +1（否则映射建立后对象可能被回收）
    bool okRC = false;
    uint32_t refcount = pr_safe_kread32(object->address + off_vm_object_ref_count, &okRC);
    if (!okRC) {
        pr_set_message("读取 vm_object 引用计数失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }
    @try {
        ds_kwrite32(object->address + off_vm_object_ref_count, refcount + 1);
    } @catch (NSException *e) {
        pr_set_message("提升 vm_object 引用计数失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    } @catch (...) {
        pr_set_message("提升 vm_object 引用计数失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    entry.vme_object_or_delta = (uint32_t)packedptr;
    entry.vme_offset          = object->objectOffset;   // 注意：这是 __builtin 位域赋值

    // 用 ds_kwritezoneelement 写回（zone 元素写入，长度要求 >= 0x20）
    @try {
        ds_kwritezoneelement(nextaddr, &entry, sizeof(entry));
    } @catch (NSException *e) {
        pr_set_message("写回本地 entry 失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    } @catch (...) {
        pr_set_message("写回本地 entry 失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    // 7) 把这一页映射进本进程
    //
    // ★ 这里必须让 size 与 offset 出自**同一个页大小**。
    // 之前的写法是 size 用编译期 PAGE_SIZE(16384)、offset 用 entryOffset
    // （它是按运行时 pr_page_size() 算出来的），两者粒度一旦不一致，
    // 内核会以 KERN_INVALID_ADDRESS 拒绝——这正是 41ms 就失败的原因。
    // 现在两边都统一取 PR_MAP_PAGE_SIZE。
    const uint64_t mapPageSize = PR_MAP_PAGE_SIZE;
    uint64_t mapOffset = object->entryOffset;

    // entryOffset = (page - entry.start) + (vme_offset << 12)。
    // 前者因 page 与 entry.start 都页对齐而是 16KB 的倍数；
    // 后者只有在 vme_offset 为 4 的倍数时才是。普通 Mach-O __TEXT
    // 的 vme_offset 恒为 0，所以正常情况下一定对齐。
    //
    // 万一不对齐，说明这个 entry 并非「对象从段首开始」的常规情形，
    // 硬凑 offset 会读到错位字节——那比直接失败更糟。所以这里明确报错。
    if (mapOffset & (mapPageSize - 1)) {
        pr_set_message("entryOffset 0x%llx 未按 16KB 对齐（vme_offset 非 4 的倍数？），"
                       "拒绝映射以免读到错位数据",
                       (unsigned long long)mapOffset);
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    mach_vm_address_t mappedaddr = 0;

    // ★ 前置记录（不再拦截）：offset 是否落在 named entry 范围内。
    //
    // XNU vm_map.c 的 IKOT_NAMED_ENTRY 分支有：
    //     if (named_entry->size < obj_offs + initial_size) {
    //         return KERN_INVALID_ARGUMENT;
    //     }
    // 我们按真机数据算过：obj_offs(0x9e3c000) + size(0x4000) = 0x9e40000 (158MB)
    // 远小于 objsize(0x16584000 = 357MB)，所以这条**不是**拒绝原因。
    //
    // 这里只把数值写进日志（留在 gMessage 里供 describe 展示），不做 return ——
    // 因为下面的重试阶梯已经能覆盖「entry 比预期小」的情形（候选 3/4/6
    // 都用 offset=0，天然合法），没必要提前把路堵死。
    //
    // 权威上限优先取内核里 vm_named_entry->size；读不到时退回
    // mach_make_memory_entry_64 回读的 entrysize。
    uint64_t limitSize = okNEs ? namedEntrySize : (uint64_t)realEntrySize;
    if (limitSize != 0 && limitSize < mapOffset + mapPageSize) {
        pr_set_message("提示：off+size=0x%llx 超出 entry 尺寸 0x%llx"
                       "（namedEntrySize=0x%llx entrySize=0x%llx），"
                       "将改用 offset=0 的候选",
                       (unsigned long long)(mapOffset + mapPageSize),
                       (unsigned long long)limitSize,
                       (unsigned long long)(okNEs ? namedEntrySize : 0),
                       (unsigned long long)realEntrySize);
    }

    // 8) 建立映射 —— 用「阶梯重试」而不是单次调用
    //
    // ── 为什么需要阶梯 ─────────────────────────────────────────────────
    //
    // 真机 v0.4.4 日志：
    //     mach_vm_map 失败：(os/kern) invalid argument(0x4)
    //     off=0x9e3c000 size=0x4000 objsize=0x16584000
    //
    // 把这个错误码逐条对回 XNU vm_map.c 里所有 return KERN_INVALID_ARGUMENT
    // 的分支后，可以确定性地排除掉大部分：
    //
    //   · vm_sanitize_cur_and_max_prots  —— 传 VM_PROT_ALL，合法
    //   · vm_sanitize_inherit            —— VM_INHERIT_NONE，合法
    //   · vm_sanitize_mask(0)            —— 0 合法
    //   · vm_sanitize_addr_size(offset)  —— 该调用点带
    //       VM_SANITIZE_FLAGS_GET_UNALIGNED_VALUES，**不做**对齐检查
    //   · named_entry->size < obj_offs + initial_size
    //                                    —— 0x16584000(357MB) >=
    //                                       0x9e40000(158MB)，通过
    //
    // 剩下的、静态分析无法再区分的只有两类：
    //
    //   (i)  named_entry->offset != 0
    //        同一分支稍后有：
    //            if (named_entry->offset) {
    //                vm_map_enter_adjust_offset(&obj_offs, &obj_end,
    //                                           named_entry->offset);  // 累加
    //            }
    //        即 obj_offs 会在守卫**之后**再被加上 named_entry->offset。
    //        若它非 0，就存在「守卫通过、但随后越界/溢出被 (4) 拒」的窗口。
    //
    //   (ii) named_entry->size 的真实值小于 0x9e40000（离线读偏移不可证）。
    //
    // 与其继续赌是哪一类，不如把候选组合都试一遍：
    // 每一次失败都是零副作用的（内核拒了不会留下半成品映射），
    // 成功的组合会被 gLastGood 记住，后续同进程直接复用。
    // 这样无论真因是 (i) 还是 (ii)，都能自行收敛。
    //
    // ── 关于 VM_PROT_IS_MASK ──────────────────────────────────────────
    //
    // XNU osfmk/mach/vm_prot.h：
    //     /* Another invalid protection value.
    //        Indicates that the other protection bits are to be applied as a
    //        mask against the actual protection bits of the map entry. */
    //     #define VM_PROT_IS_MASK  ((vm_prot_t) 0x40)
    //
    // 它**不会**导致 KERN_INVALID_ARGUMENT —— vm_map.c 调
    // vm_sanitize_cur_and_max_prots 时把 VM_PROT_IS_MASK 作为 extra_mask
    // 传了进去（vm_sanitize.c 的 allowed 掩码因此包含它），0x47 & ~0x47 == 0。
    // 但语义是错的：置位后 cur_protection 会与 named_entry->protection 取交集。
    // Rein 原版正是这么传的（vm.m:196-197），下面作为候选一并保留，
    // 但**首选**是语义正确的 VM_PROT_ALL。
    //
    // ⚠️ 注意 VM_PROT_IS_MASK 的**权威值**是 0x40，不是 0x80000000。
    //    SDK 的 <mach/vm_prot.h> 若给出别的高位值，说明是占位/过期定义，
    //    本文件因此直接硬编码 0x40，不依赖该头文件。
    //
    // ★★ v0.4.7 修正：它不是「可选的冗余位」，而是**权限校验的必需机制**。
    //
    //   真机 v0.4.6 日志：
    //       mach_vm_map 全部 1 档均失败。末档 off=entryOff prot=RWX:
    //       (os/kern) invalid right(0x11)  off=0x0 size=0x4000 prot=0x7
    //
    //   0x11 = 17 = KERN_INVALID_RIGHT，正是 vm_map.c:4184/4189 两处：
    //       if ((named_entry->protection & cur_protection) != cur_protection)
    //           return KERN_INVALID_RIGHT;
    //   而置位 VM_PROT_IS_MASK 会让内核先做：
    //       cur_protection &= named_entry->protection;   // 取交集
    //   从而把请求权限收缩成 entry 权限的子集，校验必然通过。
    //
    //   我 v0.4.5 曾以「语义错误」为由移除它 —— 那是错的：
    //   它不影响「映射后能否读写」，只影响「请求权限怎么收敛」。
#define PR_VM_PROT_IS_MASK ((vm_prot_t)0x40)

    /// 一次映射尝试的全部输入
    typedef struct {
        uint64_t    offset;   ///< memobj 内偏移（字节）
        uint64_t    size;     ///< 映射长度
        vm_prot_t   prot;     ///< cur/max protection
        bool        exact;    ///< true = 语义上精确指向目标页（可安全用于写入）
        const char *label;    ///< 日志用
    } pr_maptry_t;

    // ── 构造候选阶梯（offset 维度 × prot 维度）─────────────────────
    //
    // ★ 安全前提：**只有 exact == true 的候选才允许被写路径使用**。
    //
    // 为什么这么严格：mach_vm_map 建立的是共享映射，写它会真的改到
    // 目标 vm_object。若某候选把「对象第 0 页」映射进来，写入就会
    // 落到游戏进程对象的第 0 页 —— 那是静默改错内存，比直接失败严重得多。
    // 因此「整块 entry」这一档标 exact=false，由调用层判断。
    //
    // 两个维度：
    //   offset：O1 = entryOffset
    //           O2 = 0（当 entryOffset != 0 时另加，它是否精确见下）
    //           O3 = entryOffset - objectOffset（若对齐且不重复）
    //   prot  ：P1 = VM_PROT_ALL | VM_PROT_IS_MASK（Rein 原版，最稳）
    //           P2 = VM_PROT_ALL（entry 已申请到 ALL 时可直接用）
    //           P3 = VM_PROT_READ | VM_PROT_WRITE（下限兜底）
    //
    // ⚠️ 旧版这里有个设计缺陷：所有候选生成条件都要求 mapOffset != 0，
    //    于是当 entryOffset == 0（真机 v0.4.6 就是这种情况）时
    //    只剩下 1 档 —— 恰好印证了日志里的「全部 1 档均失败」。
    //    现在改为按维度展开，不再依赖 mapOffset 非 0。
    pr_maptry_t tries[12];
    int ntries = 0;

    // offset 候选表（去重）
    uint64_t offs[3];
    int noffs = 0;
    bool offExact[3] = {false, false, false};

    // O1：entryOffset —— 与 Rein 语义一致
    offs[noffs] = mapOffset;
    offExact[noffs] = true;
    noffs++;

    // O2：entryOffset - objectOffset（仅当 objectOffset != 0 且对齐）
    if (object->objectOffset != 0 && mapOffset >= object->objectOffset) {
        uint64_t netOff = mapOffset - object->objectOffset;
        if (netOff != mapOffset && (netOff & (PR_MAP_PAGE_SIZE - 1)) == 0) {
            offs[noffs] = netOff;
            offExact[noffs] = true;
            noffs++;
        }
    }

    // O3：0 —— 仅当它**恰好**指向目标页时才作为精确候选。
    //
    //   0 指向目标页的充要条件是 page == entry.start 且 vme_offset == 0，
    //   即 entryOffset == 0。此时它已与 O1 同值（会被去重）。
    //   另一种情况：entryOffset == objectOffset（page == entry.start），
    //   此时 offset=0 相对「对象起点」也正是目标页 —— 但这一点依赖
    //   offset 的语义解释，不能无条件当作精确，故这里只在 entryOffset==0
    //   时加入（那已由 O1 覆盖），其余情形交给末档的不精确兜底。
    (void)offExact;

    // prot 候选表。标签用**静态字符串**，避免指向局部数组。
    vm_prot_t   prots[3];
    const char *protTags[3];
    int nprots = 0;
    prots[nprots] = (vm_prot_t)(VM_PROT_ALL | PR_VM_PROT_IS_MASK);
    protTags[nprots] = "ALL|IS_MASK";
    nprots++;
    prots[nprots] = VM_PROT_ALL;
    protTags[nprots] = "RWX";
    nprots++;
    prots[nprots] = (vm_prot_t)(VM_PROT_READ | VM_PROT_WRITE);
    protTags[nprots] = "RW";
    nprots++;

    // offset 标签（静态字符串）
    const char *offTags[3];
    for (int i = 0; i < noffs; i++) {
        offTags[i] = (offs[i] == mapOffset) ? "entryOff" : "entryOff-objOff";
    }

    // 笛卡尔积展开（offset 维度优先，prot 维度次之）
    for (int oi = 0; oi < noffs; oi++) {
        for (int pi = 0; pi < nprots; pi++) {
            if (ntries >= (int)(sizeof(tries) / sizeof(tries[0]))) break;

            bool dup = false;
            for (int k = 0; k < ntries; k++) {
                if (tries[k].offset == offs[oi] && tries[k].prot == prots[pi]) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            tries[ntries].offset = offs[oi];
            tries[ntries].size   = mapPageSize;
            tries[ntries].prot   = prots[pi];
            tries[ntries].exact  = true;
            tries[ntries].label  = offTags[oi];   // 具体 prot 见日志 prot=0x%x
            ntries++;
        }
    }

    // ── 末档：整块 entry，offset=0（不精确，仅读路径可接受）──────────
    //
    // 它能让映射成功（把 offset 彻底归零，绕开所有 offset 相关校验），
    // 但映射到的是对象起始处，不是目标页。
    // 只有「读 Mach-O 头」这类自带 magic 校验的调用方才敢用。
    //
    // ★ v0.4.9：真机已证明这一档在 prot=0x7 时**必被权限门拒**（0x11）。
    //   现在给它同时试 0x3（已知 entry 权限）与 0x47（mask 收敛）。
    //   幂等性：命中即 break，成功时不会重复映射。
    if (okNEs && namedEntrySize != 0) {
        uint64_t whole = namedEntrySize;
        if ((whole & (PR_MAP_PAGE_SIZE - 1)) == 0 && whole >= mapPageSize) {
            tries[ntries++] = (pr_maptry_t){ 0, whole,
                                             (vm_prot_t)(VM_PROT_READ | VM_PROT_WRITE),
                                             false, "off=0 整块(RW)" };
            tries[ntries++] = (pr_maptry_t){ 0, whole,
                                             (vm_prot_t)(VM_PROT_ALL | PR_VM_PROT_IS_MASK),
                                             false, "off=0 整块(ALL|IS_MASK)" };
        }
    }

    kern_return_t lastRet = KERN_SUCCESS;
    uint64_t     lastOffset = 0;
    uint64_t     lastSize   = 0;
    vm_prot_t    lastProt   = 0;
    const char  *lastLabel  = "";

    // 命中的候选是否「精确指向目标页」。写路径必须检查这个标志：
    // 不精确的映射虽然可用，但写入会落到对象起始处而非目标页。
    bool hitExact = false;

    // ★ v0.4.8：逐档留痕。每个候选无论成败都记一行
    //   `off/size/prot -> ret`，失败时整条打出来。
    //   这样下一次真机日志能直接看出「哪一档、什么参数、什么错」，
    //   不必再靠末档反推。
    gTierTrace[0] = '\0';
    size_t traceUsed = 0;
    int    skipped    = 0;

    for (int i = 0; i < ntries; i++) {
        pr_maptry_t t = tries[i];

        // 该候选的 size 不能为 0，否则内核必然拒
        if (t.size == 0) { skipped++; continue; }
        // size 必须是页对齐的，否则 vm_sanitize_size 会失败
        if (t.size & (PR_MAP_PAGE_SIZE - 1)) { skipped++; continue; }
        // offset 必须是页对齐的（mach_vm_map 的硬要求）
        if (t.offset & (PR_MAP_PAGE_SIZE - 1)) { skipped++; continue; }

        mach_vm_address_t addr = 0;
        ret = mach_vm_map(mach_task_self_, &addr, t.size, 0, VM_FLAGS_ANYWHERE,
                          memobj, (memory_object_offset_t)t.offset,
                          false /* copy = FALSE */, t.prot, t.prot, VM_INHERIT_NONE);

        lastRet    = ret;
        lastOffset = t.offset;
        lastSize   = t.size;
        lastProt   = t.prot;
        lastLabel  = t.label;

        // 累积这一档的结果（截断保护：宁可少记也不溢出）
        if (traceUsed + 96 < sizeof(gTierTrace)) {
            int n = snprintf(gTierTrace + traceUsed, sizeof(gTierTrace) - traceUsed,
                             "%s#%d off=0x%llx sz=0x%llx prot=0x%x -> %s(0x%x) | ",
                             i ? "" : "",
                             i + 1,
                             (unsigned long long)t.offset,
                             (unsigned long long)t.size,
                             (unsigned)t.prot,
                             mach_error_string(ret), (unsigned)ret);
            if (n > 0) traceUsed += (size_t)n;
        }

        if (ret == KERN_SUCCESS) {
            mappedaddr = addr;
            hitExact   = t.exact;
            snprintf(gLastGoodLabel, sizeof(gLastGoodLabel), "%s（第 %d/%d 档）",
                     t.label, i + 1, ntries);
            pr_set_message("映射成功 · %s · off=0x%llx size=0x%llx prot=0x%x"
                           "（第 %d/%d 档）",
                           t.label,
                           (unsigned long long)t.offset,
                           (unsigned long long)t.size,
                           (unsigned)t.prot,
                           i + 1, ntries);
            break;
        }

        // KERN_INVALID_ADDRESS(1) / KERN_INVALID_RIGHT(2) / (4) 等都继续试下一档；
        // 这些失败不会在内核里留下残留映射，重试是安全的。
    }
    (void)skipped;

    // 把「是否精确」写进 shmem，供上层决定能不能用于写入。
    // 这一位是安全闸门：不精确的映射只允许读，绝不允许写。
    shmem.exact = hitExact;

    if (mappedaddr == 0) {
        // 全部候选都失败：把最后一档的完整现场报出来。
        //
        // ★ v0.4.8：额外打出**逐档明细** gTierTrace。
        //   v0.4.7 只报末档，导致「第 1 档 prot=ALL|IS_MASK 到底报什么错」
        //   完全不可见 —— 而这个信息恰恰是判断权限假设是否成立的关键。
        pr_set_message("mach_vm_map 全部 %d 档均失败。末档 %s：%s(0x%x) "
                       "off=0x%llx size=0x%llx objsize=0x%llx prot=0x%x\n"
                       "  逐档: %s",
                       ntries, lastLabel,
                       mach_error_string(lastRet), (unsigned)lastRet,
                       (unsigned long long)lastOffset,
                       (unsigned long long)lastSize,
                       (unsigned long long)roundedsize,
                       (unsigned)lastProt,
                       gTierTrace[0] ? gTierTrace : "(无明细)");
    }

    // 8) 释放临时载体（映射已独立存在）
    mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);

    shmem.port          = (uint64_t)memobj;
    shmem.remoteAddress = object->vmAddress;
    shmem.localAddress  = (uint64_t)mappedaddr;
    shmem.used          = (mappedaddr != 0);
    return shmem;
}

polaris_vmshmem_t polaris_vmmap_remote_page(uint64_t vmMap, uint64_t address) {
    polaris_vmshmem_t shmem = {0};
    if (!pr_kok(vmMap)) {
        pr_set_message("vm_map 无效");
        return shmem;
    }
    struct pr_vmobj vmobject = pr_vm_get_object(vmMap, address);
    if (!vmobject.address) {
        return shmem; // 文案已在 pr_vm_get_object 里写好
    }
    return pr_create_shmem_with_obj(&vmobject);
}

void polaris_vm_unmap_local(uint64_t localAddress, uint64_t size) {
    if (!localAddress) return;
    // 兜底用 PR_MAP_PAGE_SIZE，与映射时使用的粒度一致，
    // 避免这里按 4KB 释放而留下未回收的映射。
    mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)localAddress,
                       size ? size : PR_MAP_PAGE_SIZE);
}

// ---------------------------------------------------------------------------
// 页缓存（避免同一页反复建立映射）
// ---------------------------------------------------------------------------

#define PR_PAGE_CACHE_CAP   64
#define PR_PAGE_NCACHE_CAP  64

typedef struct {
    uint64_t remotePage;
    uint64_t localPage;
    bool     exact;      ///< 该页的映射是否精确（决定能否用于写入）
} pr_page_slot_t;

static pr_page_slot_t gPageCache[PR_PAGE_CACHE_CAP];
static int            gPageCacheCount = 0;
static uint64_t       gPageNeg[PR_PAGE_NCACHE_CAP];
static int            gMapFailLogged = 0;

static bool pr_page_is_bad(uint64_t page) {
    uint64_t mask = PR_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_NCACHE_CAP; i++) {
        uint64_t v = gPageNeg[(h + i) & mask];
        if (v == page) return true;
        if (v == 0) return false;
    }
    return false;
}

static void pr_page_mark_bad(uint64_t page) {
    uint64_t mask = PR_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_NCACHE_CAP; i++) {
        uint64_t slot = (h + i) & mask;
        if (gPageNeg[slot] == page) return;
        if (gPageNeg[slot] == 0) { gPageNeg[slot] = page; return; }
    }
    gPageNeg[h] = page;
}

static uint64_t pr_page_cache_get(uint64_t remotePage) {
    uint64_t mask = PR_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_CACHE_CAP; i++) {
        pr_page_slot_t *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) return s->localPage;
        if (s->remotePage == 0) break;
    }
    return 0;
}

/// 查缓存里这一页的映射是否精确（能否用于写入）。
static bool pr_page_cache_get_exact(uint64_t remotePage, bool *found) {
    uint64_t mask = PR_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_CACHE_CAP; i++) {
        pr_page_slot_t *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) {
            if (found) *found = true;
            return s->exact;
        }
        if (s->remotePage == 0) break;
    }
    if (found) *found = false;
    return false;
}

static void pr_page_cache_put(uint64_t remotePage, uint64_t localPage, bool exact) {
    if (gPageCacheCount >= PR_PAGE_CACHE_CAP) {
        polaris_remote_flush_cache();
    }
    uint64_t mask = PR_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_CACHE_CAP; i++) {
        pr_page_slot_t *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) {
            s->localPage = localPage;
            s->exact     = exact;
            return;
        }
        if (s->remotePage == 0) {
            s->remotePage = remotePage;
            s->localPage  = localPage;
            s->exact      = exact;
            gPageCacheCount++;
            return;
        }
    }
}

/// 首次映射失败的详细原因。pr_set_message 会被后续调用覆盖，
/// 而映射失败往往发生在深层（pr_create_shmem_with_obj 内部），
/// 于是到上层只剩一句笼统的话。这里把第一次失败的完整原因单独留存。
///
/// ★ v0.4.8 从 192 扩到 1024：现在要装下逐档明细，
/// 192 字节会在 `逐档:` 刚开头处就被截断。
static char gFirstFailDetail[1024] = {0};

/// 最近一次成功映射用的档位标签（写进 describe 输出）。

/// 把远程一页映射进本进程。
/// @param remotePage 目标进程里的页首地址（按 pr_page_size() 对齐）
/// @param outExact   输出：该映射是否精确指向 remotePage（可传 NULL）
/// @return 本地页首地址（与 remotePage 一一对应）；0 表示失败
static uint64_t pr_map_remote_page(uint64_t remotePage, bool *outExact) {
    if (outExact) *outExact = false;

    bool cachedFound = false;
    uint64_t local = pr_page_cache_get(remotePage);
    if (local) {
        if (outExact) *outExact = pr_page_cache_get_exact(remotePage, &cachedFound);
        return local;
    }
    if (pr_page_is_bad(remotePage)) return 0;
    if (!gRemoteVmMap) {
        pr_set_message("未登记目标 vm_map");
        return 0;
    }

    polaris_vmshmem_t sh = polaris_vmmap_remote_page(gRemoteVmMap, remotePage);
    if (!sh.used || !sh.localAddress) {
        // ★ 保留第一次失败的详细原因（含 mach_vm_map 的内核返回码）
        if (gFirstFailDetail[0] == '\0') {
            if (gMessage[0] != '\0') {
                snprintf(gFirstFailDetail, sizeof(gFirstFailDetail), "%s", gMessage);
            } else {
                snprintf(gFirstFailDetail, sizeof(gFirstFailDetail),
                         "映射 0x%llx 失败（无详细信息）", (unsigned long long)remotePage);
            }
        }
        if (gMapFailLogged < 3) {
            gMapFailLogged++;
        }
        pr_page_mark_bad(remotePage);
        return 0;
    }
    pr_page_cache_put(remotePage, sh.localAddress, sh.exact);
    if (outExact) *outExact = sh.exact;
    return sh.localAddress;
}

void polaris_remote_flush_cache(void) {
    uint64_t ps = pr_page_size();
    for (int i = 0; i < PR_PAGE_CACHE_CAP; i++) {
        if (gPageCache[i].remotePage) {
            polaris_vm_unmap_local(gPageCache[i].localPage, ps);
            gPageCache[i].remotePage = 0;
            gPageCache[i].localPage  = 0;
        }
    }
    gPageCacheCount = 0;
    memset(gPageNeg, 0, sizeof(gPageNeg));
    gMapFailLogged = 0;
    gFirstFailDetail[0] = '\0';
    gLastGoodLabel[0] = '\0';
    gEntryTrace[0] = '\0';
    gTierTrace[0] = '\0';
}

// ---------------------------------------------------------------------------
// 高层读写封装
// ---------------------------------------------------------------------------

void polaris_remote_set_target(uint64_t vmMap) {
    if (gRemoteVmMap == vmMap) return;
    polaris_remote_flush_cache();   // 换了目标进程，旧映射全部作废
    gRemoteVmMap = vmMap;
    pr_detect_page_size();
}

uint64_t polaris_remote_target(void) {
    return gRemoteVmMap;
}

bool polaris_remote_read(uint64_t vaddr, void *out, size_t len) {
    if (!out || len == 0) return false;
    if (gPageShift == 0) pr_detect_page_size();

    uint64_t ps = pr_page_size();
    uint64_t page = vaddr & ~(ps - 1);
    uint64_t off  = vaddr - page;

    // 跨页：拆成两段分别处理
    if (off + len > ps) {
        size_t first = (size_t)(ps - off);
        return polaris_remote_read(vaddr, out, first) &&
               polaris_remote_read(vaddr + first, (char *)out + first, len - first);
    }

    // 读路径允许使用不精确映射：调用方（如 Mach-O 探测）自带内容校验，
    // 读到错页会被 magic 挡掉，属于「安全失败」。
    uint64_t local = pr_map_remote_page(page, NULL);
    if (!local) return false;
    memcpy(out, (const void *)(local + off), len);
    return true;
}

bool polaris_remote_write(uint64_t vaddr, const void *src, size_t len) {
    if (!src || len == 0) return false;
    if (gPageShift == 0) pr_detect_page_size();

    uint64_t ps = pr_page_size();
    uint64_t page = vaddr & ~(ps - 1);
    uint64_t off  = vaddr - page;

    if (off + len > ps) {
        size_t first = (size_t)(ps - off);
        return polaris_remote_write(vaddr, src, first) &&
               polaris_remote_write(vaddr + first, (const char *)src + first, len - first);
    }

    // ★ 写路径**必须**用精确映射。
    //
    // 建立映射时若退到了备用 offset（例如 offset=0），映射指向的是
    // 对象起始处而非目标页；此时写入会改到游戏进程对象的第一页上 ——
    // 那是静默写错内存，后果比直接失败严重得多。
    // 所以这里主动拒绝不精确映射，并把原因写进日志。
    bool exact = false;
    uint64_t local = pr_map_remote_page(page, &exact);
    if (!local) return false;
    if (!exact) {
        pr_set_message("拒绝写入 0x%llx：本地映射不精确（备用 offset 建立），"
                       "写入会落到对象起始页而非目标页",
                       (unsigned long long)vaddr);
        // 保留首次失败原因（如果不是失败、只是不精确，这里补记）
        if (gFirstFailDetail[0] == '\0') {
            snprintf(gFirstFailDetail, sizeof(gFirstFailDetail),
                     "映射不精确（备用 offset）· 拒绝写入 0x%llx",
                     (unsigned long long)vaddr);
        }
        return false;
    }

    memcpy((void *)(local + off), src, len);
    return true;
}

uint32_t polaris_remote_read32(uint64_t vaddr, bool *ok) {
    uint32_t v = 0;
    bool r = polaris_remote_read(vaddr, &v, sizeof(v));
    if (ok) *ok = r;
    return r ? v : 0;
}

bool polaris_remote_write32(uint64_t vaddr, uint32_t value) {
    return polaris_remote_write(vaddr, &value, sizeof(value));
}

void polaris_remote_describe(char *buffer, int bufferSize) {
    if (!buffer || bufferSize <= 0) return;
    if (gRemoteVmMap == 0) {
        snprintf(buffer, (size_t)bufferSize, "跨进程访问未就绪（未登记目标 vm_map）");
        return;
    }
    // ★ 优先返回「首次映射失败」的原因。
    // 映射失败发生在深层（pr_create_shmem_with_obj 里 mach_vm_map 返回非 0），
    // 那条信息会被后续无关的 pr_set_message 覆盖掉，所以单独留了一份。
    // 只有它才能真正回答「为什么读不到目标页」——是偏移越界、权限不足，
    // 还是 memobj 无效。放在 gMessage 之前判断，确保不会被冲掉。
    if (gFirstFailDetail[0] != '\0') {
        snprintf(buffer, (size_t)bufferSize, "%s", gFirstFailDetail);
        return;
    }
    if (gMessage[0] != '\0') {
        snprintf(buffer, (size_t)bufferSize, "%s", gMessage);
        return;
    }
    snprintf(buffer, (size_t)bufferSize,
             "跨进程访问就绪 · 页大小 %llu KB · 已映射 %d 页 · %s",
             (unsigned long long)(pr_page_size() / 1024), gPageCacheCount,
             gLastGoodLabel[0] ? gLastGoodLabel : "尚未建立映射");
}
