// tests/sv 层：保留旧版 AIP_CMDLINE_TEST standalone 自测开关的最小装载 fixture。
// 顶层 test_param_parser_full 仍由库内 legacy selftest 提供；本文件只选择旧开关和依赖顺序。
// 仿真变量及退出时机均由旧模块持有，不复制其测试逻辑，也不作为生产 package 入口使用。
`define AIP_CMDLINE_TEST
`include "aip_log.sv"
`include "aip_cmdline.sv"
