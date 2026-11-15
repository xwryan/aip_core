# 独立 simv 进程恢复在途快照：只重新 source Tcl，SV 对象/执行线程由快照恢复，不得重启原业务。
set ::env(AIP_CORE) [file normalize ../..]
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set ::aip_ckpt_dir ./checkpoint_background_artifacts
set ::aip_simv_path [file normalize ./simv_checkpoint_background]
aip_restore active
source [file join $::env(AIP_CORE) dist aip_init.tcl]
source ../tcl/checkpoint_background_common.tcl
set ::aip_ckpt_dir ./checkpoint_background_artifacts
set ::aip_simv_path [file normalize ./simv_checkpoint_background]
ckb_check "snapshot simulation time restored" [expr {[ckb_get none now] == 100}]
ckb_inflight
source [file join $::env(AIP_CORE) dist aip_init.tcl]
ckb_inflight
ckb_complete
puts "CKB_RESTORE_PASS checks=$::ckb_checks"
end_test
run
