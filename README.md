# Polaris · 北极星

> iOS 内核工具箱 · DarkSword 内核读写（TrollStore 环境专用）
>
> SwiftUI + Objective-C++ · iOS 16.0+ · Xcode 16+ · arm64e · 强制深色模式

## 功能

**Tab 1 · 功能**
- 状态卡：设备型号 / 系统版本 / 引擎信息 / 激活状态徽标 / 实时进度与阶段
- 主按钮：启动内核利用（DarkSword 链路：内核缓存准备 → offsets 初始化 → `ds_run()`）
- 副按钮：**获取游戏进程**（按钮样式与主按钮区分，位于主按钮正下方；内核就绪后可点，解析 `smoba` 主二进制进程）
- 就绪后展示 Kernel Base / Kernel Slide（内核读写原语已建立）
- 利用选项：利用引擎（DarkSword，固定）、详细日志（实时控制台）
- 控制台日志：环形缓冲实时滚动，同步落盘 `Documents/polaris.log`（write+fsync，闪退不丢）
- 功能开关：**开启内透**（王者荣耀 · UnityFramework 指令补丁，可开关还原）

**Tab 2 · 设置**
- 加入官方 Telegram 频道（打开链接）
- 关于：版本 / 项目代号 / 构建环境

## 开启内透（王者荣耀）

把内核读写直接作用到游戏进程的 UnityFramework 映像上，补丁地址：

```
target = UnityFrameworkBase + 0x09E3F824      // 开启写入
value  = 0xD2800021                           // arm64: mov w1, #1
                                              // 等价于 CFSwapInt32(0x210080D2)
```

做法与常见 dylib 插件一致（插件版见 `Patchoffset.h` 的 `write_mem<T>`），
区别只在**跨进程**：

| | dylib 插件 | Polaris |
|---|---|---|
| 运行位置 | 游戏进程内 | 独立 App |
| 基址来源 | `dyld_get_image_vmaddr_slide()` | 内核遍历 smoba 的 `vm_map` 条目 |
| 写内存 | `vm_protect` + `vm_write`（本进程） | `polaris_remote_write()`（vm_object 共享映射） |
| 能否直接调 il2cpp | ✅ 可以（同进程） | ❌ 不行（见下） |

### 为什么 dylib 那套不能照搬（也不能"不需要 UnityFramework"）

常有人问：「dylib 插件是不是根本不需要 UnityFramework？」
**不是。** 两者都需要它，只是「怎么拿到基址」不同：

| 环节 | dylib 插件 | Polaris |
|---|---|---|
| 拿基址 | `_dyld_get_image_vmaddr_slide(i)` —— **同进程** dyld API，注入后与 smoba 共享地址空间，遍历 `_dyld_image_count()` 即可 | 内核侧遍历 smoba 的 `vm_map` 条目 + Mach-O 头校验 |
| 调 il2cpp | `dlopen("Frameworks/UnityFramework.framework/UnityFramework")` 后 `dlsym` 拿 `il2cpp_*` 符号，在**游戏进程内**执行 | **做不到** —— `il2cpp_class_get_method_from_name()` 必须在游戏进程里跑，跨进程无法调用 |

所以 `Il2CppAttach(@"Frameworks/UnityFramework.framework/UnityFramework")`
这一步是 **必须的**：它不是为了找基址，而是为了 `dlopen` Unity 的二进制、
再 `dlsym` 出 `il2cpp_*` 函数指针。插件只是省掉了「手动算基址」。

> 顺带印证：插件里 `getMethod()` 最后算的是
> `rvaOffset = method_abs - image_base` —— 说明**只有 RVA 是跨进程可搬运的量**。
> 这正好独立验证了本项目用 `UnityFrameworkBase + 0x09E3F824` 的做法。

**结论**：`0x09E3F824` 是 UnityFramework 的 RVA，拿到它就够了；
il2cpp 那套运行时解析对我们没用，因为我们没法在 smoba 里执行代码 ——
只能老老实实定位基址、然后**直接改 `__TEXT` 字节**。

**基址定位**（`Vendor/unitypatch.m`）：

1. `proc_find_by_name("smoba")` → `proc_task()` → `task_get_vm_map()`
2. **阶段 1**：遍历 vm_map 条目，只读条目自身 `start`/`end`，
   筛出体积 ≥ 8 MB 的映像作为候选（UnityFramework 实测约 280 MB，普通 framework 远小于此）
3. **阶段 2**：候选按「UnityFramework 常见映像区间优先 + 体积降序」排序，
   逐个校验 `MH_MAGIC_64` + `CPU_TYPE_ARM64`，解析 `LC_ID_DYLIB` 取安装名
4. 命中名含 `UnityFramework` 的映像即为基址；取不到库名时退回「最大的 arm64 dylib」

> 两阶段策略的意义不只是省时间：旧版「每个条目都读 Mach-O 头」会对游戏内核内存
> 发起大量探测，容易被游戏的反作弊（tersafe / owl）注意到。改成候选制后，
> 内核读次数下降约 57%~85%（普通 framework 一个都不会碰）。

**开关语义**（与逆向源码一致）：

- 开启：先备份目标地址原始指令，再写入 `0xD2800021`，然后**回读校验**
- 关闭：把备份的原始指令写回
- 备份只做一次，重复开关不会把补丁值当成原始值
- 写不生效（回读不符）会明确报错，不会谎报成功

**注意**：合入对局后 UnityFramework 才加载完成，请在游戏内进入对局后再开启内透。

## 稳定性：内核读取一律走安全包装

`darksword` 的 `ds_kread*` 内部会调用 `set_target_kaddr()`，而该函数在地址不合法时
**会抛 ObjC 异常**（`@throw dsexception`）：

```objc
static void set_target_kaddr(uint64_t where) {
    if (!ds_isvalid(where)) {
        ...
        @throw [NSException exceptionWithName:@"dsexception" ...];   // ← 这里
    }
    ...
}
```

这个异常从 `ds_kreadbuf` → `early_kread` 一路都是纯 C 函数，中间没有任何 `@try/@catch`。
ObjC 异常穿出 C 边界到 Swift 时，libc++abi 只能 `std::terminate()` → `abort()` → **SIGABRT**。

**v0.2.0 实机崩溃即由此而来**（`lastExceptionBacktrace` 顶到
`polaris_find_unity_framework_base` → `ds_kreadbuf` → `early_kread` → `set_target_kaddr`
→ `objc_exception_throw` → `abort()`）：遍历 vm_map 时把内核链表里的垃圾值
当成了条目指针，直接去读 `entry + 0x10`，地址非法 → 抛异常 → 打崩。

**修复**（v0.4.1）：本文件内**所有**内核读取都改走 `up_safe_*` 包装：

```objc
static bool up_safe_kreadbuf(uint64_t addr, void *buf, size_t len) {
    if (!buf || len == 0) return false;
    if (!up_kaddr_ok(addr)) return false;        // 先用 ds_isvalid() 挡掉明显非法地址
    if (!up_same_page(addr, len)) return false;  // 再拒绝跨页读（early_krw 按页映射）
    @try {
        ds_kreadbuf(addr, buf, len);
    } @catch (NSException *e) {
        return false;                            // 兜底：异常就地吞掉，绝不外泄
    } @catch (...) {
        return false;
    }
    return true;
}
```

配套加固：

| 措施 | 说明 |
|---|---|
| 循环入口守卫 | `if (!up_kaddr_ok(entry)) break;` —— 条目指针非法即中止，不再往下摸 |
| 环路检测 | `visited[512]` 记录已访问条目，内核链表自环时不会死循环 |
| 遍历上限 | `UP_MAX_ENTRIES 4096`，异常链表不会无限扫 |
| load commands 上限 | `UP_MAX_LC 1024` + `cmdsize` 合法性检查 |
| 偏移自检 | `off_vm_map_*` 未装载时直接报错返回，不用错偏移乱读 |
| 写入也加护栏 | `ds_kwrite32` 同样包在 `@try/@catch` 里 |
| kernel 指针剥离 PAC | `up_safe_kreadptr()` 读指针后清 PAC 并回填 canonical 高位 |

设计目标：**遍历任意（可能不可信）内核地址时永不抛异常**——要么返回数据，
要么返回 0，绝不让 `dsexception` 穿过 C 调用链。

## 跨进程访问：为什么不能直接 `ds_kwrite32`

这是 v0.4.3 的核心修复。`ds_kread*` / `ds_kwrite*` **只能读写内核地址**：

```objc
static void set_target_kaddr(uint64_t where) {
    if (!ds_isvalid(where)) @throw dsexception;   // ds_isvalid 只认 0xffffff.. / 0xfffffe..
    ...
}
```

`where` 在底层被当成**内核虚拟地址**塞进 `icmp6filter` 指针里做读写，
所以用户态地址**永远不可能**被 `ds_*` 直接访问。

而内透目标是 `UnityFrameworkBase + 0x09E3F824` —— 这是 **smoba 的用户态地址**
（实测 `0x12145F824`）。于是 v0.4.2 的表现是：

```
09:10:18.992  stage: 正在定位 UnityFramework
09:10:19.028  stage: 未找到 UnityFramework 映像，请确认游戏已进入对局
```

**只用了 36ms** —— 因为 `up_probe_macho()` 走的还是 `up_safe_kreadbuf()`
（带 `ds_isvalid` 预检），每个候选都在第一字节就被拒，一轮下来秒退。

### vtop 为什么也不行

最直觉的方案是 vtop（遍历页表把虚拟地址翻成物理地址）。但 [Rein](https://github.com/Y4s7cyzyfm-png/Rein)
作者在 iOS 18.6 真机上实测后写下了结论：

> 读取——不再走 `ptov_table` / `pmap` 页表遍历（iOS 18.6 上两者语义均与预期不符）。

### 采用的方案：vm_object 共享映射

`Vendor/remotepage.{h,m}`，移植自 Rein 的 `TaskRop/vm.m`（原作者真机验证过）：

1. 在目标 `vm_map` 里找到目标地址所属的 `vm_map_entry`
2. 从 entry 解出该页的 `vm_object`（`vme_object_or_delta` 是**压缩指针**）
3. 把 `vm_object` 引用计数 `+1`（否则映射建立后对象可能被回收）
4. 在本进程造一个 `memory entry`，篡改其 backing `vm_map_entry`，
   让 `vme_object` 指向目标对象、`vme_offset` 指向目标页
5. `mach_vm_map` 把这一页映射进**本进程**地址空间
6. 之后直接 `memcpy` —— 读写都退化成普通用户态内存访问

关键点：

| 项 | 值 / 说明 |
|---|---|
| `VM_PAGE_PACKED_PTR_BITS` | 31 |
| `VM_PAGE_PACKED_PTR_SHIFT` | 6 |
| 压缩指针基准 | `VM_MIN_KERNEL_ADDRESS`（base-relative 当 `bits+shift <= 38`） |
| `vme_offset` 单位 | **4KB**（`VME_OFFSET(x) = x << 12`），不是设备页大小 |
| 映射页大小 | **固定 16KB**（`PR_MAP_PAGE_SIZE`），`mach_vm_map` 的 size 与 offset 同源 |
| 页缓存 | `PR_PAGE_CACHE_CAP 64` 条正向缓存 + 64 条负缓存（记住映射失败的页） |
| 跨页读写 | 自动分段递归，按页边界切开 |

### 页大小必须只有一个来源（v0.4.4 修复）

v0.4.3 在真机上定位成功、却在读目标页时 **41ms 秒退**。根因是
`mach_vm_map` 的 `size` 与 `offset` 用了**两个不同的页大小来源**：

```c
mach_vm_map(..., PAGE_SIZE /* 编译期 16384 */, ...,
            memobj, object->entryOffset /* 按运行时 pr_page_size() 算 */, ...);
```

而 `pr_detect_page_size()` 里有一条 4KB 分支：

```c
if (ps >= 16384)      gPageShift = 14;
else if (ps >= 4096)  gPageShift = 12;   // ← 一旦命中，page 按 4KB 对齐
```

这会算出 `offset = 0x9e3f000`、而 `size = 0x4000`，`offset % size != 0`，
内核直接以 `KERN_INVALID_ADDRESS` 拒绝。

修法：

1. 新增 `PR_MAP_PAGE_SIZE`（16KB），映射层的 `size` 与 `offset` 都由它推出；
2. `pr_detect_page_size()` 不再接受 4096，一律提升到 16KB，与该常量自洽；
3. 显式校验 `entryOffset` 的 16KB 对齐（`entryOffset = (page - entry.start) + (vme_offset << 12)`，
   普通 Mach-O `__TEXT` 的 `vme_offset` 恒为 0，正常必然对齐），
   万一不对齐**直接报错**而不是硬凑 offset —— 硬凑会读到错位字节，比失败更危险。

> 曾尝试「把 offset 下取整到 16KB，再用 delta 补偿页内偏移」，
> 仿真发现 delta 较大时本地窗口会整体前移、反而覆盖不到目标地址，故弃用。

### `offset` 语义歧义与二维阶梯重试（v0.4.6 → v0.4.7）

#### 第一次真机（v0.4.4）：`KERN_INVALID_ARGUMENT(4)`

```
读目标地址 0x121fc3824 失败（基址 0x118184000）
· mach_vm_map 失败：(os/kern) invalid argument(0x4)
  off=0x9e3c000 size=0x4000 objsize=0x16584000
```

把 `off/size/objsize` 三个数代回去算，可以**确定性地否掉两个假设**：

| 假设 | 推算 | 结论 |
|---|---|---|
| offset 未按 16KB 对齐 | `0x9e3c000 % 0x4000 == 0` | ✗ 否掉（且错误码会是 `KERN_INVALID_ADDRESS(1)`） |
| offset 越出 vm_object | `0x9e3c000 + 0x4000 < 0x16584000` | ✗ 否掉 |

再把 `KERN_INVALID_ARGUMENT(4)` 逐条对回 `vm_map.c` 里所有返回该码的分支：

| 分支 | 判定 |
|---|---|
| `vm_sanitize_cur_and_max_prots` | 传 `VM_PROT_ALL`，合法 → 不是 |
| `vm_sanitize_inherit` | `VM_INHERIT_NONE`，合法 → 不是 |
| `vm_sanitize_mask(0)` | `0` 合法 → 不是 |
| `vm_sanitize_addr_size(offset)` | 该调用点带 `GET_UNALIGNED_VALUES`，不做对齐检查 → 不是 |
| `named_entry->size < obj_offs + initial_size` | `0x16584000`(357MB) ≥ `0x9e40000`(158MB) → **通过** |

剩下两类静态分析无法区分：

1. `named_entry->offset != 0` —— 同一分支稍后会把 `obj_offs` **再累加**一次
   `named_entry->offset`，存在「守卫通过、随后越界被拒」的窗口；
2. `named_entry->size` 的真实值小于 `0x9e40000`（内核偏移 `0x20` 离线不可证）。

**修法（v0.4.6）：不再赌是哪一类，改成阶梯重试。**

#### 第二次真机（v0.4.6）：错误码变成 `KERN_INVALID_RIGHT(0x11)`

```
已定位 UnityFramework：base=0x13ae6c000 target=0x144cab824
                     （偏移 0x9e3f824，页 0x144ca8000+0x3824）
读目标地址 0x144cab824 失败（基址 0x13ae6c000）
· mach_vm_map 全部 1 档均失败。末档 off=entryOff prot=RWX：
  (os/kern) invalid right(0x11)
  off=0x0 size=0x4000 objsize=0x16584000 prot=0x7
```

这条日志同时说明**两件事**，一件好一件坏。

**好消息：offset 那一层已经过了。** 错误码从 `(4)` 变成
`0x11` = 17 = `KERN_INVALID_RIGHT`，说明内核已经走到
`vm_map.c` 更靠后的位置：

```c
/* vm_map.c:4184 / 4189 */
if (mask_max_protection) max_protection &= named_entry->protection;
if (mask_cur_protection) cur_protection &= named_entry->protection;

if ((named_entry->protection & max_protection) != max_protection) {
    vmlp_api_end(VM_MAP_ENTER_MEM_OBJECT, KERN_INVALID_RIGHT);
    return KERN_INVALID_RIGHT;
}
if ((named_entry->protection & cur_protection) != cur_protection) {
    vmlp_api_end(VM_MAP_ENTER_MEM_OBJECT, KERN_INVALID_RIGHT);
    return KERN_INVALID_RIGHT;
}
```

即 **`named_entry` 的权限不够**：我们的 entry 是 `R|W`（`0x3`），
而 map 时请求 `prot=0x7`（`VM_PROT_ALL`），`(0x3 & 0x7) != 0x7` → 拒。

**坏消息：阶梯写坏了，只生成了 1 档。** 日志里
`全部 1 档均失败` 的「1」暴露了实现缺陷——旧版所有 offset 候选的
生成条件都写死了 `mapOffset != 0`，而这次 `entryOffset == 0`
（目标页恰好是 entry 的第一页），于是只剩候选 #1。

> `entryOffset` 两次真机分别是 `0x9e3c000` 和 `0x0`，
> 因为 smoba 每次启动的 `vm_map` 布局不同。这是**合法**的，
> 也恰恰说明阶梯必须覆盖 `offset == 0`。

#### v0.4.7 的两处修正

**① 恢复 `VM_PROT_IS_MASK`（`0x40`）—— 它不是我 v0.4.5 以为的「冗余位」。**

`VM_PROT_IS_MASK` 是 XNU 提供的**权限收敛机制**，
`vm_map_enter_mem_object` 在检查前会执行：

```c
mask_cur_protection = cur_protection & VM_PROT_IS_MASK;
mask_max_protection = max_protection & VM_PROT_IS_MASK;
cur_protection &= ~VM_PROT_IS_MASK;
max_protection &= ~VM_PROT_IS_MASK;
```

置位后 `mask_*` 非 0，于是先做 `cur_protection &= named_entry->protection`，
把请求权限**收缩成 entry 权限的子集**，`0x7 → 0x3`，校验必然通过。
它不影响「映射后能否读写」，只影响「请求权限怎么收敛」。

**② 顺带把 `mach_make_memory_entry_64` 的 protection 提到 `VM_PROT_ALL`**
（失败退回 `READ|WRITE`），让「请求权限 ⊆ entry 权限」恒成立。

**③ 阶梯改为二维笛卡尔积**，不再依赖 `mapOffset != 0`：

| 维度 | 候选 |
|---|---|
| offset | `O1 = entryOffset`（Rein 语义）<br>`O2 = entryOffset - objectOffset`（当 `objectOffset != 0` 且 16KB 对齐） |
| prot | `P1 = VM_PROT_ALL \| VM_PROT_IS_MASK`（Rein 原版，**首选**）<br>`P2 = VM_PROT_ALL`<br>`P3 = VM_PROT_READ \| VM_PROT_WRITE`（下限兜底） |

展开后（去重）外加一个**不精确末档**：

| 场景 | 候选数 | 展开结果 |
|---|---|---|
| A：`entryOffset == 0` | 4 | `(O1,P1) (O1,P2) (O1,P3)` + 不精确末档 |
| B：`entryOffset == 0x9e3c000` | 7 | 6 个精确 + 不精确末档 |

两种场景下**第 1 档都是 `(off=entryOffset, prot=0x47)`**，
与 Rein 的原始写法完全一致。

失败档位在内核里**不留残留映射**，重试是零副作用的；哪一档成功会写进日志。

#### 安全闸门：`exact`

末档虽然能让映射成功，但它指向的是**对象起始处**而非目标页。
`polaris_vmshmem_t` 因此新增 `exact` 字段，并贯穿页缓存：

- **读路径**允许不精确映射 —— 调用方（Mach-O 探测）自带 magic 校验，读到错页会被挡掉，是「安全失败」；
- **写路径强制要求 `exact == true`** —— 否则拒绝写入并报错。
  因为映射是共享的，写错页等于**真的改到游戏进程的对象第 0 页**，
  比直接失败严重得多。

#### 第三次真机（v0.4.7）：4 档全失败，但**信息被截断了**

```
读目标地址 0x123bc3824 失败（基址 0x119d84000）
· mach_vm_map 全部 4 档均失败。末档 off=0 size=namedEntrySize(不精确)：
  (os/kern) invalid right(0x11)
  off=0x0 size=0x8000000 objsize=0x16584000 prot=0x7
  · obj=0xffffffe66cffed00 ob        ← 就这样断了
```

这一版**推进了**（档数从 1 涨到 4，说明二维展开生效），
但也暴露了两个问题。

**问题一：只能看到末档。** 前 3 档（尤其第 1 档 `prot=ALL|IS_MASK`）
的返回码全被循环覆盖。而「第 1 档报什么错」恰恰是判断
`VM_PROT_IS_MASK` 假设是否成立的关键 —— 看不到就只能猜。

**问题二：日志被截断。** `· obj=0xffffffe66cffed00 ob` 后面没了。
逐层查下来是四个缓冲区太小：

| 位置 | 原大小 | 现在 |
|---|---|---|
| `remotepage.m` `gMessage` | 256 | 1024 |
| `remotepage.m` `gFirstFailDetail` | 192 | 1024 |
| `unitypatch.m` `gMessage` | 256 | 1024 |
| `unitypatch.m` `why` / `detail` | 192 | 1024 |
| **`PolarisBridge.mm` `message`**（×3） | 256 | 1024 |

最后一行才是真正的截断点：`remotepage` 辛苦拼出的长信息，
到了 `char message[256]` 又被砍回 256 字节。

> 教训：诊断信息在 C→OC 的边界上被静默截断，是最难发现的一类问题。
> 排查时不要把「日志短」当成「信息本来就少」。

#### 数值核对（本轮）

| 项 | 值 | 判定 |
|---|---|---|
| `target - base` | `0x123bc3824 - 0x119d84000` = `0x9e3f824` | ✅ 与内透偏移完全一致 |
| `namedEntrySize` | `0x8000000` = 128 MB | ⚠️ 与 `roundedsize`(`0x16584000` = 357 MB) 不符，待查 |
| `objsize` | `0x16584000` = 357 MB | 与 entry 128 MB 不同量级 |
| `obj` | `0xffffffe66cffed00` | ✅ 在 `[VM_MIN, VM_MAX]` 内且 64 字节对齐 |

`obj` 是合法的（落在 `0xffffffdc00000000 ~ 0xfffffffbffffffff` 之间），
所以「压缩指针解包错误」这个怀疑被排除。

> 顺带澄清一个**看着像 bug 其实不是**的点：
> `entry.vme_offset = object->objectOffset;` 写的是字节值，
> 而字段语义是 4KB 单位（读路径用 `VME_OFFSET(x) = x << 12`），
> 看起来放大了 4096 倍。但 `mach_vm_map` 走的是 **named_entry** 路径，
> 用的是 `named_entry->offset` 而非 `vme_offset`，所以这处写入
> 不影响映射成败 —— Rein 原版就是这么写的，属于无副作用的历史遗留。

#### v0.4.8：先把「看得见」做对

连续三轮都在「靠末档反推」上吃亏，所以这一版**不加新假设**，
只把日志做够：

1. **逐档留痕 `gTierTrace`** —— 每档记一行
   `#n off=0x.. sz=0x.. prot=0x.. -> err(0x..)`，失败时整条打出。
2. **`gEntryTrace` 补上原始输入** —— 增加 `eStart`(`entry.links.start`)
   与 `vmeOffraw`，使 `entryOffset` 可以现场验算：
   ```
   entryOffset ?= (vmAddress - entryStart) + (vmeOffraw << 12)
   ```
   只记结果的话，数值反常时无法区分「找错了 entry」还是「vme_offset 过大」。
3. **`vme_offset` 非 0 时主动告警** —— 常规 Mach-O `__TEXT` 的
   `vme_offset` 恒为 0，非 0 说明这个 entry 不是「对象从段首开始」。
4. **通路上所有消息缓冲区统一扩到 1024**（见上表）。

目标是让 v0.4.8 的真机日志**一次就能定位**：
第 1 档到底报什么、`entryOffset` 由哪两项构成、
`namedEntrySize` 与 `roundedsize` 为何不等。

### 读取路径的分层

修复后 `unitypatch.m` 的读取分成明确两层：

| 函数族 | 目标 | 底层 |
|---|---|---|
| `up_safe_kread*` | **内核对象**（`vm_map` / `vm_map_entry` / `vm_object` / `proc` / `task`） | `ds_kreadbuf` + `ds_isvalid` 预检 + `@try/@catch` |
| `up_user_read*` | **smoba 用户态**（Mach-O 头、UnityFramework 指令） | `polaris_remote_*` → vm_object 共享映射 + `memcpy` |

内透写入同理走 `up_user_write()`（== `polaris_remote_write()`），
不再是 `ds_kwrite32`——后者写用户态地址会被 `ds_isvalid` 直接拒掉。

> **踩坑记录**：`up_safe_kreadstr()` 已删除。它只在读内核字符串时有用，
> 而 Mach-O 的 `LC_ID_DYLIB` 名字在 smoba 用户态，必须走 `up_user_readstr()`。

## 获取游戏进程

「获取游戏进程」读取的是游戏主二进制 `smoba` 的进程，实现方式与 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的
`ReinReadGameProcess()` 一致（`Vendor/gameproc.m`）：

```objc
uint64_t proc = proc_find_by_name("smoba");          // 遍历 allproc/kernproc
uint32_t pid  = ds_kread32(proc + off_proc_p_pid);   // 读内核 proc 结构体取 pid
```

- 纯内核态链表遍历，不依赖 `task_for_pid` / `sysctl`（TrollStore 环境无 debug 授权，只有 krw 原语）
- **必须先「启动内核利用」**，内核未就绪时按钮置灰；点击后会提示「请先启动内核利用」
- 成功后在按钮上显示 pid 与「smoba · 已附加」，阶段栏同步显示「游戏进程已找到（smoba · pid N）」
- 未找到时（游戏未启动）给出「未找到游戏进程 smoba，请确认游戏已启动」，可在游戏启动后再次点击重试

接口位于 `Polaris/Kernel/Vendor/gameproc.{h,m}`，经 `PolarisBridge` 暴露给 SwiftUI：

| C 接口 | 说明 |
|---|---|
| `PolarisAcquireGameProcess()` | 同步查找 `smoba`，返回是否成功 |
| `PolarisGameProcessIsReady()` | 是否已成功获取 |
| `PolarisGameProcessPID()` | 进程 pid（0 = 未获取） |
| `PolarisGameProcessProcAddress()` | 内核 proc 结构体地址 |
| `PolarisGameProcessStatus()` | 状态文案 |

## 内核部分

DarkSword 内核利用代码来自 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的 Vendor 目录（`darksword-kexploit`），仅保留内核读写所需闭包：

- 核心：`darksword.m`（漏洞利用 + krw 原语）、`offsets.m`（内核偏移）、`utils.m`
- 支撑：`pe/`（vfs / sbx / vnode / xpaci）、`fileport.h`
- 游戏进程：`gameproc.m`（按进程名解析 `smoba`，见上一节）
- 内透补丁：`unitypatch.m`（跨进程定位 UnityFramework + 指令补丁，见上一节）
- 跨进程内存：`remotepage.m`（vm_object 共享映射 + 页缓存，见上一节）
- 预编译库：`libxpf.dylib`、`libgrabkernel2.dylib`（arm64e thin，运行时从 `Frameworks/` 加载）
- persistence 使用 stub（`transfer_krw_to_launchd` 不启用）
- 不含：RemoteCall、TaskRop、choma、decrypt/ota/screentime 等非必需模块

SwiftUI 通过 `Polaris-Bridging-Header.h` 调用 `PolarisBridge.mm`（精简自 ReinBridge）暴露的 C 接口。

## 快速开始

```bash
open Polaris.xcodeproj   # Xcode 16+ 打开，⌘R 运行（真机 arm64e）
```

## 需要替换的占位符

| 位置 | 内容 | 当前占位值 |
|---|---|---|
| `Polaris/SettingsView.swift` | `telegramURL` | `https://t.me/polaris_channel` |
| `Polaris.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER`（Debug/Release 两处） | `com.polaris.toolkit` |
| `codemagic.yaml` | `BUNDLE_ID` / `APP_VERSION` | `com.polaris.toolkit` / `0.4.8` |

> CI 里 `MARKETING_VERSION` 现在取 `${APP_VERSION}`（此前被硬编码成 `0.2.0`，
> 会导致 pbxproj 里的版本号在 CI 构建时被覆盖——崩溃日志里 `app_version: 0.2.0`
> 与工程里的 `0.4.x` 对不上就是这个原因）。

## CI（Codemagic）

`codemagic.yaml` 借鉴了 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 的流水线结构：

1. `xcodebuild` 无签名编译（`CODE_SIGNING_ALLOWED=NO`，**arm64e 单架构**）
2. `lipo -info` 校验产物架构
3. `ldid` 伪签主二进制与嵌入 dylib（`supports/entitlements-polaris.plist`）
4. dylib 统一收入 `Frameworks/` 并校验进包
5. 打包 `Polaris.tipa`（TrollStore 可直接安装），并复制一份 `Polaris.ipa`（侧载工具可用）

推送任意分支自动触发构建，产物在构建页 Artifacts 下载。

## 目录结构

```
Polaris/
├── Polaris.xcodeproj/         # Xcode 16 同步组格式工程（含共享 Scheme）
├── Polaris/
│   ├── PolarisApp.swift       # 入口 + 双 Tab
│   ├── Polaris-Bridging-Header.h
│   ├── Theme.swift            # 主题 / 通用卡片组件
│   ├── DeviceInfo.swift       # 设备与系统信息
│   ├── FunctionView.swift     # 功能页（DarkSword 引导 + 控制台日志）
│   ├── SettingsView.swift     # 设置页
│   ├── Assets.xcassets/       # 图标与强调色
│   └── Kernel/                # DarkSword 桥接与 Vendor 闭包
│       ├── PolarisBridge.h/.mm
│       └── Vendor/            # darksword-kexploit 精简闭包 + arm64e dylib
├── supports/
│   └── entitlements-polaris.plist
├── codemagic.yaml             # CI 配置
└── README.md
```

## 版本变更

| 版本 | 变更 |
|---|---|
| 0.4.8 | **修「诊断信息被截断」，不再新增内核侧假设**。第三轮真机（v0.4.7）档数已从 1 涨到 4（二维展开生效），但仍报 `invalid right(0x11)`；且日志止于 `· obj=0xffffffe66cffed00 ob` ——**被静默截断**。逐层查出是缓冲区太小：`remotepage.m` 的 `gMessage`(256) / `gFirstFailDetail`(192)、`unitypatch.m` 的 `gMessage`(256) / `why`(192) / `detail`(192)、以及**真正的截断点** `PolarisBridge.mm` 的 `char message[256]`（×3）——`remotepage` 拼好的长信息在 C→OC 边界又被砍回 256 字节。全部统一扩到 1024。同时：**① 新增 `gTierTrace` 逐档留痕**，每档记 `#n off/sz/prot -> err`，失败时整条打出（此前只看得到末档，第 1 档 `prot=ALL\|IS_MASK` 报什么错完全不可见）；**② `gEntryTrace` 补上原始输入** `eStart`/`vmeOffraw`，使 `entryOffset = (vmAddress - entryStart) + (vmeOffraw << 12)` 可现场验算；**③ `vme_offset` 非 0 时主动告警**。数值核对：`target-base = 0x9e3f824` ✅ 正确；`obj=0xffffffe66cffed00` ✅ 落在 `[VM_MIN,VM_MAX]` 内且 64 字节对齐（**排除「压缩指针解包错误」**）；`namedEntrySize=0x8000000`(128MB) 与 `roundedsize=0x16584000`(357MB) 不符 ⚠️ 待查 |
| 0.4.7 | **修复 `(os/kern) invalid right(0x11)`，并修正 v0.4.6 阶梯的两处缺陷**。真机 v0.4.6 日志把错误码从 `KERN_INVALID_ARGUMENT(4)` 推进到 `KERN_INVALID_RIGHT(17)`——**offset/size 那层已经通过**，说明 v0.4.6 的阶梯方向对了。剩下的拒绝点是 `vm_map.c:4184/4189` 的权限子集校验：entry 是 `R\|W`(`0x3`)，map 请求 `VM_PROT_ALL`(`0x7`)，`(0x3 & 0x7) != 0x7` → 拒。**① 恢复 `VM_PROT_IS_MASK`(`0x40`) 作为首选 prot 候选**：v0.4.5 以「语义用错」为由移除它是**错的**，它其实是 XNU 的权限收敛机制（置位后内核先做 `cur_protection &= named_entry->protection`，把 `0x7` 收缩成 `0x3`），不影响「映射后能否读写」，只影响「请求权限怎么收敛」。**② `mach_make_memory_entry_64` 的 protection 提到 `VM_PROT_ALL`**（失败退回 `READ\|WRITE`），让「请求权限 ⊆ entry 权限」恒成立。**③ 阶梯从一维改为二维笛卡尔积** {`entryOffset`, `entryOffset-objectOffset`} × {`ALL\|IS_MASK`, `ALL`, `RW`}：v0.4.6 所有 offset 候选的生成条件都写死 `mapOffset != 0`，而真机这次 `entryOffset == 0`，于是只剩 1 档，正好对应日志里的「全部 1 档均失败」。**④** 失败信息末尾无条件追加 `gEntryTrace`（`obj/objsz/entryOff/objOff`），避免这四个关键数被后续 `pr_set_message` 覆盖。**`VM_PROT_IS_MASK` 假设经第三轮真机未能证实（4 档全败）** |
| 0.4.6 | **用「阶梯重试」取代对 `mach_vm_map` 单次调用**：v0.4.5 加的 `named_entry->size` 校验经真机数据回算后**未被触发**（`0x16584000` = 357MB ≥ 需要的 `0x9e40000` = 158MB），说明拒绝点不在尺寸上。把 `KERN_INVALID_ARGUMENT(4)` 逐条对回 `vm_map.c` 的所有分支后，剩下的候选（`named_entry->offset` 非 0 导致 `obj_offs` 二次累加；或 `named_entry->size` 真实值更小）静态无法区分，于是改为按优先级逐个尝试 offset/size/prot 组合，失败档位零副作用。新增 `polaris_vmshmem_t.exact` 安全闸门：**读路径**允许不精确映射（Mach-O magic 自校验兜底），**写路径强制要求精确**，避免退化的 `offset=0` 映射把 4 字节写到游戏对象的错误页上。**遗留缺陷（v0.4.7 修）：阶梯写成一维且条件写死 `mapOffset != 0`，`entryOffset == 0` 时只剩 1 档** |
| 0.4.5 | **定位「(os/kern) invalid argument」的怀疑点**：v0.4.4 已证明 offset(`0x9e3c000`) 与 size(`0x4000`) 都 16KB 对齐、且远在 vm_object 之内，故「不对齐/越界」两个假设被数据否掉。错误码是 `KERN_INVALID_ARGUMENT(4)` 而非 `KERN_INVALID_ADDRESS(1)`，据此怀疑 XNU `vm_map.c` 的 `if (named_entry->size < obj_offs + initial_size)` 守卫。本次：① 回读 `mach_make_memory_entry_64` 的 in/out `entrysize`；② 直接读内核里 `vm_named_entry->size`（+0x20）作为权威上限；③ 映射前显式校验并给出可读原因；④ 去掉 `VM_PROT_IS_MASK`；⑤ 失败日志追加 `prot`。**事后回算证明该守卫未触发，本版假设不成立**；且第 ④ 点移除 `VM_PROT_IS_MASK` 本身也是错的（v0.4.7 已恢复并说明原因） |
| 0.4.4 | **修复「目标地址读不到内容」（41ms 秒退）**：`mach_vm_map` 的 `size` 取编译期 `PAGE_SIZE`(16KB)、`offset` 取按运行时 `pr_page_size()` 算出的 `entryOffset`，两个页大小来源不一致；当 `host_page_size()` 返回 4096 时 `offset % size != 0`，内核以 `KERN_INVALID_ADDRESS` 拒绝。改为统一用 `PR_MAP_PAGE_SIZE`(16KB)，`pr_detect_page_size()` 不再接受 4KB，并新增 `entryOffset` 的 16KB 对齐校验（不对齐直接报错，不硬凑 offset）。同时把映射失败的**真实内核返回码**透出到日志，取代原先误导性的「映像可能未加载」 |
| 0.4.3 | **修复「未找到 UnityFramework 映像」（36ms 秒退）**：根因是 `ds_kread*`/`ds_kwrite*` 只认内核地址，而 UnityFramework 基址与内透目标都是 smoba 用户态地址，被 `ds_isvalid` 全数拒掉。新增 `remotepage.{h,m}` 跨进程访问层——移植 Rein `TaskRop/vm.m` 的 **vm_object 共享映射**（vtop 在 iOS 18.6 上语义不符，已排除），把目标页映射进本进程后用 `memcpy` 读写；读取路径按目标分成 `up_safe_kread*`（内核对象）/ `up_user_read*`（smoba 用户态）两层；内透写入改走 `up_user_write()` 而非 `ds_kwrite32`；定位前先 `polaris_remote_set_target(vmMap)` 登记目标进程，开启/关闭路径带自愈重登记 |
| 0.4.2 | **修复内透定位到错误基址**：去掉「校验失败时退回体积最大条目」的危险兜底（smoba 有个 ~9.8GB 匿名映射，体积碾压 UnityFramework 的 280MB，导致基址错到 `0x274000000`）；阶段 1 增加页对齐筛选，候选上限提到 64 且不再按体积裁剪；排序改为「特征区间 → 合理库大小（≤2GB）→ 体积降序」；新增基址/目标地址的最终窗口闸门，越界即放弃 |
| 0.4.1 | **修复开启内透导致的 Polaris SIGABRT 崩溃**：`unitypatch.m` 全部内核读取改走 `up_safe_*`（`ds_isvalid` 预检 + `@try/@catch` 兜底），vm_map 遍历加指针守卫 / 环路检测 / 上限；定位改为两阶段候选制，内核读次数大幅下降；CI `MARKETING_VERSION` 不再被硬编码覆盖 |
| 0.4.0 | 新增「开启内透」开关（King of Glory / UnityFramework 指令补丁，支持开关还原） |
| 0.3.0 | 新增「获取游戏进程」按钮（`smoba` 主二进制，Rein 同款 `proc_find_by_name`） |
| 0.2.0 | DarkSword 内核利用链路打通 |
