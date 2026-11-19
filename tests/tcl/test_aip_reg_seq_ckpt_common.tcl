# aip_reg_seq 快照回归的共用 loader 与断言（runner 注入 AIP_CORE/RSCK_*）；restore 删除 proc 后须重新 source 本文件。
if {$::env(RSCK_LOADER) eq "so"} {
    source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} else {
    source [file join $::env(AIP_CORE) dist aip_init.tcl]
}
set ::aip_ckpt_dir [file join $::env(RSCK_WORK) snapshots_$::env(RSCK_LOADER)]
set ::aip_simv_path [file join $::env(RSCK_WORK) simv]
if {![info exists ::rsck_checks]} { set ::rsck_checks 0 }

proc rsck_check {name condition} {
    if {!$condition} { error "RSCK_FAIL $name" }
    incr ::rsck_checks
    puts "RSCK_CHECK_PASS $name"
}

# 查询本身也须成功，避免把错误文本当观测值。
proc rsck_state {kind {name none}} {
    aip_send_cmd "rs_state kind=$kind name=$name"
    if {[aip_check_status] != 0} { error "RSCK_FAIL observation $kind $name: [aip_read_result]" }
    return [aip_read_result]
}
