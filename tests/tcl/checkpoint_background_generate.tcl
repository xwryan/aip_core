# 启动三条后台业务，在途保存快照后继续运行，作为连续执行基线。
set ::env(AIP_CORE) [file normalize ../..]
source [file join $::env(AIP_CORE) dist aip_init.tcl]
source ../tcl/checkpoint_background_common.tcl
set ::aip_ckpt_dir ./checkpoint_background_artifacts
set ::aip_simv_path [file normalize ./simv_checkpoint_background]

foreach name {ckb_local ckb_legacy ckb_seq} tag {local_original legacy_original seq_original} {
    aip_send_cmd "$name text=$tag wait=0"
    ckb_check "$name startup acknowledged" \
        [expr {[aip_check_status] == 0 && [aip_read_result] eq "STARTED: $name"}]
}
run 100ns
ckb_inflight
aip_checkpoint active "note=local legacy and sequence still running"
# 重复 source 只能恢复/确认 Tcl 入口，不能再次启动 SV 命令或推进等待位置。
source [file join $::env(AIP_CORE) dist aip_init.tcl]
ckb_inflight
ckb_complete
puts "CKB_GENERATE_PASS checks=$::ckb_checks"
end_test
run
