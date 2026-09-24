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
#import <string.h>
#import <stdio.h>
#import <stdarg.h>

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
};

#define PR_PACKED_PTR_BITS                31
#define PR_PACKED_PTR_SHIFT               6
#define PR_KERNEL_POINTER_SIGNIFICANT_BITS 38

// mach_vm_allocate / mach_vm_deallocate / mach_vm_map 由 <mach/vm_map.h> 提供，
// 这里**不要**再手写 extern：手写的签名缺 task_t 等类型声明，
// 且会与实际 SDK 里的 _Nullable / audit_token 属性冲突。

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

static uint64_t gRemoteVmMap = 0;     ///< 目标进程（smoba）的 vm_map
static uint32_t gPageShift  = 0;      ///< 页大小 shift（iOS 16KB → 14）
static char     gMessage[256] = {0};

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

/// 探测页大小。iPhone 13,4（A14）为 16KB；老设备 4KB。
static void pr_detect_page_size(void) {
    if (gPageShift != 0) return;
    vm_size_t ps = 0;
    if (host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps > 0) {
        if (ps >= 16384)     gPageShift = 14;
        else if (ps >= 4096) gPageShift = 12;
    }
    if (gPageShift == 0) gPageShift = 14; // 兜底 16KB
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
        pr_set_message("目标页不在任何 vm_map 条目内（0x%llx）", address);
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
        pr_set_message("解出的 vm_object 指针无效（0x%llx）", vmeobj);
        return result;
    }

    result.vmAddress    = address;
    result.address      = vmeobj;
    result.objectOffset = objoffs;
    result.entryOffset  = entryoffs;
    return result;
}

// ---------------------------------------------------------------------------
// 核心：把目标进程的一页映射进本进程
// ---------------------------------------------------------------------------

static polaris_vmshmem_t pr_create_shmem_with_obj(struct pr_vmobj *object) {
    polaris_vmshmem_t shmem = {0};

    // 1) 读 vm_object 大小，算出要对齐的尺寸
    bool okSize = false;
    uint64_t size = pr_safe_kread64(object->address + off_vm_object_vo_un1_vou_size, &okSize);
    if (!okSize) {
        pr_set_message("读取 vm_object 大小失败");
        return shmem;
    }
    size = mach_vm_round_page(size);
    uint64_t roundedsize = mach_vm_round_page(size);
    if (roundedsize == 0) {
        pr_set_message("vm_object 尺寸为 0");
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
    mach_port_t memobj = MACH_PORT_NULL;
    memory_object_size_t entrysize = roundedsize;
    ret = mach_make_memory_entry_64(mach_task_self_, &entrysize,
                                    (memory_object_offset_t)localaddr,
                                    VM_PROT_READ | VM_PROT_WRITE,
                                    &memobj, MACH_PORT_NULL);
    if (ret != KERN_SUCCESS) {
        pr_set_message("mach_make_memory_entry_64 失败：%s", mach_error_string(ret));
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
    }

    // 4) 顺着 memory entry 找到它内部那个待篡改的 vm_map_entry
    uint64_t shmemnamedentry = task_get_ipc_port_kobject(task_self(), memobj);
    if (!pr_kok(shmemnamedentry)) {
        pr_set_message("取 memory entry 内核对象失败");
        mach_vm_deallocate(mach_task_self_, localaddr, roundedsize);
        return shmem;
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
    mach_vm_address_t mappedaddr = 0;
    vm_prot_t curprot = VM_PROT_ALL | VM_PROT_IS_MASK;
    vm_prot_t maxprot = VM_PROT_ALL | VM_PROT_IS_MASK;

    ret = mach_vm_map(mach_task_self_, &mappedaddr, PAGE_SIZE, 0, VM_FLAGS_ANYWHERE,
                      memobj, (memory_object_offset_t)object->entryOffset,
                      false /* copy = FALSE */, curprot, maxprot, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        pr_set_message("mach_vm_map 失败：%s", mach_error_string(ret));
        mappedaddr = 0;
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
    mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)localAddress,
                       size ? size : PAGE_SIZE);
}

// ---------------------------------------------------------------------------
// 页缓存（避免同一页反复建立映射）
// ---------------------------------------------------------------------------

#define PR_PAGE_CACHE_CAP   64
#define PR_PAGE_NCACHE_CAP  64

typedef struct {
    uint64_t remotePage;
    uint64_t localPage;
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

static void pr_page_cache_put(uint64_t remotePage, uint64_t localPage) {
    if (gPageCacheCount >= PR_PAGE_CACHE_CAP) {
        polaris_remote_flush_cache();
    }
    uint64_t mask = PR_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PR_PAGE_CACHE_CAP; i++) {
        pr_page_slot_t *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) { s->localPage = localPage; return; }
        if (s->remotePage == 0) {
            s->remotePage = remotePage;
            s->localPage  = localPage;
            gPageCacheCount++;
            return;
        }
    }
}

static uint64_t pr_map_remote_page(uint64_t remotePage) {
    uint64_t local = pr_page_cache_get(remotePage);
    if (local) return local;
    if (pr_page_is_bad(remotePage)) return 0;
    if (!gRemoteVmMap) {
        pr_set_message("未登记目标 vm_map");
        return 0;
    }

    polaris_vmshmem_t sh = polaris_vmmap_remote_page(gRemoteVmMap, remotePage);
    if (!sh.used || !sh.localAddress) {
        // 坏指针很常见（未映射页），只记前几次防刷屏
        if (gMapFailLogged < 3) {
            gMapFailLogged++;
        }
        pr_page_mark_bad(remotePage);
        return 0;
    }
    pr_page_cache_put(remotePage, sh.localAddress);
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

    uint64_t local = pr_map_remote_page(page);
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

    uint64_t local = pr_map_remote_page(page);
    if (!local) return false;
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
    if (gMessage[0] != '\0') {
        snprintf(buffer, (size_t)bufferSize, "%s", gMessage);
        return;
    }
    snprintf(buffer, (size_t)bufferSize,
             "跨进程访问就绪 · 页大小 %llu KB · 已映射 %d 页",
             (unsigned long long)(pr_page_size() / 1024), gPageCacheCount);
}
