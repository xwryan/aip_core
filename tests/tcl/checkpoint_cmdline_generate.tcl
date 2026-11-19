# 在旧 CLI A 下保存含一个 override 和一次运行时 set_cmdline_print 的 base 快照；恢复逻辑不能影响普通启动。
# A 的注册日志设置只来自完整键 +aip_cmdline.max_prints=3，叶名 +print_enable=0 +max_prints=0 不生效。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_pending 0
ckpr_sample A A singleton 4 1:3
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 0
ckpr_sample A A singleton 4 1:3
ckpr_command "set_param path=probe.held value=91"
ckpr_sample A A singleton 91 1:3
ckpr_command "set_cmdline_print enable=1 max_prints=5"
ckpr_sample A A singleton 91 1:5
aip_checkpoint base "note=CLI A with held override"
puts "CKPR_DONE phase=generate"
quit
