//===========================================================
// src/sv：AIP Core 统一 package 入口，按类型依赖顺序包含 core/bridge/cpu_mem 等组件。
// 类定义与命令注册表归本 package，注册对象保留到仿真结束；CPU loader、DUT、
// sequencer 等业务资源仍由 TB 所有，include 不代表自动创建或启动 bridge。
// 用法：编译时只需引入此文件即可使用所有 aip_core 组件
//   vcs -sverilog -ntb_opts uvm +incdir+<aip_core_path> aip_core_pkg.sv ...
//===========================================================
`ifndef AIP_CORE_PKG_SV
`define AIP_CORE_PKG_SV

// include guard 在 compilation unit 内共享；若先单独 include package 内组件，
// 会产生独立 $unit 类型而不再是本 package 的规范类型，因此拒绝该顺序。
// aip_clk.sv 含 interface，刻意放在 package 外，不属于此项冲突检查。
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
`elsif AIP_INJECT_BRIDGE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_DUT_CONTROL_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_TYPES_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_HOOKS_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_MEM_FRONTDOOR_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_RAW_PROBE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_RAW_OBSERVER_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_TEST_RUNNER_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_COMMANDS_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_RAL_SERVICE_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif

`ifdef AIP_CORE_PKG_PREINCLUDE_CONFLICT
// 故意引用未定义宏，使错误 include 顺序在编译阶段失败，不依赖最终 -top 选择。
`AIP_CORE_PKG_PREINCLUDE_ERROR__MUST_INCLUDE_OR_COMPILE_AIP_CORE_PKG_SV_FIRST
`else

package aip_core_pkg;
import uvm_pkg::*;

// 日志系统（无外部依赖，最先 include，其他组件均可使用）
`include "util/aip_log.sv"

// 基础工具
`include "core/aip_str.sv"
`include "util/aip_time.sv"

// 命令行参数解析（依赖 aip_str, uvm_pkg）
`include "core/aip_cmdline.sv"

// CPU 桥接（必须在 aip_cmd 之前: aip_cmd::exec 引用 aip_cpu_bridge::send_cmd）
`include "bridge/aip_cpu_bridge.sv"

// Mem ECC (SV 版, 依赖 aip_cpu_bridge 的 aip_mem_accessor)
`include "util/aip_mem_ecc.sv"

// CPU 内存抽象（依赖 aip_mem_ecc; aip_cpu_loader 推迟到 aip_cmd 后）
`include "cpu_mem/aip_cpu_mem.sv"

// 命令分发框架（依赖 aip_str, aip_cpu_bridge; 提供 aip_cmd_task / aip_cmd_1i 宏）
`include "core/aip_cmd.sv"
`include "bridge/aip_dut_control.sv"

`aip_cmd_2i(set_cmdline_print,
            aip_cmdline_print_control::configure,
            int, enable, 1,
            int, max_prints, 10)

// 运行时 .so 命令插件加载器（惰性; 需 +define+AIP_ENABLE_SOLOAD + aip_soload.c + -ldl）
`include "plugin/aip_soload.sv"

// CPU 固件 loader（依赖 aip_cpu_mem 类型与 aip_cmd 逐调用结果 API）
`include "cpu_mem/aip_cpu_loader.sv"

// 通道桥接（include 不代表启用，声明实例才启用）
`include "bridge/aip_c_bridge.sv"
`include "bridge/aip_inject_bridge.sv"
`include "bridge/aip_tcl_bridge.sv"

// RAL报告/生命周期底座；不注册命令，不启动DUT访问或配置模型。
`include "ral/aip_ral_types.sv"
`include "ral/aip_ral_hooks.sv"
`include "ral/aip_ral_mem_frontdoor.sv"
`include "ral/aip_ral_raw_probe.sv"
`include "ral/aip_ral_raw_observer.sv"
`include "ral/aip_ral_service.sv"
`include "ral/aip_ral_test_runner.sv"
`include "ral/aip_ral_commands.sv"

// ============================================================
// TCL 命令注册 — 直接用 aip_cmd_* 宏 (内部已用 \__aip_cmd_``Ccmd  escaped identifier
// 让 class 名可含 :: namespace, 5 行搞定)
// ============================================================
`aip_cmd_1i(sv::cpu_bridge_reinit,      aip_cpu_bridge_ops::reinit,      int, mbox_base, 32'h800E_0000)
`aip_cmd_1i(sv::cpu_bridge_set_timeout, aip_cpu_bridge_ops::set_timeout, int, ns,        100000)
`aip_cmd_task(sv::cpu_bridge_enable_irq,        aip_cpu_bridge_ops::enable_irq)
`aip_cmd_task(sv::cpu_bridge_enable_event_mode, aip_cpu_bridge_ops::enable_event_mode)
`aip_cmd_task(sv::cpu_bridge_status,            aip_cpu_bridge_ops::show_status)
// 路径设置 task 不写全局结果；启用逐调用模式以保留缺省成功且不占 legacy 槽。
`aip_cmd_str_1i(sv::cpu_bridge_set_msip_path,  aip_cpu_bridge_ops::set_msip_path, path, "", 1'b1)
`aip_cmd_str_1i1i(sv::cpu_bridge_set_plic_path, aip_cpu_bridge_ops::set_plic_path, string, path, "", int, src, 48, 1'b1)

// ============================================================
// CPU firmware loader — 统一使用 load_image(file, start, format)。
// TB 必须先调 aip_cpu_loader_default::set(loader_inst) 绑定实例；start 为
// 64-bit CPU 地址，format 为 hex/packed40。ROM/RAM 由 cpu region map 自动路由。
// 同一 map 的 loader 调用会串行化并共享重叠检查；不得在活动命令期间重绑 default loader。
// ============================================================
`aip_cmd_str_1u1s_status(load_image, aip_cpu_loader_default::load_image,
                         file, "", start, 64'd0, format, "hex", 1'b1)

// Boot-ready：Tcl 经 backdoor 等待 C 初始化结束写入的 magic，默认地址为
// MBOX_BASE+0x800，默认值 0xDEADBEEF（见 firmware/aip_cmd.h 的对应常量）。
// wait_value 的 set_result 由执行上下文最终应用，不能被 typed 宏缺省成功覆盖。
`aip_cmd_4i(cpu_wait, aip_cpu_loader_default::wait_value, int, addr, 32'h800E_0800, int, expected, 32'hDEAD_BEEF, int, mask, 0, int, timeout_ns, 1000000)

endpackage

import uvm_pkg::*;
import aip_core_pkg::*;

// 时钟生成器含 interface，必须位于 package 外且是统一入口的最后一个组件。
`include "util/aip_clk.sv"

`endif // AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif // AIP_CORE_PKG_SV
