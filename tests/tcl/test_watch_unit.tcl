# 后台观察的纯 Tcl 解析、资源所有权与错误门禁单测：使用真实控制/观察实现，只把 native UCLI 原语换成可检查桩。
set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root src tcl aip_sim_control.tcl]
source [file join $root src tcl aip_watch.tcl]
set checks 0
set native_next 10
set native_stops [dict create]
set deleted {}
set observed 0
set pause_count 0
set fail_install 0
set fail_callback 0
set get_count 0

proc check {label condition} {
    if {!$condition} { error "WATCH_UNIT_FAIL $label" }
    incr ::checks
    puts "WATCH_UNIT_CHECK $label"
}

# 读取桩记录所有访问，便于证明非法输入与暂停重入在接触HDL之前就被拒绝。
proc get {path} {
    incr ::get_count
    if {$path eq "tb.missing"} { error "unknown HDL path" }
    return $::observed
}

# stop桩严格追踪每个原生ID，不允许删除不属于观察器的其他断点。
proc stop {args} {
    switch -- [lindex $args 0] {
        -condition {
            if {$::fail_install} { error "native install failed" }
            incr ::native_next
            dict set ::native_stops $::native_next [dict create kind condition condition [lindex $args 1] callback {}]
            return $::native_next
        }
        -change {
            if {$::fail_install} { error "native install failed" }
            incr ::native_next
            dict set ::native_stops $::native_next [dict create kind change signal [lindex $args 1] callback {}]
            return $::native_next
        }
        -command {
            if {$::fail_callback} { error "native callback failed" }
            dict set ::native_stops [lindex $args 2] callback [lindex $args 1]
        }
        -delete {
            set id [lindex $args 1]
            if {![dict exists $::native_stops $id]} { error "wrong native stop id $id" }
            dict unset ::native_stops $id
            lappend ::deleted $id
        }
        default { error "unsupported native stop: $args" }
    }
}

# 原生时刻固定；此单测不推进时间，命中记录必须保留这个原始字符串。
proc senv {field} {
    if {$field ne "time"} { error "unexpected senv field" }
    return {123000 fs}
}

# 暂停桩验证depth守卫已经建立，业务发送/恢复不能在本回调中重入。
proc pause {} {
    incr ::pause_count
    check immediate_pause_guard [expr {[catch {_aip_control_assert_command_allowed}] == 1}]
    resume
}

# 对应一次真实的用户resume动作，供生产execution trace识别而非模拟EOF返回。
proc resume {} {}

foreach {text number} {0 0 08 8 0xff 255 0b101 5 8'hFF 255 8'd09 9 8'b1010 10 8'o17 15} {
    check "parse $text" [expr {[_aip_watch_number $text] eq $number}]
}
foreach text {{} -1 +1 0xG 8'b102 8'o8 8'dff 1_000 4'b10xz 1'hX 3.5 {1+2}} {
    check "reject $text" [expr {[_aip_watch_number $text] eq ""}]
}
check empty_status [expr {[aip_watch_status] eq "{}"}]
set huge [expr {2**128 + 1}]
check bignum [expr {[_aip_watch_number $huge] eq $huge}]
check literal_zero [expr {[_aip_watch_literal 0] eq "1'b0"}]
check literal_one [expr {[_aip_watch_literal 1] eq "1'b1"}]
check literal_wide [expr {[_aip_watch_literal $huge] eq "129'b1[string repeat 0 127]1"}]
check expected_x [expr {[dict get [_aip_watch_expected x] kind] eq "unknown" && [dict get [_aip_watch_expected x] expected] eq "x"}]
check expected_Z_casefold [expr {[dict get [_aip_watch_expected Z] kind] eq "unknown" && [dict get [_aip_watch_expected Z] expected] eq "z"}]
check unknown_match_partial [expr {[_aip_watch_unknown_match {32'h0000x001} x]}]
check unknown_match_negative [expr {![_aip_watch_unknown_match {32'h00000001} x]}]

set before $get_count
foreach path {{tb.sig;quit} {tb.sig == 1} {tb.x[0];bad} {tb.x[-1]} {tb.x
bad}} {
    check bad_path [expr {[catch {aip_watch $path 1}] == 1}]
}
foreach option {stop= stop=2 stop=true stop=-1} {
    check bad_option [expr {[catch {aip_watch tb.sig 1 $option}] == 1}]
}
foreach option {file= ctx=x file=x ctx= file=x ctx=x file=x cont=x} {
    check bad_file_option [expr {[catch {aip_watch tb.sig 1 $option}] == 1}]
}
check duplicate_option [expr {[catch {aip_watch tb.sig 1 stop=0 stop=1}] == 1}]
check duplicate_file_option [expr {[catch {aip_watch tb.sig 1 file=x ctx=a file=y ctx=b}] == 1}]
set wait_error ""
check wait_is_not_a_bridge_option [expr {[catch {aip_watch tb.sig 1 stop=0 wait=0} wait_error] == 1}]
check wait_error_is_usage [string match {usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?} $wait_error]
check invalid_did_not_read [expr {$get_count == $before}]
check unknown_signal [expr {[catch {aip_watch tb.missing 1}] == 1}]

dict set ::_aip_control_state depth 1
dict set ::_aip_control_state mode run
check paused_registration [expr {[catch {aip_watch tb.sig 1} message options] == 1}]
check paused_errorcode [expr {[dict get $options -errorcode] eq {AIP CONTROL BUSY}}]

# A TCP registration is the one narrow exception: it may arm a native stop
# while an ordinary user `run` owns the control depth, but an already-matched
# stop=1 watch must queue its pause for the outer run instead of entering
# _aip_control_pause recursively from MHPI.
set ::_aip_watch_tcp_mode 1
set observed 0
set tcp_watch [aip_watch tb.sig 1 stop=1]
set tcp_record [aip_watch_status $tcp_watch]
check tcp_active_run_registration [expr {[dict get $tcp_record state] eq "armed" && [dict get $tcp_record native_id] ne ""}]
set observed 1
_aip_watch_hit $tcp_watch
check tcp_active_run_queued [expr {[dict get [aip_watch_status $tcp_watch] state] eq "matched" && [llength [dict get [aip_sim_status] events]] == 1}]
_aip_control_drain_events
check tcp_active_run_pause_drained [expr {[llength [dict get [aip_sim_status] events]] == 0}]
set observed 1
set tcp_current [aip_watch tb.sig 1 stop=1]
set tcp_current_record [aip_watch_status $tcp_current]
check tcp_active_run_current_match [expr {[dict get $tcp_current_record state] eq "matched" && [dict get $tcp_current_record native_id] eq "" && [llength [dict get [aip_sim_status] events]] == 1}]
_aip_control_drain_events
check tcp_active_run_current_drained [expr {[llength [dict get [aip_sim_status] events]] == 0}]
unset ::_aip_watch_tcp_mode
set observed 0
dict set ::_aip_control_state depth 0
dict set ::_aip_control_state mode {}
set deleted {}

# Unknown-state targets reuse the same registration/status/cancel path.  They
# wake on any value change and let the callback classify a partial X/Z value,
# without requiring a guessed HDL width in the native stop expression.
set observed 0
set default_x_watch [aip_watch tb.default_data x]
check x_default_notification_only [expr {[dict get [aip_watch_status $default_x_watch] stop] == 0}]
aip_watch_cancel $default_x_watch
set x_watch [aip_watch tb.data x stop=0]
set x_record [aip_watch_status $x_watch]
set x_native [dict get $x_record native_id]
check x_armed [expr {[dict get $x_record target_kind] eq "unknown" && [dict get $x_record expected] eq "x" && [dict get $x_record state] eq "armed"}]
check x_change_stop [expr {[dict get $native_stops $x_native kind] eq "change" && [dict get $native_stops $x_native signal] eq "tb.data"}]
set observed 1
_aip_watch_hit $x_watch
check x_known_probe_keeps_armed [expr {[dict get [aip_watch_status $x_watch] state] eq "armed" && [llength [dict get [aip_sim_status] events]] == 1}]
_aip_control_drain_events
set observed {32'h0000x001}
_aip_watch_hit $x_watch
check x_partial_match [expr {[dict get [aip_watch_status $x_watch] state] eq "matched" && [dict get [aip_watch_status $x_watch] value] eq {32'h0000x001}}]
set observed 0
set z_watch [aip_watch tb.data Z stop=0]
set z_record [aip_watch_status $z_watch]
set z_native [dict get $z_record native_id]
check z_armed [expr {[dict get $z_record expected] eq "z" && [dict get $z_record state] eq "armed"}]
check z_change_stop [expr {[dict get $native_stops $z_native kind] eq "change"}]
set observed {8'hzz}
_aip_watch_hit $z_watch
check z_match [expr {[dict get [aip_watch_status $z_watch] state] eq "matched"}]
_aip_control_drain_events
set deleted {}

set id [aip_watch {tb.array[3].sig} 1]
set pause_before_normal $pause_count
set record [aip_watch_status $id]
set native [dict get $record native_id]
check armed [expr {[dict get $record state] eq "armed" && [dict get $record stop] == 0}]
check no_file_status [expr {[dict get $record file_status] eq "none"}]
check exact_condition [expr {[dict get $native_stops $native condition] eq {tb.array[3].sig == 1'b1}}]
check precise_callback [expr {[dict get $native_stops $native callback] eq [list ::_aip_watch_hit $id]}]
check active_checkpoint_rejected [expr {[catch {_aip_watch_assert_quiescent save}] == 1}]
source [file join $root src tcl aip_watch.tcl]
check repeated_source [expr {[aip_watch_status $id] eq $record}]
set observed 1'bx
_aip_watch_hit $id
check unknown_not_zero [expr {[dict get [aip_watch_status $id] state] eq "armed"}]
set observed 1
dict set ::_aip_control_state depth 1
_aip_watch_hit $id
set record [aip_watch_status $id]
check matched [expr {[dict get $record state] eq "matched"}]
check native_deleted [expr {$deleted eq [list $native] && ![dict exists $native_stops $native]}]
check record_value_time [expr {[dict get $record value] eq "1" && [dict get $record time] eq "123000 fs"}]
check notify_event [expr {[llength [dict get [aip_sim_status] events]] == 1}]
check no_immediate_pause [expr {$pause_count == $pause_before_normal}]
_aip_watch_hit $id
check one_shot [expr {[llength [dict get [aip_sim_status] events]] == 1 && [llength $deleted] == 1}]
dict set ::_aip_control_state depth 0
_aip_control_drain_events

set before_stops $native_next
set pause_before_immediate $pause_count
set immediate [aip_watch tb.sig 1 stop=1]
check immediate_no_stop [expr {$native_next == $before_stops}]
check immediate_matched [expr {[dict get [aip_watch_status $immediate] state] eq "matched"}]
check immediate_paused [expr {$pause_count == $pause_before_immediate + 1 && [dict get [aip_sim_status] depth] == 0}]

# When no AIP run owns the simulator, a native stop callback must enter the
# retained pause directly instead of leaving only a queued event (the TCP/SV
# autonomous-progress path).
set observed 0
set autonomous [aip_watch tb.sig 1 stop=1]
set autonomous_native [dict get [aip_watch_status $autonomous] native_id]
set pause_before $pause_count
set observed 1
_aip_watch_hit $autonomous
check autonomous_matched [expr {[dict get [aip_watch_status $autonomous] state] eq "matched"}]
check autonomous_paused [expr {$pause_count == $pause_before + 1 && [dict get [aip_sim_status] depth] == 0}]
check autonomous_no_queued_pause [expr {[llength [dict get [aip_sim_status] events]] == 0}]
check autonomous_stop_deleted [expr {![dict exists $native_stops $autonomous_native]}]
set observed 0
set autonomous_notify [aip_watch tb.sig 1 stop=0]
set observed 1
_aip_watch_hit $autonomous_notify
check autonomous_notify_event [expr {[llength [dict get [aip_sim_status] events]] == 1}]
_aip_control_drain_events
check autonomous_notify_drained [expr {[llength [dict get [aip_sim_status] events]] == 0}]

# A matched watch writes the exact content before its stop/notification action.
set marker_path [file join [pwd] aip_watch_unit_marker.tmp]
file delete -force $marker_path
set marker_channel [open $marker_path w]
close $marker_channel
set observed 0
set marker_id [aip_watch tb.sig 1 stop=0 file=$marker_path {ctx=READY 1}]
set observed 1
_aip_watch_hit $marker_id
set marker_channel [open $marker_path r]
set marker_data [read $marker_channel]
close $marker_channel
check file_content_exact [expr {$marker_data eq {READY 1}}]
check file_status_written [expr {[dict get [aip_watch_status $marker_id] file_status] eq "written"}]
_aip_control_drain_events

# A missing target is warning-only and must not prevent a stop=1 watch from
# matching and entering the normal pause path.
set missing_path [file join [pwd] aip_watch_unit_missing.tmp]
file delete -force $missing_path
set missing_id [aip_watch tb.sig 1 stop=1 file=$missing_path ctx={MISSING}]
set observed 1
check missing_hit_nonfatal [expr {[catch {_aip_watch_hit $missing_id} missing_error] == 0}]
check missing_status [expr {[dict get [aip_watch_status $missing_id] file_status] eq "missing"}]
file delete -force $marker_path $missing_path

set observed 0
set cancel_id [aip_watch tb.sig 1 stop=1]
set cancel_native [dict get [aip_watch_status $cancel_id] native_id]
dict set ::native_stops 999 [dict create condition user callback user_callback]
dict set ::_aip_control_state depth 1
check cancel_in_pause [expr {[aip_watch_cancel $cancel_id] eq "canceled"}]
dict set ::_aip_control_state depth 0
check cancel_repeated [expr {[aip_watch_cancel $cancel_id] eq "canceled"}]
check user_stop_untouched [dict exists $native_stops 999]
check cancel_owned_stop [expr {![dict exists $native_stops $cancel_native]}]
check quiescent [expr {[catch {_aip_watch_assert_quiescent save}] == 0}]
check unknown_id [expr {[catch {aip_watch_cancel nonexistent}] == 1}]

# Omitting the ID cancels every remaining armed watch, returns only the IDs it
# canceled, and leaves unrelated native stop points plus completed history alone.
set all_one [aip_watch tb.sig 1]
set all_two [aip_watch tb.data 1]
set all_one_native [dict get [aip_watch_status $all_one] native_id]
set all_two_native [dict get [aip_watch_status $all_two] native_id]
set all_canceled [aip_watch_cancel]
check cancel_all_ids [expr {[lsort -integer $all_canceled] eq [lsort -integer [list $all_one $all_two]]}]
check cancel_all_state_one [expr {[dict get [aip_watch_status $all_one] state] eq "canceled"}]
check cancel_all_state_two [expr {[dict get [aip_watch_status $all_two] state] eq "canceled"}]
check cancel_all_owned_stops [expr {![dict exists $native_stops $all_one_native] && ![dict exists $native_stops $all_two_native]}]
check cancel_all_keeps_user_stop [dict exists $native_stops 999]
check cancel_all_empty_repeat [expr {[aip_watch_cancel] eq {}}]

set fail_install 1
check native_install_failure [expr {[catch {aip_watch tb.sig 1}] == 1}]
set fail_install 0
check install_no_stale_owned_stop [expr {[dict size $native_stops] == 1}]
set fail_callback 1
check native_callback_failure [expr {[catch {aip_watch tb.sig 1}] == 1}]
set fail_callback 0
check callback_failure_cleanup [expr {[dict size $native_stops] == 1}]

set ::_aip_watch_restore_pending 1
source [file join $root src tcl aip_watch.tcl]
dict for {id record} [aip_watch_status] {
    check invalidated_after_restore [expr {[dict get $record state] eq "invalidated"}]
}
check foreign_stop_still_owned_by_user [dict exists $native_stops 999]
puts "WATCH_UNIT_PASS checks=$checks"
