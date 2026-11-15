# dist：二进制加载完成后的独立启动脚本，唯一副作用是初次桥握手。
# 启动仍经统一推进层的 bootstrap 模式；+r 缺少+f时的原生 Tcl return
# 只能结束本文件，不能截断父 aip_init_so.tcl 的初始化收尾。
#
# Keep this file to the single bridge start.  The first `run` performs the
# $stop handshake with aip_tcl_bridge.sv; in a simv built without
# -debug_access+f (e.g. +r/+rw) UCLI's `run` returns with Tcl code `return`,
# which ends the file currently being sourced while the parent continues.
_aip_advance bootstrap
