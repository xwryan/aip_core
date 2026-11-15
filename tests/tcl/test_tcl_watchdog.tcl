source ../../src/tcl/aip_cmd.tcl

set pass 0
set fail 0
proc check {name cond} {
    upvar pass p; upvar fail f
    if {$cond} { puts "\[PASS\] $name"; incr p } else { puts "\[FAIL\] $name"; incr f }
}

puts "\n=== W0: baseline ping works ==="
ping
check "ping baseline == pong" [expr {[aip_read_result] eq "pong"}]

puts "\n=== W1: hang cmd (seq 无 item_done) -> watchdog 强杀, 返回 error ==="
set hang_catch [catch {hang} hang_return]
check "已注册 hang 不抛 Tcl unknown" [expr {$hang_catch == 0}]
puts "  hang status: [aip_check_status]  result: [aip_read_result]"
check "hang status == -1" [expr {[aip_check_status] == -1}]
check "hang result 含 timeout/watchdog" \
    [expr {[string match -nocase "*timeout*" [aip_read_result]] || [string match -nocase "*watchdog*" [aip_read_result]]}]

puts "\n=== W2: bridge 存活 -> ping 仍工作 ==="
ping
check "ping after hang == pong" [expr {[aip_read_result] eq "pong"}]
check "ping after hang status==0" [expr {[aip_check_status] == 0}]

puts "\n=== W3: 清理钩子被调 ==="
wdog_last
puts "  hook: [aip_read_result]"
check "hook 记录被杀命令 hang" [expr {[string match "killed=hang*" [aip_read_result]]}]
check "hook call_count >= 1" [expr {![string match "*calls=0*" [aip_read_result]]}]

puts "\n=== W4: watchdog_status 显示配置 ==="
watchdog_status
set st [aip_read_result]
puts "  $st"
check "status 含 stall_ns" [expr {[string match "*stall_ns=*" $st]}]
check "status 含 active_seqs" [expr {[string match "*active_seqs=*" $st]}]

puts "\n=== W5: set_cmd_watchdog TCL 改阈值 ==="
set_cmd_watchdog ns=20000
check "set 返回新值" [expr {[string match "*stall_ns=20000*" [aip_read_result]]}]
watchdog_status
check "status 反映新阈值 20000" [expr {[string match "*stall_ns=20000*" [aip_read_result]]}]

puts "\n=== W6: kill_seq 无活动时返回 killed=0 ==="
kill_seq
check "无活动 seq killed=0" [expr {[string match "killed=0*" [aip_read_result]]}]

puts "\n=== W7: 未注册命令仍走 Tcl unknown ==="
set _had_dynamic_cmds [info exists ::_aip_dynamic_cmds]
if {$_had_dynamic_cmds} { set _saved_dynamic_cmds $::_aip_dynamic_cmds }
set ::_aip_dynamic_cmds 1
set missing_catch [catch {aip_missing_watchdog_probe} missing_return]
check "missing probe 抛 Tcl unknown" [expr {$missing_catch == 1}]
check "missing probe message 含命令名" \
    [expr {[string match "*aip_missing_watchdog_probe*" $missing_return]}]
if {$_had_dynamic_cmds} {
    set ::_aip_dynamic_cmds $_saved_dynamic_cmds
    unset _saved_dynamic_cmds
} else {
    unset ::_aip_dynamic_cmds
}
unset _had_dynamic_cmds

puts "\n=========================================="
puts "  PASS: $pass  FAIL: $fail  TOTAL: [expr {$pass+$fail}]"
puts "=========================================="

if {$fail == 0} {
    puts "TCL_WATCHDOG_PASS"
} else {
    error "TCL_WATCHDOG_FAIL failures=$fail"
}

quit
