# 注入 API 的纯 Tcl 协议/参数/生命周期单测（mock 寄存器与时间）；真实 FIFO、SVT、原生 pause 由 VCS 回归覆盖。
set root [file normalize [file join [file dirname [info script]] ../..]]
source [file join $root src tcl aip_sim_control.tcl]
source [file join $root src tcl aip_inject.tcl]
set ::aip_ack_timeout_ns 50000
set checks 0
set now 0
set forced 0
array set registers {__inject_protocol_version 1 __inject_ack_id 0}

proc equal {name actual expected} {
    if {$actual ne $expected} { error "INJECT_UNIT_FAIL $name actual=<$actual> expected=<$expected>" }
    incr ::checks
}

# 参数拒绝不能偷偷推进或 force 模型。
proc rejects {name body code} {
    set before $::forced
    equal "$name failure" [catch {uplevel 1 $body} result options] 1
    equal "$name code" [dict get $options -errorcode] $code
    equal "$name no mutation" $::forced $before
}

# 模型只接受本测试定义的package寄存器；缺对象必须报错以覆盖旧SV场景。
proc get {path} {
    if {![regexp {^aip_core_pkg::(.+)$} $path -> name]} { error "bad path $path" }
    return $::registers($name)
}

# 记录模拟 force，按生产的二态解析器解码。
proc force {path value} {
    incr ::forced
    regexp {^aip_core_pkg::(.+)$} $path -> name
    set ::registers($name) [_aip_control_scalar $value]
}

# 固定1ps精度、整数fs时间；推进桩只用于Tcl接口，不判断SV时序正确性。
proc senv {key} {
    if {$key eq "time"} { return "$::now fs" }
    return 1ps
}

# 每个槽默认FREE；少量模型结果足够覆盖缓存/复用/负状态而无需创建32K字节。
for {set slot 0} {$slot < 32} {incr slot} {
    foreach field {ticket state status result_len} {
        set registers(__inject_slot_${field}\[$slot\]) 0
    }
}

equal available [_aip_inject_available] 1
equal timeout_default [_aip_inject_timeout_ns {} 50] 50
equal timeout_leading_zero [_aip_inject_timeout_ns {timeout=008ns} 50] 8
equal timeout_microsecond [_aip_inject_timeout_ns {timeout=1.5us} 50] 1500
equal timeout_disabled [_aip_inject_timeout_ns {timeout=0} 50] 0
foreach options {{timeout=1ps} {timeout=4294967296ns} {other=5ns} {timeout=2ns timeout=3ns}} {
    rejects invalid_timeout {_aip_inject_timeout_ns $options 50} {AIP INJECT ARGUMENT}
}
foreach ticket {0 -1 1x 18446744073709551616} {
    rejects invalid_ticket {_aip_inject_ticket $ticket} {AIP INJECT ARGUMENT}
}
equal ticket_decimal [_aip_inject_ticket 008] 8
rejects missing_ticket {aip_job status 1} {AIP INJECT STALE}
rejects command_unicode {aip_submit 中文} {AIP INJECT ARGUMENT}
rejects command_too_long {aip_submit [string repeat a 1025]} {AIP INJECT ARGUMENT}
rejects empty_submit {aip_submit {}} {AIP INJECT ARGUMENT}
rejects wait_zero {aip_job wait 1 timeout=0} {AIP INJECT ARGUMENT}
rejects list_extra {aip_job list 1} {AIP INJECT ARGUMENT}
set ::_aip_inject_busy 1
rejects reentrant {aip_submit cmd} {AIP INJECT BUSY}
set ::_aip_inject_busy 0
dict set ::_aip_control_state depth 1
rejects callback_not_pause {aip_submit cmd} {AIP CONTROL BUSY}
dict set ::_aip_control_state depth 0

# 构造一个终态结果验证二补码、内容、ticket缓存。槽复用后旧ticket必须失效。
set registers(__inject_slot_ticket\[3\]) 7
set registers(__inject_slot_state\[3\]) 3
set registers(__inject_slot_status\[3\]) 4294967295
set registers(__inject_slot_result_len\[3\]) 2
set registers(__inject_result_ascii\[3072\]) 79
set registers(__inject_result_ascii\[3073\]) 75
set job [aip_job status 7]
equal terminal_state [dict get $job state] DONE
equal signed_status [dict get $job status] -1
equal result_text [dict get $job result] OK
equal wait_terminal [aip_job wait 7] $job
equal list_terminal [aip_job list] [list $job]
rejects snapshot_has_ticket {_aip_inject_assert_quiescent checkpoint} {AIP INJECT BUSY}
set registers(__inject_slot_ticket\[3\]) 8
rejects stale_cached_slot {aip_job status 7} {AIP INJECT STALE}
set registers(__inject_slot_state\[3\]) 6
rejects still_running_timeout {aip_job wait 8} {AIP INJECT TIMEOUT}
set registers(__inject_slot_state\[3\]) 0
equal all_reclaimed [aip_job list] {}
equal quiescent [_aip_inject_assert_quiescent checkpoint] {}

# 等待只计无活动进展的时间。原生推进桩按时长推进虚拟时间，再由 ::sv_model 模拟本次推进内的 SV 行为。
proc _vcs_run {duration} {
    incr ::now [_aip_control_time_fs $duration]
    uplevel #0 $::sv_model
}
set registers(__tcl_activity_count) 0
set ::aip_inject_poll_ns 1000

# slot 上的 job 每次推进都 tick 到 tick_until，done_at 起转为 DONE 并给出结果 OK。
proc model_job {slot tick_until done_at} {
    if {$::now <= $tick_until} { incr ::registers(__tcl_activity_count) }
    if {$::now >= $done_at && $::registers(__inject_slot_state\[$slot\]) == 2} {
        set ::registers(__inject_slot_state\[$slot\]) 3
        set ::registers(__inject_slot_result_len\[$slot\]) 2
        set ::registers(__inject_result_ascii\[[expr {$slot*1024}]\]) 79
        set ::registers(__inject_result_ascii\[[expr {$slot*1024+1}]\]) 75
    }
}
proc running_job {ticket slot tick_until done_at} {
    set ::registers(__inject_slot_ticket\[$slot\]) $ticket
    set ::registers(__inject_slot_state\[$slot\]) 2
    set ::sv_model [list model_job $slot $tick_until $done_at]
}

# 持续进展的 job 远超 50us 预算仍等到完成，且不多推进。
set now 0
running_job 31 4 150000000000 150000000000
equal progress_outlives_budget [dict get [aip_job wait 31] state] DONE
equal progress_no_extra_time $now 150000000000
set registers(__inject_slot_state\[4\]) 0

# 进展停在 30us：从最后一次观测到进展起满 20us 才放弃，job 不被 kill。
set now 0
running_job 32 5 30000000000 1000000000000
rejects stalled_wait_times_out {aip_job wait 32 timeout=20us} {AIP INJECT TIMEOUT}
equal stalled_wait_measured_from_progress $now 50000000000
equal stalled_job_not_killed [dict get [aip_job status 32] state] RUNNING
set registers(__inject_slot_state\[5\]) 0

# 接收器桩：op4 在 slot 6 受理 ticket 41（初态由 job_state 决定），op2 撤销排队，op3 回收；记录 op 与 job 期限。
proc model_receiver {job_state} {
    upvar #0 registers r
    if {$r(__inject_request_trigger) == 1 && $r(__inject_request_id) != $r(__inject_ack_id)} {
        set op $r(__inject_request_op)
        lappend ::requests [list $op $r(__inject_request_timeout_ns)]
        foreach {field value} {ack_status 0 ack_text_len 0 ack_wait 1 ack_ticket 41 ack_slot 6} {
            set r(__inject_$field) $value
        }
        switch -- $op {
            4 {
                set r(__inject_slot_ticket\[6\]) 41
                set r(__inject_slot_state\[6\]) $job_state
            }
            2 {
                set r(__inject_slot_state\[6\]) 4
                set r(__inject_slot_status\[6\]) 1
            }
            3 {
                set r(__inject_slot_ticket\[6\]) 0
                set r(__inject_slot_state\[6\]) 0
            }
        }
        set r(__inject_ack_id) $r(__inject_request_id)
    }
    if {$r(__inject_slot_state\[6\]) == 2} { model_job 6 150000000000 150000000000 }
}

# 暂停内普通命令不再请求 SV 绝对期限；持续进展的长命令拿到真实结果。
set now 0
set requests {}
set sv_model {model_receiver 2}
_aip_inject_send {cw_task tag=LONG}
equal send_requests $requests {{4 0} {3 0}}
equal send_long_result [dict get $::_aip_inject_last_result result] OK
equal send_long_status [dict get $::_aip_inject_last_result status] 0

# 无进展满预算仍在排队：撤销并回收这条从未执行的请求，以失败结果返回。
set now 0
set requests {}
set sv_model {model_receiver 1}
_aip_inject_send {cw_task tag=QUEUED}
equal queued_requests $requests {{4 0} {2 0} {3 0}}
equal queued_status [dict get $::_aip_inject_last_result status] 1
equal queued_result [string match "TIMEOUT: no activity progress for 50000ns while queued*" \
    [dict get $::_aip_inject_last_result result]] 1
equal queued_released [aip_job list] {}
set ::_aip_inject_last_result {}

# 旧 SV 没有活动计数寄存器：退化为自等待开始起的固定期限，读失败不报错也不无限等待。
unset registers(__tcl_activity_count)
set now 0
running_job 33 8 0 1000000000000
rejects old_sv_wait_times_out {aip_job wait 33 timeout=20us} {AIP INJECT TIMEOUT}
equal old_sv_fixed_budget $now 20000000000
set registers(__inject_slot_state\[8\]) 0

unset registers(__inject_protocol_version)
equal old_sv_available [_aip_inject_available] 0
equal old_sv_checkpoint [_aip_inject_assert_quiescent checkpoint] {}
rejects old_sv_submit {aip_submit cmd} {AIP INJECT UNAVAILABLE}
puts "INJECT_UNIT_PASS checks=$checks"
