source ../../src/tcl/aip_cmd.tcl

set pass 0
set fail 0
proc check {name cond} {
    upvar pass p; upvar fail f
    if {$cond} { puts "\[PASS\] $name"; incr p } else { puts "\[FAIL\] $name"; incr f }
}

puts "\n=== U1: direct user sequence has no framework count/time ==="
user_seq_run tag=link_en
check "first status" [expr {[aip_check_status] == 0}]
check "default result" [expr {[aip_read_result] eq "OK: user_seq_run"}]
user_seq_state
set state [aip_read_result]
check "sequence ran once" [expr {[string match "runs=1 *" $state]}]
check "sequence owns default enable" [expr {[string match "*enable=1*" $state]}]
check "driver received tag" [expr {[string match "*driver_tag=link_en" $state]}]

puts "\n=== U2: sequence-specific arguments remain user-owned ==="
user_seq_run enable=0 tag=ep_cfg
check "second status" [expr {[aip_check_status] == 0}]
user_seq_state
set state [aip_read_result]
check "sequence owns enable=0" [expr {[string match "runs=2 enable=0 tag=ep_cfg*" $state]}]
check "driver received second item" [expr {[string match "*driver_enable=0 driver_tag=ep_cfg" $state]}]

puts "\n=========================================="
puts "  PASS: $pass  FAIL: $fail  TOTAL: [expr {$pass+$fail}]"
puts "=========================================="
if {$fail == 0} {
    puts "USER_SEQ_PASS"
} else {
    error "USER_SEQ_FAIL failures=$fail"
}

quit
