# The Makefile launches simv from tests/sv/, so the repository root is two
# levels above the current working directory (tests/sv -> tests -> repo).
set ::env(AIP_CORE) [file normalize ../..]
source [file join $::env(AIP_CORE) src tcl aip_cmd.tcl]
set ::aip_ckpt_dir ./checkpoint_wait_artifacts
set ::aip_simv_path [file normalize ./simv_checkpoint_wait]
file delete -force $::aip_ckpt_dir

set pass 0
set fail 0
proc check {name condition} {
    upvar pass p
    upvar fail f
    if {$condition} {
        puts "PASS $name"
        incr p
    } else {
        puts "FAIL $name"
        incr f
    }
}

set s1 [aip_wait_checkpoint test_checkpoint_wait.dut_status 32'h1 STATE_ONE state_one 100ns]
check "state one returned" [expr {$s1 eq "state_one"}]
check "state one snapshot exists" \
    [file exists [file join $::aip_ckpt_dir state_one.vcssave]]
check "state one meta exists" \
    [file exists [file join $::aip_ckpt_dir state_one.meta]]

set timeout_rc [catch {
    aip_wait_checkpoint test_checkpoint_wait.dut_status 32'h9 NEVER never 5ns
} timeout_error]
check "unreachable state times out" \
    [expr {$timeout_rc == 1 && [string match {*timeout waiting*} $timeout_error]}]
set timeout_stop_listing [stop]
check "timeout removes conditional stop" \
    [expr {$timeout_stop_listing eq {No stop points are set}}]

foreach {value keyword snapshot} {
    32'h2 STATE_TWO   state_two
    32'h3 STATE_THREE state_three
    32'h4 STATE_FOUR  state_four
} {
    set result [aip_wait_checkpoint \
        test_checkpoint_wait.dut_status $value $keyword $snapshot 100ns]
    check "$keyword returned snapshot" [expr {$result eq $snapshot}]
    check "$keyword snapshot exists" \
        [file exists [file join $::aip_ckpt_dir $snapshot.vcssave]]
    check "$keyword meta exists" \
        [file exists [file join $::aip_ckpt_dir $snapshot.meta]]
}

set final_stop_listing [stop]
check "all conditional stops removed" \
    [expr {$final_stop_listing eq {No stop points are set}}]

puts "PASS: $pass FAIL: $fail TOTAL: [expr {$pass + $fail}]"
if {$fail == 0} {
    puts "CHECKPOINT_WAIT_VCS_PASS"
} else {
    error "CHECKPOINT_WAIT_VCS_FAIL failures=$fail"
}
end_test
quit
