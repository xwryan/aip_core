---
title: AIP Core 用户手册
subtitle: SystemVerilog / Tcl-UCLI / TCP / CPU mailbox 综合验证环境
version: current
date: 2026-10-09
toc_levels: 3
chapter_page_breaks: true
section_page_breaks: false
dedupe_repeated_sections: false
---

# 第一部分：快速上手

本手册面向使用 AIP Core 的验证工程师。内容按“先接入、再操作、后扩展、最后验收”的顺序编排；每章都说明适用场景、使用方法、最小示例和结果检查。文档中的命令名称和返回格式是公开接口，示例中的 DUT 层次路径、地址和端口应替换为工程实际值。

::: note
建议先完成第 1～4 章的最小路径，再启用 TCP、CPU mailbox 或动态插件。外部 UVM agent、VCS、许可证和 RTL 不属于 AIP Core 的交付范围。
:::

## 第 1 章：认识 AIP Core

### 本章目标

完成本章后，读者应能选择合适的控制入口，判断功能边界，并完成一次最小连通性检查。

### 能力总览

AIP Core 面向 UVM 仿真环境的运行期控制，将命令注册、结果回显、并发执行、sequence 调度、DUT 后门操作、CPU firmware 通信以及 Tcl/TCP 外部控制统一起来。

| 能力域 | 支持内容 | 典型使用者 |
| --- | --- | --- |
| 命令控制 | 命令注册、key=value 参数、状态和结果、软错误 | test、sequence、Tcl、外部脚本 |
| 并发调度 | fork、join、join_any、join_none、cseq、creg | 总线验证、压力场景 |
| DUT 调试 | force、force-time、deposit、get、release、readmemh/readmemb | UCLI、TCP 客户端 |
| CPU 协同 | mailbox、同步/异步、IRQ/MSIP/PLIC、firmware loop | CPU/SoC 验证 |
| 运行辅助 | 时钟、时间、日志、ECC/parity、checkpoint、watchdog | 回归和故障定位 |

### 功能边界

AIP Core 不是 RTL 模拟器、许可证服务器、UVM agent、总线 driver、集群调度器或 Tcl 独立运行时。VCS、UVM、Verdi、许可证、目标 CPU IP、工程 RTL 和网络安全策略由集成环境提供。

### 使用前提

- Linux x86-64 主机，并具备可用的 VCS 与许可证。
- UVM 环境已有可以独立运行的基础 test 和总线 agent。
- 仿真统一使用 -timescale=1ns/1ps。
- 启用 TCP 时准备可监听端口；构建发布库时准备 gcc 或 clang。

### 最小连通性检查

```sh
make -C dist all
make -C dist test
```

第一条命令构建发布目录中的库和客户端，第二条命令检查发布契约。具备 VCS 的主机还应执行 Tcl/UCLI smoke：

```sh
make -C dist test-ucli-tcl
```

### 入口选择

| 目标 | 建议入口 | 特点 |
| --- | --- | --- |
| 自动化回归 | SV 命令 | 不需要外部进程，适合 test 和 sequence |
| 交互调试 | Tcl/UCLI | 适合断点、波形和 DUT 后门操作 |
| 外部工具联动 | TCP | 语言无关，可由 Python、C 或 CI 客户端调用 |
| CPU firmware 验证 | CPU mailbox | 观察命令协议、响应和中断唤醒 |

### 交付前检查

- 已选择本次使用的入口，并确认其依赖。
- 已确认 timescale、VCS 访问能力和许可证。
- 已记录最小命令的返回值、仿真时间和日志。

## 第 2 章：构建运行环境

### 本章目标

在 Linux x86-64 上构建库和客户端，确认发布产物完整，并能在更换编译器后复现构建。

### 发布目录

默认发布内容如下；`dist` 提供可交付的运行库、客户端和构建入口。

| 路径 | 作用 |
| --- | --- |
| dist/lib/libaip_soload.so | 运行期加载 C 命令插件 |
| dist/lib/libaip_socket_dpi.so | TCP socket DPI 运行库 |
| dist/bin/aip-client | 交互式 TCP 客户端 |
| dist/include/aip_plugin.h | 插件 ABI 头文件 |
| dist/lib/libaip_tcl_bridge.so | Tcl 命令实现的 UCLI 扩展库，经 dist/aip_init_so.tcl 加载（仅 VCS UCLI） |

### 默认构建

```sh
make -C dist clean
make -C dist all CC=gcc CFLAGS="-O2 -g"
```

all 构建三个发布库（含 `libaip_tcl_bridge.so`）、客户端和头文件。Tcl 侧二选一：
`source dist/aip_init.tcl`（文本入口）或 `source dist/aip_init_so.tcl`（二进制入口，
仅 VCS UCLI）。两者提供相同的公开命令；同一会话只选择一个入口。

### 更换编译器或系统

只需替换编译器、头文件和库路径后重新执行 Makefile。Makefile 默认检查目标架构并拒绝非 x86-64，以免产生不能被目标仿真进程加载的库。

```sh
make -C dist all CC=clang CFLAGS="-O2 -g" \
  CPPFLAGS="-I./include" LDFLAGS="-L./lib"
```

### 结果检查

```sh
file dist/lib/*.so dist/bin/aip-client
dist/bin/aip-client --help
make -C dist test
```

应看到 Linux x86-64 目标、客户端帮助信息和 DIST_MAKEFILE_PASS。若出现 undefined symbol，先确认库类型、编译器 ABI 和加载时机。

### 构建故障排查

- 架构不匹配：在目标 x86-64 主机重新构建，不能直接复制其他架构的 .so。
- 找不到头文件或库：检查 CPPFLAGS、LDFLAGS 和运行时库搜索路径。
- Tcl bridge 构建失败：确认编译器、动态库工具链和目标架构可用。
- 客户端无法启动：先执行 --help，再检查动态依赖和执行权限。

## 第 3 章：接入 UVM 仿真

### 本章目标

在已有 UVM 环境中启用统一命令和 bridge，不修改外部 agent 的 driver、sequencer 或 scoreboard 实现。

### 接入步骤

| 步骤 | 操作 | 完成标准 |
| --- | --- | --- |
| 1 | 将 AIP Core 的公共 SV 文件加入编译清单 | 类型和宏可见 |
| 2 | 统一指定 -timescale=1ns/1ps | 延时和时钟单位一致 |
| 3 | 按需要创建 Tcl、TCP 或 CPU bridge | 仿真启动后 bridge ready |
| 4 | 在 test 或环境初始化阶段注册业务命令 | 命令可被 aip_cmd 查询 |
| 5 | 先执行 socket_ping 或简单读命令 | 返回值和日志一致 |
| 6 | 最后调用 end_test | UVM 正常完成 report 和 finish |

### 编译与启动约定

AIP Core 的 SV 文件应在使用它们的 test、sequence 和 bridge 之前编译。C socket 库通过 VCS 的 DPI/链接选项加入仿真；普通 C 命令插件在仿真进程内按插件 ABI 运行期加载。原生 UCLI PLI 的链接方式由 VCS 决定，不能与普通业务 .so 混用。

### 多入口集成

同一个环境可以同时启用 SV、Tcl/UCLI 和 TCP；三者共享命令定义、参数解析和 OK/ERROR 语义。建议先仅启用 SV 验证基础 test，再加入 Tcl，最后开放 TCP 端口。

### 常见接入错误

- 编译顺序错误：出现重复类型、命令表为空或时钟类型不可见。
- timescale 缺失：延时、超时和时钟周期与预期不符。
- 后门访问失败：检查 VCS debug/ACC、层次路径和设计优化设置。
- bridge 未 ready：确认创建对象、端口和启动顺序，并查看日志。

## 第 4 章：启用 Tcl/UCLI 操作

### 本章目标

使用一个初始化入口加载公开 Tcl 命令，执行带返回值的操作，并以可追溯方式结束仿真。

### 初始化与启动

在 UCLI 中 source `aip_init.tcl`；该入口按固定顺序加载公开能力，重复 source 是幂等的。
用户脚本不需要逐个加载组成文件，也不需要设置可选搜索目录；缺少必需文件时初始化直接报错。

```tcl
source ./aip_init.tcl
set r [aip_send_cmd "socket_ping"]
puts $r
end_test drain=500
# drain/idle 等待结束后自动释放业务资源
end_test idle=1us cmd=vio_release
# 多个命令按出现顺序执行
end_test idle=1us cmd=vio_stop cmd=vio_release
```

`end_test` 的 `cmd=` 清理命令在等待阶段完成后同步执行。需要命令列表时，
可用大括号保护分号：`aip_send_cmd {end_test {cmd=vio_stop;vio_release}}`。
清理命令失败不会跳过后续命令，但会让 `end_test` 返回失败状态；不能在清理阶段
嵌套 `end_test`、`fork` 或插件装载/卸载命令。

典型 VCS 启动方式：

```sh
./simv -ucli -do aip_init.tcl
```

也可以在已有 UCLI 会话中执行 source /path/to/aip_init.tcl。路径应指向工程中的实际初始化文件。

### 支持的 Tcl 操作

| 类别 | 能力 | 示例 |
| --- | --- | --- |
| 命令 | 调用已注册命令并取得结果 | aip_send_cmd "reg_read addr=0x1000" |
| 流程 | run、等待、超时、watchdog、end_test | end_test drain=500 |
| DUT | force、force-time、deposit、get、release、readmemh/readmemb | dut_force path=tb.dut.sig value=1 |
| 断点 | 生成、恢复和检查快照 | aip_checkpoint_gen base |
| 参数 | 读取 plusarg、运行期覆盖 | get_param name=UVM_TESTNAME |

### 带返回值和错误处理

```tcl
set r [aip_send_cmd "dut_get path=tb.dut.data"]
if {[string match "OK:*" $r]} {
    puts "read result: $r"
} else {
    puts stderr "command failed: $r"
}
```

未知命令、非法参数或 DUT 路径错误返回 ERROR。外部 Tcl 控制路径使用软错误，不应因为用户拼写错误触发 $fatal；脚本应检查返回前缀并决定重试或结束。

### Tcl 操作检查

- socket_ping 返回 OK: pong。
- 业务命令的结果可以保存到 Tcl 变量。
- force、get、release 的结果与波形一致。
- 脚本最后显式执行 end_test，而不是依赖客户端断开。

# 第二部分：日常操作

## 第 5 章：统一命令系统

### 本章目标

理解命令输入、执行、结果和错误的统一语义，并为业务选择普通命令、sequence 命令或组合命令。

### 命令生命周期

用户输入命令后，AIP Core 查找命令、解析 key=value 参数、执行 handler 或 sequence、保存状态和结果，再由 SV、Tcl、TCP 或 C 客户端回显。命令名在同一仿真中应唯一。

| 阶段 | 用户可观察内容 | 使用建议 |
| --- | --- | --- |
| 输入 | 命令名和键值参数 | 使用稳定、可脚本解析的格式 |
| 执行 | 同步或异步业务动作 | 长操作提供超时或进度 |
| 结果 | OK/ERROR、数据和说明 | 返回短而稳定的字符串 |
| 收尾 | 日志、状态和结束动作 | 保存来源与仿真时间 |

### 注册约定

注册命令时应明确命令名、参数名、输入类型、结果格式和失败原因。handler 负责把可恢复失败写入 status/result，不要用 $fatal 代替协议错误。

### 最小示例

```text
socket_ping
OK: pong
dut_get path=tb.dut.data
OK: value=0x00000010
```

### 参数约定

- 整数支持十进制、0x 十六进制和带宽度的 SystemVerilog 字面量。
- 路径包含方括号时，在 Tcl 中使用花括号，例如 {tb.dut.mem[3]}。
- 结果字符串包含关键数据和状态，不依赖终端颜色或人类提示语。

### 未知命令策略

TCP 来源使用 SRC_SOCKET。未知命令返回 ERROR: Unknown command: <name>，仿真继续运行；Tcl 也采用软错误。需要严格失败语义时，应由调用方明确选择相应调用入口。

### 单条命令的等待方式

注册的 task/sequence 默认同步执行；在命令末尾加入 `wait=0` 可只等待“已接受并启动”的确认，
随后立即返回，`wait=1`（默认）则等待本次 task/sequence 完成。该参数由 AIP 调度层处理，
用户 sequence 不需要增加同名业务参数。

```text
link_up wait=0                 # 启动建链，后续命令可以继续
ep_config bdf=0x0100 wait=1    # 等待配置操作完成
```

`wait=0` 的成功只表示启动成功，不代表链路已经进入 L0 或业务事务已经完成；后台结果通过日志、
状态命令或业务检查器确认。后台任务不会覆盖后续命令的返回值。CPU mailbox 命令仍使用自身的
`async=1` 协议，不与 `wait` 混用。不可后台化的控制命令会返回明确错误。

## 第 6 章：fork/join 与 sequence 调度

### 本章目标

让多个命令并行执行，并在当前总线 transaction 完成后插入外部 sequence；C 命令完成后，原有 SV sequence 从原位置继续。

### fork/join 模式

```text
fork bus_read addr=0x1000, bus_read addr=0x2000 join
fork bus_read addr=0x1000, socket_ping join_any
fork bus_read addr=0x1000, bus_write addr=0x2000 data=0x55 join_none
fork bus_read addr=0x1000, bus_write addr=0x2000 data=0x55 join_any disable_remaining=1
```

| 模式 | 返回时机 | 适用场景 |
| --- | --- | --- |
| join | 所有子命令完成 | 需要完整聚合结果 |
| join_any | 任意子命令完成 | 竞速、首个响应或超时 |
| join_none | 启动后立即返回 | 后台监控、非阻塞操作 |
| disable_remaining=1 | join_any 返回并取消未完成项 | 防止后台事务继续影响 DUT |

每个子命令都有独立的 status、result 和 msg；聚合结果携带子命令摘要，客户端应逐项检查而不是只看顶层状态。

### cseq 与 creg

aip_cmd_cseq 用于 burst、连续读写或需要连续占用 sequencer 的操作；aip_cmd_creg 用于单个寄存器 transaction。两者都在当前 transaction 完成后获得控制，完成后释放，不需要修改外部 agent。

```text
bus_burst count=3
reg_read addr=0x1000
```

期望顺序是：当前 SV transaction 完成 → C sequence 执行 → SV sequence 恢复。cseq 可连续抢占多个 transaction，creg 只抢占一个 transaction。

### 调度检查

- 记录 SV transaction 的完成时间。
- 记录 C sequence 的开始和结束时间。
- 确认 SV sequence 在 C 操作后从原位置继续。
- 不要在业务 driver 内部再次 grab；仲裁由 cseq/creg 入口负责。

## 第 7 章：DUT 信号控制

### 本章目标

通过受控命令修改或读取 DUT 信号；已认证的 TCP Tcl 直通只应在受信任的调试环境开启。

### 命令行为

| 命令 | 行为 | 典型场景 |
| --- | --- | --- |
| dut_force | 持续强制一个信号值 | 模拟异常输入或锁定状态 |
| dut_force_time | 强制指定时间，随后自动 release 并回读 | 脉冲、毛刺和时序窗口 |
| dut_deposit | 写入一次值，不保持强制 | 初始化或一次性注入 |
| dut_readmemh / dut_readmemb | 从 offset 开始向动态层次 memory 装载 hex/bin 文件；width 默认 8 bit，可指定任意有效 bit 宽度 | 固件、表项或初始化镜像装载 |
| dut_get | 读取当前 HDL 值 | 检查状态和结果 |
| dut_release | 解除 force | 恢复正常驱动 |

### 典型用法

```text
dut_force path=tb.dut.valid value=1
dut_force_time path=tb.dut.ready value=0 time=100ns
dut_deposit path=tb.dut.data value=32'hdead_beef
dut_readmemh file=firmware.hex path=tb.dut.ram offset=0x100 width=32
dut_get path=tb.dut.data
dut_release path=tb.dut.valid
```

### readmem 文件格式与位宽

`dut_readmemh` 和 `dut_readmemb` 读取的是文本文件，不是原始二进制文件。前三个
参数依次为输入文件、DUT memory 的层次路径（不带元素下标）和起始偏移；可选
`width` 表示每个数据 token 的有效 bit 宽度，默认值为 8。宽度可以是从 1 到
`uvm_hdl_data_t` 最大宽度的任意正整数，不要求按 byte 或十六进制位对齐。

每个数据 token 写入一个 `path[address]` 元素。超过 `width` 的前导零可以省略或
保留，但会被截掉的 1、x 或 z 会导致整份文件预检失败，不会静默截断。

十六进制文件示例：

```text
0a 1b                  // offset、offset+1
/* 支持块注释 */
@4 fe                  // offset+4
```

```text
dut_readmemh file=data.hex path=tb.dut.ram offset=2
```

上述命令依次写入 `tb.dut.ram[2]=8'h0a`、`ram[3]=8'h1b` 和
`ram[6]=8'hfe`。`@ADDR` 在 hex 和 bin 文件中都按十六进制解析，并与命令的
`offset` 相加。

非字节对齐示例：

```text
1abc
```

```text
dut_readmemh file=data13.hex path=tb.dut.ram offset=7 width=13
```

二进制文本文件示例：

```text
0000_0011 1111_0000
@4 1_0000_0011        # 支持井号行尾注释
```

```text
dut_readmemb file=data.bin path=tb.dut.ram offset=8 width=9
```

数据可由空格、Tab 或换行分隔，一行可以包含多个 token；支持下划线、可选的
`0x`/`0b` 前缀、`//`/`/* ... */`/`#` 注释以及 x、z、? 四态数字。文件在首次
HDL deposit 前完整预检，因此格式或位宽错误不会造成部分装载；若实际 deposit
在中途因 DUT 路径、范围或 debug access 失败，已经成功写入的元素无法回滚。

### force 与 force-time

dut_force 在显式 release 前一直覆盖 DUT 驱动；dut_force_time 在指定仿真时间到达后自动解除，并可返回解除后的读回值。需要一次性写入时使用 dut_deposit，不要用 force 模拟 deposit。

### 错误和安全边界

非法路径、非法数值、非法时间和释放失败返回 ERROR。数值解析失败不会默认为 0。HDL 路径访问仍受 VCS debug/ACC 和设计优化影响；生产回归应限制可操作路径。

## 第 8 章：结果、状态与退出

### 本章目标

让客户端和脚本可靠判断命令是否成功，处理同步/异步差异，并有序结束 UVM 仿真。

### 返回格式

| 状态 | 格式 | 处理建议 |
| --- | --- | --- |
| 成功 | OK: <result> | 解析 result，继续流程 |
| 失败 | ERROR: <reason> | 记录 reason，决定重试或结束 |
| 异步启动 | OK: accepted 或 job id | 后续查询状态 |
| fork 聚合 | OK/ERROR 加子命令摘要 | 检查每个子命令 |

### 同步和异步

同步命令在 handler 或 sequence 完成后返回业务结果；异步命令只确认已接受，调用方必须通过状态命令、job id 或日志确认最终结果。TCP 客户端断开不是可靠的结束条件。

### 结束仿真

脚本最后调用 end_test，可等待 drain、idle 或命名 checker，然后让 UVM 完成 extract、check、report 和 finish。

```text
cpu_poll addr=0x40000000 mask=0x1 expect=0x1 timeout=10us
OK: data=0x00000001 iter=8

cpu_poll addr=0x40000000 mask=0x1 expect=0x1 timeout=1us
ERROR: data=0x00000000 iter=10000
```

# 第三部分：桥接与专项能力

## 第 9 章：TCP 远程控制

### 本章目标

启动 TCP bridge，使用官方客户端或外部脚本发送命令，验证带返回、fork 和未知命令软错误。

### 服务端启动

在仿真环境创建 bridge；地址和端口应与客户端一致。创建时不监听，文件输入行为保留。

```systemverilog
`aip_tcl_bridge_create(tcl)                     // 已按前章配置 Tcl bridge
`aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "")  // 监听时动态分配端口
```

经 Tcl bridge 加载命令后，调用自动注册的无参 `<实例名>_listen`：

```tcl
source <aip_core>/dist/aip_init_so.tcl
c_bridge_listen
```

快照应在首次监听前生成。新的 simv 进程续跑时依次执行 `source`、`aip_restore`、再次 `source`、
`c_bridge_listen`；已经监听过的同一进程回滚早期快照、恢复 live socket 均不在支持范围，
OS fd 不随状态回滚。升级后执行 `make -C dist all`，
重新编译 simv 并重新生成快照。

### 客户端启动

```sh
./dist/bin/aip-client 127.0.0.1 <actual_port> --key <auth_key>
```

bridge 启动时会在仿真 log 打印本次实例的 32 位 `auth_key`；客户端也支持
`AIP_AUTH_KEY`，不传 `--key` 时会交互询问。认证成功后，未注册的 AIP 命令会直接
作为一行 Tcl/UCLI 命令执行。

多个仿真实例可以使用同一个 IP；将端口设为 `0` 后，内核会在 `bind()` 时选择空闲
临时端口，bridge 会在 log 中打印 `Listening on <ip>:<actual_port>`。固定端口冲突时
监听命令会返回 `ERROR: socket init failed`，不会自动改端口；排除冲突后可重试。

客户端按行读取输入，每行命令以换行触发一次执行；脚本客户端也应按行读取响应并检查 OK 或 ERROR 前缀。

### 认证、Tcl 直通与信号观察

bridge 启动时会在仿真日志打印本次实例的随机 `auth_key` 和实际端口。客户端使用
`--key` 或 `AIP_AUTH_KEY` 完成认证；认证成功后，先按 AIP 注册命令处理，未注册的单行命令
再交给当前 UCLI/Tcl 会话。

```text
aip-client 127.0.0.1 <actual_port> --key <auth_key>
aip_watch tb.dut.link_up 1 stop=0
aip_watch_status 1
set ::aip_echo 0
```

`aip_watch path expected stop=0|1` 注册一次性观察并立即返回 ID。`stop=0` 命中时只记录
`[AIP_WATCH]` 通知并继续仿真；`stop=1` 命中后暂停在 UCLI stop 点，需要在本地 UCLI 输入
原生 `resume`。观察命令本身已经是立即返回的后台注册，不接受 `wait=0`；追加该参数会得到
usage 错误，而不是 AIP 命令超时。可用 `aip_watch_status` 查询；
`aip_watch_cancel <id>` 取消单个观察，省略 ID 时取消全部仍处于 `armed` 状态的观察。
当 Tcl 脚本正在执行 AIP 管理的 `run` 时，TCP 仍可注册 `aip_watch`；注册不会再因在途
`run` 返回 `AIP_CONTROL_BUSY`。该受控例外只安装观察条件，不允许借此执行 force/deposit
或其他仿真推进命令；`stop=1` 命中后仍需在本地 UCLI 输入 `resume`。

改变仿真时间的 `run`、`next`、`step`、`finish` 和 `resume` 等控制命令仍应在本地 UCLI
提示符执行；TCP 直通适合查询、DUT 控制、观察注册和其他不直接接管仿真控制权的 Tcl 命令。

### 交互示例

```text
> socket_ping
OK: pong
> dut_get path=tb.dut.data
OK: value=0x10
> fork bus_read addr=0x1000, bus_read addr=0x2000 join
OK: fork completed
```

### TCP 下的 fork 和返回

TCP 命令路径支持普通命令、fork、cseq 和 creg。fork 返回顶层状态及子命令摘要；cseq/creg 返回 sequence 的业务结果。命令仍按 transaction 边界调度，不会打断正在执行的普通总线 transaction。

### 未知命令验证

```text
> does_not_exist
ERROR: Unknown command: does_not_exist
> socket_ping
OK: pong
```

第二条命令仍成功，证明未知命令使用 SRC_SOCKET 软错误，没有触发 $fatal，仿真可以继续。

### 连接管理

| 现象 | 检查项 | 处理 |
| --- | --- | --- |
| 连接拒绝 | bridge 是否 start、IP/端口是否一致 | 先看仿真日志，再检查端口 |
| 响应不完整 | 客户端是否等待换行 | 使用官方客户端或按行读取 |
| 短暂断开 | 服务端生命周期和网络策略 | 客户端可重连，但要重新确认状态 |
| 多客户端竞争 | 是否访问共享资源 | 对非幂等操作增加业务级互斥 |

## 第 10 章：CPU mailbox 与 firmware

### 本章目标

通过 mailbox 在 SV 与 firmware 之间传递命令和结果，并选择同步、异步、IRQ、MSIP 或 PLIC 唤醒方式。

### 支持能力

| 能力 | 说明 | 适用场景 |
| --- | --- | --- |
| 同步命令 | 发送后等待响应 | 读写、轮询和依赖返回值的流程 |
| 异步命令 | 发送后立即继续 | 后台事件和并行工作 |
| IRQ 唤醒 | 外部中断通知 CPU | 常规 mailbox 中断验证 |
| MSIP 唤醒 | 软件中断唤醒 | 无外部 PLIC 时的轻量路径 |
| PLIC 唤醒 | 平台中断控制器唤醒 | SoC 中断链路验证 |
| 退出握手 | SV/C 双向结束请求 | 正常关闭 firmware loop |

### 标准流程

1. 配置 mailbox 基地址和内存访问方式。
2. 选择同步或异步模式。
3. 按需启用 IRQ、MSIP 或 PLIC。
4. 发送 cpu_read32 或 cpu_write32。
5. 等待 rsp_status 和 rsp_data。
6. 在 Tcl、SV 或 TCP 中回显结果。

```text
cpu_write32 addr=0x80001000 data=0xdeadbeef
OK: write complete
cpu_read32 addr=0x80001000
OK: data=0xdeadbeef
```

### 固件启动模式

| 模式 | 特点 | 用途 |
| --- | --- | --- |
| ROM XIP | 代码在 ROM 直接执行 | 生产式启动链路 |
| RAM-only | 后门加载到 RAM 后执行 | 仿真提速 |
| ROM boot + RAM | ROM 拷贝到 RAM 后跳转 | 接近真实启动 |

### 验证边界

协议测试和 fake memory 不能替代真实 CPU RTL、cache、总线时序和中断链路验证。交付时应同时保存 firmware 镜像、mailbox 配置、响应记录和中断日志。

## 第 11 章：内存、时钟、参数与日志

### 本章目标

使用运行辅助能力构造可复现的激励、故障注入与调试流程。

### 内存与校验

支持多区域 RAM/ROM、RAM72、interleaved 数据组织，以及 parity、SECDED、CRC8 校验、错误注入和读取验证。firmware loader 可将镜像加载到指定区域。

| 操作 | 用途 | 检查结果 |
| --- | --- | --- |
| 配置 region | 建立 CPU 地址到模型区域的映射 | 地址范围和容量正确 |
| 写入/读取 | 验证数据通路 | 读回数据一致 |
| 加载镜像 | 将 hex/packed40 固件写入已配置区域 | 文件、起始地址和格式有效 |
| 注入错误 | 测试校验和错误上报 | 状态位和日志出现预期错误 |
| 加载 firmware | 准备 CPU 执行镜像 | 入口和 mailbox 可访问 |

```text
mem_config region=ram0 base=0x80000000 size=64K ecc=secded
load_image file=boot.hex start=0x80000000 format=hex
mem_write addr=0x80000000 data=0x12345678
mem_read addr=0x80000000
mem_inject addr=0x80000000 bit=3
```

### 时间与时钟

时间参数接受 fs、ps、ns、us、ms、s。时钟辅助支持周期、占空比、启动延时、复位配合、PLL 倍频/分频、锁定时间和 RMS 抖动；仿真必须指定 1ns/1ps timescale。

```systemverilog
aip_time::delay_ns(100.0);
```

```tcl
seq_wait time=10us
```

检查波形中的周期、相位和复位关系，避免不同模块混用不一致的 timescale。

### 命令行参数

支持整数、字符串、real、动态/固定数组、enum、struct、范围、候选列表、权重和 inc/dec 序列。路径化参数优先于同名无路径参数，显式运行期覆盖优先于默认值。

```sh
./simv "+dut.count=[1:3]" "+dut.mode=FAST" "+dut.arr=[-3,-2,-1]"
```

### 日志与可追溯

关键命令、输入参数、返回值、仿真时间和客户端来源应进入日志。回归结束时至少保存命令记录、UVM 报告和失败原因；禁止把 token、密码或许可证内容写入日志。

### 输出开关

在 Tcl/UCLI 中使用 `aip_output_help` 查看当前版本支持的输出控制、默认值和边界；该帮助
命令不推进仿真，即使已经关闭普通回显也会显示。

```tcl
aip_output_help
set ::aip_echo 0       ;# 关闭 AIP 命令回显和普通辅助信息
set ::fv_verbose 0     ;# 仅保留 warning/error
utils_silent           ;# 关闭 UCLI 命令行回显
utils_loud             ;# 恢复 UCLI 命令行回显
```

显式 `puts` 以及 warning、error、fatal 诊断不会被普通静音开关隐藏。参数注册日志还可用
`set_cmdline_print enable=0|1 max_prints=N` 控制；解析错误不受该开关屏蔽。

## 第 12 章：动态库与插件

### 本章目标

区分 Socket 运行库、命令插件、Tcl 入口和原生 UCLI 扩展，掌握构建、加载和兼容性边界。

### 库类型与加载方式

| 类型 | 默认发布 | 使用方式 |
| --- | --- | --- |
| Socket DPI | 是 | 在 VCS 编译/链接阶段加入 libaip_socket_dpi.so |
| 命令插件 .so | 是 | 按 aip_plugin.h ABI 编译，运行期 load |
| Tcl bridge .so | 是 | 通过 `aip_init_so.tcl` 在 VCS UCLI 中加载 |
| Tcl 公开脚本 | 是 | 通过 aip_init.tcl source |
| 原生 UCLI PLI | 否 | 按 VCS 的 PLI 注册和链接规则加入 |

### 命令插件流程

```text
1. 使用 dist/include/aip_plugin.h
2. 实现初始化函数和命令处理函数
3. 编译为 x86-64 .so
4. 在仿真中按插件接口 load
5. 执行命令并检查 OK/ERROR
6. 按需 unload
```

插件由仿真进程加载，架构、C ABI、链接选项和依赖库必须兼容。普通命令插件和原生 UCLI
扩展使用不同的集成方式，不能把一种库当作另一种库加载。

### 验证插件

```sh
make test_soload
```

预期加载、执行、卸载和错误路径均通过。若出现动态符号错误，先确认目标架构、依赖库和
加载方式与库类型一致；原生 UCLI 扩展应按目标仿真器的集成要求接入。

# 第四部分：验证与运维

## 第 13 章：测试回归

### 本章目标

按层次验证 AIP Core，避免把“库生成成功”误认为“仿真链路成功”。

### 验证层次

| 层次 | 验证内容 | 成功标准 |
| --- | --- | --- |
| 基础 | 参数、时间、日志、统一入口 | PASS 且无编译顺序错误 |
| 桥接 | Tcl、TCP、DUT、CPU | 结果正确，错误可控 |
| 调度 | fork、cseq、creg、watchdog | 顺序和恢复符合预期 |
| 发布 | 动态库、客户端、bootstrap | 构建和 smoke 均通过 |
| 环境 | VCS、许可证、真实 RTL/CPU | 在批准主机完成实机验证 |

### 推荐命令

```sh
make test_core_package
make test_c_bridge_socket
make test_c_bridge_checkpoint
make test_cseq_arbitration
make test_dut_control
make test_soload
make -C dist test-ucli-tcl
```

### TCP 必测三件事

1. 合法命令返回 OK。
2. 未知命令返回 ERROR，不触发 $fatal。
3. 未知命令之后继续发送合法命令，仿真仍能响应。

### 已知未覆盖项

spec-driven 用例和 peakrdl attach 依赖工作树之外的输入；原生 UCLI PLI smoke 受 VCS 符号导出影响。这些项目应记录为 NOT RUN 或环境相关失败，不应标记为通过。

## 第 14 章：断点、watchdog 与恢复

### 本章目标

在长回归或故障定位中保存可恢复状态，识别命令停滞，并避免旧快照造成假死。

### 断点续跑

可以生成 base 快照、记录元数据、检查可执行文件是否变化，并在独立进程中恢复。更换 simv、编译选项或关键环境后必须重新生成快照。

### watchdog

命令或 sequence 长时间没有完成时，watchdog 报告停滞并清理活动 sequence。长 task 应提供进度、超时或可取消路径。

### 卡住问题处理顺序

- 使用全新的 simv 名称和构建目录。
- save/restore 回归增加 -no_save。
- 确认 bridge 是否 idle、活动 sequence 数量和客户端连接。
- 最后检查业务命令本身。

旧 simv 的 save/restore 重执行问题与 TCP、SRC_SOCKET 或未知命令软错误无关。

## 第 15 章：完整集成场景

### 场景目标

建立一个同时支持 UVM sequence、Tcl/UCLI 和 TCP 的环境：SV sequence 发起普通总线事务，外部命令在 transaction 边界插入 cseq/creg，命令返回后 SV 继续。

### 准备阶段

- UVM agent 能独立完成基础读写。
- 公共 SV 文件和 bridge 已按工程编译顺序加入。
- 统一使用 1ns/1ps timescale。
- 已构建 socket 库和客户端，或准备按 Makefile 构建。
- 已选定 TCP 监听地址和端口。

### 启动顺序

| 顺序 | 动作 | 观察点 |
| --- | --- | --- |
| 1 | 编译并启动仿真 | 无致命错误，UVM 开始运行 |
| 2 | 启动 Tcl/TCP bridge | 日志显示 bridge ready |
| 3 | 在 UCLI source 初始化入口 | 返回成功 |
| 4 | 客户端发送 ping/read | 得到 OK 和业务数据 |
| 5 | 发送 cseq/creg | 看到 transaction 边界和 SV 恢复 |
| 6 | 执行 DUT 控制 | force/get/release 一致 |
| 7 | end_test | UVM 正常 report/finish |

### 示例交互

```text
> socket_ping
OK: pong
> reg_read addr=0x1000
OK: data=0x00000001
> bus_burst count=3
OK: completed=3
> dut_force path=tb.dut.ready value=0
OK: forced tb.dut.ready=0
> dut_release path=tb.dut.ready
OK: released
```

### 交付证据

保存编译命令、仿真日志、TCP 收发记录、sequence 顺序记录和最终 UVM 报告。客户端收到 OK 不能替代仿真内部 transaction 已完成的证据。

## 第 16 章：常见问题与验收

### 常见问题

| 现象 | 优先检查 | 正确处理 |
| --- | --- | --- |
| Tcl 初始化失败 | 入口路径、版本和文件可读性 | 使用稳定绝对路径重新 source |
| 未知 TCP 命令终止仿真 | 是否为最新 bridge、是否 clean 编译 | 使用 SRC_SOCKET 软错误路径 |
| 返回值为空 | 命令结果、换行和同步/异步模式 | 先用 socket_ping，再检查业务返回 |
| force/deposit 失败 | HDL 路径、debug/ACC、方括号转义 | 修正路径或编译访问能力 |
| 动态库 undefined symbol | 库类型和加载时机 | 区分普通 .so 与原生 UCLI PLI |
| 仿真卡住 | 干净构建目录、快照和活动 sequence | 换目录、-no_save、检查 watchdog |

### 功能边界

AIP Core 保证公开命令和 bridge 行为；总线时序、UVM agent、真实 CPU RTL、VCS 许可证、网络安全、集群调度和跨平台 ABI 需要由集成环境分别验证。

### 最终验收清单

- 至少两种入口完成连通性验证。
- 合法命令 OK、未知命令 ERROR 且仿真继续。
- fork/join、cseq/creg 有 transaction 顺序证据。
- DUT 五类命令按需验证。
- CPU mailbox 同步/异步路径按需验证。
- 动态库使用兼容架构和正确链接方式。
- 回归使用干净构建目录，已知限制单独记录。
- end_test 后 UVM_ERROR/UVM_FATAL 为 0，或失败原因明确。

# 第五部分：参考

## 第 17 章：命令与参数速查

### 控制入口

| 入口/操作 | 用途 | 最小示例 | 成功信号 |
| --- | --- | --- | --- |
| SV 调用 | 测试代码直接执行命令 | exec("socket_ping") | status=0 |
| Tcl/UCLI | 脚本或交互式调试 | aip_send_cmd "socket_ping" | OK: pong |
| TCP 客户端 | 外部程序远程控制 | aip-client 127.0.0.1 <actual_port> --key <auth_key> | 认证后按行返回 OK/ERROR |
| 文件命令 | 兼容已有批处理 | commands.txt 逐行写命令 | 逐行执行并记录 |
| CPU mailbox | 驱动 firmware 命令 | cpu_read32 addr=0x80000000 | rsp_status=0 |

### 常用流程命令

| 命令 | 常用参数 | 用途 | 返回示例 |
| --- | --- | --- | --- |
| aip_send_cmd | 命令字符串、超时 | 发送并等待结果 | OK: value=0x10 |
| get_param | name | 读取 plusarg 或运行参数 | OK: UVM_TESTNAME=smoke |
| seq_wait | time/count/timeout | 等待 sequence 或时间 | OK: waited=10us |
| kill_seq | name | 停止活动 sequence | OK: killed=1 |
| end_test | drain、idle、timeout、wait_done | 有序结束 UVM | OK: end_test |
| aip_checkpoint_gen | name、目录 | 生成断点及元数据 | OK: saved |
| aip_restore | name、timeout | 恢复断点 | OK: restored |

### DUT 命令参数

| 命令 | 必填参数 | 结果 |
| --- | --- | --- |
| dut_force | path、value | 持续强制，返回 forced |
| dut_force_time | path、value、time | 到时 release 并回读 |
| dut_deposit | path、value | 一次性写入 |
| dut_get | path | 返回当前值 |
| dut_release | path | 解除 force |

### fork、cseq、creg 语法

| 形式 | 语法要点 | 返回时机 |
| --- | --- | --- |
| fork/join | 子命令以逗号分隔 | 全部完成 |
| fork/join_any | 任一完成，可选 disable_remaining=1 | 首个完成 |
| fork/join_none | 启动即返回 | 不等待 |
| aip_cmd_cseq | 命令名加 sequence 参数 | 连续事务完成 |
| aip_cmd_creg | 命令名加单次读写参数 | 单事务完成 |

```text
fork bus_read addr=0x1000, bus_read addr=0x2000 join
bus_burst count=3
reg_read addr=0x1000
```

### TCP 客户端与服务参数

| 参数 | 默认/示例 | 说明 |
| --- | --- | --- |
| server_ip | 127.0.0.1 | 服务地址，位置参数 1 |
| port | 8888；`0` 为动态端口 | 服务端口，位置参数 2；实际端口以 bridge 启动 log 为准 |
| 命令行输入 | 每行一条 | 换行触发执行 |
| OK/ERROR | 文本前缀 | 脚本按前缀判断状态 |
| 重连 | 有限次数 | 只解决短断线，不替代状态确认 |
| 多客户端 | 可接入多个 | 非幂等操作需业务互斥 |

### 构建目标

| 目标 | 作用 | 默认 |
| --- | --- | --- |
| all | 构建运行库、客户端和 ABI 头文件 | 是 |
| libs | 只构建运行库 | 是（all 的一部分） |
| socket | 只构建 Socket DPI 库 | 否 |
| soload | 只构建命令插件加载库 | 否 |
| client | 只构建交互式客户端 | 否 |
| tcl | 构建 Tcl bridge 库 | 否 |
| test | 执行发布契约检查 | 否 |
| clean | 删除发布构建产物 | 否 |

### 返回码与错误处理

| 情况 | 返回 | 仿真是否继续 |
| --- | --- | --- |
| 合法命令 | OK: result | 是 |
| 业务失败 | ERROR: reason | 是 |
| TCP 未知命令 | ERROR: Unknown command | 是 |
| DUT 路径/数值错误 | ERROR: ... | 是 |
| 插件加载失败 | ERROR 和加载日志 | 是（加载命令失败） |
| 严格来源失败 | ERROR 或终止 | 取决于调用入口 |

### 交付前检查

- 目录字段已更新，章节可点击跳转。
- SV/Tcl/TCP 至少两种入口完成连通性验证。
- TCP 合法、未知、后续合法三种命令均有日志。
- cseq/creg 的 transaction 顺序和 SV 恢复有证据。
- 动态库在目标架构上构建并通过插件 smoke。

## 第 18 章：核心 SV 能力详解

### 本章目标

本章集中说明核心 SV 工具的用户可见行为。每节给出支持范围、输入约定、结果检查和最小示例，不要求阅读实现代码。

### 命令行参数解析

参数系统把仿真启动时的 plusarg 转换为强类型值，并提供默认值、路径化命名、随机候选和结构化参数。

| 类型 | 支持形式 | 示例 |
| --- | --- | --- |
| 整数 | 十进制、0x、带宽度、负数 | +dut.count=-10 |
| 字符串 | 普通字符串、候选 | +dut.mode=FAST |
| real | 小数、科学计数法、范围 | +clk.freq=156.25e6 |
| 数组 | 动态/固定、列表、嵌套容器 | +dut.arr=[-3,-2,-1] |
| enum | 按成员名称匹配，大小写不敏感 | +dut.speed=FAST |
| struct | 紧凑字段或点号字段 | +dut.cfg={addr=0x100,len=64} |

候选列表使用逗号或方括号；闭区间使用 [min:max]；权重使用 {value:=weight,...}；递增/递减使用 inc:start:end:step 或 dec:start:end:step。

```sh
./simv "+dut.count=[1:3]" "+dut.pick={0:=40,[1:3]:=60}" \
  "+dut.arr=[-3,-2,-1]" "+dut.seq=inc:0:8:2"
```

参数化名称优先于无路径同名名称；显式命令行值优先于默认值。格式错误、空元素、缺失闭括号和越界值应返回明确诊断，不会静默接受为 0。

### 日志与输出控制

日志能力提供 FATAL、ERROR、WARNING、INFO、DEBUG、TRACE 六级、仿真时间和可读格式。彩色显示只用于终端，脚本和回归应依赖文本等级和关键字。

| 等级 | 用途 | 建议内容 |
| --- | --- | --- |
| INFO | 正常流程和关键状态 | bridge ready、命令完成、加载成功 |
| WARN | 可恢复异常或降级 | 客户端重连、可选工具缺失 |
| ERROR | 当前操作失败 | 路径错误、命令失败、响应超时 |
| DEBUG/TRACE | 详细诊断 | 参数展开、队列和握手细节 |

aip_log::set_verbosity(level) 设置全局阈值；set_inst_verbosity 支持实例名和 *、? 通配符；set_time_unit 固定显示单位；get_count 和 summary 用于回归统计。FATAL 遵循 UVM report 流程结束，ERROR/WARNING 不会自动结束仿真。

### 字符串、数字和时间工具

字符串工具用于 trim、分割 key=value、大小写归一和安全拼接；数字工具解析十进制、十六进制、SV 带宽度字面量及有符号值；时间工具统一 fs/ps/ns/us/ms/s 并转换为仿真延时。

| 操作 | 支持内容 | 示例 |
| --- | --- | --- |
| 清理 | 去除首尾空白、判断空串 | aip_str::strip("  addr=0x10 ") |
| 分割 | 按第一个等号拆分键和值 | aip_str::split_pair("addr=0x10") |
| 数字 | 负数、十六进制、SV 字面量 | aip_str::str_to_num("-8'd10") |
| 时间 | 单位换算和浮点纳秒 | aip_time::parse_time_ns("2.5us") |

非法数字通过 width=0 与全 1 哨兵报告；调用方应返回 ERROR，不要默认为 0。aip_time::get_sim_time(unit) 返回指定单位的当前仿真时间，非法单位返回错误值。

### 时钟与延时

aip_time::delay_ns(real) 和 delay_ns_int(longint) 以纳秒延时并接受小数纳秒。aip_clk 支持频率、ppm、占空比、初始相位、PLL 倍频/分频、锁定时间和 RMS 抖动，并可在运行期 start、stop、rephase、update_ppm。

```systemverilog
real now_us = aip_time::get_sim_time("us");
aip_time::delay_ns(25.5);
```

时钟宏放在 module scope；使用前统一指定 1ns/1ps timescale，并在波形中检查周期和复位关系。

### ECC/parity 内存

先为区域配置数据宽度、校验模式（none、parity、secded、crc8）、粒度/极性、错误策略和 concat/split layout，再进行 word 或 block 读写。常用操作包括 write_word、read_word、check、inject_err、write_zero、write_incr、write_block、read_block、write_random 和 scrub。

```text
mem_config region=ram0 base=0x80000000 size=64K ecc=secded
mem_write addr=0x80000000 data=0x12345678
mem_inject addr=0x80000000 bit=3
mem_read addr=0x80000000
```

验证顺序建议为正常写读 → 单 bit 注入并确认可纠正 → 多 bit 注入并确认不可纠正 → 按需 scrub。未配置区域返回 no_config 或错误日志，不应继续假设数据有效。

### 命令注册与活动状态

aip_cmd 负责注册唯一命令名、解析参数、执行 task/sequence、保存 status/result，并向 SV、Tcl 或 TCP 回显。运行期可查询已注册命令、活动 sequence 数量和 bridge idle 状态，用于诊断“命令不存在”和“命令卡住”。

业务 handler 应把可恢复失败写入 result/status；TCP 未知命令使用 SRC_SOCKET 并返回 ERROR。需要并发时使用统一 fork 语法或 aip_cmd_cseq/aip_cmd_creg，不要让 driver 自行抢占。

### 核心组件集成边界

字符串、时间、时钟、参数、日志、命令和内存工具可以单独使用，也可以由 Tcl/TCP bridge 组合。更换 VCS 或编译器后，先执行参数/日志/时钟 smoke，再进行真实总线和 CPU 回归。

### 本章验收清单

- 负数、十六进制、数组、enum、struct 参数至少各验证一次。
- 范围、权重和 inc/dec 语法在目标 VCS 上通过。
- INFO/WARN/ERROR/DEBUG 日志可按开关控制。
- 时间和时钟波形与 timescale 一致。
- ECC/parity 正常读写和错误注入均有结果。
- 命令查询、活动状态和 watchdog 可用于故障定位。
