# aip_cpu_mem 架构 deep dive

## 1. 类层次

```
┌─────────────────────────────────────────────────────────────┐
│                       aip_cpu_mem                            │
│                       (facade)                               │
│  regions[$], find(), write(), read(), dump_map()             │
│  add_rom(), add_ram_fmt(), add_ram72_fmt(), add_ram_empty() │
│  add_region()                                                 │
└──────────────────────────┬──────────────────────────────────┘
                           │ 持有 N 个
                           ▼
            ┌──────────────────────────────┐
            │      aip_cpu_region          │
            │      (virtual base)          │
            │  base, size, paths[blk][ram] │
            │  contains(), set_path()      │
            │  pure: write_impl/read_impl  │
            └────────────┬─────────────────┘
                         │
            ┌────────────┴──────────────────────────────┐
            ▼                                           ▼
  ┌──────────────────────────┐               ┌──────────────────────┐
  │ aip_cpu_ram_region       │               │ aip_cpu_rom_region   │
  │ legacy 148-bit + parity  │               │ 64-bit plain          │
  │ decode(), splice/extract │               │ decode(), load_hex    │
  └────────────┬─────────────┘               └──────────────────────┘
               │ extends
               ▼
  ┌──────────────────────────┐
  │ aip_cpu_ram72_region     │
  │ opt-in 72-bit × 4-bank   │
  │ decode72(), virtual byte │
  │ access + zero_all()      │
  └──────────────────────────┘
```

`add_ram_fmt` 创建 legacy `aip_cpu_ram_region`；`add_ram72_fmt` 创建
`aip_cpu_ram72_region`。RAM72 继承 RAM 的 facade/loader 兼容接口及
`write_impl`、`read_impl`、`load_hex`、`zero_range`，并通过 virtual
`write_byte` / `read_byte` 与 `zero_all` 重载物理访问算法。ROM 类和其
地址映射保持不变。

## 2. 数据流 — write 全链路

用户调:
```systemverilog
cpu0.write('h8000_0103, 8'h5A, 8);
```

时序:

| 步 | 模块 | 动作 | 关键变量 |
|---|---|---|---|
| 1 | `aip_cpu_mem.write` | 校验 width ∈ {8,32,64} | width=8 ✓ |
| 2 | `aip_cpu_mem.find` | 按起始地址遍历 regions、匹配 contains | 命中 "dram" region, base=0x8000_0000 |
| 3 | `aip_cpu_mem.write` | 调 `r.write_impl(off, data, 8)` | off = 0x103 |
| 4 | `aip_cpu_ram_region.write_impl` | for 循环 1 次 (8 bit = 1 byte) | i=0 |
| 5 | `write_byte(0x103, 0x5A)` | 解码 | blk=0, ram=0, depth=0x8, slot=0, group=3 |
| 6 | `rd_row(0,0,0x8)` | `uvm_hdl_read` | 取出 148-bit 当前行 |
| 7 | `splice_group(w, 0, 3, 0x5A)` | 算 parity, 改写 9 bit | parity = XOR(0x5A) |
| 8 | `wr_row(0,0,0x8, w_new)` | `uvm_hdl_deposit` | 落地到 RTL |

## 3. 148-bit 行内存布局示例

假设 1 行存了 16 个 byte: `[B0, B1, ..., B15]`. 每 byte 9 bit (含 parity).

```
word bit:  147 ... 5 4 3 2 1 0
           ───────────────────
           odd slots:  bit 5,7,9,...,147       (72 bit)
           even slots: bit 4,6,8,...,146       (72 bit)
           reserved:   bit 0,1,2,3             (4 bit)

even slot (72 bit) = group0[9] | group1[9] | ... | group7[9]
  group_i 占 bit[4+i*18 .. 4+i*18+16] 中的偶数位
  即 word[4+(i*9+0)*2], word[4+(i*9+1)*2], ..., word[4+(i*9+8)*2]

each group = {parity[1], data[7:0]}
  word[4+(i*9+0)*2] = B_i[0]   (data bit 0)
  word[4+(i*9+1)*2] = B_i[1]
  ...
  word[4+(i*9+7)*2] = B_i[7]   (data bit 7)
  word[4+(i*9+8)*2] = parity_i (even parity)
```

odd slot 同理, 起始 bit = 5 (而非 4).

## 4. legacy 148-bit 地址映射推导

总目标: 字节地址 → (blk, ram_id, depth, slot_sel, group_id)

设 user 地址空间为字节寻址. 验证容量一致性:

- 1 row 容纳 16 byte (2 slot × 8 group × 1 byte)
- 1 ram = 512 row × 16 byte = 8192 byte = 0x2000 ✓
- 1 block = 2 ram × 0x2000 = 0x4000 ✓
- 62 block × 0x4000 = 0xF8000 ≈ 992 KB ✓

地址解码:

```
blk      = off / 0x4000
bof      = off % 0x4000
line     = bof >> 4                 // logical 128-bit line
ram_id   = bof[3]                   // 0=u00/low64, 1=u01/high64
group_id = bof[2:0]
depth    = line[9:1]                // physical row 0..511
slot_sel = line[0]                  // 0=even lane, 1=odd lane
```

同一 logical 128-bit line 的低 8 byte 写 `ram_id=0`，高 8 byte 写
`ram_id=1`。相邻两条 logical line（`line[0]` 为 0/1）复用同一个
148-bit physical row 的 even/odd lane；这是 legacy RTL 的定义。

## 5. RAM72 地址映射与继承分派

RAM72 每 block 仍覆盖 `0x4000` byte，但用两个独立的
`reg [71:0] mem [255:0][3:0]` 数组实现：`u00_ram.mem` 保存 logical
line 低 64 bit，`u01_ram.mem` 保存高 64 bit。精确解码为：

```
blk     = off / 0x4000
bof     = off % 0x4000
line    = bof >> 4
depth   = line[7:0]
bank    = line[9:8]
ram_id  = bof[3]                    // 0=u00, 1=u01
byte_id = bof[2:0]

HDL path = paths[blk][ram_id][depth][bank]
```

每个 72-bit word 有 8 个连续 group：`word[byte_id*9 +: 8]` 为 data，
`word[byte_id*9+8]` 为 parity。`add_ram72_fmt(name, base, u00_path_fmt,
u01_path_fmt, num_blocks=62, blk_id_offset=0)` 在注册时将模板索引
`blk + blk_id_offset` 填入 `paths`；运行时逻辑 block 解码不变。

由于 `aip_cpu_ram72_region` 覆盖 virtual byte access，继承来的多字节
read/write、`load_hex` 与 `zero_range` 会自动走 RAM72 的 RMW/校验路径；
`zero_all` 则覆盖为 256 × 4 bank 的逐 word 清零。RAM72 的 HDL read
失败会报错并 fail-closed：读返回 data=0、`status_ok=0`，写不会继续 RMW
deposit。

## 6. 多字节写为啥 byte-by-byte 展开?

legacy decode 先按 16 byte logical line 切分，再用 `line[0]` 选择
even/odd physical lane；`bof[3]` 只选择低/高 64-bit 的 RAM，并不选择
slot。因此：

- 写 64-bit @ `0x100`：`line=0x10`，8 byte 全部进入 ram0/low64，
  `depth=8`、`slot=0`、group `0..7`。
- 写 64-bit @ `0x108`：同一 `line=0x10`，8 byte 全部进入 ram1/high64，
  `depth=8`、`slot=0`、group `0..7`。
- 写 64-bit @ `0x10C`：前 4 byte (`0x10C..0x10F`) 进入 ram1/high64 的
  `depth=8`、`slot=0`、group `4..7`；后 4 byte (`0x110..0x113`) 进入
  ram0/low64 的 `depth=8`、`slot=1`、group `0..3`。这次写跨 RAM 与
  slot，但不跨 physical depth。

当前实现按字节执行 RMW；上述同一 `(ram_id, depth, slot)` 的连续 group
是未来可合并为一次 row RMW 的候选。

**最简实现**: 在同一已确认的 region 内按字节展开，每 byte 自己 RMW；物理
RAM/slot/depth 边界会自动处理。性能不如批量优化，但避免这些物理边界 bug。

**性能优化方向** (未实现): 把同 (depth,slot) 内的 group 合并成一次 RMW. 现有 byte 实现已够用, 仿真级别开销不显著.

## 7. parity 故障检测能力（两种 RAM 格式）

even parity 每 8 bit 配 1 bit，`parity = XOR(data[7:0])`，因此每个 9-bit
group 的总 XOR 为 0。能力:
- **单 bit 错** (data 翻 1 bit, 或 parity 翻 1 bit) → 必检测 ✓
- **双 bit 错** (同 group 内) → 漏检 (XOR 抵消)
- **跨 group 错** → 每 group 独立校验, 互不影响

legacy 与 RAM72 的注错用例都会使 `read` 返回 `status_ok=0`。Parity 只做
检测，不改变或纠正读出的 data。

无法纠错 (parity 信息不足以定位错位). 要纠错请改用 `aip_mem_ecc::secded`.

## 8. 路径表 vs 模板 — 设计权衡

| 维度 | path table (`paths[blk][ram_id]`) | 模板字符串 |
|---|---|---|
| 灵活性 | 高 (任意命名) | 低 (必须规整) |
| 注册成本 | 高 (62×2=124 条 set_path) | 低 (2 个 fmt) |
| 内存 | O(N) 字符串 | O(1) |
| 调试 | dump 整表清晰 | 只见模板需手算 |

**采纳方案**: 内部统一用 path table; facade 提供 `add_ram_fmt` 或
`add_ram72_fmt` 在注册时把模板展开成 table. 用户视角两种皆可:
- legacy 148-bit 规整命名 → 用 `add_ram_fmt`
- RAM72 规整命名 → 用 `add_ram72_fmt`（`u00_path_fmt` / `u01_path_fmt`）
- 不规整 → 用 `add_ram_empty` + 循环 `set_path`

## 9. 越权护栏

| 错误类型 | 检测点 | 处理 |
|---|---|---|
| width 非法 | `write/read` 入口 | `aip_error` + 立即 return |
| addr 不在任何 region | `find` 返回 null | `aip_error` + 立即 return, 不崩 |
| region 间地址重叠 | `add_region` 注册时 | `aip_error`, 拒绝新 region |
| path 未配置 | `get_path` 访问时 | `aip_error`, 返回空串 (上层 uvm_hdl_read fail) |
| RAM72 `uvm_hdl_read` 失败 | `rd_row72` | `aip_error`; 读 fail-closed，写跳过 RMW deposit |
| `uvm_hdl_deposit` 失败 | wr_row 内 | `aip_warning` (RTL path 拼错 / mem 不存在) |

## 10. 多 CPU 隔离机制

```systemverilog
aip_cpu_mem cpu0 = new();
aip_cpu_mem cpu1 = new();
```

两实例:
- `regions[$]` 独立
- region 对象本身独立 (不共享)
- path table 独立 → RTL 路径完全可不同

跨 CPU 地址相同 (e.g. 都 0x0) 也无问题 — 每个 cpu 自查自己的 regions, 互不干扰.

## 11. 跟其他模块的关系

| 模块 | 关系 |
|---|---|
| `aip_mem_ecc` | 复用 `xor_bits()` primitive; ROM region 写入风格类似 |
| `aip_cpu_bridge` | 互补 — bridge 是 SV↔C 通信协议, mem 是物理存储抽象 |
| `aip_mem_accessor` (虚类) | 平行抽象 — accessor 是 32-bit word 接口, mem 是 byte 接口 |
| UVM RAL backdoor | 可对接 — 把 `aip_cpu_ram_region` 包成 `uvm_reg_backdoor` 子类, 用户走 `mem.read/write(.path(UVM_BACKDOOR))` |

## 12. 后续可扩展功能 (TODO)

- [ ] 整 row 批量优化 (跳过 RMW, 同 depth 内 group 合并)
- [ ] secded 模式可选 (开关 ECC 模式)
- [ ] scrub 任务 (按 region 扫描 + 修正)
- [ ] UVM RAL backdoor 适配类
- [ ] hex 文件除了 64-bit 一行外, 支持 intel-hex / srec
- [ ] 跨 region 连续写 (一次调用横跨 ROM/RAM 边界)
- [ ] 统计 + 错误寄存器 (parity err 计数 / 最后错地址)
