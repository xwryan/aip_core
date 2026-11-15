# Known Issues & Workarounds

## C908 是 RV64 — firmware 必须 rv64gc/lp64 (历史: 早期 build 用 rv32imc)

**症状** (rv32imc 旧 prebuilt 跑真 C908)
- CPU 复位 PC=0x8000_0000 起执行
- 跑 2-3 条指令后 PC 跳 0
- mtvec 默认 0, trap → PC=0

**根因**
C908 是 64-bit (RV64GCB[V] per official datasheet). RV32 编译的压缩指令
(`c.jal`, `c.lw`, `c.sw`, `c.flw/fsw`) 在 RV64 上**有不同语义**
(映射到 `c.addiw`, `c.ld`, `c.sd`, reserved/illegal). PC 跑到第一个
misdecode 的压缩指令 → Illegal Instruction trap → mtvec=0 → 跳 0.

**修复 (已落地, 用 XuanTie 官方 startup.S 替换自写 crt0)**
- `firmware/Makefile.inc`:
  - `ARCH = rv64gc`  (原 `rv32imc_zicsr`)
  - `ABI  = lp64`    (原 `ilp32`)
  - `CFLAGS += -mcmodel=medany` (0x80000000+ 符号超 medlow 2GB)
- `firmware/startup.S` (XuanTie CSI 官方, 替代之前自写 `crt0_c908.S`):
  - 设 `mtvec = __Vectors|1` (vectored, 非 0 — 关键, 避免 trap 跳 0)
  - 标准 sp/gp 初始化, 调 `pre_main`
- `firmware/linker.xuantie.ld` (XuanTie xiaohui linker patched, 替代旧 3 模式 linker):
  - XIP: ROM 0x80000000/32K + RAM 0x80008000/864K + MBOX @ 0x800E0000
- `firmware/{csi_config.h, handlers.c}`: CSI 配置 + Default_Handler/pre_main stubs
- `firmware/prebuilt/rom_boot.{hex,elf,map}`: 用 XuanTie 官方 toolchain 重生成

**No-FPU C908 配置**
若你 C908 实例无 FPU, 重 build:
```bash
cd firmware && make plic ARCH=rv64imac    # (或 poll/msip)
```

**Bus 连通性独立检查**
SV 后门 load OK ≠ CPU bus fetch OK. RV64 build 后若仍跳 0, 读 mcause/mepc CSR
诊断:
- `mcause=0x2` (Illegal Instruction) → ISA 配置还不对, 看 misa / mxstatus
- `mcause=0x1` (Instruction Access Fault) → SoC AXI 路径未挂到 memory model
- 其他 → 见 RISC-V priv spec 异常列表

---

## TCL `fw_reload` result string empty (dispatch OK, result not propagated)

**Symptom**
```tcl
% fw_reload mode=rom_boot file=/path/to/x.hex
... [tcl_cmd] echo ...
% puts "status=[aip_check_status] result=[aip_read_result]"
status=0 result=
```

**Root cause**
`aip_cmd_str_2i` macro (`aip_cmd.sv:697-712`) writes only `this.status = 0`
after the registered svtask. It does NOT propagate
`aip_cmd::__aip_cmd_last_result` back to `this.result_out`. `aip_cmd::exec`
then copies the empty `handle.result_out` to the global, overwriting whatever
facade.load wrote.

**Status**
- Dispatch path is fully functional end-to-end: TCL → unknown override →
  aip_send_cmd → force signals → _vcs_run → SV `aip_cmd::exec` → `facade.load`
  → `inst.load()`.
- All inputs (mode, file, multi-space args) parse correctly.
- Only the result echo back to TCL is empty; the load itself executes.

**Workaround**
- SV-side direct invocation in TB code (not via TCL):
  ```sv
  loader.mode    = "rom_boot";
  loader.fw_path = "/path/to/x.hex";
  loader.load();
  ```
- Verify load success by reading first ROM bytes after dispatch:
  ```tcl
  % fw_reload mode=rom_boot file=x.hex
  % cpu_read32 addr=0x80000000
  ```
  Returns 0 → ROM not written (base/path config issue, not dispatch).
  Returns crt0 instruction (e.g. `0x000E0117`) → load succeeded.

**Proper fix (future)**
Modify `aip_cmd_str_2i` (and sibling `_str_1i1i` / `_1i1s` / `_4i` etc.) to
reset and propagate `aip_cmd::__aip_cmd_last_status/_result` around the svtask:
```sv
aip_cmd::__aip_cmd_last_status = 0;
aip_cmd::__aip_cmd_last_result = "";
svtask(...);
this.status     = aip_cmd::__aip_cmd_last_status;
this.result_out = aip_cmd::__aip_cmd_last_result;
```
Macros that do not touch globals still see status=0 result="" (no behavior change).

---

## Boot-ready handshake (`cpu_wait` command)

**What it does**
TCL blocks until CPU writes a magic value to a known mailbox offset, signaling
firmware init completed. Backdoor `uvm_hdl_read` poll — no CPU mailbox protocol
involved, so it works even before the CPU is responsive to commands.

**Wiring (already in repo)**
- `firmware/aip_cmd.h`:
  ```c
  #define MBOX_BOOT_READY_OFF   0x0800u
  #define MBOX_BOOT_READY_MAGIC 0xDEADBEEFu
  ```
- `firmware/app/main.c` writes the magic after `cmd_register_*` and before `cmd_loop()`.
- `aip_cpu_mem/src/aip_cpu_loader.sv::aip_cpu_loader_default::wait_value` —
  static task: poll `inst.cpu.read32(addr)` every 100 ns until match or timeout.
- `aip_core_pkg.sv` registers `cpu_wait` TCL command with defaults:
  - `addr=0x800E_0800`
  - `expected=0xDEADBEEF`
  - `mask=0` (auto promoted to `0xFFFFFFFF`)
  - `timeout_ns=1000000` (1 ms)

**TCL usage**
```tcl
% cpu_wait                                            ;# all defaults
% cpu_wait timeout_ns=10000000                        ;# 10 ms timeout
% cpu_wait addr=0x800E_0900 expected=0xCAFEBABE       ;# custom address / pattern
```

**Result strings (visible in sim log)**
- Success: `ready @ <time> after <ns> ns, val=0x<hex>`
- Timeout: `timeout <N> ns, last_val=0x<hex> (expected 0x<hex> mask 0x<hex>)`

Status `0` on success, `-1` on timeout / singleton-not-set.

**NOTE**: result string propagation suffers the same macro bug above. Until
fixed, status=0 alone is the success signal at the TCL prompt; the full
result string is visible in SV stdout.

**Prebuilt rebuild required**
`firmware/prebuilt/rom_boot.{hex,elf}` was generated before the magic write
was added. To regenerate with boot-ready support:
```bash
cd firmware && make plic        # (或 poll/msip)
cp build/plic.{hex,elf,map} prebuilt/
```
Until rebuilt, the prebuilt hex will boot but **never write the magic**, so
`cpu_wait` will hit timeout.

---

## Multi-stage boot-ready (optional enhancement)

Single magic at end of init is simplest. For finer debug granularity (which
init step the CPU is stuck at), write progressive values:
```c
#define STAGE_PRE_CMD_INIT  0xCAFE0001
#define STAGE_POST_REGISTER 0xCAFE0002
#define STAGE_READY         0xDEADBEEF
```
Probe with `cpu_wait expected=...` per stage. Not implemented yet.
