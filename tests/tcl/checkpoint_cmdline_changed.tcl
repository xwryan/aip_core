# CLI B 恢复旧快照：首次/重复恢复、override、loader 切换及刷新后链式保存；restore 均在顶层执行，之后重新加载定义。
# 注册日志：快照里的 set_cmdline_print(1,5) 随刷新作废，按 B 的 +aip_cmdline.max_prints=7 重读；刷新后再设置照常生效。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_sample B B singleton 22 1:7
aip_restore base
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample B A private 91 1:7
ckpr_pending 0
ckpr_command "clear_param path=probe.held"
ckpr_sample B A private 22 1:7
ckpr_command "set_param path=held value=92"
ckpr_sample B A private 92 1:7
ckpr_command "set_param path=probe.held value=93"
ckpr_sample B A private 93 1:7
ckpr_command "set_cmdline_print enable=0 max_prints=2"
ckpr_sample B A private 93 0:2

# 二次恢复从旧 ACK 重新请求；.so 分支在此切到源码，验证存活的 embedded 标志不会漏掉刷新。
aip_restore base
set ::env(CKPR_LOADER) source
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample B A private 91 1:7
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 0
ckpr_sample B A private 91 1:7
aip_checkpoint chained "note=CLI B cached private processor"
puts "CKPR_DONE phase=changed"
quit
