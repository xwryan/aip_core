# 只完成标准 loader 握手就直接监听，不插入 run 或其它 SV 命令以免掩盖 time0 竞态。
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
socket_host_gate
socket_start_checked
run
quit
