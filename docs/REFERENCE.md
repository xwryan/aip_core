# AIP Core 详细参考（按源码文件组织）

> 历史详细参考，按源码文件逐个说明 API 与实现细节。日常使用请看根目录
> [`README.md`](../README.md)（按使用场景组织）；本文件中的路径和加载方式可能滞后。

SystemVerilog 工具库 + C 固件框架，为 UVM 验证环境提供：

- 字符串 / 日志 / 时钟 / 命令行参数 通用工具
- 命令分发框架（SV ↔ C ↔ TCL 三向桥接）
- ECC/parity 后门内存读写；多 CPU 多 region 内存抽象
- 三模式 firmware 构建（ROM XIP / RAM-only / ROM bootloader + RAM）
- 寄存器 R/W seq 注册宏（`aip_cmd_reg`）；运行时 .so 命令插件热加载（`aip_soload`）

> 本文件提供项目概览与快速上手；完整功能说明、示例和验证流程见[详细手册](docs/README.md)。

## 项目概述

AIP Core 是一个 SystemVerilog 工具库，为 UVM 验证环境提供字符串工具、日志、时钟生成、命令行解析和命令分发框架。

**编译要求：**
- VCS Q-2020.03 及以上
- 必须加 `-timescale=1ns/1ps`（否则 `aip_time::delay_ns` 和 `aip_clk` 的时间延迟无效）

推荐把统一入口 include 在 TB 源文件开头。`aip_core_pkg.sv` 声明真实的
`package aip_core_pkg`；package/类消费者显式 import 需要的 package：

```systemverilog
`include "aip_core_pkg.sv"

package user_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    class user_cfg;
        int value;
    endclass
endpackage
```

这样只编译 TB 源文件即可，统一入口与使用者天然位于同一 compilation unit：

```bash
vcs -sverilog -ntb_opts uvm +incdir+<aip_core_path> +incdir+<aip_core_path>/src/sv \
    -timescale=1ns/1ps your_test.sv
```

统一入口内 package-compatible 的组件都可由 `import aip_core_pkg::*;` 导入；canonical
流程只通过 `aip_core_pkg.sv` 统一引入，以保持依赖顺序和宏定义一致。**在一个 compilation unit 中，
`aip_core_pkg.sv` 必须是最先 include/compile 的 AIP SV 文件**；不要先 direct-include
`aip_log.sv`、`aip_cmdline.sv`、`aip_cmd.sv` 等 package-compatible 组件，再包含统一入口。
有状态组件若按错误顺序被直接包含，会在 `$unit` 与 `aip_core_pkg` 中形成两套类型及静态
registry/controller，print control 和 command registry 的状态无法保证统一，因此实现明确
拒绝这种顺序。VCS elaboration 会给出包含 `AIP_CORE_PKG_PREINCLUDE_ERROR` 的诊断；修复
方法是让 `aip_core_pkg.sv` 成为该 compilation unit 的首个 AIP SV 入口。

也可在同一次 VCS analysis 调用中依次分析 `aip_core_pkg.sv` 与使用者，但必须保持上述
先后顺序，且不要把它们拆成彼此独立的 `vlogan` 调用。

`aip_clk.sv` 是有意保留的特例：它包含 `aip_clk_if` interface，因此被放在
`endpackage` 之后并且是统一入口的最后一个组件。`aip_clk_if` 与 class `aip_clk` 都在
compilation-unit scope，不会被 `import aip_core_pkg::*;` 导入。使用 clock class、interface
或相关宏时，必须让统一入口与使用者处于同一 compilation unit（推荐像上面一样在 TB
源中 include，或放在同一次 VCS analysis 流程中）；分步独立运行 `vlogan`、只 import
package 的消费者看不到 `aip_clk`。module-scope clock 宏仍由统一入口提供。
这是 scope 布局例外，不是入口顺序例外；不要把 direct-include `aip_clk.sv` 作为首入口
或推荐流程。

**最小用例** — 把 mailbox 命令通过 TCL 透传到 CPU：

```tcl
% my_add x=10 y=20
sum=30
% cpu_write32 addr=0x80001000 data=0xdeadbeef
ok
% cpu_read32  addr=0x80001000
data=0xdeadbeef
```

### 命令行参数快速使用

| 目标 | plusarg 示例 | 含义 |
|---|---|---|
| 负整数 | `+dut.count=-10` | `aip_int` 得到 `-10` |
| 宽位整数 | `+dut.key=256'hFFFF_...` | 按目标类型位宽解析，最大 1024 bit，超位宽报错 |
| 随机候选 | `+dut.count=1,2,3` 或 `+dut.count=[1,2,3]` | `aip_int` 随机选择一个候选 |
| 范围随机 | `+dut.count=[1:3]` | 从闭区间 `[1:3]` 随机取值 |
| 权重分布 | `+dut.count={0:=40,[1:3]:=60}` | 按权重随机；外层也可使用 `(...)` |
| 全宽随机 | `+dut.data=rand` | `bit[255:0]` 等无法写出上界时用 |
| 动态数组 | `+dut.arr=1,2,3` 或 `+dut.arr=[1,2,3]` | `aip_int_list` 得到三元素数组 |
| 数组按规则随机 | `+dut.arr.size=8 +dut.arr.each=[1:10]` | 8 个元素各自独立随机 |
| 数组唯一/排序 | `+dut.arr.unique=1 +dut.arr.sort=asc` | 元素互不相同 / 升序 |
| 数组生成式 | `+dut.addr=seq:0:0xF00:0x100`、`+dut.ch=perm:0:7` | 展开等差序列 / 随机排列 |

```bash
./simv '+dut.count={0:=40,[1:3]:=60}'
```

请对整个 token 加引号；shell 会在 VCS 接收参数前去掉引号字符。全部随机化语法（标量、宽位、数组）集中在 [随机化语法](#随机化语法标量与数组) 一节。

### 子文档入口

| 主题 | 文档 |
|---|---|
| AIP Core 用户手册（详细） | [`docs/README.md`](docs/README.md)（含 DOCX、Markdown 源文件和验证说明） |
| AIP Core 用户手册（DOCX） | [`docs/AIP_Core_Environment_Guide.docx`](docs/AIP_Core_Environment_Guide.docx) |
| C 固件库（协议/构建/加命令） | [`firmware/README.md`](firmware/README.md) |
| `aip_cpu_mem` API + 架构 | [`docs/cpu_mem/README.md`](docs/cpu_mem/README.md) + [`architecture.md`](docs/cpu_mem/architecture.md) |
| Linux x86-64 动态库发布 | [`dist/README.md`](dist/README.md)；执行 `make -C dist all` |
| 设计 spec | [`docs/superpowers/specs/`](docs/superpowers/specs/) |
| 实施 plan | [`docs/superpowers/plans/`](docs/superpowers/plans/) |

### 源码目录布局

核心源码按语言和职责分层：

```text
src/
├── sv/{core,bridge,util,plugin,scb,sample}/
├── tcl/
└── c/{runtime,client}/
include/                 # C 插件 ABI 头文件
tests/{sv,tcl,c,plugins,scb}/ # 项目级回归测试，按语言和插件类型分组
dist/                   # 发布 Makefile、aip_init_so.tcl 和产物目录
```

`aip_core_pkg.sv` 是根目录兼容入口，真实实现位于
`src/sv/aip_core_pkg.sv`。用户可以继续使用旧的写法：

```systemverilog
`include "aip_core_pkg.sv"
```

新构建脚本应将 `src/sv` 加入 VCS include path。UCLI Tcl 通过
`source dist/aip_init_so.tcl` 加载。simv 需要 `-debug_access+r+w+f`（bridge 用
`get`/`force` 收发命令；`+all` 是其超集；注意 `+rwf` 写法不等价，force 不生效）。

---

## 文件清单

### 核心库文件

| 文件 | 功能 | 依赖 |
|------|------|------|
| `src/sv/aip_core_pkg.sv` | 每个 compilation unit 的首个 AIP SV 入口；声明 `aip_core_pkg`、include package-compatible 组件，并在 `endpackage` 后最后 include `aip_clk.sv` | — |
| `src/sv/core/aip_str.sv` | 字符串工具类 | 无 |
| `src/sv/util/aip_time.sv` | 时间工具类 | 无 |
| `src/sv/util/aip_log.sv` | 彩色日志系统 | aip_str, uvm_pkg |
| `src/sv/util/aip_clk.sv` | 高精度时钟生成器；interface/class 保持 compilation-unit scope | aip_log, aip_time |
| `src/sv/core/aip_cmdline.sv` | 命令行参数解析器；支持按完整参数键限制注册日志次数 | aip_str, uvm_pkg |
| `src/sv/core/aip_cmd.sv` | 命令分发框架（核心） | aip_str |
| `src/sv/core/aip_seq_launcher.sv` | seq 启动器（`aip_cmd_seq`/`aip_cmd_cseq` 与运行时命令共用的 count/time 启动流程）、`aip_seq_type`/`aip_seq_type_path` 类型声明、Tcl `aip_reg_seq`/`aip_unreg_seq` | aip_cmd, aip_tcl_bridge |
| `src/sv/bridge/aip_cpu_bridge.sv` | SV↔C mailbox 桥 + IRQ ACK monitor (v2 协议) | aip_log |
| `src/sv/util/aip_mem_ecc.sv` | ECC/parity 后门内存读写 (parity/secded/crc8) | aip_log, aip_cpu_bridge |
| `src/sv/bridge/aip_c_bridge.sv` | Socket/DPI-C 命令桥接 | aip_cmd, src/c/runtime/sv_socket_dpi.c |
| `src/sv/bridge/aip_tcl_bridge.sv` | TCL/UCLI 命令桥接 | aip_cmd |
| `src/sv/bridge/aip_dut_control.sv` | 注册受控 DUT force/deposit/get/release 及动态路径 readmemh/readmemb 命令 | aip_cmd, uvm_hdl |
| `src/sv/scb/aip_scb_types.sv` | scoreboard 配置、比较模式、待比项/结果类型、状态文字 | uvm_pkg |
| `src/sv/scb/aip_scb_reporter.sv` | scoreboard 问题流表格报告 | uvm_pkg |
| `src/sv/scb/aip_scb_registry.sv` | scoreboard 名字登记与控制代理 | uvm_pkg |
| `src/sv/scb/aip_scb.sv` | 公共 scoreboard `aip_scb#(T)`：有序/有损/无序/按键匹配，任一侧先到 | aip_scb_types/reporter/registry |
| `src/sv/scb/aip_scb_cmd.sv` | Tcl 命令 scb_list/scb_status/scb_report/scb_set_limit | aip_cmd, aip_scb_registry |
| `src/sv/sample/aip_mon_hub.sv` | 整笔事务采样 hub：按 portid 订阅独立深拷贝队列，复位清队列并发布通知 | uvm_pkg |
| `src/sv/sample/aip_sample_seq.sv` | 采样 sequencer/sequence 基类：按 agent 名登记，subscribe/mon_xaction/unsubscribe | aip_mon_hub |

### C 文件

| 文件 | 功能 |
|------|------|
| `src/c/runtime/sv_socket_dpi.c` | Socket DPI-C 底层（server 端，C89 兼容） |
| `src/c/client/client.c` | 命令行客户端（连接 SV server） |

### CPU 多区域内存抽象（src/sv/cpu_mem/）

| 文件 | 功能 |
|------|------|
| `src/sv/cpu_mem/aip_cpu_mem.sv` | region 基类 + legacy `aip_cpu_ram_region`（148-bit interleaved、`parity=XOR(data)`）+ opt-in `aip_cpu_ram72_region`（u00/u01 各 `72b × 256 × 4`、同为 XOR/even parity）+ rom_region (64b) + facade |
| `src/sv/cpu_mem/aip_cpu_loader.sv` | firmware 加载器；SV/Tcl 共用 `load_image(file,start,format)` facade，以及 `cpu_wait` 命令 backend |
| `tests/sv/cpu_mem/fake_mem.sv` | 假 ROM/RAM 共享 fixture |
| `tests/sv/cpu_mem/test_cpu_mem.sv` | legacy RAM / ROM 回归 |
| `tests/sv/cpu_mem/test_cpu_mem72.sv` | RAM72 u00/u01、parity、bank/block、loader 与 fail-closed 回归 |
| `docs/cpu_mem/README.md` | API 速查 + 17 用例表 |
| `docs/cpu_mem/architecture.md` | 类层次 + 地址解码 + 容量推导 |

### C 固件库（firmware/）

| 文件 | 功能 |
|------|------|
| `firmware/core/aip_cmd.h` | C 侧命令框架头文件 (含 aip_mailbox_t v2 协议 + MBOX_BOOT_READY_OFF/MAGIC, AIP_CMD_DATA_MAX=128) |
| `firmware/core/aip_cmd.c` | C 侧命令框架实现 (cmd_init/register/dispatch/loop/builtins) |
| `firmware/core/aip_cmd_c908.h` | C908 中断参考实现头文件 |
| `firmware/core/aip_cmd_c908.c` | C908 PLIC 中断唤醒参考实现 (PLIC + mtvec) |
| `firmware/core/aip_cmd_msip.c` | CLINT MSIP 唤醒参考实现 |
| `firmware/core/csi_config.h` | XuanTie CSI 配置 (CONFIG_KERNEL_NONE + stack size) |
| `firmware/core/handlers.c` | Default_Handler / Mirq_Handler / pre_main / SystemInit stubs |
| `firmware/arch/startup.S` | XuanTie CSI 官方 startup (mtvec=__Vectors\|1, sp, gp, jalr pre_main) |
| `firmware/arch/boot_stub.S` | ram_jump 模式 ROM 跳转 stub |
| `firmware/arch/linker.xuantie.ld` | XIP linker (ROM 0x8000_0000/32K, RAM 0x8000_8000/864K) |
| `firmware/arch/linker.ram_copy.ld` / `linker.ram_jump.ld` | ram_copy / ram_jump boot 模式 linker |
| `firmware/app/{aip_chip.h,main.c,user_cmds.c}` | 平台常量 + 固件主入口 + 业务命令样板 (my_square / my_add) |
| `firmware/Makefile` | 构建入口 (`make poll|msip|plic [BOOT=rom|ram_copy|ram_jump]`) |
| `firmware/prebuilt/{poll,msip,plic}.{hex,elf,map}` | 预编译固件 (见 `docs/KNOWN_ISSUES.md` 关于需重生成的说明) |
| `firmware/tests/test_aip_cmd_host.c` | L1 host gcc 单元测试 (含 mailbox offsetof 断言) |
| `firmware/tests/Makefile` | host 测试构建 |
| `firmware/README.md` | 协议表 + 加命令模式 + build 模式表 |

### TCL 脚本

| 文件 | 功能 |
|------|------|
| `src/tcl/aip_cmd.tcl` | TCL 命令桥接脚本（加载后 SV 命令无感调用） |
| `src/tcl/aip_checkpoint.tcl` | VCS save/restore 断点续跑（被 aip_cmd.tcl 自动 source） |
| `src/tcl/aip_ucli_utils.tcl` | UCLI 原生 force/get + 后门 mem ECC/parity 工具库 |
| `src/tcl/vcs_ucli_reference.tcl` | VCS UCLI TCL 命令参考手册 |

### 工具脚本

| 文件 | 功能 |
|------|------|
| `packaging/scripts/analyze_timescale.py` | 分析 .f filelist 中所有 `\`timescale` 指令, 嵌套展开, 显示 final sticky + 冲突点 |

---

## 固件 boot 模式

| BOOT | linker | 用途 |
|---|---|---|
| `rom` (默认) | `arch/linker.xuantie.ld` | XIP：firmware 在 ROM 直跑 |
| `ram_copy` | `arch/linker.ram_copy.ld` | ROM bootloader memcpy 到 RAM 再跳 |
| `ram_jump` | `arch/linker.ram_jump.ld` | ROM 只放跳转 stub，firmware backdoor 灌 RAM |

```bash
cd firmware
make plic                  # 默认 BOOT=rom，唤醒方式 poll|msip|plic
make plic BOOT=ram_copy    # build/plic_ram_copy.hex
make all                   # poll/msip/plic 三个都编
```

## 测试矩阵

```bash
make help            # 列出全部回归 target
make ci-host         # L1 host gcc (firmware/tests) — sub-second
make ci-sv           # L2 aip_cpu_mem 回归 (legacy RAM/ROM + RAM72/packed40) — VCS
make ci-regress      # named end-checker registry 矩阵 — VCS
make ci              # 以上三项

make test_reg_seq    # aip_cmd_reg 寄存器 R/W seq — VCS (12/12)
make test_soload     # aip_soload 运行时 .so 命令插件 — VCS + gcc (12/12)
make test_cseq_arbitration  # cseq/creg grab 顺序 + 回读 — VCS
make test_c_bridge_socket   # 默认不监听、显式启动、TCP OK/ERROR、cseq — VCS + Python
make test_c_bridge_checkpoint # 新进程恢复未监听快照，再显式开启 TCP
make test_dut_control       # dut_force/deposit/get/release/force_time/readmem — VCS
make test_scb               # aip_scb 匹配语义与 14 组报告上限矩阵 — VCS
make test_mon_hub           # aip_mon_hub/aip_sample_seq 订阅、超时、复位、溢出、读者 — VCS
make test_aip_reg_seq       # Tcl aip_reg_seq/aip_unreg_seq 运行时注册，源码/.so 两种 loader — VCS + gcc
make -C dist test-ucli-so   # dist/aip_init_so.tcl + UCLI -do smoke — VCS + gcc
```

TCP 回归会依次发送 `socket_value`、`socket_cseq count=3`、未知命令和
`socket_ping`，预期看到：

```text
socket_value => OK: value=0x1234
socket_cseq count=3 => OK: socket_cseq count=3
does_not_exist => ERROR: Unknown command: does_not_exist
socket_ping => OK:
C_BRIDGE_SOCKET_PASS
```

---

## 各文件详细使用说明

### 1. aip_str.sv — 字符串工具

```systemverilog
// 查找子串
int pos = aip_str::str_find("hello world", "world");     // 返回 6

// 去除首尾空白
string s = aip_str::strip("  hello  ");                   // "hello"

// 分割字符串
string parts[] = aip_str::split("a,b,c", ",");            // {"a","b","c"}

// 替换
string r = aip_str::replace("foo bar", "bar", "baz");     // "foo baz"

// 大小写转换
string lo = aip_str::lower("HELLO");                      // "hello"
string up = aip_str::upper("hello");                      // "HELLO"

// 数字解析（支持 0x 十六进制、0b 二进制）
int width;
longint unsigned val = aip_str::str_to_num("0xFF", width); // 255

// 去除所有空格
string ns = aip_str::remove_all_spaces("a b c");          // "abc"
```

### 2. aip_time.sv — 时间工具

```systemverilog
// 获取当前仿真时间（指定单位）
real t_ns = aip_time::get_sim_time("ns");
real t_us = aip_time::get_sim_time("us");
real t_ps = aip_time::get_sim_time("ps");

// 精确延迟（与 timescale 无关，需要编译时加 -timescale）
aip_time::delay_ns(10.5);     // 延迟 10.5ns
aip_time::delay_ns_int(100);  // 延迟 100ns（整数版本）
```

### 3. aip_log.sv — 彩色日志（V3.0）

无外部依赖（最先 include），UVM 风格格式，时间单位自动从 timescale 推算。

```systemverilog
// 双括号用法（内嵌 $sformatf，省去手写）
`aip_info(("simple message"));
`aip_info(("val=%0d addr=0x%0h", val, addr));

// 带实例名（inst 在前，args 在后）
`aip_ninfo("top.dut.eth", ("packet sent, len=%0d", len));
`aip_nerror(this.name, ("timeout at addr=0x%0h", addr));

// UVM 组件内（自动 get_full_name()）
`aip_uinfo(("message"));

// 输出格式（参考 UVM）：
// [INFO ] /path/to/test.sv(42) @ 100.00 ns: simple message
// [ERROR] /path/to/sb.sv(88) @ 100.50 ns: top.env.sb: data mismatch

// 配置
aip_log::set_verbosity(aip_log::DEBUG);                       // 全局级别
aip_log::set_inst_verbosity("top.dut.*", aip_log::WARNING);   // 通配符
aip_log::set_inst_verbosity("top.dut.phy", aip_log::DEBUG);   // 精确匹配

// 时间单位（默认自动推算，也可手动设置）
aip_log::set_time_unit("us");  // 切换显示为微秒

// 统计
$display("errors: %0d", aip_log::get_count(aip_log::ERROR));
aip_log::summary();

// FATAL → 桥接 uvm_report_fatal，走 UVM 正常退出流程
`aip_fatal(("critical error"));   // extract → check → report → $finish
```

**6 个级别：** FATAL（粗体红）、ERROR（亮红）、WARNING（黄）、INFO（默认）、DEBUG（灰）、TRACE（青）

**3 套宏（18 个）：** `aip_xxx(args)` / `aip_nxxx(inst, args)` / `aip_uxxx(args)`

### 4. aip_clk.sv — 时钟生成器

```systemverilog
// 方式 1：宏一行创建（接口 + 实例 + 配置 + 启动）
`aip_clk_create(clk0, 100e6)                    // 100MHz
`aip_clk_create(clk1, 156.25e6, 50, 1e-9)       // 156.25MHz, 50ppm, 1ns 相位

// 方式 2：手动创建
aip_clk_if clk0_if();
aip_clk clk0;
initial begin
    clk0 = new("clk0", clk0_if);
    clk0.set_freq(100e6);
    clk0.set_duty_cycle(0.6);
    clk0.set_ppm(50);
    clk0.set_jitter(1e-12);       // 1ps RMS 抖动
    clk0.start();
end

// PLL 模式
clk0.set_pll_params(10, 2, 25e6);  // 25MHz * 10 / 2 = 125MHz
clk0.set_lock_time(1e-6);          // 1us PLL 锁定时间

// 运行时控制
clk0.stop();                        // 停止
clk0.start();                       // 重新启动

// 等待时钟沿（带超时）
clk0.wait_for_posedge(100ns);
clk0.wait_for_negedge();

// 多时钟同步启动
aip_clk clks[] = '{clk0, clk1, clk2};
aip_clk::start_all(clks);

// 信号使用
wire my_clk = clk0_if.clk;
```

**注意：编译必须加 `-timescale=1ns/1ps`，否则时钟延迟为零导致死循环。**
`aip_clk_if` 和 `aip_clk` 不属于 `aip_core_pkg`；除 import package 外，还要按前述方式让
`aip_core_pkg.sv` 与 clock 使用者位于同一 compilation unit。clock 宏由统一入口定义，
仍应在 module scope 使用。`aip_clk.sv` 的 package 外布局不改变首入口规则，推荐流程仍是
先包含 `aip_core_pkg.sv`。

### 5. aip_cmdline.sv — 命令行参数解析

```systemverilog
// 基本类型：通过 +path.name=value 传递
int count;
`aip_int("dut", int, count, 1)            // +dut.count=10
                                             // +dut.count=-10
                                             // +dut.count=-0x20

string name;
`aip_string("dut", name, "default")       // +dut.name=hello

real freq;
`aip_real("clk", freq, 100.0e6)           // +clk.freq=156.25e6

// 宽位整数：按目标类型位宽解析，最大 1024 bit
bit [255:0] key;
`aip_int("dut", bit [255:0], key, 0)      // +dut.key=256'hFFFF_...  或 0x...

// 数组（动态 aip_int_list / 静态 aip_int_slist，plusarg 语法相同）
int arr[];
`aip_int_list("dut", int, arr, 0)         // +dut.arr=1,2,3,4
int tbl[4];
`aip_int_slist("dut", int, tbl, 0)        // +dut.tbl=4,3,2,1

// 以上每个整数位置都可写随机语法（[1:10]、rand、{...:=...}、.each/.unique/.sort、seq:/perm:），
// 见下方「随机化语法」。

// 枚举
typedef enum {FAST, SLOW} speed_e;
speed_e spd;
`aip_enum("dut", speed_e, spd, FAST)      // +dut.spd=SLOW

// 位标志：成员值为位号，目标最多 64 位；值为成员名之或，或单个整数掩码；未知名称 hard fatal
typedef enum {CSUM = 0, TSO = 11, V1 = 32} feat_e;
bit [63:0] feat;
`aip_flags("dut", feat_e, feat, 0)        // +dut.feat=V1,CSUM 或 +dut.feat=0x100000001
// aip_cmdline_flags#(feat_e)::describe(feat) 返回 "0x100000001 (CSUM|V1)"，names(feat) 返回 "CSUM|V1"

// 结构体（紧凑格式）
typedef struct { int addr; int len; string name; } cfg_t;
cfg_t cfg;
`aip_struct_begin("dut", cfg)
    `aip_struct_int(cfg, addr, 0)
    `aip_struct_int(cfg, len, 64)
    `aip_struct_string(cfg, name, "x")
`aip_struct_end(cfg)
// +dut.cfg={addr=0x100,len=64,name=hello}
// +dut.cfg.addr=0xFF（点号优先级更高）
```

`aip_flags` 的成员名（不区分大小写）与整数掩码不能混写，成员名优先于数字解析；整数写法同 `aip_int`
固定值。来源优先级、`set_param`/`clear_param` 与层级路径同 `aip_int`，空 override 为 0。不支持随机语法，
读取不消耗随机数；未知名称、空项、位号或数值超出目标位宽都 hard fatal，并报出参数路径与非法项。

#### 随机化语法（标量与数组）

所有随机相关语法集中在此。随机源是 `$urandom`，跟随 `+ntb_random_seed`：同一种子、同一命令行
得到同一结果。每个宏在注册时抽一次值，注册日志会打印抽到的值。

**标量（`aip_int`；`aip_struct_int` 字段同）**

| 语法 | 含义 | 示例 |
| --- | --- | --- |
| `v` | 固定值；支持 `0x`/`0b`/`0o`、`N'h`、`_` 分隔、正负号。负值按目标类型位宽回绕（`-1` 进 `bit[7:0]` 得 `8'hff`） | `+dut.count=-0x20`、`+dut.count=-8'd10` |
| `a,b,c` / `[a,b,c]` | 候选列表，随机选一个 | `+dut.count=[-3,-2,-1]` |
| `[lo:hi]` | 闭区间随机 | `+dut.val=[1:10]` |
| `{x:=w, [lo:hi]:=w}` | 权重随机：`:=` 每个值各占 w，`:/` 整段共占 w；外层 `{}` 或 `()` | `+dut.val={0:=40,[1:3]:=60}` |
| `inc:a:b[:s]` / `dec:a:b[:s]` | 从等差序列 a,a±s,…,b 中随机挑一个（步长默认 1） | `+dut.val=inc:0:100:5` |
| `rand` | 全宽均匀随机；权重组内只能写 `rand:/w` | `+dut.data=rand`、`+dut.data={0:/1,rand:/9}` |

宽位：值按目标类型位宽解析，最大 1024 bit；值超出位宽、显式位宽大于类型位宽（`64'h1` 给 `int`）
都报错，不静默截断。`bit [255:0]` 这类写不出 `[0:2^N-1]` 的用 `rand`。范围、步进、权重随机在任意
位宽下都是均匀的（内部用 1026 bit 有符号算术，最后转成目标类型）。

**数组（`aip_int_list` 动态 / `aip_int_slist` 静态，键名相同）**

| 键 | 含义 | 示例 |
| --- | --- | --- |
| `arr=v1,v2,…` | 整体列表；每个元素可用上表任意标量语法 | `+dut.arr=[1:3],7,[4:6]` |
| `arr[i]=v` | 索引覆盖，优先级最高 | `+dut.arr[0]=1` |
| `.size` | 长度，可随机；仅动态数组 | `+dut.arr.size=[4:16]` |
| `.each` | 未被列表/索引覆盖的元素各自独立按此规则抽 | `+dut.arr.each=[1:10]`、`+dut.arr.each=rand` |
| `.unique=1` | 元素互不相同；`.each` 生成的元素冲突时重抽，上限 100×size | `+dut.arr.each=[0:15] +dut.arr.unique=1` |
| `.sort=asc\|desc` | 对最终数组排序，索引覆盖值一起参与 | `+dut.arr.sort=asc` |
| `arr=seq:a:b[:s]` | 展开整个等差序列（仅整数数组） | `+dut.addr=seq:0x1000:0x1F00:0x100` |
| `arr=perm:a:b` | a..b 的随机排列（仅整数数组） | `+dut.ch=perm:0:7` |

- 优先级：`arr[i]=` > `arr=`（列表 / seq / perm）> `.each` > 宏默认值。
- `seq/perm` 最多展开 1000000 个元素。
- 静态数组：不接受 `.size`；列表长于声明长度报错；seq/perm 展开长度必须等于声明长度；未覆盖元素填默认值。
- 以下情况报错而不静默降级：只有 `.each` 没有长度来源；`.size` 为负；`.unique` 不是 0/1；`.unique`
  下固定值重复或候选不足；`.sort` 不是 asc/desc；标量上用 seq/perm。
- 注册日志带控制摘要，如 `array 'arr' (scope='dut') [8] each=[1:10] unique = 3 7 ...`。

**字符串**：`aip_string` 的逗号列表随机选一个；`aip_str_list`/`aip_str_slist` 支持
`.size/.each/.unique/.sort`（`.each=a,b,c`），不支持 seq/perm。

**列表边界规则**：方括号中的逗号内容是列表，方括号中的冒号内容是范围：`[1,2,3]` 与 `[1:3]`
不是同一种语法。外层方括号边界和顶层列表结构采用 fail-closed 处理：`[1,]`、
`[,1]`、`[1,,2]`、`[1],[2]`、`[1,2`、`[1],2]` 等已验证的 malformed 输入
都会报错并保留宏的失败处理，而不会静默降级成普通标量或另一种随机语法。这项保证
仅限外层 `[...]` 边界及其顶层列表结构，不涵盖嵌套 `{...}` 或 `(...)` 内部的
非规范分隔符；权重分布应使用完整的规范形式，且不要附带尾随分隔符。

**引号**：直接从 shell 启动时，应由 shell 引号对特殊字符分组：

```sh
./simv '+dut.weight={0:=40,[1:3]:=60}'
```

传递含空格的值时，YAML、shell、VCS 各层的引号含义可对照如下：

```text
YAML source:       "+dut.message=hello world"
actual argv token: +dut.message=hello world
shell form:        '+dut.message=hello world'
VCS value:         hello world
```

YAML 引号保护 YAML 标量，shell 引号保护一个 argv token；两者都不会进入 VCS value。
故意嵌入的字面引号则会保留，因此不应仅为处理空格而把字面引号加入值中。当花括号、
方括号、冒号、逗号或空格等特殊字符可能影响 YAML 解析时，应为整个 YAML 标量加引号。
对于 SimFlow 这类以列表直接传递本地 argv 的调用，可写为：

```yaml
args:
  - "+dut.weight={0:=40,[1:3]:=60}"
```

双引号由 YAML 消费，最终 argv token 是 `+dut.weight={0:=40,[1:3]:=60}`；不应在
实际 argv token 中额外加入 shell 引号。如果 YAML 值随后作为 shell 命令字符串执行，
则写为：

```yaml
run: "./simv '+dut.weight={0:=40,[1:3]:=60}'"
```

这里的外层双引号由 YAML 消费，内层单引号必须保留在命令字符串中，供后续 shell
消费；YAML 引号本身不能保护 shell 层中的空格或花括号。这与 argv 列表直接执行不同：
后者没有后续 shell 层可消费引号。

#### 注册日志控制

`aip_cmdline` 宏完成解析和赋值后会打印注册日志。默认
`print_enable=1, max_prints=10`，每个完整 `path.name` 键最多打印 10 次；不同键分别计数。
启动 simv 时可用 plusarg 配置：

```text
+aip_cmdline.print_enable=0
+aip_cmdline.max_prints=3
```

SV 运行时可直接配置：

```systemverilog
aip_cmdline_print_control::configure(1, 5);
```

通过 TCL bridge 也可调用统一入口已注册的命令：

```tcl
set_cmdline_print enable=1 max_prints=5
```

`max_prints=-1` 表示不限制次数，`max_prints=0` 表示不打印；`print_enable=0` 全局关闭
注册日志，但参数解析与赋值仍继续。小于 `-1` 的 `max_prints` 会归一化为 `-1` 并打印
warning。每次运行时调用 `configure` 或 `set_cmdline_print` 都会清空已经累计的 per-key
计数；plusarg 只用于 fresh-process 启动配置，不承担运行时重配置。

### 6. aip_cmd.sv — 命令分发框架

```systemverilog
// --- 注册命令 ---

// 0 输入 0 输出（最基本）
`aip_cmd_task(my_cmd, my_class::my_task)

// 带类型参数
`aip_cmd_1i(print_val, ops::print_val, int, val, 0)
`aip_cmd_2i(set_range, ops::set_range, int, low, 0, int, high, 100)
`aip_cmd_3i(config3, ops::config3, int, a, 0, int, b, 0, int, c, 0)
// ... 最多 `aip_cmd_10i

// 带输出
`aip_cmd_1i1o(read_reg, ops::read_reg, int, addr, 0, int, rdata)
`aip_cmd_2i1o(write_reg, ops::write_reg, int, addr, 0, int, data, 0, int, status)
`aip_cmd_2i2o(rmw_reg, ops::rmw_reg, int, addr, 0, int, mask, 0, int, old_val, int, new_val)
// ... 最多 5i5o

// 字符串输入
`aip_cmd_str_1i(echo, ops::echo, msg, "default")

// 枚举输入
`aip_cmd_enum_1i(set_mode, ops::set_mode, mode_e, mode, MODE_IDLE)
`aip_cmd_enum_1i1o(check_mode, ops::check_mode, mode_e, mode, MODE_IDLE, int, status)

// 结构体（手动解析 args_in）
`aip_cmd_task(dma_config, ops::dma_config)
// task 内部: aip_cmd::get_arg(h.args_in, "addr") 提取参数

// 命令元数据（可选）
`aip_cmd_info(write_reg, "reg", "Write register", "addr:int data:int -> status:int")

// --- Seq 注册宏 — 绑定 UVM sequence + virtual sequencer ---
`aip_cmd_seq(axi_write, axi_wr_seq, virtual_sqr::axi_wr_sqr)
`aip_cmd_seq(axi_read,  axi_rd_seq, virtual_sqr::axi_rd_sqr)
// Seq class 需要有 int count 字段
//
// 两种控制模式：
//   count 模式: axi_write count=10       — 发 10 个 trans
//   time 模式:  axi_write time=1us       — 持续发 1 微秒
//               axi_write time=500ns     — 持续发 500 纳秒
//               axi_write time=30000ps   — 持续发 30ns
//   默认:       axi_write                — 发 1 个 trans
// 支持时间单位: fs, ps, ns, us, ms, s
//
// time 模式原理: seq.count 设为最大值, fork seq + timer join_any, 超时后 disable seq

// --- 寄存器 R/W seq 注册宏 — inline 传参 + 回读返回 ---
`aip_cmd_reg(reg_acc, reg_seq, virtual_sqr::reg_sqr)
// seq 须声明固定字段: bit is_write; longint unsigned addr,wdata,rdata; int unsigned len,mask;
// wdata/rdata 也可使用 bit [127:0]；输入超过实际 wdata 位宽时返回错误，不静默截断。
// 可选第4参数 error_expr，例如 seq.error_msg：空串成功，非空返回 ERROR/status=1。
// read 时 seq body 把回读值写入 rdata，宏格式化回 result_out 经 TCL 打印。
//
//   reg_acc op=write addr=0x1000 len=4 mask=0xff data=0xdead  → OK: write addr=0x1000 data=0xdead
//   reg_acc op=read  addr=0x1000                              → rdata=0xdead
//   reg_acc op=read                                           → ERROR: reg reg_acc: missing op/addr
//
// op 别名: write={write,wr,w,1}, read={read,rd,r,0}; 其他值报错。缺 op/addr → 不启 seq, status=1。
// 位置写法: reg_acc write 0x1000 16 0x112233445566778899aabbccddeeff00 [mask]
// 位置读法: reg_acc read 0x1000 [len]；位置形式可附加 mask=，其他核心字段不能混用命名形式。
// len 默认4，mask 默认0（旧版为0xffffffff）；框架不解释二者含义，原样透传给seq body。
// PCIe 新封装约定 mask 的bit i=1屏蔽addr+i字节、0正常访问；其他总线需自行保持语义兼容。

// --- TCP 严格插入模式：cseq / creg ---
// cseq 可执行多个 transaction；整个 sequence 在目标 sequencer 上持有 grab。
`aip_cmd_cseq(bus_burst, bus_burst_seq, virtual_sqr::bus_sqr)
// creg 是单次寄存器/总线 transaction；read 结果由 seq 写入 rdata。
`aip_cmd_creg(bus_access, bus_reg_seq, virtual_sqr::bus_sqr)
// TCP 命令示例：
//   bus_burst count=3
//   bus_access op=read addr=0x1000
//   bus_access op=write addr=0x1000 data=0x55aa len=4
// 返回：OK: <result> 或 ERROR: <reason>（每条消息一行）
// 注意：grab 等待当前 driver transaction 完成，不会打断正在执行的 transaction。
// aip_cmd_seq/aip_cmd_cseq 的 count/time 启动流程在 aip_seq_launcher::run（core/aip_seq_launcher.sv），
// 宏只生成创建 seq 并写 count 的启动器；日志仍指向宏所在的用户源码行。

// --- 运行时注册（不重编译）：SV 每种类型声明一行，Tcl 绑定到 sequencer 生成新命令 ---
`aip_seq_type(axi_wr_seq)          // T 须 `uvm_object_utils 且有 int count
`aip_seq_type_path(vio_tx_seq)     // 另有 string param_path，只有这种类型接受 path=
// Tcl：aip_reg_seq cmd=<新名> type=<宏参数原文> sqr=<sequencer UVM 全名> [path=<参数路径>]
//   aip_reg_seq cmd=vio_tx_p1 type=vio_tx_seq sqr=uvm_test_top.env.vio.p1.sqr path=vio.tx.p1
//   vio_tx_p1 count=1000 | time=1us [wait=0]   → OK: vio_tx_p1 count=1000（同 aip_cmd_seq）
//   aip_unreg_seq cmd=vio_tx_p1                → 只注销 aip_reg_seq 生成且空闲的命令
// 生成的命令类 aip_reg_seq_cmd（aip_cmd_user_task 派生）：BUSY、kill_seq/watchdog、help 分组 [aip_reg_seq]
// 与编译期命令一致；启动前写 seq.count，给了 path= 才写 seq.param_path（create 之后写，参数须在 body 中读）。
// 报错（ERROR/status=1，不覆盖、不新建）：缺 cmd=/type=/sqr=、未知/重复/空值的键、名字已存在或非法
// （字母/_ 开头，只含字母数字和 _ . : -，fork 保留）、类型未声明、sqr 找不到或不是 uvm_sequencer_base、
// 对 aip_seq_type 类型给 path=。Tcl proc 另拒绝与 Tcl 已有命令同名、多行 fork 块内注册。注入队列拒绝这两条命令。
// SV 侧同样可用：
//   aip_reg_seq_cmd cmd; string why;
//   if (!aip_reg_seq_cmd::register("vio_tx_p1", "vio_tx_seq", "uvm_test_top.env.vio.p1.sqr", "vio.tx.p1", cmd, why))
//       `uvm_error("REG", why)
//   aip_seq_launcher::find("vio_tx_seq")       // 已声明类型的启动器；未声明返回 null
// 命令名表：注册/注销后 aip_tcl_bridge::sync_cmd_names() 重写 __tcl_cmd_names_* 并递增 __tcl_cmd_names_gen，
// Tcl 缓存版本不同即重读；快照恢复后注册表与名表一起回到快照时刻，重新 source 加载脚本时重读。

// --- 时间字符串解析（SV 内部可用）---
// real ns = aip_cmd::parse_time_ns("1us");    // → 1000.0
// real ns = aip_cmd::parse_time_ns("500ns");  // → 500.0
// real ns = aip_cmd::parse_time_ns("100ps");  // → 0.1

// --- 严格无符号参数解析（SV 内部可用）---
// 空串取默认值；负数、非整数字面量或超过 max 返回 0 并给出原因（parse_int64_arg 则静默回落默认值）。
// longint unsigned qid; string why;
// if (!aip_cmd::parse_uint_arg(aip_cmd::get_arg(h.args_in, "qid"), 32'hffff_ffff, 0, qid, why, "qid"))
//     h.result_out = why;  // 例如 "qid=-1: negative value; expected an unsigned integer literal"

// --- 运行时参数 override（动态改 trans 参数，不重编译不重启）---
// SV 侧：
aip_cmdline_override::set_val("axi.wr.addr", "0x2000");
aip_cmdline_override::clear("axi.wr.addr");
aip_cmdline_override::clear_all();
// 优先级：override > plusargs > default

// --- 执行命令 ---
aip_cmd::exec("write_reg addr=0x100 data=0xFF");

// --- 并行执行 ---
aip_cmd::exec("fork cmd1, cmd2, cmd3 join");
aip_cmd::exec("fork cmd1, cmd2 join_any disable_remaining=1");

// --- 错误处理 ---
// SRC_TCL:      未知命令 → status=-1（软失败，TCL 继续处理）
// SRC_DPI:      未知命令 → $fatal（硬失败）
// SRC_INTERNAL: 未知命令 → $fatal（硬失败）
// SRC_SOCKET:   未知命令 → status=-1（软失败，TCP 返回 ERROR，仿真继续）
```

#### 运行时 .so 命令插件（aip_soload）

编译带 `+define+AIP_ENABLE_SOLOAD` + `aip_soload.c`（`-LDFLAGS -ldl`）后，
可运行时 dlopen 编译好的 .so 热插拔命令，不重启 simv。插件是 host 侧纯 C
（不碰 DUT 信号/CPU，零仿真时间），include `aip_plugin.h` 实现 handler +
`aip_plugin_init`。

```
% so_load path=./hello.so       ;# 加载, 命令自动注册进 registry
% hello world                   ;# -> hello world
% so_unload path=./hello.so     ;# 卸载, 命令注销
% so_reload path=./hello.so     ;# 改 .so 重编后热重载
```

插件写法见 `tests/plugins/hello_plugin.c`；构建 `gcc -fPIC -shared x.c -I<aip_core>/include -o x.so`。
缺 path/加载失败 → result_out=`ERROR: ...`, `aip_check_status` 返 1。

**多函数一个 .so**：把任意签名的真实 C 函数各包一层 handler（固定 ABI
`args→resp` 字符串），在一个 `aip_plugin_init` 里全登记，`so_load` 一次加载：

```c
static unsigned crc32_calc(const char *s, int n);      /* 真函数, 签名随意 */
static void h_crc(const char *args, char *resp, int max) {
    snprintf(resp, max, "crc=0x%08x", crc32_calc(args, strlen(args)));
}
int aip_plugin_init(void *ctx) {
    aip_plugin_register(ctx, "crc",     h_crc);
    aip_plugin_register(ctx, "hex_enc", h_hex_enc);   /* 想加多少加多少 */
    return 0;
}
```

`hello_plugin.c` 内含可跑示例：`crc 123456789` → `crc=0xcbf43926`、
`hex_enc ABC` → `414243`、`hex_dec 414243` → `ABC`。跑 `make test_soload` 验证。
限制：handler 只有固定字符串签名，不能回调 SV / 碰 DUT；参数返回自行 parse/format。

### 7. aip_tcl_bridge.sv — TCL/UCLI 桥接

```systemverilog
// 在 module 中启用 TCL 桥接
module my_tb;
    `aip_tcl_bridge_create(tcl_bridge)    // 启动 $stop/run 握手循环
endmodule
```

**package 状态对象（UCLI 可 force/get）：**
- `aip_core_pkg::__tcl_cmd_ascii[0:1023]` — 命令 ASCII 值数组
- `aip_core_pkg::__tcl_cmd_len` — 命令长度
- `aip_core_pkg::__tcl_result_ascii[0:1023]` — 结果 ASCII 值数组
- `aip_core_pkg::__tcl_result_len` — 结果长度
- `aip_core_pkg::__tcl_result_status` — 命令返回状态；它与“命令是否存在”相互独立
- `aip_core_pkg::__tcl_result_known` — `1` 表示命令由 SV registry/内建 `fork` 识别；`0` 表示未找到
- `aip_core_pkg::__tcl_activity_count` — `aip_activity::tick()` 计数的只读镜像，Tcl ACK 等待据此判断进展
- `aip_core_pkg::__tcl_cmd_watchdog_stall_ns` / `__tcl_cmd_watchdog_poll_ns` — 生效的停滞看门狗配置（ns，禁用时 stall=0），每条命令受理时重发
- `aip_core_pkg::__tcl_cmd_names_ascii[0:4095]` / `__tcl_cmd_names_len` — 逗号分隔的已注册命令名表，启动时写入，注册表变化（`aip_reg_seq`、插件加载等）后重写；Tcl `unknown` 据此快速失败，表满（可能截断）时 Tcl 不建缓存、全部交 SV 判定
- `aip_core_pkg::__tcl_cmd_names_gen` — 命令名表版本，每次重写加 1；Tcl 缓存版本不同即重读

这些对象属于 `aip_core_pkg`。随库提供的 `aip_cmd.tcl` 和 `aip_checkpoint.tcl` 已在
内部对相关 UCLI `get`/`force` 使用 `aip_core_pkg::__tcl_*` 限定名。

**工作流程：**
1. SV `$stop(0)` → 仿真暂停，TCL 拿到控制权
2. TCL `force` 命令数据 → TCL `run` → 仿真恢复
3. SV 读取数据 → 执行命令 → 写回结果
4. SV `$stop(0)` → 仿真再次暂停，TCL 读取结果

#### 7b. 命令停滞看门狗 + `aip_activity::tick()` 互补用法

**背景问题**：`run_loop` 是单线程串行状态机，一条命令必须执行到 `$stop(0)` 才能接下一条。若某命令内部永久阻塞（典型：seq 发了 item 但 driver 不 `item_done`，或 seq body 等一个永不到来的 response），`run_loop` 会**冻死在这一条**，后续 `end_test`/`run` 全部卡住。

**看门狗机制（停滞检测，非固定超时）**：`run_loop` 用 `fork...join_any` 包裹命令执行，记录两个当前 child 的精确 process handle，并只在确认未完成 child 的状态后定向 `kill()`；监控分支采样 package 内的活动计数 `aip_activity::count`：
- 计数**有变化** → 判定"有进展" → 喂狗（stall 清零）
- 计数**连续 `cmd_watchdog_stall_ns`（默认 50us）无变化** → 判定死锁 → 强杀该命令 → 写 error 结果 → `run_loop` 回到接命令态 → 后续命令正常执行

已注册命令即使返回 `status=-1`（例如被停滞看门狗终止），TCL 也会返回该命令的错误结果，
不会再转成 `invalid command name`。只有 `__tcl_result_known=0` 才继续尝试原生 Tcl/UCLI 命令。

关键：判据是"**多久没进展**"，而不是"**跑了多久**"。这样正常长命令不会因为耗时长被误杀，只有真正卡死（零进展）才被杀。

**Tcl 侧 ACK 等待用同一判据**：`aip_send_cmd` 只把活动计数（`__tcl_activity_count`）不变的仿真时间计入
`::aip_ack_timeout_ns`（默认 52000 ns），计数一变就重新计时，持续推进直到 ACK；每步推进预算的 1/8，
ACK 的 `$stop` 会提前结束推进。看门狗启用时预算至少为 SV 发布的 `stall + 2×poll`，被杀命令的 error
result 总先于 Tcl 放弃到达；看门狗禁用时由 `::aip_ack_timeout_ns` 兜底，到期告警
`no ack after ...ns without activity progress` 后返回。暂停中改走注入队列的普通命令和 `aip_job wait`
采用同样的无进展计时。

**`aip_activity::tick()` 的角色 —— 与看门狗互补**：

`tick()` **不影响 seq 的功能行为**（发什么包、时序、数据都与它无关）。它只是喂狗信号：告诉看门狗"我还在干活"。二者互补关系：

| seq 类型 | 是否需要在执行中 `tick()` | 原因 |
|---------|--------------------------|------|
| 短 seq（跑完 < stall 阈值 50us） | ❌ 不需要 | seq 很快结束，看门狗根本到不了超时窗口 |
| 长 seq（发很多包 / 跑 > 50us） | ✅ **必须周期 tick** | 否则整段执行 count 不变 → 被误判死锁 → 误杀 |
| 死锁 seq（等永不来的 response） | —— | 无 tick 正是判据，本就该被杀 |

> ⚠️ `aip_cmd_seq` / `aip_cmd_reg` 宏（及 `aip_reg_seq` 生成的命令）**只在 seq 完全跑完后 tick 一次**，执行中途不 tick。所以跑时长超过 stall 阈值的长 seq，必须在下面某处自己周期喂狗，否则会被误杀。

**在哪里 tick（推荐 driver 层，一处改全部受益）**：

```systemverilog
// 方式1（推荐）: driver 每处理一个 item 喂一次狗
task run_phase(uvm_phase phase);
    forever begin
        seq_item_port.get_next_item(tr);
        // ... 处理 transaction ...
        aip_activity::tick();          // 每个 item = 一次进展
        seq_item_port.item_done();
    end
endtask

// 方式2: seq body 每发一包喂狗（只保护这条 seq）
task body();
    repeat (count) begin
        start_item(tr);
        finish_item(tr);
        aip_activity::tick();
    end
endtask

// 方式3: monitor/scoreboard 每收一包 tick（同理）
```

**判断准则**：seq 跑得比 stall 阈值快 → 不用管；跑得慢 → driver 每 item `tick()`（最省心），或把阈值调大。

**看门狗配置与控制**：

```systemverilog
// SV 侧
aip_tcl_bridge::set_cmd_watchdog(100000);   // 改 stall 阈值为 100us
aip_tcl_bridge::set_cmd_watchdog(0);        // 禁用看门狗（裸执行，向后兼容）
// Tcl 的 ACK 等待自动不短于 stall+2×poll，无需再手工让 aip_ack_timeout_ns 大于 stall 阈值
```

```tcl
# TCL 侧（无需重编译，注册好的命令直接敲）
set_cmd_watchdog ns=100000    ;# 改阈值
watchdog_status               ;# 看当前配置 + 活动 seq 数
kill_seq name=my_seq          ;# 手动精准杀指定活动 seq
kill_seq                      ;# 手动杀全部活动 seq
```

**死锁时的自动清理（三层，越上层越省事）**：
1. **内置默认**：看门狗触发时自动 `kill()` 肇事命令的 seq（清 sequencer 残留的 pending item）。**精准杀**——只杀当前卡死的命令，不碰其他并行/async 的无辜 seq；`fork` 并行命令例外，杀它启动的全部子 seq。用户零配置。
2. **TCL 命令**：上面的 `set_cmd_watchdog` / `kill_seq` / `watchdog_status`，运行时可控，不重编译。
3. **SV hook（可选）**：`aip_cmd_watchdog_hook` 虚类，覆盖框架清理不到的脏状态（如复位 mailbox flag、外部资源）。

业务需要判断某命令的 sequence 是否仍在执行（拒绝重入、与重载互斥）时调用 `aip_cmd_seq_registry::active("<cmd>")`：登记存在且登记进程未结束、未被杀才返回 1，watchdog 取消后立即为 0，不必另设状态位。

```systemverilog
class my_hook extends aip_cmd_watchdog_hook;
    function void on_timeout(string cmd_str);
        // 按命令类型补做清理
        // ...
    endfunction
endclass
my_hook h = new();
aip_tcl_bridge::set_watchdog_hook(h);
```

> hook 不写也照常恢复：看门狗骨架（强杀 + 写 error + `$stop`）保证 bridge 回到接命令态跑下一条命令，**不依赖 hook**。hook 只是补框架覆盖不到的子系统脏状态。

#### 7c. 命名结束检查器：精确判断完成与失败

`aip_activity::tick()` 仍然只是进展、命令看门狗和 idle 检测信号；它表示系统仍在活动，
不能证明 scoreboard、transport 等组件已经精确完成。需要精确完成条件时，为每个组件实现并注册
一个命名 `aip_end_checker`：

```systemverilog
class my_scoreboard_checker extends aip_end_checker;
    string       checker_name;
    int unsigned matched    = 0;
    int unsigned expected   = 0;
    int unsigned pending    = 0;
    int unsigned mismatches = 0;

    function new(string checker_name, int unsigned expected);
        this.checker_name = checker_name;
        this.expected     = expected;
    endfunction

    virtual function bit is_done();
        return matched == expected && pending == 0;
    endfunction

    virtual function bit has_failed();
        return mismatches != 0;
    endfunction

    virtual function string status_detail();
        return $sformatf("%s matched=%0d expected=%0d pending=%0d mismatches=%0d",
                         checker_name, matched, expected, pending,
                         mismatches);
    endfunction
endclass

my_scoreboard_checker axis_checker;
my_scoreboard_checker shm_checker;

initial begin
    // 流量启动前，先从 test/config 得到本次运行的确定 transaction 数。
    axis_checker = new("axis_scoreboard", 128);
    shm_checker  = new("shm_transport",   64);

    // expected 已确定后、流量启动前完成注册。
    aip_tcl_bridge::register_end_checker("axis_scoreboard", axis_checker);
    aip_tcl_bridge::register_end_checker("shm_transport", shm_checker);
end
```

Scoreboard/transport 接收工作时递增 `pending`，每完成一次比较或传输就递减 `pending`，
并按结果递增 `matched` 或 `mismatches`。因此只有处理结果精确达到构造时给出的 `expected`，
且所有 in-flight 工作都已 drain（`pending == 0`）时，`is_done()` 才返回 `1`。

Tcl 侧等待所有已注册 checker 精确完成，并要求超时或缺少 checker 时失败：

```tcl
end_test wait_done=1 timeout=2ms strict=1
```

行为约定：

- 任一 checker 的 `has_failed()` 返回 `1` 都是显式失败，即使 `strict=0` 也不会降级为成功。
- `strict=1` 时，超时或没有 checker 都会失败；非 strict 模式仍保留原来的强制退出兼容行为。
- `end_test` 开始等待时会快照 checker registry，并在等待期间冻结 registry；
  `register_end_checker()`、`unregister_end_checker()`、`clear_end_checkers()` 和
  `set_end_checker()` 的修改请求会被拒绝。为兼容旧代码，public `end_checker` 仍可直接赋值，
  但直接赋值也不会改变已经捕获的本次等待集合。
- 若命令看门狗取消正在执行的 `end_test`（包括 `fork` 内的调用），bridge 会清理活动等待状态，
  通过正常 Tcl 握手返回看门狗错误并有序退出，使 UVM 能继续进入 report phase。

旧接口保持兼容：public `aip_tcl_bridge::end_checker`、
`aip_tcl_bridge::set_end_checker()`、对 `end_checker` 的直接赋值，以及不指定
`strict=1` 的既有 Tcl `end_test wait_done=1` 用法都可继续使用。

### 8. aip_cmd.tcl — TCL 命令桥接脚本

```bash
# 启动方式（推荐 -do，自动检测脚本绝对路径）
simv -ucli -do test.tcl -timescale=1ns/1ps +UVM_NO_RELNOTES

# 或 -i 模式（交互友好，有 ucli% 回显）
simv -ucli -i test.tcl -timescale=1ns/1ps +UVM_NO_RELNOTES
```

**[tcl_cmd] 橙色回显**（自动显示脚本路径 + 仿真时间）：
```
[tcl_cmd] /home/user/test/my_test.tcl @ 100.00 ns: axi_write count=10
[tcl_cmd] /home/user/test/my_test.tcl @ 200.00 ns: axi_read count=5
```
- `-do` 模式自动检测脚本绝对路径
- `source` 子文件自动切换路径
- `set ::aip_echo 0` 关闭回显
- `$stop` 源码位置打印已被自动抑制

```tcl
# 加载后，SV 注册的命令直接输入（TCL unknown 自动转发给 SV）：
write_reg addr=0x100 data=0xFF       ;# 直接输入
read_reg addr=0x200                  ;# 有返回值
set_mode mode=MODE_RUN               ;# 枚举参数
dma_config addr=0x1000 len=128       ;# 结构体风格参数

# 运行时参数 override（动态改 trans 参数）：
set_param path=axi.wr.addr value=0x2000   ;# 覆盖 plusargs
set_param path=axi.wr.data value=0xCAFE
axi_write count=10                         ;# 这 10 个 trans 全部用新参数
clear_param path=axi.wr.addr              ;# 清除单个，回退到 plusargs
clear_param                                ;# 清除全部 override

# 读运行期 plusarg（+name=value，含 UVM_TESTNAME / 自定义 / 种子等）：
puts [aip_getparam UVM_TESTNAME]          ;# 任意 +name=value 的字符串值
puts [aip_getparam ntb_random_seed]        ;# 显式 +传的种子；name=seed 未显式+传时退到 $get_initial_random_seed()
# 未传该 plusarg -> 返回空串且 aip_check_status==1；内建 get_param 命令，$value$plusargs 运行期格式串通吃任意 name

# UVM Sequence 控制（需 aip_cmd_seq 宏注册）：
axi_write count=10                    ;# 启动 seq，发 10 个 trans
axi_read count=5                     ;# 启动另一个 seq
eth_send count=3                     ;# 不同 agent 的 seq

# 多行 fork/join 语法（SV 风格）：
fork
    axi_write count=10
    eth_send count=5
join                                  ;# 等全部完成

fork
    axi_write count=100
    axi_read count=50
join_any                              ;# 等任一完成
join_any disable_remaining=1          ;# 任一完成后杀其余

fork
    axi_write count=10
join_none                             ;# 不等待，后台运行

# 单行 fork 也支持：
fork axi_write count=5, eth_send count=3 join

# 运行时注册 seq 命令（类型须先用 `aip_seq_type/`aip_seq_type_path 声明）：
aip_reg_seq cmd=eth_send_p1 type=eth_send_seq sqr=uvm_test_top.env.eth1.sqr path=eth.p1
fork eth_send count=5, eth_send_p1 count=5 join
aip_unreg_seq cmd=eth_send_p1              ;# 可选，只注销空闲的运行时命令
# 失败返回 ERROR 且 aip_check_status==1；成功后 Tcl 立即同步命令名表，新名字直接可用

# Seq 时间模式 — 按时长发包：
axi_write time=1us                   ;# 持续发 1 微秒
axi_write time=500ns                 ;# 持续发 500ns
axi_write time=30000ps               ;# 持续发 30ns (30000ps)
# 支持单位: fs, ps, ns, us, ms, s

# Fork 混合 time + count：
fork
    axi_write time=1us               ;# 时间控制
    eth_send count=50                ;# 个数控制
join

# 与 VCS/TCL 原生命令自由混合：
run 100ns                            ;# VCS 原生
set clk [get top.clk0_if.clk]       ;# VCS 原生
axi_write count=3                    ;# SV seq 命令
puts "done"                          ;# TCL 原生

# TCL 循环扫描参数空间：
for {set i 0} {$i < 10} {incr i} {
    set_param path=axi.wr.addr value=[format "0x%X" [expr {$i * 0x1000}]]
    axi_write count=1
}

# TCL proc 封装复杂操作：
proc burst_test {addr data count} {
    set_param path=axi.wr.addr value=$addr
    set_param path=axi.wr.data value=$data
    axi_write count=$count
    return [aip_read_result]
}
burst_test 0x5000 0xFF 10

# 退出仿真（必须调用，否则仿真无法正常结束）：
end_test                             ;# 立即退出
end_test drain=1000                  ;# 等 1000ns drain time 再退出
# 等待完成后执行资源清理；cmd= 可重复，按出现顺序执行
end_test idle=1us cmd=vio_stop cmd=vio_release
# 分号列表需要用大括号保护
aip_send_cmd {end_test {cmd=vio_stop;vio_release}}
# 退出后 UVM 正常走 extract → check → report → $finish

# 注意：与 VCS/TCL 内置命令冲突时（如 "help"），用 aip_send_cmd：
aip_send_cmd "help"
```

### 8b. aip_checkpoint.tcl — VCS 断点续跑

被 `aip_cmd.tcl` 末尾自动 source（定位优先 `$env(AIP_CORE)`），无需手动加载。用 VCS
`save`/`restore` 存仿真快照：boot/init 跑一次存快照，后续 test 从快照续跑跳过公共前缀。

```tcl
# ---------- 生成 base 快照（跑一次）simv -ucli -do gen_base.tcl ----------
run 1000ns                                   ;# boot / init / link-up
aip_checkpoint base                          ;# 存快照 + meta
aip_checkpoint base "note=post linkup"       ;# 带备注（含空格须整体引号）

# ---------- 后续 test（独立 simv 进程，跳过 boot）----------
aip_restore base                             ;# 校验 simv 新鲜度 + restore
source $env(AIP_CORE)/dist/aip_init_so.tcl   ;# 必须: restore 清空 Tcl 命令表
puts "now @ [_aip_sim_time]"                 ;# sim-time 接续，非从 0
run 500ns                                     ;# 续跑、发包、force 信号 …

# ---------- 配置（可选）----------
set ::aip_ckpt_dir /path/to/ckpt             ;# 默认 ./aip_ckpt
set ::aip_simv_path /abs/simv                ;# 默认自动探测 info nameofexecutable
```

等待后门状态并自动保存：

```tcl
aip_wait_checkpoint <path> <expected> <message> <snapshot> ?timeout?

# path / expected / 日志关键词 / 快照名 / 可选仿真时间超时
aip_wait_checkpoint tb.dut.status 32'h1 BOOT_DONE boot_done 10ms
aip_wait_checkpoint tb.dut.status 32'h2 LINK_UP   link_up   20ms
aip_wait_checkpoint tb.dut.status 32'h3 ENUM_DONE enum_done 20ms
aip_wait_checkpoint tb.dut.status 32'h4 READY     ready     50ms
```

`message` 含空格时必须用双引号或花括号作为一个 Tcl 参数，例如
`aip_wait_checkpoint tb.dut.status 32'h1 {BOOT READY} boot_ready 10ms`。

该命令使用 VCS 原生 UCLI `stop -condition` 条件断点做事件驱动监控，不使用 `when`，也不按
固定步长轮询。若初始值已经命中，会跳过 stop 安装；否则无论命中、超时、`run` 报错还是仿真
无推进，都会尝试删除安装时返回的准确 stop ID。若 `stop -delete` 失败，错误会被报告，但该
stop 可能仍处于活动状态；继续前应先用 UCLI 检查并清理。命中时先打印 `[AIP_STATE_CKPT]`、
关键词、路径、实际值、期望值和 `trigger_time`，再调用现有 `aip_checkpoint` 保存，成功返回快照名。

`expected` 支持带符号十进制、`0x`、`0b` 和受限的 two-state SystemVerilog 基数写法
`'h/'d/'b/'o`；`X/Z`、数字分隔符 `_` 及其他畸形值会被拒绝。width 前缀可作为输入语法，
但解析器不执行 SV 位宽截断，例如 `8'h1ff` 解析为 `0x1ff`，不会变成 `8'hff`；宽值以 Tcl
bignum 精确解析。含数组下标的路径必须用 Tcl 花括号保护，例如 `{tb.dut.state_array[3]}`。
`snapshot` 仅接受安全 basename：首字符为字母或数字，其余可含字母、数字、`_`、`.`、`-`，
不允许空白和目录跳转。

省略 `timeout` 表示不限仿真时间；可用 `fs/ps/ns/us/ms/s`，无单位按 `ns`。deadline 计算优先
读取原生 `senv time`，不可用时才退回格式化时间；实际推进精度仍受编译后的仿真器
`timeprecision` 限制，例如 1ps 内核中的 `1fs` 请求可能因时间无推进而 fail closed。需要等待时，
无效或非正 `timeout` 会在安装 `stop -condition` 前被拒绝，因此不会遗留 stop 点。

超时错误包含最后一次可读值。等待成功后若 stop 删除失败，会在保存前终止；若主等待错误与
清理错误同时发生，主错误的 Tcl options 保持权威，消息末尾追加一次清理诊断。

落盘：`<ckptdir>/<name>.vcssave`（VCS 快照）+ `<name>.meta`（每行 `key<TAB>value`：
simv_path / simv_mtime / simv_size / sim_time / note / created）。

**有效性检查**：`aip_restore` 比对当前 simv 的 mtime+size vs meta。RTL/TB 一改重编译，simv
mtime 必变 → 报 `checkpoint stale: ... rerun base-gen`。改动多小都抓得到（门槛在重编译刷 mtime）。

**失败处理**：meta 缺失 / stale → `error`；save 时 bridge 非 idle（Ctrl+C 残留）→ settle 排干，
排不掉则拒存脏快照。restore 后的 settle / 发命令 / run 交给用户脚本。

**约束**：
- 快照与 simv 二进制强绑定；编译带 `-debug_access+r+w+f` 即可（save/restore 只需 `+r`，不需要 `+all`）。
- **`save` 间歇性卡死**：实测 (W-2024.09, 2026-09-10) 同一个最小设计重复存快照，约 20%~40% 的
  运行会卡在 `save` 不返回，与 `-debug_access` 取值（`+r+w+f` / `+all`）和 ASLR 是否关闭都无关。
  卡住时 `simv` 单线程停在 `do_wait`，磁盘上留下 `<name>_tmp.save_in_progress`：UCLI `save`
  fork 出子进程写快照并 `wait()` 等它，偶发地该子进程不结束。Tcl/SV 侧不参与，本仓库无法规避。
  自动化脚本里给存快照的步骤加超时和重试（本仓库两个 checkpoint 回归已用 `CKPT_TIMEOUT` /
  `CKPT_ATTEMPTS` 这么做）；一个目标里存 N 次快照，失败概率会累乘。
- 纯 TCL bridge 通道，不覆盖 DPI-C socket / 外部进程状态。
- save 自动 `run 0` 脱离 `$stop` 上下文（VCS 禁 `$stop` 处 save，`Error-[UCLI-SAVE-STOP]`）。
- **restore 须顶层帧执行**：VCS `restore` 在 Tcl proc 内直接调会崩（假象报 `vcsMsgReport1: No such
  file or directory`，非缺 32 位库）；`aip_restore` 内部用 `uplevel #0 [list restore $ckpt]` 顶到全局帧。
- **restore 清空 Tcl 命令表**：实测 (W-2024.09, 2026-09-10) `restore` 恢复仿真状态和 Tcl 全局变量，
  但 `source`/`load` 定义的命令全部消失；`aip_restore` 内 `restore` 之后的语句也不再执行（同一
  语句序列被截断，`-do` 脚本的下一行照常执行）。因此用户脚本必须在 `aip_restore` 的下一行重新
  `source` 加载脚本；两个 loader 的幂等判断已改为检查命令是否存在，重复 source 是安全的。
  用户脚本在 restore 之前定义的 proc 同样会消失（proc 也是 command），需放到 restore 之后。
  重新 source 后已验证：命令表恢复、命令往返返回快照时刻的设计值（与快照前同一次调用逐字节
  相同）、`fv`/`gv` 可读设计、`run` 继续推进、续跑会话可再存快照。
  回归：`make test_checkpoint_restore`。
- **内核敏感**：VCS Q-2020 验证内核 ≤4.18（RHEL8）；新内核（如 6.17）save 引擎 `Bad address` 崩。
  须在受支持内核主机跑（VCS 2024 + Ubuntu 22.04/5.15，或经典 RHEL8/4.18）。
- 详见 spec `docs/superpowers/specs/2026-06-26-vcs-checkpoint-design.md`。

### 9. aip_c_bridge.sv — Socket/DPI-C 桥接

```systemverilog
// 1) 在 module 中创建 Socket 桥接；file 传空字符串表示只使用 TCP，创建时不监听
module my_tb;
    `aip_tcl_bridge_create(tcl)                     // Tcl 启动控制入口
    `aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "")  // 0 = 动态端口
endmodule
```

**环境集成步骤：**

1. TB 首先 include 根目录兼容入口 `aip_core_pkg.sv`，并把 `src/sv` 加入 include path。
2. TB 中注册普通命令、`aip_cmd_cseq`/`aip_cmd_creg`，再实例化 `aip_c_bridge_create`。
3. 编译时链接 Socket DPI 实现；可以直接编译源码，也可以使用 `dist/lib` 中的共享库。
4. 启动 `simv`，通过 Tcl bridge 加载命令并显式监听，再另开终端连接客户端：

```tcl
source <aip_core>/dist/aip_init_so.tcl
c_bridge_listen
```

命令名为 `<实例名>_listen`，无参数。快照须在首次监听前生成；续跑顺序为
在新的 simv 进程中执行 `source` → `aip_restore` → 再次 `source` → `c_bridge_listen`。
已经监听过的同一进程回滚早期快照、恢复 live socket 均不在支持范围，OS fd 不随状态回滚。
升级后执行 `make -C dist all`，重新编译 simv 并重新生成快照。

**直接编译 C 源码：**
```bash
vcs -sverilog -ntb_opts uvm -full64 \
    +incdir+<aip_core> +incdir+<aip_core>/src/sv \
    -CFLAGS -I<aip_core>/include -LDFLAGS "-ldl -pthread" \
    <aip_core>/src/c/runtime/sv_socket_dpi.c your_test.sv \
    -o simv
./simv -no_save
```

**使用发布库编译：**
```bash
make -C <aip_core>/dist all
vcs -sverilog -ntb_opts uvm -full64 \
    +incdir+<aip_core> +incdir+<aip_core>/src/sv \
    -LDFLAGS "-L<aip_core>/dist/lib -Wl,-rpath,<aip_core>/dist/lib \
              -laip_socket_dpi -ldl" \
    your_test.sv -o simv
```

**启动 C 客户端：**

```bash
make -C <aip_core>/dist client
<aip_core>/dist/bin/aip-client 127.0.0.1 <actual_port> --key <auth_key>
```

也可以直接编译客户端源码：

```bash
gcc -O2 -o aip-client <aip_core>/src/c/client/client.c \
    $(pkg-config --cflags --libs readline)
./aip-client 127.0.0.1 <actual_port> --key <auth_key>
```

客户端连接后输入已注册的 `aip_cmd` 命令，例如：

```text
bus_access op=read addr=0x1000
bus_burst count=3
```

TCP 命令也支持使用 `fork` 并行派发多个已注册命令。命令必须写在同一行，子命令之间用逗号分隔：

```text
fork bus_read addr=0x1000, bus_read addr=0x2000 join
fork bus_burst count=3, socket_ping join_any
fork bus_read addr=0x1000, bus_write addr=0x2000 data=0x55 join_none
fork bus_read addr=0x1000, bus_write addr=0x2000 data=0x55 join_any disable_remaining=1
```

语义与 `aip_cmd::exec()` 的 fork 形式一致：

- `join`：等待所有子命令完成，并汇总结果；
- `join_any`：任意一个子命令完成后返回；
- `join_none`：立即返回，子命令在后台继续执行，不汇总最终结果；
- `disable_remaining=1`：仅与 `join_any` 一起使用，首个子命令完成后终止其余子命令。

TCP 的 `SRC_SOCKET` 来源会传递到每个子命令。若子命令不存在，不会触发 `$fatal`，而是返回错误并保持仿真继续：

```text
fork does_not_exist, socket_ping join
=> ERROR: fork: failure(s): [does_not_exist:status=-1,msg=Unknown command: does_not_exist]
```

建议不要在同一个 `fork` 中并发执行会修改同一个注册命令句柄或同一个共享 sequencer 状态的命令；需要严格总线顺序时使用 `aip_cmd_cseq`/`aip_cmd_creg`。

客户端会显示服务端返回的 `OK:`/`ERROR:` 行。未知的 `aip_cmd` 名称不会终止仿真，
而是返回 `ERROR: Unknown command: <name>`。

**UCLI 原生命令与认证：**

桥接启动时会在 log 打印每个仿真实例独有的 32 位 `auth_key`。客户端先认证，再发送
命令；`force`、`get`、`release` 等不在 `aip_cmd` 注册表中的命令会原样交给 UCLI/Tcl
解释器。`run/next/step/quit/finish/restart/resume` 会被 VCS MHPI API 拒绝，必须在
本地 UCLI 执行：

```text
aip-client 127.0.0.1 <actual_port> --key <auth_key>
force tb.dut.signal 1
get tb.dut.signal
set ::debug_mode 1
```

客户端也支持 `AIP_AUTH_KEY`，或在未传 `--key` 时交互输入。认证前仅允许
`auth <auth_key>`，错误 key 返回 `ERROR: AUTH_FAILED`。

认证后的 Tcl 观察命令直接使用普通 Tcl 语法：

```text
aip_watch tb.dut.link_up 1 stop=0
aip_watch_status 1
aip_watch_status
aip_watch_cancel 1
aip_watch_cancel             ;# cancel all armed watches
aip_sim_status
```

`stop=0` 使用 VCS 原生条件 stop，命中后仿真停在 UCLI stop 点；必须在本地输入原生
`resume`，TCP bridge 才能继续处理后续请求。`aip_watch` 注册后立即返回观察 ID，
不接受 `wait=0`；带上该参数会立即得到 Tcl usage 错误，不会进入 AIP ACK 超时流程。
如果本地 Tcl 正在执行 AIP 管理的 `run`，TCP 仍允许注册 `aip_watch`；此时注册只读取
信号并安装观察条件，`stop=1` 命中后由外层 `run` 安全进入本地 `pause%`，不返回
`AIP_CONTROL_BUSY`。该例外不适用于 force/deposit 或其他会推进仿真的原始 Tcl 命令。
TCP 请求仍依赖 SV 仿真线程调度，VCS 停在 `ucli%` 时应先从 UCLI 执行 `run` 或
`resume`，请求才会被处理。使用这些 Tcl 命令前仍需在 `simv -ucli` 会话加载 AIP Tcl
bootstrap（通常在 `-do` 脚本中 `source <aip_core>/dist/aip_init_so.tcl`）。
VCS 的 MHPI 回调接口不接受 `run/next/step/quit/finish/restart/resume`；这些改变仿真
时间或控制权的命令会返回明确错误，必须在本地 UCLI 提示符执行。

TCP 现在已内置注册以下 DUT 控制命令（认证后直接发送）：

```text
dut_force       path=<层次路径> value=<整数或 Verilog 数值>
dut_force_time  path=<层次路径> value=<值> time=<时间，例如 100ns>
dut_deposit     path=<层次路径> value=<整数或 Verilog 数值>
dut_readmemh    file=<hex文件> path=<memory路径> offset=<起始元素> width=<bit宽度，默认8>
dut_readmemb    file=<bin文件> path=<memory路径> offset=<起始元素> width=<bit宽度，默认8>
dut_get         path=<层次路径>
dut_release     path=<层次路径>
```

`dut_readmemh` / `dut_readmemb` 的文件是文本格式，每个空白分隔的数据 token
写入一个 `path[address]` 元素，不是原始二进制字节流。`width` 可取 1 到
`uvm_hdl_data_t` 最大宽度的任意正整数，省略时为 8；超过位宽的数据报错而不
截断。文件支持下划线、x/z/?、`//`/`/* */`/`#` 注释和 `@ADDR`，其中地址按
十六进制解析并与 `offset` 相加。例如：

```text
# data13.hex
1abc

dut_readmemh file=data13.hex path=tb.dut.ram offset=7 width=13
```

客户端随后发送：

```text
dut_force path=tb.dut.signal value=1
dut_get path=tb.dut.signal
dut_force_time path=tb.dut.signal value=0 time=100ns
dut_deposit path=tb.dut.signal value=0x3
dut_readmemb file=data.bin path=tb.dut.ram offset=0 width=9
dut_release path=tb.dut.signal
```

这些命令执行 SV/UVM HDL API，语义等价于常用的 `force/deposit/get/release`。
`dut_force_time` 阻塞当前命令直到时间到期，然后自动 release。编译时应开启
VPI/HDL 访问（VCS 建议 `-debug_access+all`），否则 `uvm_hdl_*` 可能因信号不可见而失败。
`run`、`stop`、断点等
依赖 UCLI 调度器的命令仍应在 `simv -ucli` 会话中执行；若需要远程触发，应同样
封装成明确的 SV 命令并定义返回值。

### 10. sv_socket_dpi.c / client.c — C 层

- `sv_socket_dpi.c`：非阻塞 Socket 服务端，支持最多 64 个客户端，`MAX_CMD_LEN=1024`
- `client.c`：readline 命令行客户端，支持历史记录、Tab 补全、自动重连

### 11. aip_ucli_utils.tcl — UCLI 原生 force/get + ECC mem 工具库

**与 aip_cmd.tcl 并列, 不冲突**: aip_cmd.tcl 走 SV bridge 派发命令; aip_ucli_utils.tcl 直接走 UCLI 原生 force/get/run。两者共存, 推荐顺序 `source aip_cmd.tcl; source aip_ucli_utils.tcl` (utils 自动复用 aip_cmd 的 caller/time/aip_echo)。

**功能分类：**

```tcl
# ---------- Force / Deposit ----------
fv tb.dut.cfg_reg 32'hDEADBEEF              ;# 单信号 deposit
fv tb.dut.go 1 -force                       ;# force
fv_bit tb.dut.cfg_reg 7 1                   ;# bit 7 = 1
fv_bit tb.dut.cfg_reg 15:8 8'hAA            ;# bit[15:8] = 0xAA
fv_fill tb.dut.mem{i} 0 2048                ;# 整片清零
fv_fill tb.dut.mem{i} 100 8 -val_step 1     ;# 递增: mem[0..7]=100..107
fv_fill tb.dut.mem{i} 0 256 -from 100 -step 4  ;# 从地址 100 起步, 步长 4
fv_fill tb.dut.mem{i}{j} 0 16 -count2 8     ;# 2D loop
fv_random tb.dut.mem{i} 1024 -width 32 -seed 42
fv_zero / fv_ones / fv_incr                 ;# 快捷别名

# ---------- Get / Release ----------
gv tb.dut.cfg_reg -hex                      ;# get + radix 转换 (-hex/-dec/-bin/-raw)
fv_release tb.dut.cfg_reg                   ;# release force (别名 unforce)

# ---------- 避免 TCL [] 解析的 4 种方式 ----------
# RTL 路径含 [N] 时 TCL 会当 command sub 报错, 解决:
# 1. 花括号 (推荐)
fv {tb.dut.mem[5]} 32'hAA
# 2. set 变量
set p {tb.dut.bank[2].mem[5]}; fv $p 32'hAA
# 3. 反斜杠转义
fv tb.dut.mem\[5\] 32'hAA
# 4. fv_at / gv_at wrapper (base + idx 分开传)
fv_at tb.dut.mem 5 32'hAA
gv_at tb.dut.mem 5 -hex
fv_at_bit tb.dut.cfg_reg 7 1
fv_at_release tb.dut.mem 5

# ---------- 流程控制 ----------
run_to tb.dut.done 1 -timeout 1us -poll 50ns   ;# 推进 sim 直到信号匹配
wait_posedge tb.dut.clk -n 10                  ;# 等 10 个 posedge
pulse tb.dut.go 1 100ns                        ;# force-run-release-deposit_default
pulse tb.dut.req 1 50ns -default 0
reset_dut tb.dut.rst_n 0 100ns                 ;# 标准复位序列

# ---------- 波形 ----------
dump_fsdb_start -file wave.fsdb -level 0
dump_fsdb_stop
dump_vcd_start wave.vcd

# ---------- 文件 mem I/O ----------
dump_mem tb.dut.mem{i} -from 0 -to 1023 -file out.hex
load_mem tb.dut.mem{i} -file in.hex -from 0

# ---------- 调试 ----------
bp_set tb.dut.error_flag 1 { puts "ERROR @ [time_now]" ; stop }
bp_clear all
find_signal {clk|reset} -scope tb.dut
drivers_of tb.dut.cfg_reg
loads_of tb.dut.cfg_reg

# ---------- Util ----------
time_now                                    ;# 当前 sim 时间字符串
safe_finish                                 ;# 关 dump → end_test → finish
batch { fv a 1 ; fv b 2 ; fv c 3 }          ;# 多命令分组 (error containment)
utils_help                                  ;# 所有命令 + 简介 (按类别)
utils_help fv_fill                          ;# 单命令详细
utils_help -category ecc                    ;# 按类别筛选
# 兼容别名: fv_help 同 utils_help

# ---------- 全局开关 ----------
set ::fv_verbose 0                          ;# 0=quiet info/debug, warn/error 仍打印
set ::aip_echo 0                            ;# 跟 aip_cmd.tcl 共享, 全静音
utils_silent                                ;# 关 VCS UCLI "ucli% <cmd>" 行回显
utils_loud                                  ;# 恢复 UCLI 行回显
```

**关于 `utils_silent` / `utils_loud`**:

VCS UCLI `-do <script.tcl>` 模式默认逐行打印 `ucli% <cmd>`, 跟 utils 彩色输出混在一起读起来累:

```
ucli% fv tb.dut.cfg_reg 32'hAA              ← VCS do.tcl 自动 echo (烦)
[ucli] @ 100000 ps: fv: deposit ...         ← utils 输出
  PASS: ...
```

`utils_silent` 关掉三层 + 装一个 wrapper:
- `set ::tcl_prompt1 ::list` — 关 `ucli%` prompt
- `config -cmdecho off` — 关命令行 echo (do.tcl `puts "[prompt]$line"`)
- 副作用: 同时关 result echo, 导致 `run 10ns` 不再返回时间
- **补救**: 自动安装 `run`/`step`/`next`/`_vcs_run` wrapper, 跑完显式 `puts "<cmd> @ <time>"`

```
[ucli] @ 100.000000 ns: fv: deposit ...        ← utils 输出 (绿)
run 10ns @ 110.000000 ns                       ← wrapper 显式打印 (sim 推进可见)
  PASS: ...
```

**例外**: `utils_silent` **自身那行** 仍会被 echo (do.tcl 处理那行的早期阶段 echo 已不可逆)。第二行起全干净。

**时间格式**: 全局统一 `X.XXXXXX ns` 6 位小数 (fs 精度)。`senv time` 返回 fs/ps/ns/us/ms/s 任意单位都自动转 ns, 由 `_aip_format_time_ns` 处理。

推荐模板:
```tcl
source ../src/tcl/aip_ucli_utils.tcl
utils_silent          ;# 之后所有命令 silent + run 时间可见
# ... 你的测试逻辑 ...
```

`utils_loud` 反向恢复:
- `set ::tcl_prompt1 ucli::tcl_prompt1_nocle` 恢复 `ucli%`
- `config -cmdecho on` 恢复 cmd echo
- **卸载 wrapper**: `rename ::run {}` + `rename ::__orig_run ::run` 把原生 run 改回原名, utils 不再插手 run/step/next 行为

**不影响 sanity test**: utils 内部 `_aip_safe_run` 已用 `redirect /dev/null { ... }` 包裹 run 调用, wrapper 内的 puts 被 redirect 吃掉。只有用户脚本**直接**调 `run 10ns` 时才看到 wrapper 输出 (这正是想要的可见性)。

**ECC / Parity 后门 mem 读写（业界标准 SECDED Hamming + parity + CRC-8）：**

```tcl
# 配置 mem 路径 (per-path 独立, 多 ram 可各异)
mem_cfg tb.dut.ram_cache  -width 32 -ecc_mode secded                    ;# (32,7) SECDED
mem_cfg tb.dut.ram_ddr    -width 64 -ecc_mode secded                    ;# (64,8) SECDED
mem_cfg tb.dut.ram_sram   -width 32 -ecc_mode parity -parity_grain 8    ;# byte parity (DRAM 风格)
mem_cfg tb.dut.ram_rom    -width 32 -ecc_mode crc8                      ;# CRC-8 检测
mem_cfg tb.dut.ram_scratch -width 32 -ecc_mode none                     ;# 无校验

# 读写 (用户给原始 data, 自动加 ECC; 读时自动 verify, 返回 raw data)
mem_write tb.dut.ram_cache 0x10 32'hDEADBEEF      ;# 自动加 7-bit SECDED
set v [mem_read tb.dut.ram_cache 0x10]            ;# 自动验证, 1-bit 错自动纠
mem_check tb.dut.ram_cache 0x10                   ;# 返回 ok/single_err/double_err

# Block / 模式写
mem_write_block tb.dut.ram_cache 0 {1 2 3 4}
mem_write_zero  tb.dut.ram_cache 0 1024
mem_write_incr  tb.dut.ram_cache 0 256
mem_write_random tb.dut.ram_cache 0 1024 -seed 42
mem_read_block  tb.dut.ram_cache 0 16              ;# 返回 list

# 故障注入 + 全扫描
mem_inject_err tb.dut.ram_cache 5 3                ;# 翻 stored bit 3 (data bit 3)
mem_scrub tb.dut.ram_cache 0 1023                  ;# 全扫: ok/single/double 统计
mem_scrub tb.dut.ram_cache 0 1023 -fix 1           ;# 自动纠正可纠 1-bit 错

# 配置管理
mem_cfg_list                                       ;# 列所有配置 (表格)
mem_cfg_get tb.dut.ram                             ;# 返回 config dict
mem_cfg_clear tb.dut.ram                           ;# 清单个 / 全部
```

**支持的 ECC 模式：**

| Mode | 说明 | 开销 | 检测/纠错 |
|------|------|------|----------|
| `none` | 无校验直写 | 0 | 无 |
| `parity` | 奇偶校验, 粒度 `-parity_grain 8/16/32/word` × `-parity_polarity even/odd` | 1 bit / group | 单 bit 检测 (无纠) |
| `secded` | Hamming SECDED, 支持 (8,5)/(16,6)/(32,7)/(64,8)/(128,9) | 5~9 bit | 单 bit 纠 + 双 bit 检 |
| `crc8` | CRC-8 poly 0x07 (MSB-first) | 8 bit | 多 bit 检测 (无纠) |

**存储布局：**

- `concat` (默认): `mem[addr] = {ecc[N-1:0], data[W-1:0]}`, 单 mem entry 含 data + ECC, 宽度 W+N
- `split`: 数据 mem + 独立 ECC mem (DDR ECC chip 风格), 需 `-ecc_path <ecc_mem_path>`

**输出格式（统一与 aip_cmd.tcl 风格对齐）：**

```
[ucli] /path/test.tcl @ 12.34 ns: fv: deposit tb.dut.cfg_reg = 32'hAA      (绿 info)
[ucli] /path/test.tcl @ 1.02 us: mem_read tb.dut.ram[5] single_err pos=7   (黄 warn)
[ucli] /path/test.tcl @ 2.50 us: mem_scrub UNCORRECTABLE ram[3] double_err  (红 error)
```

颜色: 绿 (info) / 黄 (warn) / 红 (error) / 灰 (debug). caller path / time 在 aip_cmd.tcl loaded 时自动注入。

### 12. analyze_timescale.py — Filelist Timescale 分析

VCS 的 `\`timescale` 是 sticky 指令, 多文件混用 + IP 库不同 timescale 容易导致编译时实际生效 timescale 跟预期不一致。本脚本递归展开 .f 文件, 列出所有 `\`timescale` / `\`resetall` 事件, 计算最终 sticky timescale + 冲突点。

```bash
python3 analyze_timescale.py top.f                    # 基本
python3 analyze_timescale.py top.f sub.f              # 多 filelist
python3 analyze_timescale.py top.f --default 1ns/1ps  # 模拟 vcs -timescale=
python3 analyze_timescale.py top.f -v                 # verbose, 显示所有文件
python3 analyze_timescale.py top.f -j out.json        # JSON 报告
```

**功能：**

- 递归 `-f` / `-F` 嵌套 .f
- 跳过 `-v`/`-y`/`+incdir+`/`-D` 等非源文件选项
- 识别 `\`timescale` + `\`resetall`
- `$ENV_VAR` 环境变量展开
- 检测循环 include
- 输出: 每文件 timescale 事件 + FINAL sticky timescale + CONFLICTS + 最差精度

**示例输出：**

```
FILE                                  TIMESCALE@END   EVENTS
aip_time.sv                           1ns/1ps         L9 `timescale 1ns/1ps (was 1ns/1ns)
aip_clk.sv                            1ns/1ps         L9 `timescale 1ns/1ps (was 1ns/1ps)
...
FINAL sticky timescale at end of compilation: 1ns/1ps

CONFLICTS (timescale 中途变化, 1 处):
  aip_time.sv:9  1ns/1ns -> 1ns/1ps

最差精度: 1ns/100ps @ ip_xxx.sv:1
```

**典型应用场景：**

- 仿真出现频率/时钟/延迟异常 (实际 vs 期望差 10×/100×) → 跑此脚本看是否某 IP 把 timescale 拉粗
- 调试 `vcs -timescale=` 命令行被源码 `\`timescale` 覆盖问题
- 修复方法: 在主文件顶部加 `\`timescale 1ns/1ps`, 或编译加 `-override_timescale=1ns/1ps` 强制覆盖

### 13. aip_cpu_bridge.sv — CPU 命令桥接

通过共享内存 mailbox 将 TCL/SV 命令发送到 RTL 仿真中运行的 C908 CPU 固件。

**SV 侧设置：**

```systemverilog
// 1. 实现 mem accessor（项目相关的 backdoor 读写）
class my_mem extends aip_mem_accessor;
    virtual task wr_mem(input longint unsigned addr, input int unsigned data);
        // 用项目的 backdoor 写接口
        force tb.soc.mem[addr[15:0]] = data;
    endtask
    virtual task rd_mem(input longint unsigned addr, output int unsigned data);
        data = tb.soc.mem[addr[15:0]];
    endtask
endclass

// 2. 注册 CPU 命令（自动路由到 cpu_bridge）
`aip_cmd_cpu(read_reg)
`aip_cmd_cpu(dma_test)

// 3. 初始化 — 四种模式组合
module tb;
    `aip_tcl_bridge_create(tcl)
    my_mem mem_acc;

    // 事件监控 (事件模式需要，放在 module 作用域)
    `aip_cpu_bridge_monitor(soc.ram.mem, 960)  // base_idx = 0xF00/4 = 960

    // IRQ 连接 (IRQ 模式需要)
    assign soc.cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;

    initial begin
        mem_acc = new();
        aip_cpu_bridge::init(mem_acc, 64'hF000_0000);

        // ---- 选择模式（按需开启）----

        // 模式 A: 纯轮询（默认，什么都不加）
        // 两侧都是 poll，最简单

        // 模式 B: IRQ（只优化 SV→C 通知）
        // aip_cpu_bridge::enable_irq();

        // 模式 C: 事件（只优化 C→SV 通知）
        // aip_cpu_bridge::enable_event_mode();

        // 模式 D: IRQ + 事件（推荐，两侧零延迟）
        aip_cpu_bridge::enable_irq();
        aip_cpu_bridge::enable_event_mode();

        // 超时保护（所有模式都支持）
        aip_cpu_bridge::set_timeout(100000.0);  // 100us，0=禁用
    end
endmodule
```

**四种模式组合：**

| 模式 | SV→C 通知 | C→SV 通知 | 初始化 | 适用场景 |
|------|-----------|-----------|--------|---------|
| A 纯轮询 | C poll cmd_flag | SV #10 poll rsp_flag | `init()` | 最简单，调试用 |
| B IRQ | IRQ 脉冲唤醒 WFI | SV #10 poll rsp_flag | + `enable_irq()` | C 侧省功耗 |
| C 事件 | C poll cmd_flag | `@(event)` 零延迟 | + `enable_event_mode()` + monitor 宏 | SV 侧零延迟 |
| **D IRQ+事件** | **IRQ 脉冲唤醒** | **`@(event)` 零延迟** | **+ 两者都开** | **推荐，两侧最优** |

**用户接线要求：**

| 模式 | SV 侧 | module 作用域 |
|------|--------|---------------|
| A 纯轮询 | 无 | 无 |
| B IRQ | `assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;` | — |
| C 事件 | — | `` `aip_cpu_bridge_monitor(ram.mem, base_idx) `` |
| D IRQ+事件 | IRQ assign | + monitor 宏 |

**`\`aip_cpu_bridge_monitor(mem_path, base_idx)` 详解**:

事件驱动模式下让 SV 走**零延迟事件触发**, 替代默认 `#10` 轮询 (默认每 10ns 检查 rsp_flag)。

宏展开:
```sv
`define aip_cpu_bridge_monitor(mem_path, base_idx) \
    always @(mem_path[(base_idx) + 130]) begin \
        if (mem_path[(base_idx) + 130] == 1) \
            -> aip_core_pkg::__cpu_bridge_rsp_event; \
    end
```

工作原理:
1. `always @(mem_path[base_idx + 130])` 持续监控 mailbox 内 rsp_flag word 变化
   - `base_idx` = mailbox base address 对应的 word index (e.g. mailbox=0xF00, base_idx=0xF00/4=960)
   - `+ 130` = rsp_flag offset = 0x208/4 (mailbox 内 OFF_RSP_FLAG = 0x208)
2. C 写 `rsp_flag = 1` (表示响应就绪) 触发 always
3. `-> aip_core_pkg::__cpu_bridge_rsp_event` 触发 package event
4. `aip_cpu_bridge::send_cmd` 位于同一个 package 内，可直接用
   `@(__cpu_bridge_rsp_event)` 访问该状态并立即解阻塞读响应

**轮询 vs 事件对比**:

| 模式 | SV 等响应延迟 | 用法 |
|------|----------------|------|
| 轮询 (默认) | 0~10ns (#10 poll) | 不需 monitor |
| 事件 (推荐) | **0ns** (事件驱动) | 需 monitor + `enable_event_mode()` |

**参数取值**:
- `mem_path`: mailbox 实际存的 RTL mem 数组 hdl path (e.g. `soc.ram_share.mem`)
- `base_idx`: mailbox base address 对应的 word index 起点
  - mailbox base = `0x0000_0000`, mem 从 0 起 → base_idx = `0`
  - mailbox base = `0x0000_0F00`, mem 从 0 起 → base_idx = `0xF00 / 4 = 960`
  - mailbox base = `0xF000_0000`, mem 从 `0xF000_0000` 起映射 → base_idx = `0`

**必须 module scope 原因**:
- `always @(...)` 不能声明在 class/package 中，只能放在 module/interface 等允许过程块的作用域
- mem_path 是 RTL mem 的 hierarchical reference, 解析依赖 module 实例化层级
- monitor 宏跨越 module/package 边界，因此必须用
  `aip_core_pkg::__cpu_bridge_rsp_event` 限定 package event

`aip_cpu_bridge` 的方法定义在 `aip_core_pkg` 内部，可以直接访问相应 package state；
用户在 module 边界接 IRQ 或由 monitor 触发 event 时必须写 `aip_core_pkg::` 限定名。

不用 monitor 也能跑 (轮询模式), 但响应延迟较高 + sim 推进密集。事件模式是性能优化, 跟 IRQ 模式可叠加。

**C 固件侧：**

```c
#include "aip_cmd.h"

void do_read_reg(const char *args) {
    int addr = cmd_get_int(args, "addr", 0);
    int data = *(volatile int *)(long)addr;
    cmd_return("data=0x%x", data);
}

void do_dma_test(const char *args) {
    int src  = cmd_get_int(args, "src", 0);
    int dst  = cmd_get_int(args, "dst", 0);
    int len  = cmd_get_int(args, "len", 256);
    // ... 执行 DMA 操作 ...
    cmd_return("ok src=0x%x dst=0x%x len=%d", src, dst, len);
}

int main(void) {
    cmd_init((volatile void *)0xF0000000);

    // 可选：开启 C908 中断（配合 SV 侧 enable_irq）
    // cmd_irq_init();  // 需 #include "aip_cmd_c908.h"

    cmd_register("read_reg", do_read_reg);
    cmd_register("dma_test", do_dma_test);
    cmd_loop();  // 轮询模式忙等 / IRQ 模式 WFI 休眠
    return 0;
}
```

**内建命令（`aip_cpu_bridge_builtins` 宏一键注册）：**

SV 侧加 `` `aip_cpu_bridge_builtins ``，C 侧加 `cmd_register_builtins()`。

```tcl
# 基础读写
cpu_read32 addr=0x40000000                    ;# → data=0x12345678
cpu_write32 addr=0x40000000 data=0xFF
cpu_read64 addr=0x40000000                    ;# → data=0xDEADBEEF12345678
cpu_write64 addr=0x40000000 data=0xCAFE

# 字节倒序（大小端转换）
cpu_write32_swap addr=0x100 data=0x80102030   ;# 实际写入 0x30201080
cpu_read32_swap addr=0x100                    ;# 读出后字节倒序返回
cpu_write64_swap addr=0x100 data=0x0102030405060708
cpu_read64_swap addr=0x100

# 轮询等待寄存器状态位
cpu_poll32 addr=0x100 mask=0x1 expect=0x1 timeout=10000
#  → ok data=0x... iter=N    (匹配成功)
#  → timeout data=0x... iter=10000 (超时)

# SV 后门（不走 CPU，backdoor 直接访问，速度快）
cpu_memset addr=0x40000000 len=256 val=0       ;# 批量清零
cpu_memdump addr=0x40000000 len=64             ;# dump 内存
#  Address     +0       +4       +8       +C
#  ---------   -------- -------- -------- --------
#  40000000:  12345678 deadbeef aabbccdd 30201080
```

**退出机制：**

```tcl
# 正常退出: TCL 通知 CPU 停止 cmd_loop
cpu_exit
end_test drain=500
```

```c
// C 侧异常退出: 通知 SV 终止仿真
if (error_detected) {
    cmd_exit(-1);   // SV 侧收到后 aip_fatal → 仿真终止
    return;
}

// C 侧正常退出
cmd_exit(0);        // SV 侧 warning，不 fatal
```

| 退出场景 | 触发 | SV 行为 |
|----------|------|---------|
| TCL `cpu_exit` | SV→C | `[INFO]` 提示，C 的 cmd_loop 返回 |
| C `cmd_exit(0)` | C→SV | `[WARNING]`，send_cmd 返回 -1 |
| C `cmd_exit(-1)` | C→SV | `[ERROR]+[FATAL]`，仿真终止 |

**TCL 使用（两种模式完全一致，用户无感）：**

```tcl
# 同步调用 — 等待 CPU 返回结果
read_reg addr=0x100

# 异步调用 — 立即返回，不等 CPU 响应
dma_test src=0x1000 dst=0x2000 len=4096 async=1

# 混合 fork — SV 命令和 CPU 命令并行
fork read_reg addr=0x100, wr addr=0x200 data=0xFF join
```

**TCL 动态配置 cpu_bridge (aip_cpu_bridge_ops + sv:: 命令)**:

`aip_cpu_bridge_ops` 是 cpu_bridge TCL 友好 wrapper, 把 `aip_cpu_bridge::init/set_timeout/enable_irq/enable_event_mode` 暴露成 TCL 命令。命名 `sv::cpu_bridge_*` 区分 SV 注册命令与 TCL 内置 proc。

```tcl
sv::cpu_bridge_status                          ;# 查看当前配置
sv::cpu_bridge_set_timeout ns=200000           ;# 改 timeout (默认 100us)
sv::cpu_bridge_enable_irq                      ;# 开 IRQ 模式
sv::cpu_bridge_enable_event_mode               ;# 开事件模式
sv::cpu_bridge_reinit mbox_base=0xF0001000     ;# 改 mailbox base + 重新 init
```

**注意 `mem_accessor` 仍需 SV 注册一次** (TCL 无法构造 SV class 实例):
```sv
my_mem_accessor mem_acc = new();
aip_cpu_bridge_ops::set_mem(mem_acc);          // 给 ops 存 (TCL reinit 复用)
aip_cpu_bridge::init(mem_acc, 64'hF000_0000);  // 默认 init, TCL 之后可 reinit 改 base
```

实现细节 (SV escaped identifier):
- `aip_cmd.sv` 内 `aip_cmd_task` / `aip_cmd_1i` 等宏内部 class 名用 escaped identifier `\__aip_cmd_<Ccmd> `, 允许 Ccmd 含 `::`
- 注册命令名 = class 名后半段, 完全对应
- 调用 `\`aip_cmd_task(sv::cpu_bridge_status, aip_cpu_bridge_ops::show_status)` 一行搞定

**UVM 完整使用流程 — module 与 tc_base 职责分工**:

由于 SV 语法限制 (always/assign/initial 只允许 module scope), 必须 module 内放硬件接线; 其余 procedural 操作可全在 tc_base 内, 跟 aip_tcl_bridge::run_loop 配合无缝集成。

| 内容 | scope | 说明 |
|------|-------|------|
| `\`aip_cpu_bridge_monitor(mem, idx)` | module 必需 | 展开 `always @(...)`, SV 不允许 class 内 always |
| `assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;` | module 必需 | assign 只允许 module scope；跨 package 边界必须限定状态对象 |
| `\`aip_clk_create(name, freq)` | module 必需 | 展开 interface + initial；统一入口须与使用者同一 compilation unit |
| `\`aip_tcl_bridge_create(name)` | **可选** (用 tc_base 替代) | 展开 initial; tc_base 改用 run_phase 直接调 run_loop |
| `\`aip_cpu_bridge_builtins` | **允许 class 声明的 scope** | 展开 class 定义，可放 user package/module/class |
| `\`aip_cmd_cpu(name)` / `\`aip_cmd_task` | **任意 scope** | class 定义 |
| `my_mem_accessor` 实例化 | **任意 scope** | class new() |
| `aip_cpu_bridge_ops::set_mem()` + `init()` | **任意 procedural** | static method call |
| `aip_tcl_bridge::run_loop()` | **任意 task** | static task, tc_base run_phase 调用 |

```sv
// ============================================================
// 1. 用户 package — import aip_core 类型并放置 class 定义/命令注册
// ============================================================
package user_pkg;
import uvm_pkg::*;
import aip_core_pkg::*;

class my_mem_accessor extends aip_mem_accessor;
    virtual task wr_mem(input longint unsigned addr, input int unsigned data);
        force tb.soc.ram_share.mem[addr[15:0] >> 2] = data;
    endtask
    virtual task rd_mem(input longint unsigned addr, output int unsigned data);
        data = tb.soc.ram_share.mem[addr[15:0] >> 2];
    endtask
endclass

// 用户 CPU 命令 (cpu:: 前缀语义化)
`aip_cmd_cpu(cpu::my_read_reg)
`aip_cmd_cpu(cpu::dma_test)

// CPU bridge 内建命令 (cpu_read32/write32/...) — class 定义在 user package
`aip_cpu_bridge_builtins

endpackage

import user_pkg::*;

// ============================================================
// 2. UVM tc_base — 吸收所有 procedural 操作
//    (不需要 aip_tcl_bridge_create 宏, run_phase 直接调 run_loop)
// ============================================================
class tc_base extends uvm_test;
    `uvm_component_utils(tc_base)
    my_mem_accessor mem_acc;
    my_env env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = my_env::type_id::create("env", this);
        // backdoor 注入 + cpu_bridge init (TCL 之后可 sv::cpu_bridge_reinit 改 base)
        mem_acc = new();
        aip_cpu_bridge_ops::set_mem(mem_acc);
        aip_cpu_bridge::init(mem_acc, 64'hF000_0000);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        virtual_sqr::axi_wr_sqr = env.wr_agent.sqr;
        virtual_sqr::axi_rd_sqr = env.rd_agent.sqr;
        // TCL 接管 — 直接调 aip_tcl_bridge::run_loop (不需 aip_tcl_bridge_create 宏)
        aip_tcl_bridge::run_loop();
        // end_test 回来后 UVM 正常 extract→check→report→$finish
        phase.drop_objection(this);
    endtask
endclass

// ============================================================
// 3. testbench top — 只放 SV 必须 module scope 的东西
// ============================================================
module tb;
    `aip_clk_create(clk_sys, 100e6)                        // initial 块, 必须 module
    `aip_clk_create(clk_cpu, 800e6)
    soc_top soc(...);
    assign soc.cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq; // assign, 必须 module
    `aip_cpu_bridge_monitor(soc.ram_share.mem, 960)       // always 块, 必须 module
    initial run_test();                                    // UVM 入口
endmodule
```

**关键点**:
- tc_base 等效 `aip_tcl_bridge_create` 宏 (用 `aip_tcl_bridge::run_loop()` in run_phase 替代)
- tc_base 持有 mem_accessor 跟 test 生命周期一致, 比 module initial 更易管理 (不同 test 可换不同 mem 实现)
- module 只剩 3 类: clock 生成 / 信号接线 (IRQ assign) / 事件 monitor (always)
- class 注册可放 user package，不需要为它们增加 module 包裹

```tcl
# TCL 脚本完整流程 (三层协同)
source aip_cmd.tcl
source aip_ucli_utils.tcl
utils_silent

# Stage 1: TCL 动态配置 cpu_bridge
sv::cpu_bridge_set_timeout ns=200000
sv::cpu_bridge_enable_irq
sv::cpu_bridge_enable_event_mode

# Stage 2: setup (utils 后门, 0 sim time)
mem_cfg tb.soc.ram_main -width 32 -ecc_mode secded
mem_write_zero tb.soc.ram_main 0x0 1024
load_mem tb.soc.ram_main -file boot.hex -from 0

# Stage 3: runtime (C 真执行)
run 1us
my_read_reg addr=0x40000000
dma_test src=0x1000 dst=0x2000 len=4096
cpu_read32 addr=0x40000100             ;# SV 后门经 bridge
cpu_poll32 addr=0x40000300 mask=0x1 expect=0x1 timeout=10000

# Stage 4: 并行 (C 命令 + UVM seq)
fork
    dma_test src=0x3000 dst=0x4000 len=1024
    axi_write count=100
join

# Stage 5: debug + dump
dump_mem tb.soc.ram_main -from 0x2000 -to 0x2FFF -file post_dma.hex
mem_scrub tb.soc.ram_main 0x0 0xFFFF -fix 1

# Stage 6: 退出
cpu_exit
end_test drain=500
```

**三路径协同**:

| 路径 | 调用 | 仿真时间 | 用途 |
|------|------|---------|------|
| **utils 后门** | `mem_write_*`, `dump_mem`, `mem_scrub` | 0 (无 sim 推进) | 批量 setup/dump, ECC scrub |
| **cpu_bridge builtin** | `cpu_read32`, `cpu_write32`, `cpu_poll32`, `cpu_memdump` | bridge handshake (~ns) | SV 后门 (mem_accessor) 经 bridge 派发, sim 推进 |
| **cpu_bridge custom (C)** | `my_read_reg`, `dma_test`, `crc_calc` | mailbox + C 跑 (~us) | C CPU 真实执行 (cache/MMU/bus 都参与) |
| **SV 注册配置 (sv::)** | `sv::cpu_bridge_set_timeout`, `sv::cpu_bridge_enable_irq` 等 | 0 | TCL 动态调 cpu_bridge 配置 (不重编译) |

---

## VCS Q-2020 兼容性注意事项

| 问题 | 解决方案 |
|------|---------|
| `longint unsigned'(0)` 不支持 | 用 `{64{1'b1}}` 或 `64'h1` |
| `aip_cmdline#(real)` 不支持 | 用 `aip_cmdline_real` 独立类 |
| `s[i] == "\r"` 错误匹配 `'r'` | 用 `s[i] == 8'd13` 字节值比较 |
| `{string, byte}` 拼接不可靠 | 用 `string'(byte_val)` |
| 编译无 timescale | 必须加 `-timescale=1ns/1ps` |
| class 静态变量 UCLI 不可 force | 将 bridge 状态声明为 `aip_core_pkg::__tcl_*` package 变量，并用限定名 `get`/`force` |
| UCLI 无 `examine` 命令 | 用 `get` 替代 |
| `fork...join_none` 在 `new()` 中不可靠 | 用 `start()` task 分离 |
| 命名 fork-join + `disable <name>` 多 class 实例互扰 | 用匿名 `fork...join_any` + `disable fork` (aip_clk 已修) |
| 多 ram + 高频时钟 + 低精度 timescale 导致 50MHz 出 5GHz/83GHz | aip_time/aip_clk 顶部加 `\`timescale 1ns/1ps`; 或 vcs `-override_timescale=1ns/1ps`; 用 analyze_timescale.py 排查 |
| UCLI `force -release` 不支持 | utils 用 `release` builtin / `force -cancel` fallback |
| UCLI `get` 返回 `'b...` 二进制 raw 字符串 | 用 `gv` 自动 parse 多 radix |
| Q-2020 `-full64` 运行时 `vcsMsgReport1` 误查 `linux/bin` | VCS launcher 通常会自动设置内部变量；若运行时丢失，可在启动 `simv` 前设置 `VMR_MODE_FLAG=64`，确认 `$VCS_HOME/linux64/bin/vcsMsgReport1` 存在。`VCS_TARGET_ARCH` 不是 `vcsMsgReport` 读取的变量；不要跨架构软链接 helper |

---

## 快速开始示例 — 基础命令

```systemverilog
`include "aip_core_pkg.sv"
import uvm_pkg::*;
import aip_core_pkg::*;

class my_ops;
    static task hello();
        $display("Hello from SV!");
    endtask
    static task write_reg(input int addr, input int data, output int status);
        $display("write: 0x%0h = 0x%0h", addr, data);
        status = 0;
        #10;
    endtask
endclass

`aip_cmd_task(hello, my_ops::hello)
`aip_cmd_2i1o(wr, my_ops::write_reg, int, addr, 0, int, data, 0, int, status)

module tb;
    `aip_clk_create(clk0, 100e6)
    `aip_tcl_bridge_create(tcl)
    initial begin
        `aip_cmd_info(hello, "basic", "Say hello", "none")
        `aip_cmd_info(wr, "reg", "Write register", "addr:int data:int -> status:int")
    end
endmodule
```

```bash
vcs -sverilog -ntb_opts uvm +incdir+. -timescale=1ns/1ps tb.sv -debug_access+r+w+f
./simv -ucli -i aip_cmd.tcl
```

```tcl
hello                                ;# 直接输入
wr addr=0x100 data=0xFF             ;# 带参数
aip_send_cmd "help"                  ;# help 与 VCS 内置冲突，需显式调用
run 50ns                             ;# VCS 原生命令正常使用
```

---

## 快速开始示例 — UVM Seq + Virtual Sequencer

**编译一次，TCL 脚本无限变化，不需要重新编译。**

```systemverilog
`include "aip_core_pkg.sv"
import uvm_pkg::*;
import aip_core_pkg::*;

// 1. Transaction — 参数用 aip_cmdline 注册
class axi_trans extends uvm_sequence_item;
    `uvm_object_utils(axi_trans)
    int addr, data, len;
    function new(string name = "");
        super.new(name);
        `aip_int("axi.wr", int, addr, 0)       // +axi.wr.addr=0x100
        `aip_int("axi.wr", int, data, 0)       // +axi.wr.data=0xFF
        `aip_int("axi.wr", int, len, 1)        // +axi.wr.len=[1:16]
    endfunction
endclass

// 2. Sequence — body 只做 repeat(count) 发 trans
class axi_wr_seq extends uvm_sequence #(axi_trans);
    `uvm_object_utils(axi_wr_seq)
    int count = 1;
    function new(string name = ""); super.new(name); endfunction
    task body();
        repeat(count) begin
            axi_trans tr = axi_trans::type_id::create("tr");
            start_item(tr);   // trans.new() 自动从 plusargs/override 获取参数
            finish_item(tr);
        end
    endtask
endclass

// 3. Virtual Sequencer — 静态成员集中管理
class virtual_sqr extends uvm_sequencer;
    `uvm_component_utils(virtual_sqr)
    static uvm_sequencer #(axi_trans) axi_wr_sqr;
    static uvm_sequencer #(axi_trans) axi_rd_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

// 4. 宏注册 — 一行绑定 seq + sequencer
`aip_cmd_seq(axi_write, axi_wr_seq, virtual_sqr::axi_wr_sqr)
`aip_cmd_seq(axi_read,  axi_rd_seq, virtual_sqr::axi_rd_sqr)

// 5. Env — connect_phase 绑定 static sqr
class my_env extends uvm_env;
    // ... agents ...
    function void connect_phase(uvm_phase phase);
        virtual_sqr::axi_wr_sqr = wr_agent.sqr;
        virtual_sqr::axi_rd_sqr = rd_agent.sqr;
    endfunction
endclass

// 6. base_test — 唯一需要的 SV test，TCL 脚本替代 SV 用例
//    不需要写 SV test case，不需要写 seq start 逻辑
class base_test extends uvm_test;
    `uvm_component_utils(base_test)
    my_env env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = my_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        // 绑定 virtual sequencer
        virtual_sqr::axi_wr_sqr = env.wr_agent.sqr;
        virtual_sqr::axi_rd_sqr = env.rd_agent.sqr;

        // TCL 接管 — 直接调用 run_loop，不需要 aip_tcl_bridge_create 宏
        aip_tcl_bridge::run_loop();

        // end_test 后到这里，UVM 正常走 extract → check → report → $finish
        phase.drop_objection(this);
    endtask
endclass
```

```bash
# 编译一次（之后不需要再编译）
vcs -sverilog -ntb_opts uvm +incdir+. -timescale=1ns/1ps tb.sv -debug_access+r+w+f

# 跑不同用例 — 只换 TCL 脚本，不重编译
./simv -ucli -i test_basic_write.tcl +UVM_TESTNAME=base_test
./simv -ucli -i test_burst_rw.tcl   +UVM_TESTNAME=base_test +axi.wr.data=0xFF
./simv -ucli -i test_stress.tcl     +UVM_TESTNAME=base_test
```

TCL 脚本就是用例（替代传统的 SV test case）：

```tcl
# test_basic_write.tcl — 基础写测试（个数控制）
source aip_cmd.tcl
set_param { axi.wr.addr 0x1000 }
axi_write count=10
end_test drain=500

# test_timed_write.tcl — 时间控制发包
source aip_cmd.tcl
set_param {
    axi.wr.addr  [0:0xFFFF]
    axi.wr.data  [0:0xFFFFFFFF]
}
axi_write time=1us            ;# 持续写 1 微秒
axi_read time=500ns           ;# 持续读 500ns
end_test drain=500

# test_burst_rw.tcl — 并行读写（混合 count + time）
source aip_cmd.tcl
set_param {
    axi.wr.addr  [0:0xFFFF]
    axi.wr.len   1,2,4,8,16
}
fork
    axi_write time=2us        ;# 写 2 微秒
    axi_read count=100        ;# 读 100 个
join
end_test drain=1000

# test_stress.tcl — 压力扫描
source aip_cmd.tcl
for {set i 0} {$i < 10} {incr i} {
    set_param {
        axi.wr.addr  [0:0xFFFF]
        axi.wr.len   [1:64]
    }
    fork
        axi_write time=10us
        axi_read time=10us
    join
}
end_test drain=2000

# test_interactive.tcl — 交互式调试（不加 end_test，手动输入）
source aip_cmd.tcl
# 然后在 UCLI 中手动输入：
#   axi_write count=1
#   set_param path=axi.wr.addr value=0x2000
#   axi_write time=100ns
#   end_test drain=500
```

---

## 用户自定义 Seq 指南

### 第一步：写 Transaction

trans 的字段用 `aip_cmdline` 注册，`new()` 时自动从 plusargs/override 读取。

```systemverilog
class my_trans extends uvm_sequence_item;
    `uvm_object_utils(my_trans)
    int addr, data, len;
    string mode;

    function new(string name = "");
        super.new(name);
        // 每次 create → new 都会读取最新的 override/plusargs 值
        `aip_int("pkt.wr", int, addr, 0)          // +pkt.wr.addr=0x100 或 set_param
        `aip_int("pkt.wr", int, data, 32'hDEAD)   // 支持随机: [0:0xFF], 1,2,3
        `aip_int("pkt.wr", int, len, 1)            // 支持递增: inc:1:64:1
        `aip_string("pkt.wr", mode, "INCR")
    endfunction
endclass
```

### 第二步：写 Sequence

**唯一要求：有 `int count` 字段，`body()` 中用 `repeat(count)`。**

```systemverilog
class my_write_seq extends uvm_sequence #(my_trans);
    `uvm_object_utils(my_write_seq)
    int count = 1;    // ← 必须有，宏会设置它

    function new(string name = ""); super.new(name); endfunction

    task body();
        repeat(count) begin
            my_trans tr = my_trans::type_id::create("tr");
            // ↑ create 调用 new()，此时 aip_cmdline 读取参数

            start_item(tr);
            // ↑ 向 sequencer 请求仲裁，等 driver 就绪（不创建 tr）

            // 可选：在 start_item 和 finish_item 之间修改 tr
            // tr.addr = tr.addr + 4;          // 手动覆盖
            // tr.randomize() with { len < 8; }; // 约束随机

            finish_item(tr);
            // ↑ 发送 tr 给 driver，等待 item_done
        end
    endtask
endclass
```

**执行时序：**
```
create("tr")  → new()      → aip_cmdline 读 override/plusargs
start_item    → sequencer   → 等 driver 就绪（不创建对象）
              → 用户可改 tr → 覆盖或 randomize
finish_item   → driver      → 驱动 DUT，等 item_done
```

### 第三步：注册

```systemverilog
// 一行注册：命令名, seq 类型, virtual_sqr 的静态 sequencer
`aip_cmd_seq(my_write, my_write_seq, virtual_sqr::wr_sqr)

// 可选：添加帮助信息
`aip_cmd_info(my_write, "pkt", "Write packets", "count:int or time:str")

// 或只声明类型，由 Tcl 运行时绑定 sequencer（每个实例一条命令，无需重编译）：
`aip_seq_type(my_write_seq)        // Tcl: aip_reg_seq cmd=my_write1 type=my_write_seq sqr=uvm_test_top.env.wr1.sqr
```

### 第四步：TCL 中使用

```tcl
# 个数模式
my_write count=10             ;# 发 10 个 trans

# 时间模式（框架自动设 count=MAX，超时后 disable seq）
my_write time=1us             ;# 持续发 1 微秒

# 默认
my_write                      ;# 发 1 个

# 改参数
set_param { pkt.wr.addr [0:0xFFFF] }
my_write time=500ns           ;# 500ns 内持续发，addr 每次随机

# 并行
fork
    my_write time=2us
    my_read count=100
join
```

### 注意事项

| 项目 | 说明 |
|------|------|
| `count` 字段 | 必须是 `int count`，宏通过它控制发包数 |
| `create` vs `start_item` | `create` 调用 `new()` 读参数；`start_item` 只做仲裁，不创建 |
| 参数读取时机 | 每次 `create` 都重新读取 override 表，保证参数实时生效 |
| time 模式原理 | `count` 设为 MAX，`fork seq + timer join_any`，超时 `disable` seq |
| `set_param` 安全性 | `$stop/run` 握手保证 TCL 改参和 SV 读参不会同时发生 |
| 嵌套 path | trans 的 `aip_int` path 支持多级: `"eth.ipv4.tcp"` |

---

**与传统 UVM 流程对比：**

| | 传统 UVM | TCL 模式 |
|---|---|---|
| SV test case | 每个用例一个 .sv 文件 | 只写一个 base_test |
| SV sequence | test 中手动 start | TCL 脚本控制 |
| 发包控制 | 固定 count 或 constraint | count 或 time，运行时可选 |
| 参数修改 | 改 SV 或 plusargs，可能要重编译 | TCL set_param 运行时改 |
| 编译次数 | 每改一次可能编译一次 | 只编译一次 |
| 用例文件 | .sv（需编译） | .tcl（直接运行） |
| 并行控制 | SV fork/join | TCL fork/join（支持 time+count 混合） |
| 退出机制 | drop_objection | end_test drain=N |
| 调试 | 改代码重编译重跑 | TCL 交互式试探 |

## CPU firmware pipeline

TCL → SV bridge → CPU firmware 链路由 `src/sv/cpu_mem/`（内存抽象 + loader）、
`src/sv/bridge/aip_cpu_bridge.sv`（mailbox 协议）和 `firmware/`（可复用 C 库 +
参考固件）组成。See:

- Spec: `docs/superpowers/specs/2026-05-27-cpu-firmware-pipeline-design.md`
- Library README: `firmware/README.md`
- Memory model: `docs/cpu_mem/README.md`

Three boot modes (`rom`, `ram_copy`, `ram_jump`), three wake modes
(`poll`, `msip`, `plic`), IRQ ACK protocol v2, macro-based command
registration via existing `aip_cmd` / `aip_cmdline`.

## 同会话续跑与旧块重放

新脚本经 `dist/aip_init_so.tcl` 加载库后直接使用普通 `source/-do`；受控仿真
推进中的暂停由 VCS 原生 `pause/resume` 保留调用栈，仅在 stdin 为 TTY 时
自动使用 `run -keep` 处理推进期间 Ctrl+C；非交互场景保留原批处理中止语义。
显式 `-keep` 仍原样传递，但原生 VCS 遇到 EOF 可能自行继续。
Q-2020 会在执行前拒绝 `-keep`，控制层不会通过实际发送非法命令来探测，避免
VCS 把脚本直接留在 UCLI 提示符。若 `VCS_HOME` 路径包含 Q/P-20xx，自动插入的
`-keep` 会在首次 run 前关闭；自定义安装路径可用 `AIP_VCS_RUN_KEEP=0/1` 覆盖。
显式 `run -keep` 仍返回原生错误。无法使用 `-keep` 时，Ctrl+C 保栈续跑不可用，
应使用 `aip_watch stop=1` 的 `pause/resume` 或兼容的 `aip_run_self` 重放路径。
能力判断只在首次需要自动 `-keep` 时读取并缓存环境变量，不发送非法探测命令，
不会额外推进仿真，也不会给后续 run 增加持续运行时开销。
`aip_watch path value stop=1` 的一次性观察使用同一
暂停入口；省略 stop 或设为0只通知。完整参数、限制见 README 第8.2节。

`resume` 不再承担 AIP 桥状态清理；显式清理入口改为 `aip_recover`，不能在
保栈暂停中调用。原脚本若用 `resume` 清理桥状态，应改为 `aip_recover`。
`aip_recover` 目前标记为 deprecated，但仍保留用于非TTY中断、restore孤立桥和
旧脚本的异常清理；它不是同会话续跑接口。
暂停时普通已注册命令通过独立注入队列受理；同一注册绑定 FIFO、不同绑定并行，
每笔返回独立 ticket/结果，不改写原 bridge 槽。使用 `aip_submit` 和
`aip_job status|wait|cancel|release` 管理 ticket；队列容量为32，运行中超时不
杀任务，只有终态才能 release。暂停中的普通命令不设绝对期限，与 ACK 一样按无活动进展
等待（见 7b），放弃时仍排队的请求被撤销回收；`aip_job wait` 同样按无进展计时，
`aip_submit timeout=` 仍是绝对期限。checkpoint/restore、参数全局修改及插件生命周期
命令仍要求无活动 ticket。注入推进会同步推进原任务和DUT，不能用它消除业务资源竞争。
`run`/helper 在保留暂停中只接受有限时间，并复用同一安全推进器。
托管 watch 暂停没有等到真实 `resume` 而因 EOF 返回时，报
`AIP_CONTROL_PAUSE_ABORTED`，不静默继续脚本。

下面的旧 `aip_run_self/aip_source` 接口仍兼容错误块重放，不是同会话续跑
的前提，也不能替代原生栈。它们属于 deprecated 兼容层；新用例不再推荐增加
`aip_run_self`，但不能仅因保栈续跑通过就删除跨进程 `_left.tcl` 能力。

### 旧接口：错误块重放 (aip_run_self)

已有 TCL 脚本可保留 `aip_run_self` 启用 block 级错误跟踪及 `_left.tcl` 重放。
保栈暂停本身不展开此栈，也不生成 `_left.tcl`；只有异常展开进入旧错误路径。

详见 `docs/superpowers/specs/2026-06-02-aip-source-resume-design.md`.

简明用法:
```tcl
# xxx.tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl
aip_run_self                    ;# 1 行接管 body 执行流

# body (照旧):
set_param path=p1 value=v1
fork test_a, test_b join_none
run 100us
final_check
```

错误导致原调用栈展开后：

- 自动 dump 剩余 block 到 `xxx_left.tcl` 同目录
- 续跑路径 1: UCLI 内 `aip_source xxx_left.tcl` (name-only, 自动解析到同 dir)
- 续跑路径 2: 重启 `vcs -ucli -do xxx.tcl`, aip_run_self 自动检测 _left 切换续跑
- 跑完自动删 _left

公共 API:

- `aip_run_self` — `-do` 入口接管, 1 行启用追踪
- `aip_source <name>` — 加载并 block-level 跟踪执行 TCL 文件
- `aip_flush_left` — 手动入口 (自动 catch 失效时兜底, 写 _left 文件)
- `aip_source_status` — 调试用, 显示 stack 状态

约束 (文档化):

- TCL 控制流块 (`for`/`while`/`proc`) 作为整块续跑重头, 用户自管幂等
- 跨 simv session TCL global var 不保留, 用户脚本顶部 set 的 var 续跑后 re-set
- 用户直 `source xxx.tcl` (非 aip_run_self/aip_source) 跟踪失效
- **多行 fork 块跨 session 续跑不支持**. 多行 `fork\n  cmd_a\n  cmd_b\njoin` 在 TCL `info complete` 下是 4 个独立 block (fork/cmd_a/cmd_b/join), 中间 Ctrl+C 后续跑会破坏 fork_mode 状态. **推荐用单行**: `fork cmd_a, cmd_b join` (1 个 block, 续跑保持原子性). 单 dispatch 内的 SV 端真并发不受影响.

---

## License

源码自研。第三方：
- `firmware/arch/startup.S`、`firmware/core/csi_config.h` — XuanTie CSI 官方启动代码（随 XuanTie toolchain 分发）
