# Tcl ACK 按活动进展计时的 UCLI 黑盒验证（命令由 test_cmd_ack_progress.sv 注册）；任何失败都阻止 PASS 标记。
source ../../src/tcl/aip_cmd.tcl
set ::ap_checks 0

proc ap_check {name condition} {
    if {!$condition} { error "CMD_ACK_PROGRESS_FAIL $name" }
    incr ::ap_checks
    puts "CMD_ACK_PROGRESS_CHECK $name"
}

# 独立把 senv time 换算成整数 ns，不复用待测层的时间换算。
proc ap_now {} {
    if {![regexp {^\s*([0-9]+)(?:\.([0-9]+))?\s*(fs|ps|ns|us|ms|s)\s*$} [senv time] -> whole fraction unit]} {
        error "CMD_ACK_PROGRESS_FAIL bad simulation time"
    }
    set scale [dict get {fs 1 ps 1000 ns 1000000 us 1000000000 ms 1000000000000 s 1000000000000000} $unit]
    set whole [string trimleft $whole 0]
    if {$whole eq ""} { set whole 0 }
    set fs [expr {$whole * $scale}]
    if {$fraction ne ""} {
        set divisor [expr {10 ** [string length $fraction]}]
        set fraction [string trimleft $fraction 0]
        if {$fraction eq ""} { set fraction 0 }
        incr fs [expr {$fraction * $scale / $divisor}]
    }
    return [expr {$fs / 1000000}]
}

# 本条命令的 ACK 已到达，读到的是它自己的结果而非上一条的陈旧结果。
proc ap_acked {} {
    return [expr {[aip_parse_int [get aip_core_pkg::__tcl_result_id]] == $::_aip_cmd_seq}]
}

proc ap_state {field} {
    aip_send_cmd "ap_state field=$field"
    if {[aip_check_status] != 0 || ![ap_acked]} { error "CMD_ACK_PROGRESS_FAIL state $field" }
    return [aip_read_result]
}

ap_check default_budget [expr {$::aip_ack_timeout_ns == 52000}]
watchdog_status
ap_check default_watchdog [string match "stall_ns=50000 poll_ns=1000 *" [aip_read_result]]

puts "CMD_ACK_PROGRESS_STAGE fast"
# 快命令与以前一致：ACK 的 $stop 立即结束等待，不多推进仿真时间。
set start [ap_now]
ap_state last_tick
ap_check zero_time_command [expr {[ap_now] == $start}]
set start [ap_now]
ap_tick ns=300 period=100 tag=short
ap_check short_result [expr {[ap_acked] && [aip_check_status] == 0 && [aip_read_result] eq "DONE:ap_tick:short"}]
ap_check short_exact_time [expr {[ap_now] - $start == 300}]
set start [ap_now]
ap_tick ns=40000 tag=silent
ap_check silent_result [expr {[ap_acked] && [aip_read_result] eq "DONE:ap_tick:silent"}]
ap_check silent_exact_time [expr {[ap_now] - $start == 40000}]

puts "CMD_ACK_PROGRESS_STAGE long_progress"
# 持续 tick 1ms（远超 52us 预算）：一直等到 ACK，拿到真实结果且不多推进。
set start [ap_now]
ap_tick ns=1000000 period=500 tag=long
ap_check long_acked [ap_acked]
ap_check long_result [expr {[aip_check_status] == 0 && [aip_read_result] eq "DONE:ap_tick:long"}]
ap_check long_exact_time [expr {[ap_now] - $start == 1000000}]

puts "CMD_ACK_PROGRESS_STAGE watchdog_first"
# tick 300us 后停住：SV watchdog 在 Tcl 预算耗尽前强杀，Tcl 拿到 watchdog 结果。
ap_tick ns=300000 period=500 hang=1 tag=stall
set acked [ap_acked]
set status [aip_check_status]
set result [aip_read_result]
set ack_at [ap_now]
set last [ap_state last_tick]
ap_check stall_acked $acked
ap_check stall_watchdog_result [expr {$status == -1 && [string match "*stalled*watchdog*" $result]}]
ap_check stall_killed_by_watchdog [expr {$ack_at - $last >= 50000}]
ap_check stall_before_tcl_budget [expr {$ack_at - $last < 52000}]
ap_tick ns=10 tag=after_watchdog
ap_check bridge_alive_after_watchdog [expr {[ap_acked] && [aip_read_result] eq "DONE:ap_tick:after_watchdog"}]

# 预算下限读自 SV：watchdog 调到 120us 后，默认 52us 的 Tcl 预算让位于它。
set_cmd_watchdog ns=120000
ap_tick ns=100000 period=500 hang=1 tag=stall_long
set acked [ap_acked]
set result [aip_read_result]
set ack_at [ap_now]
set last [ap_state last_tick]
ap_check raised_watchdog_acked $acked
ap_check raised_watchdog_result [string match "*stalled*watchdog*" $result]
ap_check raised_watchdog_time [expr {$ack_at - $last >= 120000 && $ack_at - $last < 122000}]
set_cmd_watchdog ns=50000

# 调低 ::aip_ack_timeout_ns 也不会早于 watchdog 放弃：预算取二者中较大者。
set ::aip_ack_timeout_ns 5000
ap_tick ns=20000 period=500 hang=1 tag=stall_low_budget
set acked [ap_acked]
set result [aip_read_result]
set ::aip_ack_timeout_ns 52000
ap_check low_budget_waits_for_watchdog [expr {$acked && [string match "*stalled*watchdog*" $result]}]

puts "CMD_ACK_PROGRESS_STAGE watchdog_disabled"
# 禁用 watchdog：tick 200us 后静默 150us，Tcl 在最后一次进展后 52us（至多再多 1 步）放弃并告警，不挂住。
set_cmd_watchdog ns=0
ap_tick ns=200000 period=500 quiet=150000 tag=quiet
set acked [ap_acked]
set gave_up [ap_now]
ap_check quiet_not_acked [expr {!$acked}]
# 让仍在执行的命令自然结束，桥随之回到空闲。
run 200us
set last [ap_state last_tick]
set done [ap_state done_at]
ap_check quiet_command_finished_later [expr {$done > $gave_up}]
ap_check quiet_waited_idle_budget [expr {$gave_up - $last >= 52000}]
ap_check quiet_gave_up_promptly [expr {$gave_up - $last <= 52000 + 6500}]

# 调大预算的旧脚本照常工作：静默段短于预算即拿到真实结果。
set ::aip_ack_timeout_ns 5000000
ap_tick ns=1000 period=500 quiet=200000 tag=raised
ap_check raised_budget_result [expr {[ap_acked] && [aip_read_result] eq "DONE:ap_tick:raised"}]
set ::aip_ack_timeout_ns 52000
set_cmd_watchdog ns=50000

puts "CMD_ACK_PROGRESS_PASS checks=$::ap_checks"
end_test
quit
