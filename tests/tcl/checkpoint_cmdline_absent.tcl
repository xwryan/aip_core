# 缺省 CLI 进程恢复 A：旧专属键/数组必须消失，已有 override 保持到显式 clear。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_sample N N singleton -4
aip_restore base
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample N A private 91
ckpr_command "clear_param path=probe.held"
ckpr_sample N A private -4
puts "CKPR_DONE phase=absent"
quit
