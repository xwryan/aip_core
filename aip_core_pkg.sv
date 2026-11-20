// aip_core 根入口：aip_core.f 唯一编译的源文件，按原编译顺序 include 本项目的全部源码（package、interface、module）；
// 路径相对仓库根目录，经 aip_core.f 的 +incdir+./ 解析。依赖项目须先经各自的 filelist 编译。
// 兼容入口：规范的 AIP SV package 在 src/sv/aip_core_pkg.sv；仓库 tests 以 +incdir+<仓库根> 后 `include "aip_core_pkg.sv" 引用本文件。
// AIP_CORE_PKG_SV 由 src/sv/aip_core_pkg.sv 自身的 guard 定义，这里只判断不定义，否则会跳过该文件。
`ifndef AIP_CORE_PKG_SV
`include "src/sv/aip_core_pkg.sv"
`endif // AIP_CORE_PKG_SV
