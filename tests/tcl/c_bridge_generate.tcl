# tests/tcl：默认未监听时执行文件命令并生成唯一基准快照；所有 OS 检查由宿主握手完成。
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
run 1000ns
socket_reject_arguments
socket_checked socket_check_default
socket_checked socket_check_failed_start
socket_checked socket_check_default
socket_host_gate
puts "C_BRIDGE_SAVE_BEGIN"
flush stdout
aip_checkpoint base "note=C bridge never listened"
puts "C_BRIDGE_GENERATE_DONE"
quit
