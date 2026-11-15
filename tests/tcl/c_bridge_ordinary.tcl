# 普通仿真默认不监听：宿主确认无 LISTEN fd 后才显式调用注册命令，UVM 收到末尾 ping 才结束。
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
run 1000ns
socket_reject_arguments
socket_checked socket_check_default
socket_checked socket_check_failed_start
socket_checked socket_check_default
socket_host_gate
socket_start_checked
run
quit
