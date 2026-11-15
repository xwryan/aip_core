//===========================================================
// AIP Core Package - 统一入口文件
// 用法：编译时只需引入此文件即可使用所有 aip_core 组件
//   vcs -sverilog -ntb_opts uvm +incdir+<aip_core_path> aip_core_pkg.sv ...
//===========================================================
`ifndef AIP_CORE_PKG_SV
`define AIP_CORE_PKG_SV

// Component include guards are compilation-unit global. A package-compatible
// component included first would create a second, independent $unit definition
// instead of the canonical aip_core_pkg definition. Reject that ordering.
// aip_clk.sv is the exception because its interface intentionally remains
// outside the package.
`ifdef AIP_LOG_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_STR_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_TIME_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_CMDLINE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_CPU_BRIDGE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_MEM_ECC_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_CPU_MEM_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_CMD_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SOLOAD_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_CPU_LOADER_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_C_BRIDGE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_TCL_BRIDGE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif

`ifdef AIP_CORE_PKG_PREINCLUDE_CONFLICT
// Deliberately undefined: force an analysis-time error even when the compiler
// selects an unrelated elaboration top with -top.
`AIP_CORE_PKG_PREINCLUDE_ERROR__MUST_INCLUDE_OR_COMPILE_AIP_CORE_PKG_SV_FIRST
`else

package aip_core_pkg;
import uvm_pkg::*;

// 日志系统（无外部依赖，最先 include，其他组件均可使用）
`include "aip_log.sv"

// 基础工具
`include "aip_str.sv"
`include "aip_time.sv"

// 命令行参数解析（依赖 aip_str, uvm_pkg）
`include "aip_cmdline.sv"

// CPU 桥接（必须在 aip_cmd 之前: aip_cmd::exec 引用 aip_cpu_bridge::send_cmd）
`include "aip_cpu_bridge.sv"

// Mem ECC (SV 版, 依赖 aip_cpu_bridge 的 aip_mem_accessor)
`include "aip_mem_ecc.sv"

// CPU 内存抽象（依赖 aip_mem_ecc; aip_cpu_loader 推迟到 aip_cmd 后）
`include "aip_cpu_mem/src/aip_cpu_mem.sv"

// 命令分发框架（依赖 aip_str, aip_cpu_bridge; 提供 aip_cmd_task / aip_cmd_1i 宏）
`include "aip_cmd.sv"

`aip_cmd_2i(set_cmdline_print,
            aip_cmdline_print_control::configure,
            int, enable, 1,
            int, max_prints, 10)

// 运行时 .so 命令插件加载器（惰性; 需 +define+AIP_ENABLE_SOLOAD + aip_soload.c + -ldl）
`include "aip_soload.sv"

// CPU firmware loader (依赖 aip_cpu_mem types + aip_cmd 静态成员)
`include "aip_cpu_mem/src/aip_cpu_loader.sv"

// 通道桥接（include 不代表启用，声明实例才启用）
`include "aip_c_bridge.sv"
`include "aip_tcl_bridge.sv"

// ============================================================
// TCL 命令注册 — 直接用 aip_cmd_* 宏 (内部已用 \__aip_cmd_``Ccmd  escaped identifier
// 让 class 名可含 :: namespace, 5 行搞定)
// ============================================================
`aip_cmd_1i(sv::cpu_bridge_reinit,      aip_cpu_bridge_ops::reinit,      int, mbox_base, 32'h800E_0000)
`aip_cmd_1i(sv::cpu_bridge_set_timeout, aip_cpu_bridge_ops::set_timeout, int, ns,        100000)
`aip_cmd_task(sv::cpu_bridge_enable_irq,        aip_cpu_bridge_ops::enable_irq)
`aip_cmd_task(sv::cpu_bridge_enable_event_mode, aip_cpu_bridge_ops::enable_event_mode)
`aip_cmd_task(sv::cpu_bridge_status,            aip_cpu_bridge_ops::show_status)
`aip_cmd_str_1i(sv::cpu_bridge_set_msip_path,  aip_cpu_bridge_ops::set_msip_path, path, "")
`aip_cmd_str_1i1i(sv::cpu_bridge_set_plic_path, aip_cpu_bridge_ops::set_plic_path, string, path, "", int, src, 48)

// ============================================================
// CPU firmware loader 命令 — 通过 aip_cpu_loader_default singleton
// TB 必须先调 aip_cpu_loader_default::set(loader_inst) 绑定实例
// ============================================================
`aip_cmd_str_2i_status(fw_reload,    aip_cpu_loader_default::load,         mode, "", file, "")
`aip_cmd_str_1i_status(load_packed40, aip_cpu_loader_default::load_packed40, file, "")
`aip_cmd_str_1i1i(load_rom,     aip_cpu_loader_default::load_rom_hex, string, file, "", int, offset, 0)
`aip_cmd_str_1i1i(load_ram,     aip_cpu_loader_default::load_ram_hex, string, file, "", int, offset, 0)
`aip_cmd_1i1s    (load_hex_at,  aip_cpu_loader_default::load_hex_at,  int, addr, 0, string, file, "")

// Boot-ready handshake: host TCL waits for C-side magic write via backdoor poll.
// C writes 0xDEADBEEF to MBOX_BASE+0x800 at end of main init (firmware/aip_cmd.h
// MBOX_BOOT_READY_OFF / MBOX_BOOT_READY_MAGIC, cpu_demo/src/main.c).
`aip_cmd_4i(cpu_wait, aip_cpu_loader_default::wait_value, int, addr, 32'h800E_0800, int, expected, 32'hDEAD_BEEF, int, mask, 0, int, timeout_ns, 1000000)

endpackage

import uvm_pkg::*;
import aip_core_pkg::*;

// 时钟生成器含 interface，必须位于 package 外且是统一入口的最后一个组件。
`include "aip_clk.sv"

`endif // AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif // AIP_CORE_PKG_SV
