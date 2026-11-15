# firmware — CPU bridge command framework (XuanTie C908, RV64)

自包含的 CPU 固件: 实现 SV ↔ C mailbox 协议 (配合 `aip_cpu_bridge.sv`),
含示例 app、命令框架、XuanTie 启动/linker、三种 wake 模式构建。

## 布局

```
firmware/
├── Makefile          # 构建入口 (XuanTie); make poll|msip|plic|all|clean
├── app/              # 应用层 (用户改这里)
│   ├── main.c        # cmd_init → builtins → user_register → cmd_loop
│   ├── user_cmds.c   # 示例命令 my_add/my_square + user_register()
│   └── aip_chip.h    # ROM/RAM/MBOX/PLIC/CLINT 地址
├── core/             # 命令框架库
│   ├── aip_cmd.c .h        # 注册/分发/mailbox I/O/cmd_loop/builtins
│   ├── aip_cmd_msip.c      # MSIP 唤醒 (msip 模式): Mtspend_Handler + cmd_msip_init
│   ├── aip_cmd_c908.c .h   # PLIC 唤醒 (plic 模式): Mirq_Handler + cmd_irq_init
│   ├── handlers.c          # CSI runtime stub (SystemInit/pre_main/Default_Handler)
│   └── csi_config.h
├── arch/             # 架构相关
│   ├── startup.S            # XuanTie reset + __Vectors
│   └── linker.xuantie.ld    # ROM/XIP linker (BOOT=rom)
├── prebuilt/         # 预编译产物 (poll/msip/plic.{hex,elf,map})
└── tests/            # host gcc 单测 (parse/dispatch/protocol)
```

## 构建 (三种 wake 模式 = 三个指令)

```bash
make poll      # CPU 轮询 cmd_flag (无中断)        → build/poll.hex
make msip      # SV 后门 deposit CLINT MSIP0 唤醒   → build/msip.hex
make plic      # SV 后门 deposit PLIC IP(src48) 唤醒 → build/plic.hex
make all       # 三个都编
make clean
```

- **工具链**: 默认 `CROSS` = XuanTie 绝对路径 (避免 PATH 命中 /usr/bin 通用 gcc)。
  别的机器: `make plic CROSS=/path/to/riscv64-unknown-elf-`。
- **boot 模式**: `BOOT=rom` (默认, XIP)。`ram_copy`/`ram_jump` 为 Spec2,尚未实现
  (传 `BOOT=ram_*` 会 `$(error)`)。
- wake 模式与 SV 侧对应: poll=默认; msip=`aip_cpu_bridge::set_msip_path(...)`;
  plic=`aip_cpu_bridge::set_plic_path(path,48)`。详见 docs/superpowers/specs/2026-06-0{3,4}-*。

## Mailbox 协议 v2

| Offset | Field          | Owner  | Notes                                          |
|--------|----------------|--------|------------------------------------------------|
| +0x000 | cmd_flag       | SV→C   | 1=pending. C clears unconditionally on dispatch. |
| +0x004 | cmd_len        | SV     | bytes                                          |
| +0x008 | cmd_data[128]  | SV     | 1 char per 32-bit word                         |
| +0x208 | rsp_flag       | C→SV   |                                                |
| +0x20C | rsp_status     | C      | 0=ok, -1=error                                 |
| +0x210 | rsp_len        | C      |                                                |
| +0x214 | rsp_data[128]  | C      |                                                |
| +0x414 | async_flag     | SV     |                                                |
| +0x418 | exit_flag      | bidir  | 1=SV req, 2=C req                              |
| +0x41C | exit_code      | C      |                                                |
| +0x420 | irq_ack_flag   | C→SV   | ISR writes 1; SV drops IRQ + clears.           |

## 加命令

改 `app/user_cmds.c`:
```c
#include "aip_cmd.h"

static void do_my_cmd(const char *args) {
    int x = cmd_get_int(args, "x", 0);
    cmd_return("result=%d", x * 2);
}

void user_register(void) {
    cmd_register("my_cmd", do_my_cmd);
}
```
SV TB 加一行 passthrough: `` `aip_cmd_cpu(my_cmd) ``,然后重编固件。

## host 单测
```bash
make -C tests      # gcc 编 + 跑 parse/dispatch/protocol 单测
```
