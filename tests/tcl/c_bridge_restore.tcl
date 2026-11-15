# tests/tcl：另一进程恢复从未监听的快照；initial 不重跑，仍可在 reload 后显式创建新 socket。
# restore 独立处于顶层；宿主先确认恢复未自动监听，然后验证完整真实客户端协议。
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
run 1000ns
aip_restore base
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
socket_checked socket_check_default
socket_reject_arguments
socket_host_gate
socket_start_checked
run
quit
