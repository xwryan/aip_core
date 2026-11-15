# tests/tcl：只完成标准 loader 握手便直接监听，不插入 run 或其它 SV 命令隐藏 time0 竞态。
# 宿主 gate 只等待墙钟、不推进仿真；显式启动后复用真实协议，确认持久线程已正常运行。
source [file join $::env(AIP_CORE) tests tcl c_bridge_common.tcl]
socket_host_gate
socket_start_checked
run
quit
