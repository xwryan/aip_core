// AIP Core 统一 package 入口：按类型依赖顺序 include 各组件并注册内置命令。
// 注册对象保留到仿真结束；CPU loader、DUT、sequencer 等业务资源仍归 TB 所有。
`ifndef AIP_CORE_PKG_SV
`define AIP_CORE_PKG_SV

// 组件若先于本 package 被单独 include，共享的 include guard 会让它只剩 $unit 下的独立类型，故拒绝。
// aip_clk.sv 含 interface，刻意放在 package 外，不在此检查之列。
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
`elsif AIP_SEQ_LAUNCHER_SV
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
`elsif AIP_SCB_TYPES_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SCB_REPORTER_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SCB_REGISTRY_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SCB_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SCB_CMD_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_MON_HUB_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`elsif AIP_SAMPLE_SEQ_SV
`define AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif

`ifdef AIP_CORE_PKG_PREINCLUDE_CONFLICT
// 故意引用未定义宏，使错误 include 顺序在编译阶段失败，不依赖最终 -top 选择。
`AIP_CORE_PKG_PREINCLUDE_ERROR__MUST_INCLUDE_OR_COMPILE_AIP_CORE_PKG_SV_FIRST
`else

package aip_core_pkg;
import uvm_pkg::*;

`include "util/aip_log.sv"

`include "core/aip_str.sv"
`include "util/aip_time.sv"

`include "core/aip_cmdline.sv"

`include "util/aip_wait_policy.sv"

// 须在 aip_cmd 之前：aip_cmd::exec 引用 aip_cpu_bridge::send_cmd。
`include "bridge/aip_cpu_bridge.sv"

// 依赖 aip_cpu_bridge 中的 aip_mem_accessor。
`include "util/aip_mem_ecc.sv"

`include "cpu_mem/aip_cpu_mem.sv"

`include "core/aip_cmd.sv"
`include "bridge/aip_dut_control.sv"

`aip_cmd_2i(set_cmdline_print,
            aip_cmdline_print_control::configure,
            int, enable, 1,
            int, max_prints, 10)

// 运行时 .so 插件惰性加载，需 +define+AIP_ENABLE_SOLOAD、aip_soload.c 与 -ldl。
`include "plugin/aip_soload.sv"

// 依赖 aip_cpu_mem 类型与 aip_cmd 逐调用结果 API，故放在 aip_cmd 之后。
`include "cpu_mem/aip_cpu_loader.sv"

// include 不代表启用，声明实例才启用。
`include "bridge/aip_c_bridge.sv"
`include "bridge/aip_inject_bridge.sv"
`include "bridge/aip_tcl_bridge.sv"

// seq 启动器与 aip_reg_seq：依赖 aip_activity 和命令名表重发，故在 Tcl bridge 之后。
`include "core/aip_seq_launcher.sv"

// RAL 报告/生命周期底座；include 本身不访问 DUT，也不配置模型。
`include "ral/aip_ral_types.sv"
`include "ral/aip_ral_hooks.sv"
`include "ral/aip_ral_mem_frontdoor.sv"
`include "ral/aip_ral_raw_probe.sv"
`include "ral/aip_ral_raw_observer.sv"
`include "ral/aip_ral_service.sv"
`include "ral/aip_ral_test_runner.sv"
`include "ral/aip_ral_commands.sv"

// 公共 scoreboard 与整笔事务采样只依赖 UVM；scoreboard 的 Tcl 查询命令依赖 aip_cmd，放在其后。
`include "scb/aip_scb_types.sv"
`include "scb/aip_scb_reporter.sv"
`include "scb/aip_scb_registry.sv"
`include "scb/aip_scb.sv"
`include "scb/aip_scb_cmd.sv"
`include "sample/aip_mon_hub.sv"
`include "sample/aip_sample_seq.sv"

// 内置 Tcl 命令：宏用 escaped identifier 生成类名，故命令名可带 :: 命名空间。
`aip_cmd_1i(sv::cpu_bridge_reinit,      aip_cpu_bridge_ops::reinit,      int, mbox_base, 32'h800E_0000)
`aip_cmd_1i(sv::cpu_bridge_set_timeout, aip_cpu_bridge_ops::set_timeout, int, ns,        100000)
`aip_cmd_task(sv::cpu_bridge_enable_irq,        aip_cpu_bridge_ops::enable_irq)
`aip_cmd_task(sv::cpu_bridge_enable_event_mode, aip_cpu_bridge_ops::enable_event_mode)
`aip_cmd_task(sv::cpu_bridge_status,            aip_cpu_bridge_ops::show_status)
// 路径设置 task 不写结果：末参 1'b1 启用局部结果，保留缺省成功且不占 legacy 槽。
`aip_cmd_str_1i(sv::cpu_bridge_set_msip_path,  aip_cpu_bridge_ops::set_msip_path, path, "", 1'b1)
`aip_cmd_str_1i1i(sv::cpu_bridge_set_plic_path, aip_cpu_bridge_ops::set_plic_path, string, path, "", int, src, 48, 1'b1)

// load_image(file, start=64 位 CPU 地址, format=hex/packed40)，ROM/RAM 按 cpu region map 自动路由。
// TB 须先用 aip_cpu_loader_default::set() 绑定实例，活动命令期间不得重绑。
`aip_cmd_str_1u1s_status(load_image, aip_cpu_loader_default::load_image,
                         file, "", start, 64'd0, format, "hex", 1'b1)

// Boot-ready：经 backdoor 等待 C 初始化结束时写入的 magic，
// 默认地址 MBOX_BASE+0x800、值 0xDEADBEEF（见 firmware/core/aip_cmd.h 的对应常量）。
// wait_value 的 set_result 由执行上下文最终应用，不能被 typed 宏的缺省成功覆盖。
`aip_cmd_4i(cpu_wait, aip_cpu_loader_default::wait_value, int, addr, 32'h800E_0800, int, expected, 32'hDEAD_BEEF, int, mask, 0, int, timeout_ns, 1000000)

endpackage

import uvm_pkg::*;
import aip_core_pkg::*;

// 时钟生成器含 interface，必须位于 package 外且是统一入口的最后一个组件。
`include "util/aip_clk.sv"

`endif // AIP_CORE_PKG_PREINCLUDE_CONFLICT
`endif // AIP_CORE_PKG_SV
