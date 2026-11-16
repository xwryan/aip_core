// aip_cmdline 兼容聚合入口（生产经 aip_core_pkg.sv 使用，standalone include 路径不变）：在调用者命名空间内展开
// cmdline/*.sv 类实现与 cmdline/*.svh 纯宏；不要单独编译或直接 include 这些片段。
`ifndef AIP_CMDLINE_SV
`define AIP_CMDLINE_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
`include "core/aip_str.sv"

// 唯一加载窗口：外部直接包含内部文件会产生分析期错误，避免同一类被定义到两个作用域。
`define AIP_CMDLINE_INTERNAL_INCLUDE

// 上下文包含前向声明；宏先声明但只在用户调用时展开，不提前求值或消费随机数。
`include "core/cmdline/aip_cmdline_context.sv"
`include "core/cmdline/aip_cmdline_macros.svh"

// 实现依赖顺序不可随意交换：基础解析 -> schema 公共运行时 -> 类型化数组 -> 严格队列。
`include "core/cmdline/aip_cmdline_scalar.sv"
`include "core/cmdline/aip_cmdline_query.sv"
`include "core/cmdline/aip_cmdline_flags.sv"
`include "core/cmdline/aip_struct_runtime.sv"
`include "core/cmdline/aip_struct_arrays.sv"
`include "core/cmdline/aip_cmdline_queues.sv"
`include "core/cmdline/aip_struct_macros.svh"

// 旧 standalone +define+AIP_CMDLINE_TEST 自测入口（不用于 package 入口，不依赖发布包外的 tests/）。
`ifdef AIP_CMDLINE_TEST
`include "core/cmdline/aip_cmdline_selftest.sv"
`endif

`undef AIP_CMDLINE_INTERNAL_INCLUDE
`endif // AIP_CMDLINE_SV
