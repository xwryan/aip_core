//===========================================================
// 所属层次：src/sv/core；aip_cmdline 的兼容聚合入口。
// 生产环境仍通过 aip_core_pkg.sv 使用，已有 standalone include 路径保持不变。
// 依赖 aip_log、uvm_pkg；本入口加载 aip_str，不另建 package，也不复制静态状态。
// 所有片段在调用者当前命名空间内展开；用户目标值由用户持有，override/schema
// 元数据的生命周期和诊断帧作用域由各实现层管理，不因文件拆分而改变。
// 类实现位于 cmdline/*.sv，纯宏位于 cmdline/*.svh；不要单独编译/直接 include 片段。
// 完整交付 src/sv/ 目录即可，已有 +incdir+<repo>/src/sv 和用户 filelist 无需增加片段。
//===========================================================
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
`include "core/cmdline/aip_struct_runtime.sv"
`include "core/cmdline/aip_struct_arrays.sv"
`include "core/cmdline/aip_cmdline_queues.sv"
`include "core/cmdline/aip_struct_macros.svh"

// 保留旧版 standalone +define+AIP_CMDLINE_TEST 自测入口，不依赖发布包外的 tests/。
// 该旧开关不用于 package 入口；常规 package 验证采用 tests/sv 下的独立测试顶层。
`ifdef AIP_CMDLINE_TEST
`include "core/cmdline/aip_cmdline_selftest.sv"
`endif

`undef AIP_CMDLINE_INTERNAL_INCLUDE
`endif // AIP_CMDLINE_SV
