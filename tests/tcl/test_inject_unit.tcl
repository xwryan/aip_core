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
unset registers(__inject_protocol_version)
equal old_sv_available [_aip_inject_available] 0
equal old_sv_checkpoint [_aip_inject_assert_quiescent checkpoint] {}
rejects old_sv_submit {aip_submit cmd} {AIP INJECT UNAVAILABLE}
puts "INJECT_UNIT_PASS checks=$checks"
