# tests/tcl：CLI B 恢复旧快照，验证首次/重复恢复、override、loader 切换及刷新后链式保存。
# restore 均为顶层语句，随后重新加载定义；不在 proc/catch 内执行原生恢复。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_sample B B singleton 22
aip_restore base
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample B A private 91
ckpr_pending 0
ckpr_command "clear_param path=probe.held"
ckpr_sample B A private 22
ckpr_command "set_param path=held value=92"
ckpr_sample B A private 92
ckpr_command "set_param path=probe.held value=93"
ckpr_sample B A private 93

# 二次恢复从旧 ACK 重新请求；.so 分支在此切到源码，验证存活的 embedded 标志不会漏掉刷新。
aip_restore base
set ::env(CKPR_LOADER) source
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample B A private 91
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 0
ckpr_sample B A private 91
aip_checkpoint chained "note=CLI B cached private processor"
puts "CKPR_DONE phase=changed"
quit
