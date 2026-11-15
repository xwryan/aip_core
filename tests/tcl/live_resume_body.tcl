# 正式保栈暂停黑盒门禁（公开 loader、watch/control API 与真实 cw_seq），由 Python PTY runner 驱动交互；本组不推进暂停现场。
set ::live_checks 0
set ::live_effects 0
set ::live_seq_effects 0
set ::live_phase setup
set ::live_watch_ids {}

proc live_check {label condition} {
    if {!$condition} { error "AIP_LIVE_FAIL $label" }
    incr ::live_checks
    puts "AIP_LIVE_CHECK $label"
}

# 从原生 senv time 独立换算整数 fs，不依赖待测控制层的时间解析实现或浮点舍入。
proc live_time_fs {} {
    set raw [senv time]
    if {![regexp {^\s*([0-9]+)(?:\.([0-9]+))?\s*(fs|ps|ns|us|ms|s)\s*$} $raw -> whole fraction unit]} {
        error "AIP_LIVE_FAIL unsupported time <$raw>"
    }
    set scales [dict create fs 1 ps 1000 ns 1000000 us 1000000000 ms 1000000000000 s 1000000000000000]
    set scale [dict get $scales $unit]
    set whole [string trimleft $whole 0]
    if {$whole eq ""} { set whole 0 }
    set result [expr {$whole * $scale}]
    if {$fraction ne ""} {
        set divisor [expr {10 ** [string length $fraction]}]
        set fraction [string trimleft $fraction 0]
        if {$fraction eq ""} { set fraction 0 }
        if {($fraction * $scale) % $divisor != 0} {
            error "AIP_LIVE_FAIL sub-fs time <$raw>"
        }
        incr result [expr {$fraction * $scale / $divisor}]
    }
    return $result
}

# 只在上一条请求已完成后通过真实桥查询业务计数；暂停时不调用此过程。
proc live_state {name field} {
    aip_send_cmd "cw_state name=$name field=$field"
    live_check "state query $field" [expr {[aip_check_status] == 0}]
    return [aip_read_result]
}

# 暂停现场快照仅使用只读 get；完整保留请求/返回 payload，防止仅 ID 相同
# 却已覆写请求，或 ACK 同刻暂停时被被拒绝的新命令污染了旧返回槽。
proc live_snapshot {} {
    set len [aip_parse_int [get aip_core_pkg::__tcl_cmd_len]]
    set payload {}
    for {set i 0} {$i < $len} {incr i} {
        lappend payload [get aip_core_pkg::__tcl_cmd_ascii\[$i\]]
    }
    set result_len [aip_parse_int [get aip_core_pkg::__tcl_result_len]]
    set result_payload {}
    for {set i 0} {$i < $result_len} {incr i} {
        lappend result_payload [get aip_core_pkg::__tcl_result_ascii\[$i\]]
    }
    return [dict create time [senv time] seq $::_aip_cmd_seq \
        id [get aip_core_pkg::__tcl_cmd_id] ack [get aip_core_pkg::__tcl_result_id] \
        len $len trigger [get aip_core_pkg::__tcl_cmd_trigger] payload $payload \
        result_len $result_len result_payload $result_payload \
        result_status [get aip_core_pkg::__tcl_result_status] \
        result_known [get aip_core_pkg::__tcl_result_known] \
        free_run [get aip_core_pkg::__tcl_free_run] idle [get aip_core_pkg::__tcl_bridge_idle] \
        effects $::live_effects seq_effects $::live_seq_effects phase $::live_phase]
}

# 在 native pause 提示符运行；拒绝必须是正式 BUSY 错误，而非缺参数/缺文件假阳性。
proc live_expect_busy {label command} {
    set rc [catch {uplevel #0 $command} message options]
    live_check "busy code $label" [expr {$rc == 1}]
    live_check "busy errorcode $label" [expr {[dict exists $options -errorcode] &&
        [dict get $options -errorcode] eq {AIP CONTROL BUSY}}]
    live_check "busy message $label" [string match AIP_CONTROL_BUSY* $message]
    puts "AIP_LIVE_BUSY_PASS $label"
}

# loader 重复初始化不能归零请求编号、watch 或正在等待的执行栈。
proc live_repeat_init {} {
    set before_id $::_aip_cmd_seq
    set before_watches [aip_watch_status]
    source $::live_loader
    live_check repeat_id [expr {$::_aip_cmd_seq == $before_id}]
    live_check repeat_watches [expr {[aip_watch_status] eq $before_watches}]
    live_check native_resume [expr {[info procs resume] eq ""}]
    live_check builtin_continue_command [expr {[info procs continue] eq ""}]
}

# 普通 proc/for 中保留局部变量；两个断点必须共用最初的 100ns deadline。
proc live_nested_run {} {
    set cookie run_local_cookie
    set start [live_time_fs]
    set ::live_phase finite_run
    for {set iteration 0} {$iteration < 3} {incr iteration} {
        if {$iteration == 1} { continue }
        incr ::live_effects
        if {$iteration == 0} {
            run 100ns
            live_check finite_deadline [expr {[live_time_fs] == $start + 100000000}]
            live_check run_local [expr {$cookie eq "run_local_cookie"}]
            live_check run_iteration [expr {$iteration == 0}]
        } else {
            run 10ns
        }
    }
    live_check run_effects [expr {$::live_effects == 2}]
}

# 一个真实 UVM item，暂停/ACK 同刻暂停后仍只能启动、驱动、完成各一次。
proc live_nested_sequence {} {
    set cookie sequence_local_cookie
    set previous $::_aip_cmd_seq
    set start [live_time_fs]
    set ::live_phase sequence
    incr ::live_seq_effects
    cw_seq ns=400 tag=live_resume
    # 用户延迟 400ns 加真实 driver 300ns；ACK 同刻暂停不能补跑剩余轮询窗口。
    live_check sequence_deadline [expr {[live_time_fs] == $start + 700000000}]
    set result [aip_read_result]
    live_check sequence_status [expr {[aip_check_status] == 0}]
    live_check sequence_result [expr {$result eq "DONE:cw_seq:live_resume"}]
    live_check request_not_resent [expr {$::_aip_cmd_seq == $previous + 1}]
    live_check sequence_local [expr {$cookie eq "sequence_local_cookie"}]
    live_check sequence_effects [expr {$::live_seq_effects == 1}]
    set ::live_phase after_sequence
    live_check sequence_started_once [expr {[live_state cw_seq started] == 1}]
    live_check sequence_finished_once [expr {[live_state cw_seq finished] == 1}]
    live_check driver_once [expr {[live_state none driver_count] == 1}]
    live_check driver_tag [expr {[live_state none driver_tag] eq "live_resume"}]
}

# 手动中断组刻意不写 -keep；生产 run 必须自动添加且恢复原有限期限。
proc live_manual {} {
    set cookie manual_local_cookie
    set start [live_time_fs]
    set ::live_phase manual
    for {set iteration 0} {$iteration < 2} {incr iteration} {
        incr ::live_effects
        puts "AIP_LIVE_MANUAL_BEFORE iteration=$iteration time=[senv time]"
        run 500000ns
        live_check manual_local [expr {$cookie eq "manual_local_cookie"}]
        live_check manual_effects [expr {$::live_effects == $iteration + 1}]
        live_check manual_deadline [expr {[live_time_fs] == $start + ($iteration + 1) * 500000000000}]
        puts "AIP_LIVE_MANUAL_AFTER iteration=$iteration time=[senv time]"
    }
}

# 旧入口继续保持“失败块重放”而非保栈语义；文件仅来自 runner 的临时副本。
proc live_legacy {} {
    set source_file [file join $::env(AIP_LIVE_WORK) live_resume_legacy_source_case.tcl]
    set source_left [file join $::env(AIP_LIVE_WORK) live_resume_legacy_source_case_left.tcl]
    set ::live_legacy_allow 0
    set ::live_legacy_prefix 0
    set ::live_legacy_suffix 0
    live_check legacy_source_failure [expr {[catch {aip_source $source_file}] == 1}]
    live_check legacy_source_left [file exists $source_left]
    live_check legacy_source_stopped [expr {$::live_legacy_prefix == 1 && $::live_legacy_suffix == 0}]
    set ::live_legacy_allow 1
    aip_source $source_left
    live_check legacy_source_replayed_once [expr {$::live_legacy_prefix == 1 && $::live_legacy_suffix == 1}]
    live_check legacy_source_cleaned [expr {![file exists $source_left]}]

    set self_file [file join $::env(AIP_LIVE_WORK) live_resume_legacy_self_case.tcl]
    set self_left [file join $::env(AIP_LIVE_WORK) live_resume_legacy_self_case_left.tcl]
    set ::live_self_allow 0
    set ::live_self_prefix 0
    set ::live_self_suffix 0
    _aip_set_script $self_file
    source $self_file
    live_check legacy_self_left [file exists $self_left]
    live_check legacy_self_stopped [expr {$::live_self_prefix == 1 && $::live_self_suffix == 0}]
    set ::live_self_allow 1
    _aip_set_script $self_file
    source $self_file
    live_check legacy_self_replayed_once [expr {$::live_self_prefix == 1 && $::live_self_suffix == 1}]
    live_check legacy_self_cleaned [expr {![file exists $self_left]}]
    live_check legacy_stack_empty [expr {[aip_source_status] eq "(empty)"}]
}

live_check initialized $::aip_initialized
live_check correct_loader [expr {$::env(AIP_LIVE_LOADER) eq "so" ?
    ([info exists ::aip_tcl_embedded] && $::aip_tcl_embedded) :
    (![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded)}]
puts "AIP_LIVE_LIBRARY loader=$::env(AIP_LIVE_LOADER) loaded=[info loaded]"
live_repeat_init

set mode $::env(AIP_LIVE_MODE)
if {$mode eq "watch" || $mode eq "ack"} {
    foreach signal {first second pending} {
        set id [aip_watch aip_live_resume_fixture.$signal 1 stop=1]
        lappend ::live_watch_ids $id
        live_check "watch armed $signal" [expr {[dict get [aip_watch_status $id] state] eq "armed"}]
    }
    if {$mode eq "ack"} {
        lappend ::live_watch_ids [aip_watch aip_live_resume_fixture.first_ack 1 stop=1]
    }
    live_repeat_init
}

switch -- $mode {
    baseline - watch - ack {
        live_nested_run
        live_nested_sequence
        foreach id $::live_watch_ids {
            live_check "watch matched $id" [expr {[dict get [aip_watch_status $id] state] eq "matched"}]
        }
        if {$mode ne "baseline"} {
            live_check debug_value_visible [expr {[aip_parse_int [get aip_live_resume_fixture.debug_flag]] == 1}]
        }
    }
    notify {
        set notify_id [aip_watch aip_live_resume_fixture.first 1]
        set canceled_id [aip_watch aip_live_resume_fixture.second 1 stop=1]
        aip_watch_cancel $canceled_id
        aip_watch_cancel $canceled_id
        live_check watch_canceled [expr {[dict get [aip_watch_status $canceled_id] state] eq "canceled"}]
        live_nested_run
        live_check watch_notified [expr {[dict get [aip_watch_status $notify_id] state] eq "matched"}]
    }
    manual { live_manual }
    legacy { live_legacy }
    default { error "AIP_LIVE_FAIL unknown mode $mode" }
}

set seen {}
foreach value {1 2 3} { if {$value == 2} { continue }; lappend seen $value }
live_check builtin_continue [expr {$seen eq "1 3"}]
live_repeat_init
live_check control_idle [expr {[dict get [aip_sim_status] depth] == 0}]
puts "AIP_LIVE_PASS loader=$::env(AIP_LIVE_LOADER) mode=$mode checks=$::live_checks"
end_test
run
quit
