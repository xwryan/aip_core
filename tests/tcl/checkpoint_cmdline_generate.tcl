# tests/tcl：在旧 CLI A 下保存快照，含一个已有 override；不允许恢复逻辑影响普通启动。
# 本阶段只保存 base，所有快照/日志归 runner；恢复期望由独立脚本给出。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_pending 0
ckpr_sample A A singleton 4
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 0
ckpr_sample A A singleton 4
ckpr_command "set_param path=probe.held value=91"
ckpr_sample A A singleton 91
aip_checkpoint base "note=CLI A with held override"
puts "CKPR_DONE phase=generate"
quit
