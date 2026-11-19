# 纯 Tcl 控制层单测（独立虚拟时间/桥接槽/事件队列，模拟原生推进/暂停）：经真实 Tcl execution frame 区分 pause% 与 stop 回调，
# 检查嵌套推进不覆盖原 owner/结果/截止时间。真实 pause%、Ctrl+C、二进制入口由 VCS 上的 PTY 回归覆盖。
set test_root [file normalize [file join [file dirname [info script]] ../..]]
set control_file [file join $test_root src tcl aip_sim_control.tcl]
set checks 0

proc check {name condition} {
    if {!$condition} { error "SIM_CONTROL_UNIT_FAIL: $name" }
    incr ::checks
}
proc equal {name actual expected} { check "$name: '$actual' != '$expected'" [expr {$actual eq $expected}] }
# 只接受指定错误码；TCL_RETURN/BREAK 等不能被当成安全的拒绝。
proc rejects {name script errorcode} {
    set code [catch {uplevel 1 $script} value options]
    check "$name must fail" [expr {$code == 1}]
    equal "$name errorcode" [dict get $options -errorcode] $errorcode
}

# 控制层绝不可替换这些用户/原生入口；固定返回文本用于检测是否偷换了 onbreak。
proc onbreak {args} { return {user_break_handler} }
# 原生 resume 夹具区分有效恢复、帮助和非法参数，供 execution trace 验证。
proc resume {args} {
    if {$args eq "-help"} {return native_help}
    if {[llength $args] != 0} {error native_bad_arguments}
    return native_resume_untouched
}
set original_onbreak [info body onbreak]
set original_resume [info body resume]
source $control_file

# 每个场景拥有独立桥接槽和仿真时间；队列元素为 {绝对fs 触发Tcl脚本}。
proc reset_fixture {} {
    set ::_aip_control_state [dict create depth 0 mode {} pending_id {} orphan_id {} watch_paused 0 pause_reason {} events {} resume_serial 0 tty_mode unknown tty_probe_error {} debug_active 0 debug_event {}]
    set ::now_fs 0
    set ::native_calls {}
    set ::force_calls {}
    set ::stops {}
    set ::pause_count 0
    set ::pause_action {}
    set ::native_error 0
    set ::native_return 0
    set ::pause_eof 0
    set ::get_count 0
    set ::get_error 0
    set ::tty_fixture tty
    set ::tty_probes 0
    array set ::bridge {__tcl_result_id 0 __tcl_cmd_id 0 __tcl_cmd_trigger 0 __tcl_cmd_len 0}
}

# host 单测不依赖运行 pytest/make 的终端类型；只模拟 test 的三种实际结果。
rename exec _unit_native_exec
proc exec {args} {
    equal tty_probe_arguments $args {test -t 0 <@ stdin}
    incr ::tty_probes
    switch -- $::tty_fixture {
        tty { return {} }
        non_tty { return -code error -errorcode {CHILDSTATUS 123 1} {child process exited abnormally} }
        default { return -code error -errorcode {POSIX ENOENT} {test executable missing} }
    }
}
# 仅暴露整数 fs 时间和固定 ps 精度；不模拟格式化显示时间的舍入。
proc senv {key} {
    switch -- $key {
        time { return "$::now_fs fs" }
        timePrecision { return {1 ps} }
        default { error "unknown senv key $key" }
    }
}
# 虚拟桥接读取可注入错误，用于确保不把未知 HDL 状态当作有效 ACK。
proc get {path} {
    incr ::get_count
    if {$::get_error} { return -code error -errorcode {MOCK GET ERROR} unreadable_hdl }
    if {![regexp {^aip_core_pkg::(.*)$} $path -> name]} {error "unexpected get $path"}
    return $::bridge($name)
}

# force 夹具保存精确目标；调试 ACK 清尾不可写 result_id 或别的结果槽。
proc force {path value} {
    lappend ::force_calls [list $path $value]
    if {![regexp {^aip_core_pkg::(.*)$} $path -> name]} {error "unexpected force $path"}
    set ::bridge($name) [_aip_control_scalar $value]
}

namespace eval synopsys {}
# 模拟 VCS 实际 ::synopsys::pause 帧以及 uplevel #0 提示符；普通回调没有
# 此帧。暂停内检查共享桥/恢复门禁，有限调试推进交给每个场景单独验证。
proc synopsys::pause {} {
    incr ::pause_count
    equal paused_flag [dict get [aip_sim_status] watch_paused] 1
    check paused_depth [expr {[dict get [aip_sim_status] depth] > 0}]
    equal actual_pause_context [_aip_control_is_paused_context] 1
    rejects send_during_pause {_aip_control_assert_command_allowed} {AIP CONTROL BUSY}
    rejects unlimited_during_pause {_aip_advance run} {AIP CONTROL DEBUG_UNSUPPORTED}
    rejects reconcile_during_pause {_aip_control_reconcile} {AIP CONTROL BUSY}
    if {$::pause_action ne ""} {uplevel #0 $::pause_action}
    if {!$::pause_eof} {resume}
}
# 全局原生别名保留独立调用层，以覆盖与真实 UCLI 相同的帧命名。
proc pause {} { synopsys::pause }

# 模拟原生命令一次推进到期限或首个断点。它不会替控制层自动补期限。
proc _vcs_run {args} {
    lappend ::native_calls $args
    if {$::native_error} { return -code error -errorcode {MOCK NATIVE ERROR} native_error }
    if {$::native_return} { return -code return native_return }
    set args [lsearch -all -inline -not -exact $args -keep]
    set absolute 0
    if {[llength $args] > 0 && [lindex $args 0] in {-absolute absolute -relative relative}} {
        set absolute [expr {[lindex $args 0] in {-absolute absolute}}]
        set args [lrange $args 1 end]
    }
    if {[llength $args] == 0} {
        set deadline 999999999999999999999999
    } elseif {[llength $args] == 1} {
        set duration [_aip_control_time_fs [lindex $args 0] 1000]
        set deadline [expr {$absolute ? $duration : $::now_fs + $duration}]
    } else {
        set deadline 999999999999999999999999
    }
    if {[llength $::stops] != 0 && [lindex $::stops 0 0] <= $deadline} {
        set stop [lindex $::stops 0]
        set ::stops [lrange $::stops 1 end]
        set ::now_fs [lindex $stop 0]
        uplevel #0 [lindex $stop 1]
        return native_stop
    }
    set ::now_fs $deadline
    return native_done
}

reset_fixture
equal exact_bignum [_aip_control_time_fs 9007199254740993fs] 9007199254740993
equal exact_seconds [_aip_control_time_fs 001.000000000000001s] 1000000000000001
equal leading_zero [_aip_control_time_fs 08.125ns] 8125000
equal decimal_subunit [_aip_control_time_fs 0.001ps] 1
equal unitless_precision [_aip_control_time_fs 10 1000] 10000
equal zero [_aip_control_time_fs 0] 0
foreach value {0.1fs 1e3ns -1ns NaN 1NS} {
    rejects "reject time $value" {_aip_control_time_fs $value} {AIP CONTROL TIME}
}
equal scalar_hex [_aip_control_scalar {32'hff}] 255
equal scalar_binary [_aip_control_scalar {'b101}] 5
equal scalar_decimal [_aip_control_scalar {32'd008}] 8
foreach value {'bX 'b102 'hZ 08x} {
    rejects "reject scalar $value" {_aip_control_scalar $value} {AIP CONTROL STATE}
}

# 源码重复加载必须保留用户 hook、原生命令和已排队事件。
_aip_control_signal_watch preserved 0
source $control_file
equal onbreak_untouched [info body onbreak] $original_onbreak
equal resume_untouched [info body resume] $original_resume
equal reload_preserves_events [llength [dict get [aip_sim_status] events]] 1

# 两个 watch 只打断原本的一段 run：notify-only 也必须补剩余时长。
reset_fixture
set stops {{20000000 {_aip_control_signal_watch notice 0}} {30000000 {_aip_control_signal_pause paused}}}
equal run_result [_aip_advance run 100ns] native_done
equal fixed_deadline $now_fs 100000000
equal one_pause $pause_count 1
equal three_advances [llength $native_calls] 3
equal original_keep [lindex $native_calls 0] {-keep 100ns}
equal first_remainder [lindex $native_calls 1] {-keep 80000000fs}
equal second_remainder [lindex $native_calls 2] {-keep 70000000fs}
equal depth_clean [dict get [aip_sim_status] depth] 0

# 大于 double 精确整数范围的仿真时刻仍逐 fs 正确；暂停中若原生调试命令
# 推进了时间，恢复依据原截止点扣除，而不是把剩余时长再次叠加。
reset_fixture
set now_fs 9007199254740993
set stops [list [list 9007199254740995 {_aip_control_signal_watch bignum 0}]]
_aip_advance run 7fs
equal bignum_deadline $now_fs 9007199254741000
equal bignum_remainder [lindex $native_calls 1] {-keep 5fs}
reset_fixture
_aip_control_signal_pause queued
set pause_action {incr ::now_fs 10000000}
_aip_advance run 100ns
equal initial_pause_deadline $now_fs 100000000
equal initial_pause_remaining [lindex $native_calls 0] {-keep 90000000fs}

# 原生的其他用户断点不属于 AIP watch，必须返回、不自动跨过去。
reset_fixture
set stops {{25000000 {set ::user_hook_ran 1}}}
equal foreign_stop_result [_aip_advance run 100ns] native_stop
equal foreign_stop_time $now_fs 25000000
equal foreign_stop_one_advance [llength $native_calls] 1
equal foreign_hook $user_hook_ran 1

# ACK 与 watch 同时到达：先暂停，恢复后返回真实 ACK，不补剩余 80ns。
reset_fixture
_aip_control_pending_begin 7
set stops {{20000000 {set ::bridge(__tcl_result_id) 7; _aip_control_signal_pause ack_ready}}}
equal ack_result [_aip_advance ack 100ns] native_stop
equal ack_no_extra_time $now_fs 20000000
equal ack_no_extra_run [llength $native_calls] 1
equal pending_survives [dict get [aip_sim_status] pending_id] 7
rejects wrong_pending_end {_aip_control_pending_end 8} {AIP CONTROL STATE}
_aip_control_pending_end 7
equal pending_released [dict get [aip_sim_status] pending_id] {}

# ACK 早已就绪，不得再次推进；预先排队的暂停仍应被兑现。
reset_fixture
_aip_control_pending_begin 9
set bridge(__tcl_result_id) 9
_aip_control_signal_pause before_ack
_aip_advance ack 100ns
equal ready_ack_no_run [llength $native_calls] 0
equal ready_ack_pause $pause_count 1
_aip_control_pending_end 9

# absolute、无单位、显式 -keep、run 0 及无限 run 的参数语义。
# helper 推进嵌在 proc 内调用，从不自动加 -keep；run 推进在 TTY 下自动加，补剩余时长时保留。
reset_fixture
set now_fs 10000000
set stops {{20000000 {_aip_control_signal_watch abs_notice 0}}}
_aip_advance helper -absolute 50ns
equal absolute_deadline $now_fs 50000000
equal absolute_helper_remainder [lindex $native_calls 1] 30000000fs
reset_fixture
set now_fs 10000000
set stops {{20000000 {_aip_control_signal_watch abs_notice 0}}}
_aip_advance run -absolute 50ns
equal absolute_run_deadline $now_fs 50000000
equal absolute_run_first [lindex $native_calls 0] {-keep -absolute 50ns}
equal absolute_remainder [lindex $native_calls 1] {-keep 30000000fs}
reset_fixture
_aip_advance run 10
equal bare_uses_precision $now_fs 10000
reset_fixture
_aip_advance run -keep 10ns
equal no_duplicate_keep [lindex $native_calls 0] {-keep 10ns}
reset_fixture
_aip_advance run 0
equal zero_runs_once [llength $native_calls] 1
equal zero_preserves_time $now_fs 0
equal zero_no_implicit_keep [lindex $native_calls 0] 0
reset_fixture
set stops {{1000 {_aip_control_signal_watch infinity 0}} {2000 {set ::foreign 1}}}
_aip_advance run
equal unlimited_resumes [llength $native_calls] 2
equal unlimited_foreign_returns $now_fs 2000

# 内部启动/存档/清理推进不消费 watch 事件，不自行增加 -keep。
foreach mode {bootstrap checkpoint settle} {
    reset_fixture
    _aip_control_signal_pause deferred
    _aip_advance $mode 0
    equal "$mode raw args" [lindex $native_calls 0] 0
    equal "$mode no pause" $pause_count 0
    equal "$mode retains watch" [llength [dict get [aip_sim_status] events]] 1
    set native_return 1
    set code [catch {_aip_advance $mode} value options]
    equal "$mode preserves native return" $code 2
    equal "$mode return text" $value native_return
    equal "$mode return cleans depth" [dict get [aip_sim_status] depth] 0
}

# 原生错误清除本层深度但不能吞掉 errorcode、重发请求或清掉命令拥有权。
reset_fixture
_aip_control_pending_begin 11
set native_error 1
rejects native_failure {_aip_advance ack 100ns} {MOCK NATIVE ERROR}
equal error_clean_depth [dict get [aip_sim_status] depth] 0
equal error_keeps_owner [dict get [aip_sim_status] pending_id] 11
_aip_control_pending_end 11

# 空闲时当前值已匹配可立即暂停，不需要下一次 run 才生效。
reset_fixture
_aip_control_pause immediate
equal immediate_pause $pause_count 1
equal immediate_depth_clean [dict get [aip_sim_status] depth] 0
equal resume_trace_removed [trace info execution resume] {}
reset_fixture
set pause_eof 1
rejects eof_must_not_continue {_aip_control_pause no_input} {AIP CONTROL PAUSE_ABORTED}
equal eof_depth_clean [dict get [aip_sim_status] depth] 0
equal eof_trace_removed [trace info execution resume] {}
reset_fixture
set pause_eof 1
set pause_action {catch {resume badarg}; resume -help}
rejects invalid_resume_is_not_success {_aip_control_pause bad_resume} {AIP CONTROL PAUSE_ABORTED}
equal invalid_resume_did_not_advance [dict get [aip_sim_status] resume_serial] 0

# 无 debug/无 HDL 读取权限的全新加载不需要 get；残留状态仍严格读并报错。
reset_fixture
set get_error 1
_aip_control_reconcile
equal clean_reconcile_no_get $get_count 0
dict set ::_aip_control_state depth 2
rejects dirty_reconcile_strict {_aip_control_reconcile} {MOCK GET ERROR}

# restore/reload 遗留深度只能在实际栈已退出后恢复；队列不能被顺手删掉。
reset_fixture
dict set ::_aip_control_state depth 3
dict set ::_aip_control_state mode ack
dict set ::_aip_control_state pending_id 123
_aip_control_signal_watch restore_notice 0
_aip_control_reconcile
equal reconciled_depth [dict get [aip_sim_status] depth] 0
equal reconciled_idle_pending [dict get [aip_sim_status] pending_id] {}
equal reconciled_watch_preserved [llength [dict get [aip_sim_status] events]] 1
set bridge(__tcl_cmd_trigger) 1
set bridge(__tcl_cmd_len) 9
set bridge(__tcl_cmd_id) 17
_aip_control_reconcile
equal reconciled_orphan [dict get [aip_sim_status] orphan_id] 17
equal reconciled_no_owner [dict get [aip_sim_status] pending_id] {}
_aip_control_assert_idle aip_recover

# 不支持的目标不能悄悄重跑；无事件时仍完整交给原生处理。
reset_fixture
set stops {{1000 {_aip_control_signal_watch advanced 0}}}
rejects opaque_resume {_aip_advance run -line 42} {AIP CONTROL UNSUPPORTED_RESUME}
equal opaque_keeps_native [lindex $native_calls 0] {-keep -line 42}
equal opaque_error_cleans_depth [dict get [aip_sim_status] depth] 0
rejects bad_mode {_aip_advance nonsense 1ns} {AIP CONTROL ARGUMENT}
rejects bad_pause_flag {_aip_control_signal_watch invalid maybe} {AIP CONTROL ARGUMENT}

# 自动 -keep 只给真实TTY；非TTY首轮、watch补时、无限续跑都不能偷偷加上。
reset_fixture
set tty_fixture non_tty
set stops {{20000000 {_aip_control_signal_watch batch 0}}}
_aip_advance run 100ns
equal batch_first_no_keep [lindex $native_calls 0] 100ns
equal batch_remainder_no_keep [lindex $native_calls 1] 80000000fs
equal batch_exact_deadline $now_fs 100000000
equal batch_detected [dict get [aip_sim_status] tty_mode] non_tty
_aip_advance run 1ns
equal detection_cached $tty_probes 1
_aip_control_reconcile
equal restore_invalidates_tty_cache [dict get [aip_sim_status] tty_mode] unknown
set tty_fixture tty
_aip_advance run 1ns
equal restore_reprobes_current_input $tty_probes 2
equal restore_new_tty [dict get [aip_sim_status] tty_mode] tty
equal restore_uses_new_keep [lindex $native_calls end] {-keep 1ns}
reset_fixture
set tty_fixture non_tty
set stops {{1000 {_aip_control_signal_watch batch_unlimited 0}} {2000 {set ::done 1}}}
_aip_advance run
equal batch_unlimited_first [lindex $native_calls 0] {}
equal batch_unlimited_again [lindex $native_calls 1] {}
reset_fixture
set tty_fixture non_tty
set stops {{20000000 {_aip_control_signal_watch user_keep 0}}}
_aip_advance run -keep 100ns
equal explicit_keep_honored [lindex $native_calls 0] {-keep 100ns}
equal explicit_keep_remainder [lindex $native_calls 1] {-keep 80000000fs}
equal explicit_keep_no_probe $tty_probes 0
reset_fixture
set tty_fixture missing
_aip_advance run 1ns
equal failed_probe_no_keep [lindex $native_calls 0] 1ns
equal failed_probe_recorded [dict get [aip_sim_status] tty_mode] probe_failed
check failed_probe_diagnostic [expr {[dict get [aip_sim_status] tty_probe_error] ne ""}]
_aip_control_reconcile
equal restore_clears_probe_error [dict get [aip_sim_status] tty_probe_error] {}
equal restore_retries_failed_probe [dict get [aip_sim_status] tty_mode] unknown

# depth/watch_paused 残留和正在运行的 stop 回调都不是原生 pause 提示符。
reset_fixture
dict set ::_aip_control_state depth 1
dict set ::_aip_control_state watch_paused 1
equal stale_state_not_pause [_aip_control_is_paused_context] 0
rejects stale_debug_refused {_aip_debug_advance 1ns} {AIP CONTROL BUSY}
equal stale_no_native [llength $native_calls] 0
reset_fixture
set stops {{1000000 {
    equal running_callback_not_pause [_aip_control_is_paused_context] 0
    rejects callback_run {_aip_advance run 1ns} {AIP CONTROL BUSY}
    rejects callback_debug {_aip_debug_advance 1ns} {AIP CONTROL BUSY}
}}}
_aip_advance run 10ns

# proc/uplevel #0 嵌套仍必须识别真实 pause 帧；调试时间计入原绝对期限。
# 同时拒绝无界/高级目标，且预检不碰 native/force/状态。
proc debug_user_proc {} {
    equal sourced_proc_pause [_aip_control_is_paused_context] 1
    set snapshot $::_aip_control_state
    foreach args {{} {-line 12} {-posedge clk} {-keep} {-absolute 1ns} {-1ns}} {
        rejects "unsupported debug $args" {_aip_advance run {*}$args} {AIP CONTROL DEBUG_UNSUPPORTED}
    }
    equal rejected_debug_preserves_state $::_aip_control_state $snapshot
    set result [_aip_advance helper 30ns]
    equal debug_before [dict get $result before] 20000000
    equal debug_after [dict get $result after] 50000000
    equal original_mode_retained [dict get [aip_sim_status] mode] run
    equal original_depth_retained [dict get [aip_sim_status] depth] 1
    equal debug_no_nested_keep [lindex $::native_calls end] 30000000fs
}
reset_fixture
set stops {{20000000 {_aip_control_signal_pause retained}}}
set pause_action debug_user_proc
_aip_advance run 100ns
equal debug_remaining_original_deadline $now_fs 100000000
equal debug_original_remainder [lindex $native_calls end] {-keep 50000000fs}
reset_fixture
set stops {{20000000 {_aip_control_signal_pause cross}}}
set pause_action {_aip_debug_advance 150ns}
_aip_advance run 100ns
equal debug_cross_no_extra $now_fs 170000000
equal debug_cross_native_count [llength $native_calls] 2

# 原请求 ACK 在暂停期间到达：只清匹配 trigger/len，保留 owner、结果 ID/
# 内容。ACK 截断后继续到调试期限，最后恢复时原 caller 立即消费同一结果。
reset_fixture
_aip_control_pending_begin 31
array set bridge {__tcl_cmd_id 31 __tcl_cmd_trigger 1 __tcl_cmd_len 55 __tcl_result_str ORIGINAL}
set stops {{20000000 {_aip_control_signal_pause original_wait}} {70000000 {set ::bridge(__tcl_result_id) 31}}}
set pause_action {
    _aip_debug_advance 100ns
    equal debug_ack_owner [dict get [aip_sim_status] pending_id] 31
    equal debug_ack_result_id $::bridge(__tcl_result_id) 31
    equal debug_ack_result_text $::bridge(__tcl_result_str) ORIGINAL
    equal debug_ack_trigger $::bridge(__tcl_cmd_trigger) 0
    equal debug_ack_length $::bridge(__tcl_cmd_len) 0
    foreach write $::force_calls {
        check ack_only_owns_tail [expr {[lindex $write 0] in {aip_core_pkg::__tcl_cmd_trigger aip_core_pkg::__tcl_cmd_len}}]
    }
}
_aip_advance ack 100ns
equal debug_ack_time $now_fs 120000000
equal debug_ack_native_count [llength $native_calls] 3
_aip_control_pending_end 31

# 其他 ID 的 ACK 不可清尾；真实 ID 与 owner 矛盾必须拒绝并保留所有槽。
reset_fixture
_aip_control_pending_begin 32
array set bridge {__tcl_cmd_id 32 __tcl_cmd_trigger 1 __tcl_cmd_len 55 __tcl_result_id 999}
set stops {{20000000 {_aip_control_signal_pause unrelated_ack}}}
set pause_action {
    _aip_debug_advance 10ns
    equal unrelated_ack_no_force [llength $::force_calls] 0
    set ::bridge(__tcl_result_id) 32
    set ::bridge(__tcl_cmd_id) 99
    rejects wrong_bridge_owner {_aip_debug_advance 1ns} {AIP CONTROL STATE}
    equal wrong_owner_no_force [llength $::force_calls] 0
    equal wrong_owner_guard_cleared [dict get [aip_sim_status] debug_active] 0
    set ::bridge(__tcl_cmd_id) 32
}
_aip_advance ack 100ns
_aip_control_pending_end 32

# 新 watch/未知断点只终止调试命令，不递归 pause，也不放行原脚本。
foreach {event expected_kind} {
    {_aip_control_signal_pause nested_watch} watch
    {set ::foreign_stop 1} native_stop
} {
    reset_fixture
    set stops [list [list 20000000 {_aip_control_signal_pause outer}] [list 30000000 $event]]
    set ::expected_kind $expected_kind
    set pause_action {
        rejects nested_stop {_aip_debug_advance 50ns} {AIP CONTROL DEBUG_INTERRUPTED}
        equal debug_stop_time $::now_fs 30000000
        equal debug_stop_event [dict get [aip_sim_status] debug_event kind] $::expected_kind
        equal debug_still_paused [dict get [aip_sim_status] watch_paused] 1
        equal debug_not_reentrant [dict get [aip_sim_status] debug_active] 0
        equal debug_did_not_resume [dict get [aip_sim_status] resume_serial] 0
        _aip_debug_advance 1ns
    }
    _aip_advance run 100ns
    equal debug_one_original_pause $pause_count 1
    equal debug_stop_original_deadline $now_fs 100000000
}

# 通知可补时；调试原生回调的重入、reconcile 均拒绝，原队列前缀不能被
# debug 消费，否则外层 drain 的批计数会失效或漏掉第二个已排队暂停。
reset_fixture
set stops {{20000000 {_aip_control_signal_pause outer}} {30000000 {
    equal nested_native_not_prompt [_aip_control_is_paused_context] 0
    rejects recursive_debug {_aip_debug_advance 1ns} {AIP CONTROL BUSY}
    rejects recursive_reconcile {_aip_control_reconcile} {AIP CONTROL BUSY}
    _aip_control_signal_watch debug_notice 0
}}}
set pause_action {_aip_debug_advance 50ns; equal notify_debug_deadline $::now_fs 70000000}
_aip_advance run 100ns
equal debug_notify_original_deadline $now_fs 100000000
reset_fixture
_aip_control_signal_pause first
_aip_control_signal_pause second
set pause_action {
    if {$::pause_count == 1} {
        _aip_debug_advance 1ns
        equal original_event_retained [llength [dict get [aip_sim_status] events]] 1
    }
}
_aip_advance run 100ns
equal original_event_pauses $pause_count 2

# 原生错误保持错误码，取消式 TCL_RETURN 降级成安全错误；finally 只释放
# 调试防重入，不碰原 depth/mode。restore 在真实栈退出后可清陈旧 debug 标志。
reset_fixture
set stops {{20000000 {_aip_control_signal_pause error_case}}}
set pause_action {
    set ::native_error 1
    rejects debug_native_error {_aip_debug_advance 1ns} {MOCK NATIVE ERROR}
    set ::native_error 0
    set ::native_return 1
    rejects debug_native_cancel {_aip_debug_advance 1ns} {AIP CONTROL DEBUG_INTERRUPTED}
    set ::native_return 0
    equal debug_error_depth [dict get [aip_sim_status] depth] 1
    equal debug_error_mode [dict get [aip_sim_status] mode] run
    equal debug_error_guard [dict get [aip_sim_status] debug_active] 0
}
_aip_advance run 100ns
dict set ::_aip_control_state debug_active 1
_aip_control_reconcile
equal reconcile_debug_reset [dict get [aip_sim_status] debug_active] 0
equal final_resume_untouched [info body resume] $original_resume
equal final_onbreak_untouched [info body onbreak] $original_onbreak

# 真实辅助库的门禁必须先于信号副作用；这里只替换 HDL 读写边界，保留
# run_to/wait_posedge/pulse/reset_dut 的生产实现及其对控制层的路由。
source [file join $test_root src tcl aip_ucli_utils.tcl]
set ::fv_verbose 0
# 记录脉冲/复位写入；默认返回不影响辅助流程自己的返回值。
proc fv {path value args} { lappend ::helper_writes [list $path $value {*}$args] }
# 记录临时 force 归还，验证调试中断后没有半个脉冲遗留。
proc fv_release {path} { lappend ::helper_writes [list release $path] }
# ready 恒为一，clk 每次读取翻转；其余信号恒零，用于有限超时路径。
proc gv {path args} {
    if {$path eq "ready"} {return 1}
    if {$path eq "clk"} {set result $::helper_clock; set ::helper_clock [expr {!$::helper_clock}]; return $result}
    return 0
}
reset_fixture
set ::helper_writes {}
set ::helper_clock 0
set stops {{20000000 {_aip_control_signal_pause helper_case}}}
set pause_action {
    equal helper_immediate_match [run_to ready 1] 1
    equal helper_finite_timeout [run_to low 1 -timeout 2ns -poll 1ns] 0
    equal helper_finite_edge [wait_posedge clk -timeout 2ns -poll 1ns] 1
    pulse signal 1 2ns
    reset_dut reset 0 3ns
    equal helper_pause_time $::now_fs 28000000
    equal helper_writes $::helper_writes {{signal 1 -force} {release signal} {signal 0} {reset 0 -force} {reset 1 -force}}
    set before $::helper_writes
    rejects pulse_unbounded {pulse bad 1 nonsense} {AIP CONTROL DEBUG_UNSUPPORTED}
    rejects reset_unbounded {reset_dut bad 0 nonsense} {AIP CONTROL DEBUG_UNSUPPORTED}
    equal helper_bad_duration_no_force $::helper_writes $before
}
_aip_advance run 100ns
equal helper_original_deadline $now_fs 100000000
reset_fixture
set ::helper_writes {}
set stops {{20000000 {_aip_control_signal_pause interrupted_pulse}} {30000000 {_aip_control_signal_pause pulse_watch}}}
set pause_action {
    rejects pulse_interrupted {pulse signal 1 20ns} {AIP CONTROL DEBUG_INTERRUPTED}
    equal interrupted_pulse_released $::helper_writes {{signal 1 -force} {release signal} {signal 0}}
}
_aip_advance run 100ns
reset_fixture
set ::helper_writes {}
set stops {{1000000 {
    rejects callback_pulse {pulse signal 1 1ns} {AIP CONTROL BUSY}
    rejects callback_reset {reset_dut reset 0 1ns} {AIP CONTROL BUSY}
    rejects callback_run_to {run_to ready 1} {AIP CONTROL BUSY}
    rejects callback_wait_edge {wait_posedge clk} {AIP CONTROL BUSY}
    equal callback_helpers_no_force $::helper_writes {}
}}}
_aip_advance run 10ns

rename exec {}
rename _unit_native_exec exec

puts "SIM_CONTROL_UNIT_PASS checks=$checks"
