# 正式暂停注入 API 的真实业务断言；不读取队列私有槽、不替换生产 proc、不模拟调度完成。
set ::pi_checks 0
set ::pi_returned 0
set ::pi_suffix 0
set ::pi_mode $::env(AIP_INJECTION_MODE)
if {$::pi_mode eq "manual"} { set ::aip_ack_timeout_ns 1000000 }

# 检查须基于真实读回值；异常由外层 PTY 捕获。
proc pi_check {name condition} {
    if {!$condition} { error "AIP_INJECTION_FAIL $name" }
    incr ::pi_checks
    puts "AIP_INJECTION_CHECK $name"
}

# 从VCS原生时间文本独立解析整数fs，避免测试和待测层共享时间换算错误。
proc pi_now {} {
    if {![regexp {^\s*([0-9]+)(?:\.([0-9]+))?\s*(fs|ps|ns|us|ms|s)\s*$} [senv time] -> whole fraction unit]} {
        error "AIP_INJECTION_FAIL bad simulation time"
    }
    set scale [dict get {fs 1 ps 1000 ns 1000000 us 1000000000 ms 1000000000000 s 1000000000000000} $unit]
    set whole [string trimleft $whole 0]
    if {$whole eq ""} { set whole 0 }
    set value [expr {$whole * $scale}]
    if {$fraction ne ""} {
        set divisor [expr {10 ** [string length $fraction]}]
        set fraction [string trimleft $fraction 0]
        if {$fraction eq ""} { set fraction 0 }
        pi_check integral_fs [expr {($fraction * $scale) % $divisor == 0}]
        incr value [expr {$fraction * $scale / $divisor}]
    }
    return $value
}

# 只在外层恢复后用正常bridge读取业务计数；每次状态查询也核验返回码。
proc pi_query {name field} {
    aip_send_cmd "cw_state name=$name field=$field"
    pi_check "query_${name}_${field}" [expr {[aip_check_status] == 0}]
    return [aip_read_result]
}

# 同一个ticket完成后仍应持有自身结果；不同任务/同名后续任务不得覆盖它。
proc pi_done {ticket result status} {
    set job [aip_job wait $ticket]
    pi_check done_state [expr {[dict get $job state] eq "DONE"}]
    pi_check done_ticket [expr {[dict get $job ticket] == $ticket}]
    pi_check done_result [expr {[dict get $job result] eq $result}]
    pi_check done_status [expr {[dict get $job status] == $status}]
    return $job
}

# 最初pause只验证真实保栈和原请求身份；manual组的正常后台ACK已被消费。
proc pi_pause_begin {} {
    pi_check active_depth [expr {[dict get [aip_sim_status] depth] > 0}]
    pi_check script_frozen [expr {$::pi_returned == 0 && $::pi_suffix == 0}]
    if {$::pi_mode eq "watch"} {
        pi_check exact_watch_time [expr {[pi_now] == 350000000}]
        pi_check original_pending [expr {[dict get [aip_sim_status] pending_id] == 1}]
    } else {
        pi_check original_background [expr {[dict get [aip_sim_status] pending_id] eq ""}]
        pi_check interrupt_before_finish [expr {[pi_now] < 400000000000}]
    }
    puts AIP_INJECTION_PAUSED
}

# 不同handle可在原seq在途时完成；普通命令入口也应自动使用独立注入路径。
proc pi_foreign {} {
    set ::pi_foreign [aip_submit {cw_front ns=30 tag=FOREIGN code=17}]
    pi_done $::pi_foreign DONE:cw_front:FOREIGN 17
    cw_task ns=10 tag=ORDINARY
    pi_check ordinary_result [expr {[aip_read_result] eq "DONE:cw_task:ORDINARY"}]
    pi_check ordinary_status [expr {[aip_check_status] == 0}]
    cw_typed ns=20 tag=BACKGROUND wait=0
    pi_check ordinary_started [regexp {^STARTED: cw_typed ticket=([0-9]+)$} [aip_read_result] -> started]
    pi_check ordinary_really_running [expr {[dict get [aip_job status $started] state] eq "RUNNING"}]
    pi_done $started DONE:cw_typed:BACKGROUND 0
    aip_job release $started
    if {$::pi_mode eq "watch"} {
        pi_check original_inflight [expr {[aip_parse_int [get aip_core_pkg::__tcl_result_id]] != 1}]
    } else {
        pi_check original_inflight [expr {[pi_now] < 400000000000}]
    }
    pi_check foreign_did_not_resume [expr {$::pi_returned == 0 && $::pi_suffix == 0}]
    puts AIP_INJECTION_FOREIGN_PASS
}

# 显式提交只确认排队，不把同 handle 后续请求伪报 STARTED；取消与排队超时都不能修改原请求参数。
proc pi_queue {} {
    set ::pi_first [aip_submit {cw_seq ns=40 tag=FIRST code=23}]
    set ::pi_second [aip_submit {cw_seq ns=10 tag=SECOND code=29}]
    set cancelled [aip_submit {cw_seq ns=0 tag=CANCELLED}]
    set expired [aip_submit {cw_seq ns=0 tag=EXPIRED} timeout=5ns]
    foreach ticket [list $::pi_first $::pi_second $cancelled] {
        pi_check same_handle_queued [expr {[dict get [aip_job status $ticket] state] eq "QUEUED"}]
    }
    aip_job cancel $cancelled
    pi_check cancelled_state [expr {[dict get [aip_job status $cancelled] state] eq "CANCELLED"}]
    run 10ns
    pi_check expired_state [expr {[dict get [aip_job status $expired] state] eq "TIMED_OUT"}]
    aip_job release $cancelled
    aip_job release $expired
    pi_check stale_cancelled [expr {[catch {aip_job status $cancelled}] == 1}]
    # 固定容量包含已完成但未release的结果；满队列不能覆盖先前ticket。
    set extras {}
    for {set index 0} {$index < 29} {incr index} {
        lappend extras [aip_submit "cw_seq ns=0 tag=CAPACITY_$index"]
    }
    pi_check exact_capacity [expr {[llength [aip_job list]] == 32}]
    set code [catch {aip_submit {cw_seq ns=0 tag=OVERFLOW}} message]
    pi_check overflow_rejected [expr {$code == 1}]
    pi_check overflow_diagnostic [string match *capacity* [string tolower $message]]
    foreach ticket $extras {
        aip_job cancel $ticket
        pi_check overflow_cancel [expr {[dict get [aip_job status $ticket] state] eq "CANCELLED"}]
        aip_job release $ticket
    }
    pi_check capacity_reclaimed [expr {[llength [aip_job list]] == 3}]
    foreach command {{end_test} {so_unload x} {set_cmd_watchdog ns=0} {cw_seq wait=0} {no_such_injection_command}} {
        pi_check unsafe_rejected [expr {[catch {aip_submit $command}] == 1}]
    }
    pi_check queue_did_not_resume [expr {$::pi_returned == 0 && $::pi_suffix == 0}]
    puts AIP_INJECTION_FIFO_QUEUED
}

# 独立job运行超时不能kill业务或提前回收句柄；完成后转终态并可回收。
# 旧global-result的两个别名必须串行，局部返回命令仍能同时完成。
proc pi_lifecycle {} {
    aip_send_cmd "set_cmd_watchdog ns=0"
    set running [aip_submit {cw_task ns=80 tag=RUN_TIMEOUT} timeout=5ns]
    run 10ns
    pi_check running_timeout [expr {[dict get [aip_job status $running] state] eq "RUNNING_TIMEOUT"}]
    pi_check running_cancel_rejected [expr {[catch {aip_job cancel $running}] == 1}]
    pi_check running_release_rejected [expr {[catch {aip_job release $running}] == 1}]
    run 100ns
    pi_check running_timeout_finished [expr {[dict get [aip_job status $running] state] eq "TIMED_OUT"}]
    pi_check running_not_killed [expr {[pi_query cw_task finished] == 2}]
    aip_job release $running
    set legacy [aip_submit {cw_legacy_late text=SAVED}]
    set alias [aip_submit {cw_legacy text=AFTER}]
    set local [aip_submit {cw_front ns=20 tag=LOCAL}]
    pi_check legacy_held [expr {[dict get [aip_job status $legacy] state] eq "RUNNING"}]
    pi_check legacy_alias_queued [expr {[dict get [aip_job status $alias] state] eq "QUEUED"}]
    pi_done $local DONE:cw_front:LOCAL 0
    pi_check legacy_still_running [expr {[dict get [aip_job status $legacy] state] eq "RUNNING"}]
    pi_done $alias LEGACY:AFTER 0
    pi_done $legacy LEGACY_SAVED:SAVED 23
    foreach ticket [list $legacy $alias $local] { aip_job release $ticket }
    # 两个注册名虽绑定同一种sequence/同一个sequencer，用户task仍应并行
    # 进入；真正item竞争交给UVM仲裁，不能按sequence类型全局排队。
    set binding_a [aip_submit {cw_seq ns=100 tag=BINDING_A}]
    set binding_b [aip_submit {cw_seq_other ns=100 tag=BINDING_B}]
    pi_check binding_a_running [expr {[dict get [aip_job status $binding_a] state] eq "RUNNING"}]
    pi_check binding_b_running [expr {[dict get [aip_job status $binding_b] state] eq "RUNNING"}]
    pi_done $binding_a DONE:cw_seq:BINDING_A 0
    pi_done $binding_b DONE:cw_seq_other:BINDING_B 0
    aip_job release $binding_a
    aip_job release $binding_b
    pi_check six_driver_items [expr {[pi_query none driver_count] == 6}]
    pi_check all_jobs_released [expr {[llength [aip_job list]] == 0}]
}

# 等末笔后，前笔结果必须仍然可读；原bridge的ACK可清尾，但pending owner
# 必须留给原caller。记录resume前时间，外层用它检查没有重复推进。
proc pi_finish_jobs {} {
    if {$::pi_mode eq "manual"} { run 410000ns }
    pi_done $::pi_second DONE:cw_seq:SECOND 29
    pi_done $::pi_first DONE:cw_seq:FIRST 23
    pi_done $::pi_foreign DONE:cw_front:FOREIGN 17
    if {$::pi_mode eq "watch"} {
        pi_check pending_owner_retained [expr {[dict get [aip_sim_status] pending_id] == 1}]
        pi_check original_ack_retained [expr {[aip_parse_int [get aip_core_pkg::__tcl_result_id]] == 1}]
    }
    pi_check trigger_drained [expr {[aip_parse_int [get aip_core_pkg::__tcl_cmd_trigger]] == 0}]
    pi_check outer_still_frozen [expr {$::pi_returned == 0 && $::pi_suffix == 0}]
    foreach ticket [list $::pi_first $::pi_second $::pi_foreign] { aip_job release $ticket }
    set ::pi_before_resume [pi_now]
    puts AIP_INJECTION_JOBS_DONE
}

# 原脚本的proc/for局部变量仅在真实resume后继续；取消/过期job不能进入业务。
# 最后再发正常seq，验证原caller消费结果后桥接生命周期仍然可用。
proc pi_original {} {
    set cookie original_local_cookie
    for {set iteration 0} {$iteration < 2} {incr iteration} {
        if {$iteration == 0} {
            if {$::pi_mode eq "manual"} {
                aip_send_cmd "set_cmd_watchdog ns=0"
                cw_seq ns=400000 tag=ORIGINAL wait=0
                pi_check background_started [expr {[aip_read_result] eq "STARTED: cw_seq"}]
                set start [pi_now]
                puts AIP_INJECTION_MANUAL_BEFORE
                run 500000ns
                pi_check original_deadline [expr {[pi_now] == $start + 500000000000}]
            } else {
                cw_seq ns=400 tag=ORIGINAL
                pi_check original_result [expr {[aip_read_result] eq "DONE:cw_seq:ORIGINAL"}]
                pi_check original_status [expr {[aip_check_status] == 0}]
                pi_check original_not_reissued [expr {$::_aip_cmd_seq == 1}]
                pi_check no_extra_resume_time [expr {[pi_now] == $::pi_before_resume}]
            }
            pi_check preserved_local [expr {$cookie eq "original_local_cookie" && $iteration == 0}]
            set ::pi_returned 1
        } else {
            incr ::pi_suffix
        }
    }
    pi_check suffix_once [expr {$::pi_suffix == 1}]
    pi_check three_seq_started [expr {[pi_query cw_seq started] == 3}]
    pi_check three_seq_finished [expr {[pi_query cw_seq finished] == 3}]
    pi_check fifo_last_enter [string match *tag=SECOND* [pi_query cw_seq enter]]
    pi_check fifo_last_leave [string match *tag=SECOND* [pi_query cw_seq leave]]
    pi_check three_driver_items [expr {[pi_query none driver_count] == 3}]
    pi_check foreign_once [expr {[pi_query cw_front finished] == 1}]
    pi_check ordinary_once [expr {[pi_query cw_task finished] == 1}]
    cw_seq ns=0 tag=AFTER_RESUME
    pi_check next_command [expr {[aip_read_result] eq "DONE:cw_seq:AFTER_RESUME"}]
    pi_check four_driver_items [expr {[pi_query none driver_count] == 4}]
}

if {$::pi_mode eq "watch"} { aip_watch aip_live_resume_fixture.pending 1 stop=1 }
pi_original
pi_lifecycle
puts "AIP_INJECTION_TCL_PASS loader=$::env(AIP_INJECTION_LOADER) mode=$::pi_mode checks=$::pi_checks"
end_test drain=0
_vcs_run
