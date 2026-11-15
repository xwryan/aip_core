# 真实 VCS bridge watchdog/取消报告验证，只驱动 life_ 测试命令；每个 sim 进程只触发一个永久 recovery 场景。
# VCS -do 不保证 info script 有路径，故由构建入口经环境变量传入 repo 根目录。
set ::env(AIP_CORE) $::env(AIP_RAL_TEST_ROOT)
source [file join $::env(AIP_RAL_TEST_ROOT) src tcl aip_cmd.tcl]
set life_checks 0

proc life_demand {condition label} {
    if {!$condition} { error "RAL_LIFECYCLE_TCL_ASSERT $label" }
    incr ::life_checks
}

# 使用实际逐byte桥接结果，按合法list和首个等号解析，不读取产品内部变量。
proc life_fields {value} {
    life_demand [expr {[llength $value] > 0}] "nonempty_list"
    set fields [dict create _status [lindex $value 0]]
    foreach element [lrange $value 1 end] {
        set split [string first = $element]
        life_demand [expr {$split > 0}] "key_value"
        set key [string range $element 0 [expr {$split - 1}]]
        life_demand [expr {![dict exists $fields $key]}] "no_duplicate_keys"
        dict set fields $key [string range $element [expr {$split + 1}] end]
    }
    return $fields
}

life_mode
set life_case [aip_read_result]
life_demand [expr {$life_case in {action parse inventory quiesce reset resume sequence dirtycancel restore normalleak priorerror cancelleak}}] "known_fresh_case"
life_background wait=0
life_demand [expr {[aip_read_result] eq "STARTED: life_background"}] "background_started"

# 普通命令必须保留旧watchdog文字，内部listener不能篡改所有命令的协议。
life_plain_hang
life_demand [expr {[aip_check_status] == -1 && [string match "ERROR: cmd 'life_plain_hang' stalled *bridge watchdog killed it)*" [aip_read_result]]}] "old_watchdog_text_unchanged"
life_stats
set life_before [life_fields "OK [aip_read_result]"]
life_demand [expr {[dict get $life_before hooks] == 1 && [dict get $life_before watchdog] == 1 && [dict get $life_before background] > 0}] "generic_listener_and_user_hook"

if {$life_case in {dirtycancel restore normalleak cancelleak}} {
    life_hang
} else {
    # 两个fork子命令且RAL在wrapper的同步后代中：必须继承同请求scope，不能按名字猜。
    aip_send_cmd "fork life_wrapper, life_plain_hang join"
}
set life_result [aip_read_result]
life_demand [expr {[aip_check_status] != 0 && $life_result ne "OLD_OK_MUST_NOT_ESCAPE" && [string length $life_result] <= 1024}] "current_terminal_result_replaces_old_OK"
set life_current [life_fields $life_result]
set life_clean [expr {$life_case in {parse inventory}}]
life_demand [expr {[dict get $life_current recovery_required] == !$life_clean}] "phase_sensitive_recovery"
foreach key {phase side_effects partial restore resumed reset_attempted reset_performed destructive} {
    life_demand [dict exists $life_current $key] "complete_terminal_safety"
}
if {$life_case in {dirtycancel cancelleak}} {
    life_demand [expr {[dict get $life_current code] eq "CANCELLED"}] "dirty_cooperative_cancel"
} elseif {$life_case eq "normalleak"} {
    life_demand [expr {[dict get $life_current code] eq "BUS_ERROR"}] "normal_return_with_live_sequence_is_not_clean"
} elseif {$life_case eq "priorerror"} {
    life_demand [expr {[dict get $life_current code] eq "HOOK_ERROR" && [dict get $life_current phase] eq "quiesce" && [dict get $life_current global_errors] == 2}] "earliest_error_phase_separate_from_current_action"
} elseif {$life_case eq "restore"} {
    life_demand [expr {[dict get $life_current restore] eq "failed" && [dict get $life_current _status] eq "FAIL" && [dict get $life_current first_status] eq "ERROR" && [dict get $life_current first_code] eq "RESTORE_ERROR"}] "normal_restore_failure_current_response"
} else {
    life_demand [expr {[dict get $life_current code] eq "WATCHDOG_TIMEOUT"}] "actual_watchdog_snapshot"
}
if {$life_case in {parse sequence}} {
    life_demand [expr {[dict get $life_current inventory_complete] == 0 && ![dict exists $life_current total]}] "pre_inventory_no_fake_counts"
} else {
    life_demand [expr {[dict get $life_current inventory_complete] == 1 && [dict get $life_current total] == 6 && [dict get $life_current fields] == 6 && [dict get $life_current memories] == 0}] "committed_inventory_preserved"
    life_demand [expr {[dict get $life_current passed] + [dict get $life_current excluded] + [dict get $life_current failed] + [dict get $life_current errors] + [dict get $life_current untestable] == 6}] "terminal_count_conservation"
    life_demand [expr {[dict get $life_current passed] == 1 && [dict get $life_current excluded] == 1}] "outside_PASS_and_active_EXCLUDED_preserved"
    if {$life_case in {action dirtycancel normalleak priorerror restore cancelleak}} {
        life_demand [expr {[dict get $life_current errors] == 2 && [dict get $life_current failed] == 1 && [dict get $life_current untestable] == 1 && [dict get $life_current first] eq "soc.f0"}] "active_FAIL_upgraded_outside_FAIL_preserved"
    } else {
        life_demand [expr {[dict get $life_current errors] == 0 && [dict get $life_current failed] == 2 && [dict get $life_current untestable] == 2}] "global_phase_keeps_finalized_leaf_results"
    }
}
if {$life_case eq "reset"} {
    life_demand [expr {[dict get $life_current reset_attempted] == 1 && [dict get $life_current reset_performed] == 0 && [dict get $life_current destructive] == 1}] "reset_attempt_atomic_markers"
}

# 原因属于详细账本而非公共报告新key；从只读测试入口校验深拷贝和保留边界。
life_reasons
set life_reasons [life_fields "OK [aip_read_result]"]
life_demand [expr {[dict get $life_reasons outside] eq "" && [dict get $life_reasons excluded] eq ""}] "outside_and_EXCLUDED_reasons_unchanged"
if {$life_case ni {parse sequence}} {
    set pending_reason aborted_after_watchdog
    set active_reason ""
    if {$life_case in {action priorerror}} { set active_reason watchdog_killed }
    if {$life_case in {dirtycancel cancelleak}} {
        set active_reason cancel_cleanup_failed
        set pending_reason aborted_after_cancel
    }
    if {$life_case eq "normalleak"} {
        set active_reason unclosed_sequence_or_grab
        set pending_reason aborted_after_error
    }
    if {$life_case eq "restore"} {
        set active_reason restore_failed
        set pending_reason aborted_after_error
    }
    life_demand [expr {[dict get $life_reasons active] eq $active_reason && [dict get $life_reasons pending] eq $pending_reason}] "terminal_leaf_reasons_preserved_in_snapshot"
}

life_stats
set life_after [life_fields "OK [aip_read_result]"]
set life_was_watchdog [expr {$life_case ni {dirtycancel restore normalleak cancelleak}}]
life_demand [expr {[dict get $life_after hooks] == 1 + $life_was_watchdog && [dict get $life_after watchdog] == 1 + $life_was_watchdog}] "hook_and_fork_listener_coexist"
life_demand [expr {[dict get $life_after background] > [dict get $life_before background]}] "unrelated_background_survives"

foreach name {life_gate_op life_gate_test} {
    aip_send_cmd "$name deliberately_malformed"
    set gate [life_fields [aip_read_result]]
    if {$life_clean} {
        life_demand [expr {[dict get $gate code] eq "BAD_ARGS"}] "clean_kill_does_not_permanently_gate"
    } else {
        life_demand [expr {[dict get $gate code] eq "RECOVERY_REQUIRED" && [dict get $gate phase] eq "dispatch" && [dict get $gate recovery_required] == 1}] "permanent_gate_before_parse"
        foreach key {side_effects partial restore resumed} {
            life_demand [expr {[dict get $gate $key] eq [dict get $life_current $key]}] "latched_safety_not_mutated"
        }
        if {$name eq "life_gate_test"} {
            life_demand [expr {[dict get $gate inventory_complete] == 0 && [dict get $gate reset_attempted] == 0 && [dict get $gate reset_performed] == 0 && [dict get $gate destructive] == 0 && ![dict exists $gate total]}] "new_command_gate_no_inventory_reset"
        }
    }
}
life_stats
set life_end [life_fields "OK [aip_read_result]"]
life_demand [expr {[dict get $life_end parses] == ($life_clean ? 2 : 0) && [dict get $life_end actions] == [dict get $life_after actions]}] "gate_zero_parse_or_DUT_actions"

# 主动清理测试后台；仅用户显式kill可以结束它，随后end_test让UVM产生最终summary。
kill_seq name=life_background
puts "RAL_LIFECYCLE_TCL_PASS case=$life_case checks=$life_checks"
end_test
run
quit
