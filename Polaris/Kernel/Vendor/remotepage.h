//
//  remotepage.h
//  Polaris · 跨进程内存访问（vm_object 共享映射）
//
//  ────────────────────────────────────────────────────────────────────────
//  为什么要这个文件？
//
//  darksword 的 `ds_kread* / ds_kwrite*` 只能读写【内核地址】：
//
//      static void set_target_kaddr(uint64_t where) {
//          if (!ds_isvalid(where)) @throw dsexception;   // ds_isvalid 只认内核地址
//          ...
//      }
//
//  而内透目标 `UnityFrameworkBase + 0x09E3F824` 是 **smoba 的用户态地址**
//  （实测 0x12145F824）—— 直接调 ds_kwrite32 会被 ds_isvalid 拒掉。
//
//  要让内核读写落到另一个进程的用户页上，有两条路：
//
//    A. vtop：遍历页表把虚拟地址转成物理地址，再按物理地址读写。
//       ✗ Rein 作者在 iOS 18.6 上实测 `ptov_table / pmap 页表遍历`
//         「两者语义均与预期不符」，此路不通。
//
//    B. vm_object 共享映射（本文件采用）：
//       1) 在目标进程 vm_map 里找到目标地址所属的 vm_map_entry
//       2) 从 entry 解出该页的 vm_object（vme_object_or_delta 是压缩指针）
//       3) 把该 vm_object 引用计数 +1
//       4) 造一个本地 memory entry，篡改其 backing vm_map_entry，
//          让它的 vme_object 指向目标 vm_object
//       5) mach_vm_map 把这一页映射进【本进程】地址空间
//       6) 之后直接 memcpy 读写 —— 读写都走这里
//
//  这样就把「跨进程内核读写」降级成了「本进程内存读写」，既没有 vtop 的
//  语义风险，也不需要给 ds_* 开任何后门。移植自 Rein 的 TaskRop/vm.m
//  （原作者已在 iOS 18.6 真机验证）。
//  ────────────────────────────────────────────────────────────────────────
//

#ifndef polaris_remotepage_h
#define polaris_remotepage_h

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// vmmapremotepage 的返回值
typedef struct {
    uint64_t port;          ///< 本地 memory entry port（用于后续 deallocate）
    uint64_t remoteAddress; ///< 目标进程里的虚拟地址（页首）
    uint64_t localAddress;  ///< 映射进本进程后的地址（页首）
    bool     used;          ///< 映射是否成功

    /// ★ 安全闸门：映射是否**精确**指向 remoteAddress 那一页。
    ///
    /// 建立映射时内核可能拒绝某些 offset 组合，代码会退到备用 offset
    /// （例如 offset=0）。那种情况下映射能用，但 `localAddress` 对应的
    /// 是对象起始处，**不是** remoteAddress 指向的页。
    ///
    /// 读路径：有内容校验（如 Mach-O magic）时可接受不精确映射；
    /// 写路径：**必须** exact==true，否则会把数据写到错误的页上。
    bool     exact;
} polaris_vmshmem_t;

// ---------------------------------------------------------------------------
// 底层原语（移植自 Rein TaskRop/vm.m，已剥离 RemoteCall 依赖）
// ---------------------------------------------------------------------------

/// 把 vm_map 里某个虚拟地址所属的一页，经 vm_object 共享映射进本进程。
/// @param vmMap   目标进程的 vm_map 内核地址
/// @param address 目标进程里的虚拟地址（任意页内偏移，内部会按页对齐）
/// @return 映射结果；used=false 表示失败
polaris_vmshmem_t polaris_vmmap_remote_page(uint64_t vmMap, uint64_t address);

/// 解除一次 polaris_vmmap_remote_page 建立的本地映射。
void polaris_vm_unmap_local(uint64_t localAddress, uint64_t size);

// ---------------------------------------------------------------------------
// 面向内透的高层封装：设置目标进程 + 按虚拟地址读写
// ---------------------------------------------------------------------------

/// 登记目标进程（smoba）的 vm_map，并设置页大小。
/// 后续 polaris_remote_read/write 都用这个 vm_map 做页映射。
void polaris_remote_set_target(uint64_t vmMap);

/// 当前登记的目标 vm_map（0 = 未设置）。
uint64_t polaris_remote_target(void);

/// 从目标进程读取 len 字节。跨页自动分段映射。
/// @return 成功返回 true；任何一步失败返回 false（不抛异常）
bool polaris_remote_read(uint64_t vaddr, void *out, size_t len);

/// 向目标进程写入 len 字节。跨页自动分段映射。
///
/// 注意：写入是直接改共享映射到的本地页 —— 因为映射用的是同一个
/// vm_object，写本地页等价于写目标进程的物理页。
/// @return 成功返回 true
bool polaris_remote_write(uint64_t vaddr, const void *src, size_t len);

/// 读 32 位（失败返回 0）
uint32_t polaris_remote_read32(uint64_t vaddr, bool *ok);

/// 写 32 位（失败返回 false）
bool polaris_remote_write32(uint64_t vaddr, uint32_t value);

/// 释放所有缓存的本地映射（关闭内透 / 切换目标进程时调用）。
void polaris_remote_flush_cache(void);

/// 状态描述（页大小、已映射页数、最近一次失败原因）。
void polaris_remote_describe(char *buffer, int bufferSize);

#ifdef __cplusplus
}
#endif

#endif /* polaris_remotepage_h */
