# tests/tcl：CLI C 先恢复已经持有 B 私有参数源的快照，再重复恢复该快照及原始 A 快照。
# 反复恢复 ACK=1/0 的不同快照，检查刷新请求不会与已缓存来源碰撞。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_sample C C singleton 31
aip_restore chained
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91
aip_restore chained
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91
aip_restore base
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91
puts "CKPR_DONE phase=chained"
quit
