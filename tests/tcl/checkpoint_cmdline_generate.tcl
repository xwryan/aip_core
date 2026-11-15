# 在旧 CLI A 下保存含一个 override 的 base 快照；恢复逻辑不能影响普通启动。
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
