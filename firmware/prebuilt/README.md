# firmware/prebuilt/ — 预编译 firmware artifacts

未装 RISC-V toolchain 也可直接用。跟 `firmware/app/{main,user_cmds}.c` 源码同步。
用 `cd firmware && make <mode>` (XuanTie) 重生成。

## 文件 (三种 wake 模式)

| 文件 | wake 模式 | 说明 |
|---|---|---|
| `poll.{hex,elf,map}` | **poll** | CPU 轮询 cmd_flag (无中断)。`make poll` |
| `msip.{hex,elf,map}` | **msip** | CPU 挂 wfi,SV 后门 deposit CLINT MSIP0(0x0C00_0000) → 机器软件中断(mcause=3) 唤醒。`make msip`。用前 testbench 调 `aip_cpu_bridge::set_msip_path("<MSIP0 hdl 路径>")`。详见 docs/superpowers/specs/2026-06-03-cpu-msip-wake-design.md |
| `plic.{hex,elf,map}` | **plic** | CPU 挂 wfi,SV 后门置 PLIC_IP pending(src=48) → 机器外部中断(mcause=11) claim/complete 唤醒。`make plic`。用前 testbench 调 `aip_cpu_bridge::set_plic_path("<PLIC_IP word hdl 路径>", 48)`。详见 docs/superpowers/specs/2026-06-04-cpu-plic-wake-design.md |

`.hex` = objcopy -O verilog (`@ADDR` + byte stream);`.elf` = 反汇编用;`.map` = 符号布局。

## Boot 模式 (BOOT 旋钮, 正交 wake)

| BOOT | 输出后缀 | 行为 | loader 模式 |
|---|---|---|---|
| `rom` (默认) | (无) | XIP, 代码 ROM 内执行 | `rom_xip` / `rom_boot` |
| `ram_copy` | `_ram_copy` | reset 时 startup 把镜像 ROM→RAM 拷贝, 从 RAM 跑 (最真实) | `rom_boot` |
| `ram_jump` | `_ram_jump` | 单 hex: ROM stub @0x80000000 跳 RAM; payload 预置 RAM | `ram_jump` |

任意 wake × boot 组合: `cd firmware && make <poll|msip|plic> BOOT=<rom|ram_copy|ram_jump>`
→ `build/<wake>[_<boot>].hex`。prebuilt/ 只放 rom 三种, boot 变体按需自编。

- **ram_copy**: linker `arch/linker.ram_copy.ld` 把 .text/.rodata/.data VMA=RAM/LMA=ROM,
  startup.S (`-DAIP_BOOT_RAM_COPY`) 在 reset 时按 `__ram_image_lma→vma` 线性拷贝。镜像须 ≤32K ROM。
- **ram_jump**: linker `arch/linker.ram_jump.ld` 整体 VMA=LMA=RAM + ROM `.boot_stub`(`arch/boot_stub.S`)
  `j Reset_Handler`。SV `aip_cpu_loader` 用 `ram_jump` 模式把单 hex 同时灌 rom+ram, 各区按地址范围自过滤。

## 构建参数

```
BOOT     = rom (XIP) | ram_copy (ROM→RAM copy) | ram_jump (stub→RAM)
ARCH/ABI = rv64gc / lp64                        C908 = RV64GCB[V]
MODEL    = medany                               0x80000000+ 超 medlow 2GB
TOOLCHAIN= XuanTie-900-gcc-elf-newlib V3.4.0    玄铁官方 GCC 14.3.0 (绝对路径默认)
LINKER   = arch/linker.xuantie.ld               ROM 0x80000000/32K + RAM 0x80008000/864K
STARTUP  = arch/startup.S (XuanTie CSI)         .vectors + Reset_Handler (mtvec=__Vectors|1)
ENTRY    = 0x80000034 (Reset_Handler); 0x80000000 c.j → 0x80000034
```

无 FPU 的 C908: `make plic ARCH=rv64imac`。

## 内存布局

```
ROM    : 0x8000_0000 ~ 0x8000_7FFF   (32 KB)  ← reset PC
RAM    : 0x8000_8000 ~ 0x800D_FFFF   (864 KB)
MBOX   : 0x800E_0000 ~ 0x800E_0FFF   (4 KB)
PLIC+CLINT : 0x0800_0000 ~ 0x0FFF_FFFF (128 MB, StrongOrdered)  CLINT@+0x4000000
```
MBOX 地址若不同: 改 `firmware/app/aip_chip.h::MBOX_BASE` 重编 + 同步 `aip_core_pkg.sv` 的 `cpu_wait` 默认 addr。

## 启动流程

```
1. CPU 复位 → PC=0x80000000 → c.j Reset_Handler (0x80000034)
2. Reset_Handler: clear GPR → mie/mip=0, mstatus.MIE=0 → gp → mtvec=__Vectors|1 → sp → pre_main
3. pre_main: 清 .bss → main
4. main: cmd_init(0x800E0000) → register_builtins → user_register
       → [msip: cmd_msip_init][plic: cmd_irq_init]
       → store 0xDEADBEEF @ 0x800E0800 (boot-ready magic) → cmd_loop
```

## Boot-ready handshake

CPU 在 cmd_loop 前写 0xDEADBEEF 到 0x800E_0800。TCL `cpu_wait` 后门 poll 等此 magic 判 ready:
```tcl
% cpu_wait                       ;# 默认 1ms 超时
% cpu_wait timeout_ns=10000000   ;# 10ms
```

## 内含命令

**内建** (`core/aip_cmd.c::cmd_register_builtins`): `cpu_read32/write32/read64/write64` +
`*_swap` 变体 + `cpu_poll32` + `cpu_memset` + `cpu_memdump` + `cpu_exit`。
**业务示例** (`app/user_cmds.c`): `my_square x=N`、`my_add x=A y=B`。

## SV 后门加载

```sv
aip_cpu_bridge::init(your_mem_accessor, 64'h800E_0000);
// loader 把 hex deposit 到 ROM; 复位释放后 CPU 从 0x80000000 跑
// wake: msip → set_msip_path(...); plic → set_plic_path(..., 48)
```
TCL 命令经 `aip_cmd.tcl` unknown override 自动桥接到 mailbox。

## 重出 hex

```bash
cd firmware
# 改 app/user_cmds.c 加命令
make poll      # 或 msip / plic → build/<mode>.hex
cp build/<mode>.hex prebuilt/   # 更新 prebuilt (可选)
```
