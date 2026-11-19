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

puts "\n=== U3: status-only failure gets ERROR text, never OK ==="
user_seq_run status=7 tag=fail_only
check "status-only status kept" [expr {[aip_check_status] == 7}]
check "status-only text is ERROR" [expr {[aip_read_result] eq "ERROR: user_seq_run status=7"}]

puts "\n=== U4: seq-set text returned as is ==="
user_seq_run status=3 text=CUSTOM_FAIL
check "custom text status kept" [expr {[aip_check_status] == 3}]
check "custom text kept" [expr {[aip_read_result] eq "CUSTOM_FAIL"}]

puts "\n=== U5: set_result API works for user sequences ==="
user_seq_run api=1
check "set_result status" [expr {[aip_check_status] == 4}]
check "set_result text" [expr {[aip_read_result] eq "ERROR: user_seq_run rejected via set_result"}]

puts "\n=== U6: status 0 without text stays OK ==="
user_seq_run tag=ok_again
check "default OK unchanged" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: user_seq_run"}]

puts "\n=========================================="
puts "  PASS: $pass  FAIL: $fail  TOTAL: [expr {$pass+$fail}]"
puts "=========================================="
if {$fail == 0} {
    puts "USER_SEQ_PASS"
} else {
    error "USER_SEQ_FAIL failures=$fail"
}

quit
