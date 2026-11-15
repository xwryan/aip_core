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
- `firmware/Makefile`:
  - `ARCH = rv64gc`  (原 `rv32imc_zicsr`)
  - `ABI  = lp64`    (原 `ilp32`)
  - `CFLAGS += -mcmodel=medany` (0x80000000+ 符号超 medlow 2GB)
- `firmware/arch/startup.S` (XuanTie CSI 官方, 替代之前自写 `crt0_c908.S`):
  - 设 `mtvec = __Vectors|1` (vectored, 非 0 — 关键, 避免 trap 跳 0)
  - 标准 sp/gp 初始化, 调 `pre_main`
- `firmware/arch/linker.xuantie.ld` (XuanTie xiaohui linker patched, 替代旧 3 模式 linker):
  - XIP: ROM 0x80000000/32K + RAM 0x80008000/864K + MBOX @ 0x800E0000
- `firmware/core/{csi_config.h, handlers.c}`: CSI 配置 + Default_Handler/pre_main stubs
- `firmware/prebuilt/{poll,msip,plic}.{hex,elf,map}`: 用 XuanTie 官方 toolchain 重生成

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

## Boot-ready handshake (`cpu_wait` command)

**What it does**
TCL blocks until CPU writes a magic value to a known mailbox offset, signaling
firmware init completed. Backdoor `uvm_hdl_read` poll — no CPU mailbox protocol
involved, so it works even before the CPU is responsive to commands.

**Wiring (already in repo)**
- `firmware/core/aip_cmd.h`:
  ```c
  #define MBOX_BOOT_READY_OFF   0x0800u
  #define MBOX_BOOT_READY_MAGIC 0xDEADBEEFu
  ```
- `firmware/app/main.c` writes the magic after `cmd_register_*` and before `cmd_loop()`.
- `src/sv/cpu_mem/aip_cpu_loader.sv::aip_cpu_loader_default::wait_value` —
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

**Prebuilt rebuild required**
`firmware/prebuilt/*.hex` were generated before the magic write was added
**and** before `AIP_CMD_DATA_MAX` was corrected from 512 to 128 words
(`firmware/core/aip_cmd.h`). With the old value the C struct placed `rsp_flag`
at +0x808 while SV polls +0x208, so the stale prebuilt firmware can never
answer a synchronous command. To regenerate:
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

---

## UCLI `run` returns with Tcl code `return` after the bridge `$stop` unless `-debug_access+f`

**Symptom** (simv built without `+f`, e.g. `-debug_access+r` or `+rw`)
`source aip_cmd.tcl` returns, but nothing after its bridge-start block ran:
`::_aip_known_cmds` is never built (the `unknown` fast-fail path stays off and
every unknown command costs one SV round trip before failing) and, when
`aip_cmd.tcl` is sourced directly rather than through `dist/aip_init.tcl`,
`aip_checkpoint` / `aip_restore` / `aip_wait_checkpoint` are missing.

**Root cause**
When `run` (`_vcs_run`) comes back from the bridge's initial `$stop`, UCLI
returns it to Tcl with completion code 2 (`return`, level 1) instead of 0 —
the same effect as a `return` statement at that point, which ends the file
being sourced (the parent file continues) or the enclosing proc.  Measured on
VCS W-2024.09 with `dist/tests/tcl_ucli_smoke.sv` and
`catch {_vcs_run} res opts`: `+rw+f` and `+all` give `rc=0`; `+r`, `+rw`,
`+rw+cbk`, `+rw+pp`, `+rw+dmptf`, `+rw+class`, `+rw+thread` give
`rc=2 -level 1`.  The `+f` (force) capability is what switches `$stop` to the
normal-return path.

`+r`/`+rw` builds are not a supported bridge configuration anyway:
`aip_send_cmd` delivers every command with `force aip_core_pkg::__tcl_cmd_*`,
which needs `+f`.

**Workaround**
Build simv with `-debug_access+r+w+f` (`+r` for `get`, `+f` for `force`,
`+w` for `deposit`-based helpers); `+all` is a superset and also works.
Checkpointing needs nothing beyond `+r+w+f`: measured on W-2024.09
(2026-09-10), UCLI `save`/`restore` succeed with `+r+w+f`, `+r` and
`+simctrl`, and fail only with no `-debug_access` at all
(`Error-[UCLI-117]`).  Spell the options out: `-debug_access+rwf` is
accepted by `vcs` but measured as `rc=2` (no force capability).
`dist/aip_init_so.tcl` is immune to the script truncation (the bridge start
is isolated in `dist/aip_run.tcl`); `dist/aip_init.tcl` sources
`aip_checkpoint.tcl` itself, so only the command-table cache is lost there.

---

## VCS UCLI `restore` clears the Tcl command table

**Symptom**
Everything after `aip_restore` fails with `invalid command name "_aip_sim_time"`
(or any other `aip_*` / `fv` / `mem_*` command), even though the restore itself
succeeded and simulation time resumed at the snapshot.

**Root cause**
Measured on VCS W-2024.09 (2026-09-10) with both the source loader
(`dist/aip_init.tcl`) and the binary loader (`dist/aip_init_so.tcl`): UCLI
`restore` restores the simulation state and keeps Tcl **global variables**, but
every command defined by `source` or `load` is gone.  Execution also does not
continue past the `restore` inside `aip_restore`, so the confirmation `puts`
after it never prints; the next line of the `-do` script does run.

Because the globals survive, `::aip_initialized` is still `1` after the restore,
so simply re-sourcing the loader used to be a silent no-op.

**Workaround (in the repo)**
Both loaders now treat a missing `aip_send_cmd` as "not initialized", so a
second `source` after a restore re-loads everything; `dist/aip_init_so.tcl`
additionally skips the bridge start when the bridge was already running before
the restore.  User scripts must include that second `source` at file scope:

```tcl
aip_restore base
source /path/to/aip_core/dist/aip_init_so.tcl
run 500ns
```

After that second `source`, the restored session is fully usable: the command
table is back, a bridge round trip returns the value the design holds at the
snapshot (byte-identical to the same call taken before the snapshot), the UCLI
helpers read the design, `run` advances the simulation, and the session can take
further snapshots of its own.

One thing the second `source` cannot bring back is anything the *user* script
defined before the restore — procs are commands too, so a helper proc defined
above `aip_restore` is gone with the rest. Define them after the restore.

Regression: `make test_checkpoint_restore` (build with `-debug_access+r+w+f`;
see the note above about `+all`).

---

## VCS UCLI `save` hangs intermittently

**Symptom**
`aip_checkpoint` (or a bare UCLI `save`) never returns.  The snapshot
directory holds `<name>.FILES` and `<name>_tmp.save_in_progress` but no
finished `<name>.vcssave`.  Re-running the same command usually succeeds.

**Measurements** (VCS W-2024.09, host with ASLR on, trivial 2-signal design,
`save` repeated 5x per configuration, 60 s timeout, 2026-09-10)

| build | ASLR | ok | hung |
|---|---|---|---|
| `-debug_access+r+w+f` | on (simv re-execs itself) | 4 | 1 |
| `-debug_access+r+w+f` | off (`setarch -R`) | 3 | 2 |
| `-debug_access+all` | on | 3 | 2 |
| `-debug_access+all` | off (`setarch -R`) | 3 | 2 |

So the hang is independent of `-debug_access` and of the ASLR re-exec that
VCS performs at startup to enable `$save`.  An earlier note in this file
attributed a single observed hang to `+all`; that was one sample of a flaky
failure, not a property of `+all`, and has been corrected.

**Where it hangs**
A hung `simv` has a single thread parked in `do_wait` (`/proc/<pid>/wchan`)
with `<name>_tmp.save_in_progress` on disk: UCLI `save` forks a child to write
the snapshot and blocks in `wait()` for it, and intermittently that child never
completes.  Nothing on the Tcl or SV side is involved, so nothing in this
repository can prevent it.

**Workaround**
Treat snapshot creation as retryable: put a timeout around the step that
saves and re-run it on timeout.  Both checkpoint regressions do exactly that
(`CKPT_TIMEOUT`, `CKPT_ATTEMPTS` in the root Makefile), and note that a target
taking several snapshots compounds the risk: `test_checkpoint_wait_vcs` saves
four times, so at a per-save hang rate of ~25% it would fail most runs without
the retry.  Nothing in this repository makes the hang
more or less likely, and a snapshot that completes is sound — `restore`
from it behaves identically to the pre-snapshot session (see
`make test_checkpoint_restore`, which compares a bridge round trip taken
before the snapshot against the same call after the restore).

