# aip_cpu_mem — 多 CPU 多 region 内存抽象层

## 1. 目标

给 UVM/SV testbench 提供 **统一的 CPU 内存读写接口**, 屏蔽底层物理存储拓扑:

- 单接口 `cpu.write(addr, data, width)` / `cpu.read(addr, data, width, ok)`
- 按**起始地址**路由到一个包含该地址的 **ROM / RAM / 其他 region**
- RAM 自动加 **even parity** (每 8 bit 1 bit 校验)
- 多 CPU 各自实例化, **base_addr + RTL path 隔离**
- 每 region 持有 `paths[blk][ram_id]` 二维表, 支持任意 RTL 命名

## 2. 物理拓扑 (默认示例)

### CPU ROM

```
1 block × 2 ram × 2048 depth × 64-bit
每条逻辑 128-bit line 的低 64 bit → ram0 / uu0
每条逻辑 128-bit line 的高 64 bit → ram1 / uu1
1 logical line = 16 byte；每个 RAM row = 8 byte (无 parity)
单 block = 32 KB
```

### CPU RAM — legacy 148-bit interleaved layout (`add_ram_fmt`)

```
62 block × 2 ram × 512 depth × 148-bit
ram0 / u00 接每条逻辑 128-bit line 的低 64 bit
ram1 / u01 接每条逻辑 128-bit line 的高 64 bit

148-bit 行布局:
  bits[3:0]       保留
  bits[4,6,...,146]  even slot (72 bit)
  bits[5,7,...,147]  odd  slot (72 bit)

每 slot = 8 group × 9 bit
9 bit = {parity[1], data[7:0]}
slot data = 8 byte
1 row = 16 data byte = 144 stored bit + 4 reserved

单 block = 0x4000 byte (16 KB)
total    = 62 × 0x4000 = 0xF8000 = 992 KB
```

这是保留的原有格式：每个 72-bit slot 的 9-bit group 按 2-stride 散布在
148-bit row 中，`bits[3:0]` 保留。现有 RTL 使用该格式时继续调用
`add_ram_fmt`，不受 RAM72 影响。

### CPU RAM — RAM72 layout (`add_ram72_fmt`, opt-in)

```
62 block × 2 RAM (u00_ram / u01_ram)
每个 RAM: reg [71:0] mem [255:0][3:0]

u00_ram = 每条逻辑 128-bit line 的低 64 bit
u01_ram = 每条逻辑 128-bit line 的高 64 bit

72-bit word = 8 个连续 9-bit group
  word[byte_id*9 +: 8] = data[7:0]
  word[byte_id*9 + 8]  = parity

1 logical line = u00 的 8 byte + u01 的 8 byte = 16 byte
1 block = 256 depth × 4 bank × 16 byte = 0x4000 byte
total   = 62 × 0x4000 = 0xF8000 = 992 KB
```

RAM72 是独立、可选的物理布局；它不改变 ROM，也不替换 legacy 148-bit
RAM 的路径、地址空间或调用方式。

## 3. 地址解码 (核心算法)

### ROM

```
off = byte_addr - base
blk          = off / 0x8000
bof          = off % 0x8000
depth        = bof / 16                 # logical 128-bit line 0..2047
byte_in_line = bof % 16
ram_id       = byte_in_line / 8         # 0=low64/uu0, 1=high64/uu1
byte_in_word = byte_in_line % 8
```

### Legacy 148-bit RAM (`add_ram_fmt`)

```
off = byte_addr - base
blk      = off / 0x4000
bof      = off % 0x4000
line     = bof >> 4                    # logical 128-bit line
ram_id   = bof[3]                      # 0=low64/u00, 1=high64/u01
group_id = bof[2:0]
depth    = line[9:1]                   # physical row 0..511
slot_sel = line[0]                     # 0=even lane, 1=odd lane
```

每 byte 对应行内 9 bit (8 data + 1 parity), 按 2-stride 散布:

```
even slot bit pos: word[4 + (group_id*9 + j) * 2]   for j=0..8
odd  slot bit pos: word[5 + (group_id*9 + j) * 2]   for j=0..8
其中 j=0..7 为 data, j=8 为 parity
```

### RAM72 (`add_ram72_fmt`)

```
off     = byte_addr - base
blk     = off / 0x4000
bof     = off % 0x4000
line    = bof >> 4
depth   = line[7:0]
bank    = line[9:8]
ram_id  = bof[3]                       # 0=u00, 1=u01
byte_id = bof[2:0]

HDL path = paths[blk][ram_id][depth][bank]
```

`paths[blk][ram_id]` 保存 `mem` 数组的基路径；RAM72 访问时在其后追加
`[depth][bank]`。`blk_id_offset` 仅影响注册阶段填入模板的物理 RTL 索引，
不影响上述逻辑 `blk` 解码。

## 4. Even parity 算法（两种 RAM 格式共用）

```
对每 byte b:
  parity = XOR(b[0..7])
  XOR({parity, b[7:0]}) = 0     # 9-bit group 的总 XOR 为 0
```

实现直接使用 `aip_mem_ecc::xor_bits(b, 8)`。Parity 只用于检测，不会纠正
被读出的 data；单个 group 内的双 bit 翻转可能因 XOR 抵消而漏检。

## 5. API 速查

### facade 注册

| 接口 | 用途 |
|---|---|
| `add_rom(name, base, ram0_path, ram1_path)` | ROM 1 块 2 path 显式 (RTL 名无索引) |
| `add_rom_id(name, base, blk_id, fmt0, fmt1)` | ROM 1 块, RTL 带索引 (如 `dut.rom[3].uu0`) |
| `add_rom_fmt(name, base, fmt0, fmt1, num_blocks, blk_id_offset=0)` | ROM 多块模板 |
| `add_ram_fmt(name, base, ram0_path_fmt, ram1_path_fmt, num_blocks=62, blk_id_offset=0)` | legacy 148-bit RAM 多块模板 |
| `add_ram72_fmt(name, base, u00_path_fmt, u01_path_fmt, num_blocks=62, blk_id_offset=0)` | 可选 RAM72 多块模板；`u00` 低 64、`u01` 高 64 |
| `add_ram_empty(name, base, num_blocks)` | RAM 空创建 + 用户手填 `set_path` |
| `add_region(r)` | 注册任意自定义 region 子类 |

### 用户接口 — 通用

| 接口 | 说明 |
|---|---|
| `write(addr, data, width=64)` | width = 8/32/64，按起始地址路由到单一 region；调用方须保证整次访问不跨 region |
| `read(addr, data, width=64, status_ok)` | 按起始地址路由到单一 region；调用方须保证整次访问不跨 region。`status_ok=0` 表示 RAM parity 校验失败，或 RAM72 HDL read 失败 |
| `find(addr)` | 返回 region 引用 (调试用) |
| `dump_map()` | 打印当前地址布局表 |

> 注意：普通 `write` / `read` 只对起始地址执行一次 `find(addr)`，不会把一笔
> 8/32/64-bit 访问拆分后跨 region 路由。需要跨边界时由调用方拆分访问；
> `zero_range` 是例外，会按 region 自动分段。

### 用户接口 — 显式宽度 (类型安全, 推荐)

| 接口 | 说明 |
|---|---|
| `write8 (addr, bit[7:0]  data)` | 8-bit 写 |
| `write32(addr, bit[31:0] data)` | 32-bit 写 |
| `write64(addr, bit[63:0] data)` | 64-bit 写 |
| `read8 (addr, bit[7:0]  data, ok)` | 8-bit 读 |
| `read32(addr, bit[31:0] data, ok)` | 32-bit 读 |
| `read64(addr, bit[63:0] data, ok)` | 64-bit 读 |

### 块批量接口

| 接口 | 说明 |
|---|---|
| `write_block(addr, data[$], width=64)` | 队列连续写；每个元素单独按其起始地址路由，元素本身不得跨 region |
| `read_block(addr, count, data[$], width=64)` | 连续读到队列；每个元素单独按其起始地址路由，元素本身不得跨 region |
| `write_zero(addr, nbytes)` | 字节级清零 (走 RMW)；每个 byte 是独立的 `write8` 路由 |
| `write_incr(addr, count, start_v=0, width=64)` | 递增填；每个元素是独立 `write` 路由，元素本身不得跨 region |

### 批量归零接口 (高效)

| 接口 | 说明 |
|---|---|
| `zero_region(name)` | 整 region 清零, 跳过 RMW. RAM 写入与 zero data 一致的 parity row，ROM 直接写 0 |
| `zero_all()` | 所有 region 全清 |
| `zero_range(addr_from, addr_to)` | 按地址范围清, 跨 region 自动分段 |
| `region.zero_all()` | region 自身整体清 (子类高效实现) |
| `region.zero_range(off_from, off_to)` | region 内 offset 范围清 |

### region 直接访问 (高级)

| 接口 | 说明 |
|---|---|
| `region.set_path(blk, ram_id, path)` | 手填路径 |
| `region.get_path(blk, ram_id)` | 查询路径 |
| `rom.load_hex(filename, addr_off=0)` | 从 hex 文件加载 firmware |
| `ram.write_byte/read_byte` | byte 级直接访问 (跳过 facade) |

## 6. 典型用法

### 6.1 基本场景

```systemverilog
aip_cpu_mem cpu0;

initial begin
    cpu0 = new();

    // ROM: 1 块, 显式 2 path
    cpu0.add_rom(
        .name      ("rom"),
        .base      ('h0000_0000),
        .ram0_path ("dut.xxxx.uu0.mem_core_array"),
        .ram1_path ("dut.xxx.uu1.mem_core_array")
    );

    // RAM: 62 块, 模板拼路径
    cpu0.add_ram_fmt(
        .name          ("dram"),
        .base          ('h8000_0000),
        .ram0_path_fmt ("dut.foo.blk%0d.uu0.mem_core_array"),
        .ram1_path_fmt ("dut.foo.blk%0d.uu1.mem_core_array"),
        .num_blocks    (62)
    );

    cpu0.dump_map();

    // 业务代码 — 用户无感
    cpu0.write64('h0000_0008, 64'h1234_5678_9ABC_DEF0);   // ROM
    cpu0.write64('h8000_0100, 64'hDEAD_BEEF_CAFE_BABE);   // RAM, 走 parity
    cpu0.write32('h8000_0100, 32'hAA55);
    cpu0.write8 ('h8000_0103, 8'h5A);

    begin
        bit [63:0] d64; bit [31:0] d32; bit [7:0] d8;
        bit ok;
        cpu0.read64('h0000_0008, d64, ok);
        cpu0.read64('h8000_0100, d64, ok);   // ok=0 → parity 错
        cpu0.read32('h8000_0100, d32, ok);
        cpu0.read8 ('h8000_0103, d8,  ok);
    end

    // 块批量
    longint unsigned blk_in[$], blk_out[$];
    blk_in.push_back(64'h1111_1111_1111_1111);
    blk_in.push_back(64'h2222_2222_2222_2222);
    cpu0.write_block('h8000_0200, blk_in, 64);
    cpu0.read_block ('h8000_0200, 2, blk_out, 64);

    cpu0.write_zero ('h8000_0400, 16);             // 16 字节清零
    cpu0.write_incr ('h8000_0500, 8, 64'h100, 64); // 0x100,0x101,...0x107
end
```

### 6.2 RAM72 可选布局

当 RTL 每 block 的两个 RAM 定义如下时，注册 RAM72，不需要修改 facade、
loader 或 ROM：

```systemverilog
reg [71:0] mem [255:0][3:0];  // u00_ram
reg [71:0] mem [255:0][3:0];  // u01_ram
```

```systemverilog
aip_cpu_ram72_region ram;

ram = cpu0.add_ram72_fmt(
    .name          ("dram"),
    .base          ('h8000_0000),
    .u00_path_fmt  ("tb.cpu_ram[%0d].u00_ram.mem"),
    .u01_path_fmt  ("tb.cpu_ram[%0d].u01_ram.mem"),
    .num_blocks    (62)
);
```

同一套 `write8/32/64`、`read8/32/64`、`load_hex`、`zero_range` 和
`zero_all` 接口仍可使用。RAM72 读 HDL path 失败时返回 data=`0` 且
`status_ok=0`；写操作在读失败后停止，不执行 RMW deposit。

### 6.3 多 CPU 隔离

```systemverilog
aip_cpu_mem cpu0 = new();
aip_cpu_mem cpu1 = new();

cpu0.add_rom("rom",  'h0000_0000, "tb.cpu0.rom.uu0.mem_core_array",
                                  "tb.cpu0.rom.uu1.mem_core_array");
cpu0.add_ram_fmt("dram", 'h8000_0000,
                 "tb.cpu0.dram.blk%0d.uu0.mem_core_array",
                 "tb.cpu0.dram.blk%0d.uu1.mem_core_array", 62);

cpu1.add_rom("rom",  'h1000_0000, "tb.cpu1.rom.uu0.mem_core_array",
                                  "tb.cpu1.rom.uu1.mem_core_array");
cpu1.add_ram_fmt("dram", 'hA000_0000,
                 "tb.cpu1.dram.blk%0d.uu0.mem_core_array",
                 "tb.cpu1.dram.blk%0d.uu1.mem_core_array", 62);
```

### 6.4 RTL 索引不从 0 起 (`blk_id` / `blk_id_offset`)

**注意**: `$sformatf` 不做算术. `"dut.foo.blk[2+%0d]"` 会产出 `dut.foo.blk[2+0]` 字面串, **无效**. 用专门参数:

**ROM 单块带索引** (如 `dut.rom[3].uu0/uu1`):

```systemverilog
cpu0.add_rom_id(
    .name          ("rom"),
    .base          ('h0000_0000),
    .blk_id        (3),
    .ram0_path_fmt ("dut.rom[%0d].uu0.mem_core_array"),
    .ram1_path_fmt ("dut.rom[%0d].uu1.mem_core_array")
);
// 内部生成: dut.rom[3].uu0...  dut.rom[3].uu1...
```

**RAM 多块带 offset** (62 块, RTL 索引 2..63):

```systemverilog
cpu0.add_ram_fmt(
    .name          ("dram"),
    .base          ('h8000_0000),
    .ram0_path_fmt ("dut.xxxx[%0d].xxx.uu0.mem_core_array"),
    .ram1_path_fmt ("dut.xxxx[%0d].xxx.uu1.mem_core_array"),
    .num_blocks    (62),
    .blk_id_offset (2)    // 逻辑 0..61 → RTL 2..63
);
```

**RAM72 多块带 offset** 也使用相同语义：逻辑 block `0..61` 的地址映射不变，
只有 `u00_path_fmt` / `u01_path_fmt` 中 `%0d` 的物理 RTL 索引变为 `2..63`。

```systemverilog
cpu0.add_ram72_fmt(
    .name          ("dram72"),
    .base          ('h8000_0000),
    .u00_path_fmt  ("dut.cpu_ram[%0d].u00_ram.mem"),
    .u01_path_fmt  ("dut.cpu_ram[%0d].u01_ram.mem"),
    .num_blocks    (62),
    .blk_id_offset (2)
);
```

**ROM 多块带 offset** (少见, 同 add_rom_fmt 用 `.blk_id_offset(N)`).

### 6.5 不规整命名

```systemverilog
string blk_names[62] = '{"a", "b", "c", ...};

aip_cpu_ram_region r = cpu0.add_ram_empty("dram", 'h8000_0000, 62);
foreach (blk_names[i]) begin
    r.set_path(i, 0, $sformatf("dut.ram_bank_%s.uu0.mem_core_array", blk_names[i]));
    r.set_path(i, 1, $sformatf("dut.ram_bank_%s.uu1.mem_core_array", blk_names[i]));
end
```

### 6.6 加载 firmware

```systemverilog
aip_cpu_rom_region rom = cpu0.add_rom(...);
rom.load_hex("demo/firmware.hex", .addr_off(0));
```

### 6.7 Packed40 combined ROM/RAM image

Packed40 是显式选择的 ROM/RAM 合并镜像格式，可从 TCL 加载：

```tcl
load_packed40 file=image.hex
fw_reload mode=packed40 file=image.hex
```

输入每行格式为 `@<entry_index> <40-bit word>`，例如 `@00000000 8aed202000`。
`entry_index` 是物理条目索引，不是 CPU byte address；ROM 后接 RAM 的连续性仅描述
物理条目索引空间（两者之间没有 CPU RAM 地址空洞），不要求输入记录按顺序排列。
解析器接受稀疏、乱序记录；重复的 `entry_index` 按文件顺序依次写入，后一条会覆盖前一条。

每个 40-bit 源 word 只提取逻辑 byte `[38:31]`、`[29:22]`、`[20:13]`、`[11:4]`；源 parity
`[39]`、`[30]`、`[21]`、`[12]` 及 padding `[3:0]` 均忽略。小于 `rom.size/4` 的条目写入
ROM，后续条目从 offset zero 开始写入 RAM。RAM 写入会重新生成目标 parity，也适用于 RAM72
的 u00/u01 物理布局。

这是 opt-in 格式；`load_rom`、`load_ram`、`load_hex` 及标准 Verilog byte-hex 的
`@absolute_byte_address` 语义保持不变。

Packed40 加载是增量、非原子操作。遇到格式错误、越界或 backdoor 写入失败时，
命令会报失败，但不会回滚之前已成功的记录；若 4-byte 条目的后续 byte 写入失败，
该条目已写入的前缀也可能保留。失败后应先 reset/归零并重新加载，再继续使用。

## 7. 容量速查

| 部件 | 配置 | 单 RAM | 单 block | 总容量 |
|---|---|---|---|---|
| CPU ROM | 1 × 2 × 2048 × 64b | 0x4000 (16 KB) | 0x8000 (32 KB) | **32 KB** |
| CPU RAM (legacy) | 62 × 2 × 512 × 148b | 0x2000 (8 KB data) | 0x4000 (16 KB) | **0xF8000 (992 KB)** |
| CPU RAM (RAM72) | 62 × 2 × 256 × 4 × 72b | 0x2000 (8 KB data) | 0x4000 (16 KB) | **0xF8000 (992 KB)** |

## 8. 地址映射核对表 (示例)

| user addr | region | block | ram_id | RTL path | 说明 |
|---|---|---|---|---|---|
| 0x0000_0008 | ROM | 0 | 1 (uu1) | `dut.xxxx.uu1.mem_core_array[0]` | logical line 0 的高 64 |
| 0x0000_3FF8 | ROM | 0 | 1 (uu1) | `dut.xxxx.uu1.mem_core_array[1023]` | logical line 1023 的高 64 |
| 0x0000_4000 | ROM | 0 | 0 (uu0) | `dut.xxxx.uu0.mem_core_array[1024]` | logical line 1024 的低 64 |
| 0x8000_0100 | legacy RAM | 0 | 0 (uu0) | `dut.foo.blk0.uu0.mem_core_array[8]` | line=16, depth=8, even lane |
| 0x8000_0108 | legacy RAM | 0 | 1 (uu1) | `dut.foo.blk0.uu1.mem_core_array[8]` | 同一 logical line 的高 64 |
| 0x8000_4000 | legacy RAM | 1 | 0 (uu0) | `dut.foo.blk1.uu0.mem_core_array[0]` | 跨 block |
| 0x8007_FFFF | legacy RAM | 61 | 1 (uu1) | `dut.foo.blk61.uu1.mem_core_array[511]` | 最后 byte |
| 0x8000_0100 | RAM72 | 0 | 0 (u00) | `tb.cpu_ram[0].u00_ram.mem[16][0]` | line=16, depth=16, bank=0 |
| 0x8000_0108 | RAM72 | 0 | 1 (u01) | `tb.cpu_ram[0].u01_ram.mem[16][0]` | 同一 logical line 的高 64 |

## 9. 写入流程

```
cpu.write(addr, data, width)
    │
    ▼
[1] find(addr) → 返回匹配 region
    │
    ▼
[2] region.write_impl(addr - base, data, width)
    │
    ├── ROM: 对齐快路径 → 直接 wr_row
    │          非对齐    → 按字节 RMW
    │
    └── RAM: 按字节展开 → write_byte
              │
              ▼
         [3] legacy decode(off) → (blk, ram_id, depth, slot_sel, group_id)
              │
              ▼
         [4] rd_row(blk, ram_id, depth) → 取出 148-bit 当前行
              │
              ▼
         [5] splice_group(w, slot_sel, group_id, byte)
              │  → 算 even parity, 改写 9 bit (8 data + 1 parity)
              ▼
         [6] wr_row(blk, ram_id, depth, w_new)
              │
              ▼
         [7] uvm_hdl_deposit(path, w) → 落到 RTL array
```

## 10. 读出流程

```
cpu.read(addr, data, width, ok)
    │
    ▼
[1] find(addr) → region
    │
    ▼
[2] region.read_impl
    │
    ├── ROM: 直接读, ok=1 (无 parity)
    │
    └── RAM: 按字节展开 → read_byte
              │
              ▼
         [3] decode + rd_row
              │
              ▼
         [4] extract_group → 取出 8 data + 1 stored_parity
              │
              ▼
         [5] recalc_parity = XOR(data)
              │
              ▼
         [6] ok_i = (stored == recalc)
              │
              ▼
         [7] 累积: 任一 byte ok=0 → 整 word ok=0
```

## 11. 测试覆盖

`test/test_cpu_mem.sv` 覆盖 legacy 148-bit RAM 与 ROM；`test/test_cpu_mem72.sv`
覆盖 RAM72 的低/高 64-bit 路由、连续 group、parity、bank/block 边界、
`blk_id_offset`、loader 兼容和 HDL read-failure fail-closed 行为，以及 Packed40 的 ROM/RAM
映射、严格解析与状态错误、TCL 命令状态和 RAM72 parity。

| ID | 名称 | 验证点 |
|---|---|---|
| T1 | ROM 64-bit 对齐 | 基本写读 + 物理 array 验证 |
| T2 | ROM 128-bit logical-line interleave | 低64→uu0、高64→uu1；0x3FF8 / 0x4000 / 0x7FF8 |
| T3 | ROM 非对齐 32/8 bit | RMW 路径 + 字节序验证 |
| T4 | ROM load_hex | 从文件加载 firmware |
| T5 | RAM 64-bit + parity | 基本写读 + parity 自动生成 |
| T6 | RAM 低/高64 与 even/odd lane | +0x8 选高64/u01；+0x10 通过 odd lane 与 +0x0 共享物理 row |
| T7 | RAM physical depth / RAM transition | 0x1ff8 / 0x2000 跨 physical depth 255→256 且高64/u01→低64/u00 |
| T8 | RAM block 边界 | 0x4000 / 0xC000 边界 |
| T9 | RAM parity 注错 | 故意翻 bit → read 返回 ok=0 |
| T10 | 地址越界 | 越界写不崩, 报 aip_error |
| T11 | RAM 显式 8/32/64 + block 批量 | write8/32/64 + read8/32/64 + write_block/read_block/write_zero/write_incr |
| T12 | 批量归零 | zero_region(rom) + zero_region(dram) + zero_range + zero_all + 物理 array 验证 |
| T13 | blk_id_offset | RTL 索引从 5 起, path 拼接 + 读写 + 物理 bar[5..7] 验证 |
| T14 | add_rom_id | ROM 单块 RTL 带索引 (rom_arr[3].uu0/uu1), 写读 + 物理验证 |
| T15 | load_hex range guard | combined hex 按 region 自路由，跳过范围外 `@segment` |

默认回归仅运行 legacy/ROM 测试，不包含 Packed40：
```bash
cd aip_cpu_mem/test
make clean && make && ./simv
# 期望: pass=86 fail=0  [OVERALL] PASS
```

Packed40 与 RAM72 的相关回归：
```bash
cd aip_cpu_mem/test
make run72
# 期望: [OVERALL] PASS
```

## 12. 文件结构

```
aip_cpu_mem/
├── src/
│   └── aip_cpu_mem.sv       核心实现 (legacy RAM、RAM72、ROM、facade)
├── test/
│   ├── test_cpu_mem.sv      legacy RAM / ROM 回归
│   ├── test_cpu_mem72.sv    RAM72 回归
│   └── Makefile             vcs 编译
└── docs/
    ├── README.md            本文档
    └── architecture.md      设计 deep dive
```

## 13. 依赖

- **aip_log.sv** — `aip_info / aip_warning / aip_error` 宏
- **aip_mem_ecc.sv** — `xor_bits()` static primitive
- **uvm_pkg** — `uvm_hdl_deposit / uvm_hdl_read / uvm_hdl_data_t`

通过 `\`include "aip_core_pkg.sv"` 一次性引入全部依赖.

## 14. 扩展点

要新增 region 类型 (如 SRAM / cache / peripheral):

1. 继承 `aip_cpu_region`
2. 实现 `write_impl` / `read_impl`
3. 在 facade 加便利 `add_xxx` 方法 (可选)
4. 用户调 `cpu.add_region(r)` 直接注册

地址路由 / 越界检查 / 重叠检测 全自动复用 facade.

## 15. VCS Q-2020 兼容性

代码避开了常见 VCS Q-2020 坑:
- 不用 `longint unsigned'(...)` cast 语法
- 64-bit mask 用 `{64{1'b1}}` 或 `64'h1`
- queue by-value 改 inline 循环
- 不用 `aip_cmdline#(real)` 这类 T' cast 失败的模板
