// tests/sv 层：内部片段不是用户入口，直接包含必须在 analysis 阶段明确拒绝。
// 每个分支单独编译；显式 -top 仍不能跳过 guard，因此不会把错误延迟到 elaboration。
// 不依赖日志、UVM 或 parser 对象，防止缺失外部类型造成“错误原因不正确”的假通过。
`ifdef AIP_SPLIT_INTERNAL_MACRO
`include "cmdline/aip_cmdline_macros.svh"
`else
`include "cmdline/aip_cmdline_context.sv"
`endif

// 若内部 guard 失效，此空 top 会顺利通过编译，Makefile 必须据此判失败。
module test_cmdline_split_internal_reject;
endmodule
