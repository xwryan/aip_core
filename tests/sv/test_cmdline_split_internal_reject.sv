// 内部片段不是用户入口：直接包含必须在 analysis 阶段明确拒绝（显式 -top 也不能绕过 guard）。
// 不依赖日志/UVM/parser，防止因缺失外部类型报错而假通过。
`ifdef AIP_SPLIT_INTERNAL_MACRO
`include "cmdline/aip_cmdline_macros.svh"
`else
`include "cmdline/aip_cmdline_context.sv"
`endif

// 若内部 guard 失效，此空 top 会顺利通过编译，Makefile 必须据此判失败。
module test_cmdline_split_internal_reject;
endmodule
