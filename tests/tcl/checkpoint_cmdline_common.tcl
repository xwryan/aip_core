# tests/tcl：真实参数恢复回归的共用 loader 和断言；依赖 runner 注入的 AIP_CORE/CKPR_*。
# Tcl 期望独立于 CLI；脚本/快照由 runner 专属目录持有。restore 删除 proc 后必须重新 source。
if {$::env(CKPR_LOADER) eq "so"} {
    source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} else {
    source [file join $::env(AIP_CORE) dist aip_init.tcl]
}
set ::aip_ckpt_dir [file join $::env(CKPR_WORK) snapshots_$::env(CKPR_RUN_ID)]
set ::aip_simv_path [file join $::env(CKPR_WORK) simv]
puts "CKPR_LOADER mode=$::env(CKPR_LOADER) embedded=$::aip_tcl_embedded"

# 同步执行并校验本次结果；失败抛出明确标记，runner 不能仅以进程退出码判定成功。
proc ckpr_sample {profile saved source_kind held} {
    aip_send_cmd "ckpr_sample profile=$profile saved=$saved source=$source_kind held=$held"
    if {[aip_check_status] != 0 || [aip_read_result] ne "CKPR_OK"} {
        error "CKPR_FAIL sample command failed"
    }
}

# 只读 request/ack，确认刷新在任何采样/仿真推进前已请求；want=0 也检查重复 source 幂等。
proc ckpr_pending {want} {
    set request [_aip_control_scalar [get aip_core_pkg::__aip_cmdline_refresh_request]]
    set ack [_aip_control_scalar [get aip_core_pkg::__aip_cmdline_refresh_ack]]
    if {($request != $ack) != $want} { error "CKPR_FAIL pending expected=$want request=$request ack=$ack" }
    puts "CKPR_PENDING want=$want request=$request ack=$ack"
}

# 使用正式命令设置或清除 override；其返回码必须成功，避免优先级断言读到测试设置失败的值。
proc ckpr_command {command} {
    aip_send_cmd $command
    if {[aip_check_status] != 0} { error "CKPR_FAIL command=$command result=[aip_read_result]" }
}
