# CLI C 先恢复已持有 B 私有参数源的快照，再反复恢复它与原始 A 快照（ACK=1/0），检查刷新请求不与已缓存来源碰撞。
# 注册日志每次恢复都按 C 的 +aip_cmdline.print_enable=0 +aip_cmdline.max_prints=4 重读，不受 ACK 奇偶影响。
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
run 10ns
ckpr_sample C C singleton 31 0:4
aip_restore chained
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91 0:4
aip_restore chained
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91 0:4
aip_restore base
set ::env(CKPR_LOADER) $::env(CKPR_RUN_ID)
source [file join $::env(AIP_CORE) tests tcl checkpoint_cmdline_common.tcl]
ckpr_pending 1
ckpr_sample C A private 91 0:4
puts "CKPR_DONE phase=chained"
quit
