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

#### 与 KuaiDou（第三方逆向）的交叉验证

对照一份 KuaiDou.ipa 的静态分析报告，逐条核对我们这条链路：

| KuaiDou 组件 | 我们 | 结论 |
|---|---|---|
| `vm_map_find_entry` | `pr_vmmap_find_entry` | ✅ 等价 |
| `vm_get_object` | `pr_vm_get_object` | ✅ 等价 |
| `vm_create_shmem_with_object` | `pr_create_shmem_with_obj` | ✅ 等价 |
| `vm_map_remote_page` | `polaris_vmmap_remote_page` | ✅ 等价 |
| `task_get_ipc_port_kobject` | 已用 | ✅ 等价 |
| **`vm_map_rb_walk`** | 用链表 `links.next` | ⚠️ 见下 |
| **`kread_smrptr`** | **没有** | ⚠️ 见下 |

两条**结构性差异**：

1. **`vm_map_rb_walk` vs 链表遍历。** XNU 的 `vm_map_entry` 同时挂在
   两个结构上：`links`（按地址排序的双向链表）和 `store`（红黑树）。
   两条路径**内容相同**，所以结果应当一致；但 KuaiDou 走红黑树，
   说明红黑树在异常布局下更稳。我们的链表遍历带环路检测与 4096 上限，
   先记下这个差异，暂不改动。

2. **`kread_smrptr` 用于读取带 SMR（Safe Memory Reclamation）保护的指针。**
   `vm_map` 的 entry 链表在并发修改时用 SMR 保护。我们的
   `pr_safe_kreadptr` 直接从内核读指针，**遇到正在被回收的 entry
   可能读到脏值或 NULL**。这可以解释「为什么同一个地址，
   有时能定位到 entry、有时 entryOffset 变成 0」。

另外报告确认了两条与实现一致的细节：

- **`ds_kread` 按最多 0x20 字节分块**，`ds_kwrite32` 是
  read-modify-write。`sizeof(vm_map_entry)` ≈ 0x88 远超 0x20，
  所以我们走 `ds_kwritezoneelement` 而非 `ds_kwrite32` —— **正确**。
- **KuaiDou 的映射尺寸是 `0x8000`（32KB）**，不是整个 `vm_object`。
  这提示我们：`named_entry->size` 未必等于 `vm_object` 的大小，
  而 `mach_vm_map` 的 `offset + size` 必须落在它之内。

> 用 XNU 源码核对我们使用的 offset，全部正确：
> `_vm_map.hdr` 在 `+0x10`（前面是 `lck_rw_t lock`），
> `hdr.links` = `{prev,next,start,end}` 各 8 字节，
> 所以 `entry+0x8` = `links.next`、`entry+0x10` = `start`、
> `entry+0x18` = `end`。`vm_map_entry.store` 在 `+0x20`，我们不需要它。

#### 深挖报告后的三个定论（v0.4.8）

把报告里提到的每个量都拿去和 XNU 源码对了一遍，得到三个确定结论。

**结论一：`named_entry->offset` 才是真正生效的对象内偏移 —— 这是个真 bug。**

`mach_vm_map` 走 `IKOT_NAMED_ENTRY` 分支时，内核会做：

```c
/* mementry.c:4212 */
if (named_entry->offset) {
    vm_map_enter_adjust_offset(&obj_offs, &obj_end, named_entry->offset);
}
```

而 `vm_map_enter_adjust_offset`（`mementry.c:3966`）做的是 **`*obj_offs += quantity`**。

于是有效偏移是：

```
effective_offset = mach_vm_map 传入的 off  +  named_entry->offset
```

关键在于 `named_entry->offset` 是**建 entry 那一刻就冻结的快照**：

```c
/* mementry2.c:890，mach_make_memory_entry_64 内部 */
user_entry->offset = VME_OFFSET(vm_map_copy_first_entry(copy));
```

而我们在建 entry 时写的是：

```c
entry.vme_offset = object->objectOffset;   /* 单位错误！ */
```

`objectOffset` 是**字节**，而 `vme_offset` 是 **4KB 页单位**（`VME_OFFSET(x) = x << 12`）。
按 XNU 语义，这一行应该传页号而非字节数。

顺带把另一个悬案也证清了：`is_object` 分支取对象时**根本不看 `vme_offset`**：

```c
/* mementry.c:4716 → mementry.c:21519 */
object = vm_named_entry_to_vm_object(named_entry);
/* 里面是： object = VME_OBJECT(copy_entry);   只读 vme_object_or_delta */
```

所以 `entry.vme_offset` 写对写错都不影响"映射到哪个对象"，只影响
`named_entry->offset` 这个**加法项** —— 而它会把阶梯里所有 offset 候选
整体平移。**这解释了为什么 offset 维度看起来完全不起作用**（v0.4.6 传
`0x9e3c000` 与 v0.4.7 传 `0` 表现一致）。

修法（v0.4.8）：显式用 `ds_kwrite64` 把 `named_entry->offset` **归零**，
让偏移完全由 `mach_vm_map` 的 `off` 决定，offset 维度才真正可分辨。
`struct vm_named_entry` 的布局由 XNU 源码确定，并用两个已知值交叉校验：

| 字段 | 偏移 | 校验 |
|---|---|---|
| `Lock`（`decl_lck_mtx_data`） | `+0x00` | |
| `backing`（`map`/`copy` 联合） | `+0x10` | ✅ 与实测 `off_vm_named_entry_backing_copy = 0x10` 吻合 |
| **`offset`** | **`+0x18`** | ← 本次新增 |
| `size` | `+0x20` | ✅ 与实测 `off_vm_named_entry_size = 0x20` 吻合 |
| `data_offset` | `+0x28` | |

两个独立已知 offset 都与模型吻合，`offset = 0x18` 因此可靠。

**结论二：`0x8000000`(128MB) 不是异常，是 `ANON_CHUNK_SIZE`。**

v0.4.7 日志里 `namedEntrySize = 0x8000000` 与 `objsize = 0x16584000` 不符，
此前列为疑点。查 `osfmk/mach/arm/vm_param.h` 后确认：

```c
/* Work-around for <rdar://problem/6626493> */
#define ANON_CHUNK_SIZE (128ULL * 1024 * 1024) /* 128MB */
```

内核**会把匿名对象按 128MB 分块**，`named_entry` 只覆盖第一个 chunk。
所以这两个数**本来就不该相等** —— 这不是异常，是预期行为。
它也直接解释了 v0.4.6 的 `(4)`：

| 版本 | `obj_offs + initial_size` | `named_entry->size` | 结果 |
|---|---|---|---|
| v0.4.6 | `0x9e40000`（`0x9e3c000 + 0x4000`） | `0x8000000` | `0x9e40000 > 0x8000000` → `KERN_INVALID_ARGUMENT(4)` ✅ 对上 |
| v0.4.7 末档 | `0x8000000`（`0 + 0x8000000`） | `0x8000000` | 刚好等于，尺寸关**通过** |

**结论三：`prot=0x47` 那档不可能报 `0x11` —— 说明 v0.4.7 日志仍在误导。**
（此结论保留待真机复核，见下节。）

#### 一个被证伪的假设：union 大小错位（记录以免重犯）

曾怀疑 `pr_vmmapentry` 的匿名联合首成员写成 `uint32_t`（4 字节）而 XNU 是
`vm_offset_t`（8 字节），会让 `vme_alias`/`vme_offset` 整体错位 4 字节。
用 `clang -Xclang -fdump-record-layouts` 交叉编译到 `arm64-apple-ios17.0`
实测两种写法：

```
XNU  : 72:0-11 vme_alias   73:4-55 vme_offset
OURS : 72:0-11 vme_alias   73:4-55 vme_offset
```

**两者完全相同。** 原因是 `vme_alias:12` + `vme_offset:52` 合计 64 位，
clang 必定给它开一个完整的 64 位分配单元，所以首成员是 4 还是 8 字节不影响。
该假设**证伪**，无需改动。

#### `prot=0x47` 之谜：为什么"不该报 0x11"

按 `mementry.c:4163-4189` 的判定顺序逐档模拟（`extra_mask = VM_PROT_IS_MASK`，
已核对调用点实参 `mementry.c:3998-4002`）：

```c
mask_cur = cur & VM_PROT_IS_MASK;      /* 0x47 → mask 置位 */
cur     &= ~VM_PROT_IS_MASK;           /* 0x47 → 0x07 */
if (mask_cur) cur &= named_entry->protection;   /* ← 取交集 */
```

`0x47` 档的 `mask` 位**置位**，于是请求权限会先与 `named_entry->protection`
取交集，再做"是否子集"校验 —— **交集必然满足子集关系**，数学上不可能失败。

用穷举验证：让 `named_entry->protection` 取遍 `0x00`–`0x7f`，**不存在任何
一个取值**能同时让 `0x47`/`0x7`/`0x3` 三档都返回 `0x11`。即便
`protection = 0`，`0x47` 档仍返回成功。

结论：v0.4.7 日志说的"全部 4 档均失败"与源码模型不符 —— 但当时无法区分
是措辞问题还是上游问题，**只能靠逐档留痕区分**。v0.4.8 加上了 `gTierTrace`。

#### ★ 谜题解开：v0.4.8 真机逐档数据（两道门全部定位）

v0.4.8 真机拿到了完整的逐档返回码：

```
逐档: #1 off=0x9e3c000 sz=0x4000    prot=0x47 -> (os/kern) invalid argument(0x4)
      #2 off=0x9e3c000 sz=0x4000    prot=0x7  -> (os/kern) invalid right(0x11)
      #3 off=0x9e3c000 sz=0x4000    prot=0x3  -> (os/kern) invalid argument(0x4)
      #4 off=0x0       sz=0x8000000 prot=0x7  -> (os/kern) invalid right(0x11)
```

这一行信息把两道门**完全反推**了出来，且模型与真机 **4/4 吻合**：

**第一道「权限门」→ 反推出 `named_entry->protection = 0x3`**

| 请求 prot | 结果 | 推论 |
|---|---|---|
| `0x7` (RWX) | `0x11` 被拒 | `protection` **缺 `EXECUTE`** |
| `0x3` (RW) | 通过（倒在尺寸门） | `protection` **含 `READ\|WRITE`** |
| `0x47` | 通过（倒在尺寸门） | mask 置位后请求权限被清零，子集校验恒成立 ✔ |

即 `mach_make_memory_entry_64(..., VM_PROT_ALL)` 实际只拿到 `READ|WRITE`。

> 注意这**推翻了我此前"`0x47` 必成功"的模型**：它确实通过了权限门，
> 但没能成功 —— 因为它倒在了第二道门上。逐档日志的价值正在于此。

**第二道「尺寸门」→ 这才是真正的拦路虎**

```c
/* mementry.c:4198-4201 */
if (named_entry->size < obj_offs + initial_size) return KERN_INVALID_ARGUMENT;
```

| 量 | 值 |
|---|---|
| `named_entry->size` | `0x8000000`（128MB = `ANON_CHUNK_SIZE`） |
| `obj_offs + initial_size` | `0x9e3c000 + 0x4000` = `0x9e40000`（158MB） |
| 判定 | `0x8000000 < 0x9e40000` → **触发** → `(4)` |

**为什么 `#2` 报 `0x11` 而 `#1`/`#3` 报 `0x4`：** 权限门在尺寸门**之前**。
`#2` 的 `prot=0x7` 先被权限门拒掉，根本没机会走到尺寸门；`#1`/`#3`
通过了权限门，倒在尺寸门。

**为什么 `#4` 报 `0x11`：** 它的 `size` 恰好等于 `namedEntrySize`，
尺寸门**通过**了，但 `prot=0x7` 在权限门就被拒。（末档此前一直用
`VM_PROT_ALL` 作 prot，正好踩在已知必败的组合上。）

#### v0.4.9：抬高 `named_entry->size`

既然真正的拦路虎是尺寸门，而它只是一个**纯数值比较**（无任何硬件/MMU
约束），最直接的修法就是把 `named_entry->size` 抬到够用：

```c
needSize = pr_round_page(object->entryOffset + PR_MAP_PAGE_SIZE);
if (namedEntrySize < needSize)
    ds_kwrite64(shmemnamedentry + off_vm_named_entry_size, needSize);
```

`named_entry` 是本进程私有对象、随 `mach_vm_deallocate` 释放，且每次
映射前都重建，影响面可控。

同时修正末档的 prot：此前用 `VM_PROT_ALL`（`0x7`）恰好必败，现在
改为同时试 `0x3`（已知 entry 权限）与 `0x47`（mask 收敛）。
另把 `gTierTrace` 从 512 扩到 1024 —— 阶梯最多可展到 8 档
（2 offset × 3 prot + 2 整块），按单档最长 83 字节算 `8 × 83 = 664 > 512`，
**又会踩截断的坑**，这次提前留够。

修复后的阶梯推演（`entryOffset = 0x9e3c000`，`size` 已抬到 `0x9e40000`）：

| # | off | size | prot | 预测 |
|---|---|---|---|---|
| **1** | `0x9e3c000` | `0x4000` | `0x47` | **成功**（精确指目标页）🎉 |
| 2 | `0x9e3c000` | `0x4000` | `0x7` | `0x11`（权限门，预期） |
| 3 | `0x9e3c000` | `0x4000` | `0x3` | 成功（精确） |
| 4 | `0` | `0x9e40000` | `0x3` | 成功（不精确） |
| 5 | `0` | `0x9e40000` | `0x47` | 成功（不精确） |

**第 1 档就会命中且是精确偏移** —— 内透读写将落到正确页面上。


#### v0.5.0 → v0.5.1：内透通了，但 smoba 被 codesign 击杀（错误修法 → 正确修法）

v0.4.9 的真机日志证明**读写链路完全打通**：

```
12:33:58.221 stage: 正在定位 UnityFramework
12:33:58.277 stage: 内透已开启 · 0x1387c3824（原值 0xAA1803E1 → 0xD2800021）
12:33:58.277 transparent wall ready — base=0x12e984000 target=0x1387c3824
```

`base = 0x12e984000`、`target = 0x1387c3824`，差值正好 `0x9e3f824` ✅。
原值 `0xAA1803E1`（`MOV W1, #0x3F08` 之类）被换成 `0xD2800021`，
回读校验也通过 —— **v0.4.9 的修复成立**。

但约 10 秒后 smoba 崩溃：

```
termination : {"flags":2,"code":2,"namespace":"CODESIGNING","indicator":"Invalid Page"}
subtype     : KERN_PROTECTION_FAILURE at 0x00000001387c0810
ktriageinfo : "VM - (arg = 0x0) CL - "
vmRegionInfo: 0x1387c0810 is in 0x12e984000-0x14021c000
              ---> __TEXT ... r-x/rwx SM=COW .../UnityFramework
```

##### 崩溃地址与补丁点同页

| | 地址 | 所在 16KB 页 | 页内偏移 |
|---|---|---|---|
| 补丁点 | `0x1387c3824` | `0x1387c0000` | `0x3824` |
| 崩溃点 | `0x1387c0810` | `0x1387c0000` | `0x0810` |

同属一页，`vmRegionInfo` 也确认它落在 UnityFramework 的 `__TEXT`
（`r-x/rwx SM=COW`，280.6M）。这不是巧合 —— 是我们写过的那一页。

##### 机制：`cs_invalid_page()` 按 `CS_KILL` 直接 SIGKILL

链条全部来自 XNU 源码，逐段可查：

1. **我们写脏了一页已签名的代码页。** 目标页属于 UnityFramework 的
   `__TEXT`，是 `SM=COW` 的签名代码。经 vm_object 共享映射写入后，
   VM 在这一页上记下 `vmp_wpmapped = 1`（曾被以可写方式映射进 pmap）
   与 `vmp_dirty = 1`。

2. **smoba 再次碰到这一页时走 `vm_fault_enter()`**，命中这条分支
   （`osfmk/vm/vm_fault.c`）：

   ```c
   else if (vm_fault_cs_page_immutable(m, ..., prot) &&
            ((prot & VM_PROT_WRITE) || m->vmp_wpmapped)) {
       /* 该页本应不可变，却有被改动的风险 */
       *cs_violation = TRUE;
   }
   ```

   随即 `vm_fault_cs_handle_violation()` → `cs_invalid_page(vaddr, &cs_killed)`。

3. **`cs_invalid_page()`（`bsd/kern/kern_cs.c`）只认 proc 的 csflags：**

   ```c
   if (flags & CS_KILL) { flags |= CS_KILLED; send_kill = 1; retval = 1; }
   ...
   if (send_kill) threadsignal(current_thread(), SIGKILL, EXC_BAD_ACCESS, FALSE);
   ```

   smoba 是平台二进制，csflags 带 `CS_KILL` → 收 `SIGKILL`。
   这份崩溃报告里的 `namespace: CODESIGNING` / `indicator: "Invalid Page"`
   就是第 2 步 `os_reason_create(OS_REASON_CODESIGNING,
   CODESIGNING_EXIT_REASON_INVALID_PAGE)` 写下的。

##### 官方后门：`cs_allow_invalid()`

同一个文件里，Apple 给「故意改自己代码」这种场景留了出口。它有**三步**，
注意顺序和主次：

```c
/* bsd/kern/kern_cs.c, cs_allow_invalid() */
if (0 != mac_proc_check_run_cs_invalid(p)) return 0;   /* MACF hook，内核外绕不过 */

proc_lock(p);
flags = proc_getcsflags(p) & ~(CS_KILL | CS_HARD);     /* ① ← 真正的解药 */
if (flags & CS_VALID) flags |= CS_DEBUGGED;
proc_csflags_update(p, flags);
proc_unlock(p);

task_set_memory_ownership_transfer(proc_task(p), TRUE);
vm_map_switch_protect(get_task_map(proc_task(p)), FALSE);  /* ② 补充 */
vm_map_cs_debugged_set(get_task_map(proc_task(p)), TRUE);  /* ③ 补充 */
```

**修法（v0.5.0，❌ 结论错误）**：我当时只实现了 ②③ —— 以为往 `vm_map`
里落 `cs_debugged` 就等于「让系统认为 smoba 是被调试的进程」，
`cs_invalid_page()` 收到 `CS_KILL` 就会放行。

```c
/* v0.5.0 只做了这一步 —— 不够 */
uint64_t bitsAddr = vmMap + off_vm_map_hdr + off_vm_map_cs_bits;  // vmMap + 0x90
uint32_t bits = ds_kread32(bitsAddr);
uint32_t want = (bits | 0x00008000)   // cs_debugged = 1     (bit 15)
                      & ~0x00000010;  // switch_protect = 0  (bit 4)
ds_kwrite32(bitsAddr, want);
```

新增 `off_vm_map_cs_bits = 0x80`（相对 `vm_map_header` 的偏移，绝对位置
`vmMap + 0x10 + 0x80 = vmMap + 0x90`），与既有 `off_vm_map_header_links_next = 0x08`
/ `off_vm_map_header_nentries = 0x20` 的用法与编码风格一致 —— 这三个偏移
都是「相对 hdr」的，已交叉校验（`0x10 + 0x08 = 0x18` ✅、`0x10 + 0x20 = 0x30` ✅、
`0x10 + 0x80 = 0x90` ✅）。

> ⚠️ **踩坑记录（记录以免重犯）**：最初按字面把这两个字段当成
> 「相邻的两个字节」写成 `+0x98` / `+0x99` 并分两次 `ds_kwrite32`，
> **完全错误**。它们其实位于**同一个 32 位字**里（bit 4 与 bit 15），
> 必须**读-改-写整个字**，否则会踩坏 `wait_for_space` .. `cs_enforcement`
> 之间的十几个标志位。
>
> 实测方法：构造 `struct _vm_map` 后置位再回读那个 32 位字 ——
> `switch_protect=1` 得到 `0x00000010`（bit 4），
> `cs_debugged=1` 得到 `0x00008000`（bit 15），
> 且两次都在偏移 `0x90` 的同一个字里。

> ⚠️ **为什么位域布局不能靠 clang 的 `-fdump-record-layouts` 读**：
> 它把位域按 8 位一行打印（`72:4` / `73:7`），看起来像相邻字节，
> 实际只是位号。**运行期实测才是可靠方法** —— 上面那组数字就是这么来的。

##### 顺带修掉的两个真 bug

**① 4 字节回读会读到错页（会导致「写成功却报失败」）**

`remotepage.m` 的 `polaris_remote_read()` 在 `off + len > ps` 时会
「从页首重新发起」把请求拆成两段，而第二段的页内偏移是按**映射粒度**
重算的 —— 简化处理会让第二段落到**另一页**。目标地址
`0x1387c3824` 在 16KB 页里偏移 `0x3824 = 14372`，`14372 + 4 > 16384`，
**恰好越过页尾**，于是 4 字节读会被拆成两次映射，第二次读回的是下一页。

v0.5.0 改成**整字（8 字节）读回取低 32 位**：指令必然 4 字节对齐，
不可能跨越页边界，整字读在这里天然原子。同时 `up_user_read` /
`up_user_write` 加了一页上限，禁止调用方再传跨页长度。

**② 幂等短路：已是目标值就不重复写**

每多写一次就多一次「页被标脏」的机会。开启/关闭路径现在都先读一遍，
值已经对了就**直接返回**，不再碰内存。

##### v0.5.0 真机结果：**仍然崩溃** —— 上面那个修法是错的

v0.5.0 装机测试，smoba 依旧收到 `CODESIGNING / Invalid Page` 的 `SIGKILL`。
新崩溃报告给了一个 v0.4.9 报告里没有的字段：

```
pid 10013  ·  smoba 12.1.10103  ·  iPhone OS 18.6 (22G86)  ·  iPhone13,4
faultingThread : 35  (name: CoreThread)
frame 0        : UnityFramework + 0x09e3e324
usedImages     : UnityFramework base = 0x11a050000
subtype        : KERN_PROTECTION_FAILURE at 0x0000000123e8e324
procLaunch 15:23:24  →  captureTime 15:24:27   (存活 63 秒)
```

**`faultingThread` 的 frame 0 就是崩溃地址本身** —— 说明这不是「访问了
某个数据」而是**正在执行这条指令时被杀**。而：

| | 值 | 相对 UnityFramework |
|---|---|---|
| 补丁点 | `0x123e8f824` | `+0x09E3F824` |
| 崩溃点（= PC） | `0x123e8e324` | `+0x09e3e324` |

`0x09E3F824 - 0x09e3e324 = 0x1500`（5376 字节 / 1344 条指令）。
崩溃点与补丁点**同属 16KB 页** `0x123e8c000`（补丁在页内 `0x3824`，
崩溃在页内 `0x2324`），但**分属不同的 4KB 页**。这正是我们自己写脏的
那一页 —— smoba 执行到该页 `0x2324` 处时被 CS 击杀。

##### 我错在哪里

把 XNU 翻遍后确认：

- **`cs_invalid_page()` 只读 proc 的 csflags。** 全函数没有一处引用 `vm_map`
  的任何字段，也没有 `cs_debugged` —— 它只做
  `flags = proc_getcsflags(p); if (flags & CS_KILL) { send_kill = 1; }`。
- **`cs_debugged` 在整个 XNU 里只有一个消费者**：
  `vm_map_entry_is_overwritable()`（`osfmk/vm/vm_map_entry.c:9385`）里的
  `if (entry->used_for_jit && vm_map_cs_enforcement(dst_map) && !dst_map->cs_debugged) return FALSE;`
  —— 那是一条 **JIT 覆盖检查**，与击杀判定毫无关系。

所以 ②③ 出现在 `cs_allow_invalid()` 里，服务的是「被调试进程的额外特权」，
**不是解药**。解药是最前面的 **①**：`proc_getcsflags(p) & ~(CS_KILL | CS_HARD)`。

> 换句话说：v0.5.0 我抄了后门的下半段，把上半段漏了。
> 而 v0.5.0 之所以**仍然没有在写入时立刻崩**（它撑了 63 秒），
> 是因为 ② 里的 `switch_protect = FALSE` 确实关掉了「切换映射时保护不可变页」
> 那一路，让 smoba 多活了一会儿 —— 但它挡不住 `vm_fault_enter()` 那条主路径。


##### v0.5.1：清掉 `p_csflags` 的击杀位（主修法）

csflags 不在 `struct proc` 里，它被搬进了 `struct proc_ro`：

```
proc->p_proc_ro (proc + 0x18)  →  proc_ro->p_csflags (proc_ro + 0x24)
```

| 字段 | 偏移 | 依据 |
|---|---|---|
| `proc->p_proc_ro` | `+0x18` | 已有偏移表项 |
| `proc_ro->p_uniqueid` | `+0x10` | `bsd/sys/proc_ro.h` |
| **`proc_ro->p_csflags`** | **`+0x24`** | 本版新增 |
| `proc_ro->p_ucred` | `+0x28` | 已有 `off_proc_ro_p_ucred = 0x28` ✅ 互相印证 |

`+0x24` 是**编译并运行**实测得到的（构造 `struct proc_ro` 后取
`offsetof`，非字面推算），且与既有 `p_ucred = 0x28` 的「相邻成员」关系吻合。

新增 `off_proc_ro_p_csflags = 0x24`，写入逻辑与 `cs_allow_invalid()` 的 ① 一致：

```c
uint64_t procRo = kreadptr(proc + off_proc_p_proc_ro);
uint64_t csflagsAddr = procRo + off_proc_ro_p_csflags;

uint32_t flags = ds_kread32(csflagsAddr);
uint32_t want  = flags & ~(0x200 /*CS_KILL*/ | 0x100 /*CS_HARD*/);
if (flags & 0x1 /*CS_VALID*/) want |= 0x10000000 /*CS_DEBUGGED*/;
ds_kwrite32(csflagsAddr, want);
/* 回读确认 (back & (CS_KILL|CS_HARD)) == 0 */
```

`CS_*` 取值来自 `bsd/kern/cs_blobs.h`：
`CS_VALID = 0x1`、`CS_HARD = 0x100`、`CS_KILL = 0x200`、
`CS_KILLED = 0x1000000`、`CS_DEBUGGED = 0x10000000`。

②③ 保留为**并列的补充步骤**（成本极低，顺手落上），但**不再当作解药**：
只有 ① 成功时才继续做 ③，日志会分别标出两者结果。

> **诚实边界**：`cs_allow_invalid()` 开头那道
> `mac_proc_check_run_cs_invalid(p)` 是 MACF 钩子，在内核外绕不过。
> 但这条路**根本不需要调用 `cs_allow_invalid()`** —— 我们是**直接改
> `p_csflags` 的值**，不经过那道检查，等价于「骗过它」。

##### 需要真机验证的点

日志里会分别标出两个结果：

```
内透已开启 · 0x…（原值 … → …）· csflags击杀位已清 · vm_map补充位已落   ← 最优
内透已开启 · 0x…（原值 … → …）· csflags击杀位未清（偏移缺失或写入被拒）· vm_map补充位未落
```

- `csflags击杀位已清` → `cs_invalid_page()` 不再走 `send_kill` 分支，
  `CS_HARD` / `CS_VALID` 逻辑接管，**smoba 不该再被击杀**。
- `csflags击杀位未清` → 内透本身仍可用（写入链路与 v0.4.9 相同），
  但 smoba 仍有被击杀风险，需按这条线索继续查（优先怀疑偏移表未就绪）。

若在 `csflags击杀位已清` 的前提下仍然崩溃，下一步方向是把
`vm_map_entry.protection` 在写入前后临时放宽/恢复，或从 `pmap` 层面处理 ——
但那属于更深的改动，**先把 ① 这条路在真机上验完再说**。


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
| 0.5.1 | **★ 纠正 v0.5.0 的错误修法：真正该写的是 `proc_ro->p_csflags`，不是 `vm_map->cs_debugged`。** v0.5.0 真机测试 smoba **仍然崩溃**，且新报告给出决定性证据 —— `faultingThread = 35`(`CoreThread`) 的 **frame 0 = `UnityFramework + 0x09e3e324`**，即崩溃地址**就是正在执行的 PC**；它与补丁偏移 `0x09E3F824` 相差恰好 `0x1500`、同属 16KB 页 `0x123e8c000`（`UnityFramework base = 0x11a050000`），`procLaunch 15:23:24 → captureTime 15:24:27` 存活 **63 秒**。<br>**① 自查出 v0.5.0 的错**：我只实现了 `cs_allow_invalid()` 的 ②③（`vm_map_switch_protect(map,FALSE)` + `vm_map_cs_debugged_set(map,TRUE)`），**漏掉了真正起作用的 ①** `flags = proc_getcsflags(p) & ~(CS_KILL\|CS_HARD)`。<br>**② 源码层面的确证**：`cs_invalid_page()`（`bsd/kern/kern_cs.c`）**全函数只读 proc 的 csflags**，`if (flags & CS_KILL) send_kill = 1`，从头到尾没有引用 `vm_map` 的任何字段；而 `cs_debugged` 在整个 XNU 里**只有一个消费者** —— `vm_map_entry_is_overwritable()`（`osfmk/vm/vm_map_entry.c:9385`）里的 JIT 覆盖检查，**完全不参与击杀判定**。②③ 之所以存在，是服务「被调试进程的额外特权」，不是解药。<br>**③ 修法**：新增 `off_proc_ro_p_csflags = 0x24`（**编译+运行实测** `offsetof`，非字面推算；与既有 `p_ucred = 0x28` 相邻关系吻合），沿 `proc->p_proc_ro`(`+0x18`) → `proc_ro->p_csflags`(`+0x24`) 直接读-改-写：清 `CS_KILL(0x200)\|CS_HARD(0x100)`，若原为 `CS_VALID(0x1)` 则顺带置 `CS_DEBUGGED(0x10000000)`，并回读确认。②③ 降级为**并列补充**，日志分别标注两者结果。<br>**④ 诚实边界**：`cs_allow_invalid()` 开头那道 `mac_proc_check_run_cs_invalid(p)` 是 MACF 钩子、内核外绕不过 —— 但**这条路不需要调用它**，我们直接改 `p_csflags` 的值，不经过那道检查。<br>**⑤ 保留 v0.5.0 的两个真 bug 修复**：整字(8B)读回避免 16KB 页跨页读到错页；开启/关闭的幂等短路。 |
| 0.5.0 | **★ 内透读写链路已打通，本版修复随之暴露的「smoba 被 codesign 击杀」。** v0.4.9 真机日志证明 `内透已开启 · 0x1387c3824（原值 0xAA1803E1 → 0xD2800021）` + `transparent wall ready — base=0x12e984000`（差值正好 `0x9e3f824` ✅），**v0.4.9 的修复成立**；但约 10 秒后 smoba 收到 `SIGKILL`，`termination = {namespace: CODESIGNING, code: 2, indicator: "Invalid Page"}`、`ktriageinfo = "VM - (arg = 0x0) CL - "`。<br>**① 定位崩溃与补丁同页**：崩溃地址 `0x1387c0810` 与补丁点 `0x1387c3824` 同属 16KB 页 `0x1387c0000`，`vmRegionInfo` 确认落在 UnityFramework `__TEXT`(`r-x/rwx SM=COW`)。<br>**② 机制（逐段核对 XNU 源码）**：我们写脏了一页已签名的代码页 ⇒ 该页带上 `vmp_wpmapped`/`vmp_dirty` ⇒ smoba 再碰它时 `vm_fault_enter()` 命中 `vm_fault_cs_page_immutable() && (prot & VM_PROT_WRITE \|\| m->vmp_wpmapped)` ⇒ `vm_fault_cs_handle_violation()` ⇒ `cs_invalid_page()`（`bsd/kern/kern_cs.c`）里 `if (flags & CS_KILL) send_kill = 1` ⇒ `threadsignal(SIGKILL, EXC_BAD_ACCESS)`。smoba 是平台二进制，csflags 带 `CS_KILL`，必死。<br>**③ 修法：写 `vm_map->cs_debugged` / `switch_protect`**。这是官方 `cs_allow_invalid()` 的后半段（同文件）：它除了清 `CS_KILL\|CS_HARD`，还做 `vm_map_switch_protect(map, FALSE)` + `vm_map_cs_debugged_set(map, TRUE)`。Polaris 不调内核函数，直接把这两个布尔字段写进 smoba 的 `vm_map`（`vmMap + off_vm_map_hdr + 0x98/0x99`），等价于「让系统认为 smoba 是被调试的进程」，`cs_invalid_page()` 收到 `CS_KILL` 便放行。新增 `off_vm_map_cs_debugged = 0x98`、`off_vm_map_switch_protect = 0x99`（据 `osfmk/vm/vm_map.h` 位域排布）。<br>**④ 顺路清掉两个真 bug**：**(a) 4 字节回读会读到错页** —— `0x9E3F824` 在 16KB 页里偏移 `0x3824`，`0x3824 + 4 > 0x4000`，`polaris_remote_read()` 的跨页分支会把它拆成两次映射、第二次落到**另一页**，导致「写成功却报失败」；改为**整字(8B)读回取低 32 位**（指令 4 字节对齐，必然不跨页，天然原子），并给 `up_user_read/write` 加「单次不得超过一页」的上限。**(b) 幂等短路**：开启/关闭前先读一遍，值已是目标值就**直接返回**，不再多写一次（每写一次就多一次标脏机会）。另修 `up_user_readstr` 里写死的 `0x1000` 页内切分（16KB 页机器上让同页被映射 4 次），改用运行期页大小。<br>**⑤ 诚实边界**：④ 的两条**本身不足以**避免崩溃 —— 崩溃判定在**页状态**上而非写入次数上，真正起作用的是 ③。日志会明确标出 `codesign 保险已就位` / `codesign 保险未落上`，需真机确认 |
| 0.4.9 | **★ 谜题解开并修复：抬高 `named_entry->size`，跨过真正的拦路虎。** v0.4.8 的逐档留痕拿到了决定性数据：`#1 off=0x9e3c000 prot=0x47 -> (4)`、`#2 prot=0x7 -> (0x11)`、`#3 prot=0x3 -> (4)`、`#4 off=0 sz=0x8000000 prot=0x7 -> (0x11)`。<br>**① 反推出 `named_entry->protection = 0x3`**：`0x7` 被拒 ⇒ 缺 `EXECUTE`；`0x3` 通过 ⇒ 含 `READ\|WRITE`。（这**推翻了我此前「`0x47` 必成功」的模型** —— 它确实过了权限门，但倒在了第二道门。）<br>**② 定位真正的拦路虎 = 尺寸门**（`mementry.c:4198`）：`named_entry->size`(`0x8000000`=128MB) < `obj_offs+size`(`0x9e3c000+0x4000`=`0x9e40000`=158MB) ⇒ `(4)`。这也解释了 `#2` 为何报 `0x11` 而非 `0x4` —— **权限门在尺寸门之前**，`0x7` 先被权限门拒掉，根本没走到尺寸门。模型与真机 **4/4 吻合**。<br>**③ 修法**：尺寸门只是**纯数值比较**（无任何硬件/MMU 约束），故直接 `ds_kwrite64(namedEntry+0x20, pr_round_page(entryOffset+PAGE))` 把它抬高到够用；`named_entry` 是本进程私有对象、随 `mach_vm_deallocate` 释放，影响面可控。<br>**④ 加固末档 prot**：此前用 `VM_PROT_ALL`(`0x7`) 恰好是已知必败组合，改为同时试 `0x3` 与 `0x47`。<br>**⑤ 预防性扩容**：`gTierTrace` 512→1024 —— 阶梯最多可展到 8 档（2 offset × 3 prot + 2 整块），单档最长 83 字节，`8×83=664 > 512` **又会踩截断的坑**。<br>**⑥ 结果（真机已确认）**：`内透已开启 · 0x1387c3824（原值 0xAA1803E1 → 0xD2800021）`、`transparent wall ready — base=0x12e984000 target=0x1387c3824` —— **读写链路完全打通**。遗留的 smoba 崩溃由 v0.5.0 处理 |
| 0.4.8 | **修「诊断信息被截断」+ 找到 `named_entry->offset` 这个真 bug**。第三轮真机（v0.4.7）档数已从 1 涨到 4（二维展开生效），但仍报 `invalid right(0x11)`；且日志止于 `· obj=0xffffffe66cffed00 ob` ——**被静默截断**。逐层查出是缓冲区太小：`remotepage.m` 的 `gMessage`(256) / `gFirstFailDetail`(192)、`unitypatch.m` 的 `gMessage`(256) / `why`(192) / `detail`(192)、以及**真正的截断点** `PolarisBridge.mm` 的 `char message[256]`（×3）——`remotepage` 拼好的长信息在 C→OC 边界又被砍回 256 字节。全部统一扩到 1024。同时：**① 新增 `gTierTrace` 逐档留痕**，每档记 `#n off/sz/prot -> err`，失败时整条打出（此前只看得到末档，第 1 档 `prot=ALL\|IS_MASK` 报什么错完全不可见）；**② `gEntryTrace` 补上原始输入** `eStart`/`vmeOffraw`；**③ `vme_offset` 非 0 时主动告警**。数值核对：`target-base = 0x9e3f824` ✅；`obj=0xffffffe66cffed00` ✅ 落在 `[VM_MIN,VM_MAX]` 内且 64 字节对齐（**排除「压缩指针解包错误」**）。<br>**④ 本版核心新发现（对照 XNU 源码确证）：`named_entry->offset` 才是真正生效的对象内偏移。** `mementry.c:4212` 在 `named_entry->offset` 非 0 时执行 `vm_map_enter_adjust_offset(&obj_offs, ..., named_entry->offset)`，而该函数（`mementry.c:3966`）做的是 **加法** `*obj_offs += quantity` —— 故 `effective_offset = mach_vm_map 的 off + named_entry->offset`。此值在建 entry 时由 `mementry2.c:890` 从本地 entry 的 `vme_offset` **快照冻结**，而我们写的 `entry.vme_offset = object->objectOffset` 是**单位错误**（字节 ≠ 4KB 页号）。这解释了「offset 维度为何形同无效」：所有候选被同一个加法项整体平移，v0.4.6 的 `0x9e3c000` 与 v0.4.7 的 `0` 表现一致。修法：`ds_kwrite64` 把 `named_entry->offset` **显式归零**，偏移改由 `mach_vm_map` 的 `off` 全权决定。`struct vm_named_entry` 布局由 XNU 源码定，并用两个已知值交叉校验（`backing=+0x10` ✅、`size=+0x20` ✅ ⇒ `offset=+0x18`）。<br>**⑤ 澄清 `0x8000000`(128MB) 不是异常**：等于 `osfmk/mach/arm/vm_param.h` 的 `ANON_CHUNK_SIZE`，内核按 128MB 分块匿名对象，`named_entry` 只覆盖首块，故它与 `vm_object` 大小**本就不相等**。<br>**⑥ 证伪一个假设**：曾疑 `pr_vmmapentry` 联合首成员 4 vs 8 字节导致 `vme_offset` 错位，用 `-fdump-record-layouts` 交叉编译实测两者布局**完全相同**（`vme_alias:12`+`vme_offset:52` 共 64 位，必然独占一个 64 位单元），无需改动。<br>**⑦ 记下一个待真机复核的悖论**：按 `mementry.c:4163-4189` 穷举 `named_entry->protection` 的 0x00–0x7f，**不存在任何取值**能让 `0x47` 档返回 `0x11`（mask 置位后请求权限先取交集，子集校验必然成立）。故 v0.4.7 的「全部 4 档均失败」与源码模型不符，**必须靠逐档明细判定**，在此之前不再叠加新假设。**→ v0.4.9 用逐档数据解开了此悖论** |
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
