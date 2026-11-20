// aip_core 主 filelist：用大写 -F 引用（vcs -F <路径>/aip_core/aip_core.f），文件与 +incdir+ 都相对本文件目录，可在任意目录编译。
// 不拉入依赖；无前置项目（UVM 即可）。
// 只编译根入口 aip_core_pkg.sv；在自己的 package/module 内 `include "aip_core_import.svh" 即可 import 本项目的 package。
// 须最先编译且只编译一次；仓库自身的 tests 仍可直接 `include "aip_core_pkg.sv"（两处入口是同一个 package、同一个 guard）。
+incdir+./
+incdir+./src/sv
./aip_core_pkg.sv
