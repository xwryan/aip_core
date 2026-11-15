# Plain Tcl regression for the state-triggered checkpoint helpers and control flow.
set here [file dirname [file normalize [info script]]]
source [file join $here .. .. src tcl aip_checkpoint.tcl]

# Keep the real implementation loaded, but replace the VCS-backed save operation.
rename aip_checkpoint __real_aip_checkpoint

set pass 0
set fail 0
proc check {name condition} {
    global pass fail
    if {$condition} {
        puts "PASS $name"
        incr pass
    } else {
        puts "FAIL $name"
        incr fail
    }
}

proc one_prefix {message} {
    expr {[regexp -all {aip_wait_checkpoint:} $message] == 1 &&
          [string match {aip_wait_checkpoint:*} $message]}
}

proc stub_error {message errorcode errorinfo} {
    if {$errorcode eq ""} { error $message }
    return -code error -errorcode $errorcode -errorinfo $errorinfo $message
}

proc preserved_options {options errorcode errorinfo} {
    expr {[dict get $options -errorcode] eq $errorcode &&
          [string first $errorinfo [dict get $options -errorinfo]] == 0}
}

proc reset_stubs {} {
    set ::stub_value 0
    set ::stub_target 1
    set ::stub_time_ns 0.0
    set ::stub_time_text ""
    set ::stub_time_error ""
    set ::stub_time_errorcode {}
    set ::stub_time_errorinfo {}
    set ::stub_time_calls 0
    set ::stub_time_fail_at 0
    set ::stub_senv_available 0
    set ::stub_senv_raw ""
    set ::stub_mode hit
    set ::stub_get_fail 0
    set ::stub_get_errorcode {}
    set ::stub_get_errorinfo {}
    set ::stub_get_calls 0
    set ::stub_get_fail_at 0
    set ::stub_stop_fail 0
    set ::stub_stop_errorcode {}
    set ::stub_stop_errorinfo {}
    set ::stub_stop_installs 0
    set ::stub_stop_deletes 0
    set ::stub_stop_id 73
    set ::stub_stop_active ""
    set ::stub_stop_condition ""
    set ::stub_stop_delete_ids {}
    set ::stub_stop_delete_fail ""
    set ::stub_stop_delete_errorcode {}
    set ::stub_stop_delete_errorinfo {}
    set ::stub_run_args {}
    set ::stub_run_errorcode {}
    set ::stub_run_errorinfo {}
    set ::stub_saved {}
    set ::stub_save_fail 0
    set ::stub_save_errorcode {}
    set ::stub_save_errorinfo {}
}

# UCLI stubs. These model only the commands used by aip_wait_checkpoint.
proc get {path} {
    incr ::stub_get_calls
    if {$::stub_get_fail ne "0" &&
            ($::stub_get_fail_at == 0 || $::stub_get_calls == $::stub_get_fail_at)} {
        stub_error $::stub_get_fail $::stub_get_errorcode $::stub_get_errorinfo
    }
    return $::stub_value
}
proc stop {args} {
    switch -- [lindex $args 0] {
        -condition {
            incr ::stub_stop_installs
            if {$::stub_stop_fail ne "0"} {
                stub_error $::stub_stop_fail \
                    $::stub_stop_errorcode $::stub_stop_errorinfo
            }
            set ::stub_stop_condition [lindex $args 1]
            set ::stub_stop_active $::stub_stop_id
            return $::stub_stop_id
        }
        -delete {
            set stop_id [lindex $args 1]
            incr ::stub_stop_deletes
            lappend ::stub_stop_delete_ids $stop_id
            if {$stop_id ne $::stub_stop_active} {
                error "stub stop delete id '$stop_id' does not match active '$::stub_stop_active'"
            }
            if {$::stub_stop_delete_fail ne ""} {
                stub_error $::stub_stop_delete_fail \
                    $::stub_stop_delete_errorcode $::stub_stop_delete_errorinfo
            }
            set ::stub_stop_active ""
            return $stop_id
        }
        default { error "stub unsupported stop arguments '$args'" }
    }
}
proc run {args} {
    lappend ::stub_run_args $args
    switch -- $::stub_mode {
        hit {
            set ::stub_value $::stub_target
            set ::stub_time_ns [expr {$::stub_time_ns + 5.0}]
        }
        timeout {
            set duration [lindex $args 0]
            if {![regexp {^([0-9]+(?:\.[0-9]+)?)ns$} $duration _ amount]} {
                error "stub expected bounded run, got '$duration'"
            }
            set ::stub_time_ns [expr {$::stub_time_ns + double($amount)}]
        }
        run_error {
            stub_error {stub run failure} $::stub_run_errorcode $::stub_run_errorinfo
        }
        no_progress { return }
        default { error "unknown stub mode $::stub_mode" }
    }
}
proc _aip_sim_time {} {
    incr ::stub_time_calls
    if {$::stub_time_error ne "" &&
            ($::stub_time_fail_at == 0 || $::stub_time_calls == $::stub_time_fail_at)} {
        stub_error $::stub_time_error $::stub_time_errorcode $::stub_time_errorinfo
    }
    if {$::stub_time_text ne ""} { return $::stub_time_text }
    return [format "%.3f ns" $::stub_time_ns]
}
proc senv {name} {
    if {$name ne "time" || !$::stub_senv_available} {
        error "stub senv '$name' unavailable"
    }
    if {$::stub_senv_raw ne ""} { return $::stub_senv_raw }
    return [format "%.0f fs" [expr {$::stub_time_ns * 1000000.0}]]
}
proc aip_checkpoint {snapshot args} {
    if {$::stub_save_fail} {
        stub_error {stub save failure} $::stub_save_errorcode $::stub_save_errorinfo
    }
    lappend ::stub_saved [list $snapshot {*}$args]
}

# Strict two-state literal parsing, including decimal strings with leading zero.
foreach {literal expected} {
    08 8 09 9 -10 -10 +10 10 0x10 16 -0x10 -16 0b101 5
    32'hff 255 -8'd10 -10 8'b1010 10 8'o17 15
} {
    check "parse $literal" [expr {[_aip_wait_ckpt_parse_value $literal] == $expected}]
}
foreach literal {32'hx 4'b10xz garbage {} 1_000} {
    check "reject '$literal'" [expr {[_aip_wait_ckpt_parse_value $literal] eq ""}]
}

# Values wider than Tcl scan's signed machine range must remain distinct bignums.
set two128  340282366920938463463374607431768211456
set two128p1 340282366920938463463374607431768211457
set hex128 "1[string repeat 0 32]"
set hex128p1 "1[string repeat 0 31]1"
set bin128 "1[string repeat 0 128]"
set bin128p1 "1[string repeat 0 127]1"
set oct128 "4[string repeat 0 42]"
set oct128p1 "4[string repeat 0 41]1"
set wide_cases [list \
    [list {decimal signed maximum} 9223372036854775807 9223372036854775807] \
    [list {decimal signed minimum} -9223372036854775808 -9223372036854775808] \
    [list {decimal unsigned maximum} 18446744073709551615 18446744073709551615] \
    [list {hex signed minimum magnitude} -0x8000000000000000 -9223372036854775808] \
    [list {hex unsigned maximum} 0xffffffffffffffff 18446744073709551615] \
    [list {SV decimal unsigned maximum} 64'd18446744073709551615 18446744073709551615] \
    [list {SV hex unsigned maximum} 64'hffffffffffffffff 18446744073709551615] \
    [list {SV octal unsigned maximum} 64'o1777777777777777777777 18446744073709551615] \
    [list {decimal 128-bit value} $two128 $two128] \
    [list {decimal distinct 128-bit value} $two128p1 $two128p1] \
    [list {hex 128-bit value} 0x$hex128 $two128] \
    [list {hex distinct 128-bit value} 0x$hex128p1 $two128p1] \
    [list {binary 128-bit value} 0b$bin128 $two128] \
    [list {binary distinct 128-bit value} 0b$bin128p1 $two128p1] \
    [list {SV decimal 128-bit value} 129'd$two128 $two128] \
    [list {SV decimal distinct 128-bit value} 129'd$two128p1 $two128p1] \
    [list {SV hex 128-bit value} 129'h$hex128 $two128] \
    [list {SV hex distinct 128-bit value} 129'h$hex128p1 $two128p1] \
    [list {SV binary 128-bit value} 129'b$bin128 $two128] \
    [list {SV binary distinct 128-bit value} 129'b$bin128p1 $two128p1] \
    [list {SV octal 128-bit value} 129'o$oct128 $two128] \
    [list {SV octal distinct 128-bit value} 129'o$oct128p1 $two128p1]]
foreach case $wide_cases {
    lassign $case name literal expected
    set parsed [_aip_wait_ckpt_parse_value $literal]
    check "parse $name" [expr {$parsed ne "" && $parsed == $expected}]
}

reset_stubs
set ::stub_value "129'h$hex128"
set ::stub_target "129'h$hex128p1"
set result [aip_wait_checkpoint tb.wide "129'h$hex128p1" WIDE wide_wait 20ns]
check "distinct 128-bit values do not hit immediately" [expr {
    $result eq "wide_wait" && $::stub_stop_installs == 1 &&
    $::stub_stop_deletes == 1 && $::stub_stop_delete_ids eq {73}
}]

# Strict duration conversion to nanoseconds.
foreach {duration expected} {
    1fs 0.000001 1ps 0.001 1ns 1.0 1us 1000.0
    1ms 1000000.0 1s 1000000000.0 2.5us 2500.0 12 12.0
} {
    check "duration $duration" [expr {[_aip_wait_ckpt_duration_ns $duration] == $expected}]
}
foreach duration {abc 1xs 1.2.3ns {1 ns extra} {}} {
    set rc [catch {_aip_wait_ckpt_duration_ns $duration} err]
    check "reject duration '$duration'" [expr {$rc == 1 && [one_prefix $err]}]
}

reset_stubs
set ::stub_time_text {12.500 ns}
check "simulation time parsing" [expr {[_aip_wait_ckpt_time_ns] == 12.5}]
set ::stub_time_text {not-a-time}
set rc [catch {_aip_wait_ckpt_time_ns} err]
check "bad simulation time rejected" [expr {$rc == 1 && [one_prefix $err]}]

# Immediate hit saves without installing a monitor and keeps original metadata.
reset_stubs
set ::stub_value 1
set result [aip_wait_checkpoint tb.status 32'h1 READY ready]
check "immediate result" [expr {$result eq "ready"}]
check "immediate skips stop" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]
check "immediate saves" [expr {[lindex [lindex $::stub_saved 0] 0] eq "ready"}]
check "immediate note metadata" [expr {
    [lindex [lindex $::stub_saved 0] 1] eq
    {note=READY; trigger_time=0.000 ns; path=tb.status; expected=32'h1}
}]

# Delayed hit installs/deletes once, returns the snapshot, and saves after hit.
reset_stubs
set result [aip_wait_checkpoint tb.status 32'h1 BOOT boot 20ns]
check "delayed result" [expr {$result eq "boot"}]
check "delayed installs/deletes exact stop" [expr {
    $::stub_stop_installs == 1 && $::stub_stop_deletes == 1 &&
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]
check "delayed monitor condition" [expr {$::stub_stop_condition eq {tb.status == 1}}]
check "delayed note metadata" [expr {
    [lindex [lindex $::stub_saved 0] 1] eq
    {note=BOOT; trigger_time=5.000 ns; path=tb.status; expected=32'h1}
}]

# A Tcl-special array path remains a single condition argument; no timeout calls run bare.
reset_stubs
set result [aip_wait_checkpoint {tb.state_array[3]} 1 ARRAY array_wait]
check "array path and unlimited result" [expr {$result eq "array_wait"}]
check "unlimited wait installs/deletes exact stop" [expr {
    $::stub_stop_installs == 1 && $::stub_stop_deletes == 1 &&
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]
check "array condition is literal" [expr {$::stub_stop_condition eq {tb.state_array[3] == 1}}]
check "unlimited wait uses bare run" [expr {[llength $::stub_run_args] == 1 && [lindex $::stub_run_args 0] eq {}}]

# Timeout is deadline-based, reports the last value, and always removes the monitor.
reset_stubs
set ::stub_mode timeout
set rc [catch {aip_wait_checkpoint tb.status 2 NEVER never 10ns} err]
check "timeout errors with last value" [expr {
    $rc == 1 && [one_prefix $err] &&
    [string match {*timeout waiting*last value=0*} $err]
}]
check "timeout deletes exact stop with no stale stop" [expr {
    $::stub_stop_installs == 1 && $::stub_stop_deletes == 1 &&
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]
check "timeout uses remaining deadline" [expr {[lindex [lindex $::stub_run_args 0] 0] eq {10.000000000ns}}]

# Native raw time must preserve an fs deadline hidden by the display formatter.
reset_stubs
set ::stub_senv_available 1
set ::stub_mode timeout
set rc [catch {aip_wait_checkpoint tb.status 2 NEVER never 1fs} err]
check "precise raw time makes 1fs a timeout" [expr {
    $rc == 1 && [one_prefix $err] &&
    [string match {*timeout waiting*last value=0*} $err] &&
    ![string match {*without advancing*} $err]
}]
check "1fs timeout deletes exact stop" [expr {
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]
check "1fs run uses precise remaining duration" [expr {
    [lindex [lindex $::stub_run_args 0] 0] eq {0.000001000ns}
}]

# Invalid timeouts fail before monitor installation.
foreach timeout {nonsense 0ns} {
    reset_stubs
    set rc [catch {aip_wait_checkpoint tb.status 2 BAD bad $timeout} err]
    check "timeout '$timeout' rejected" [expr {$rc == 1 && [one_prefix $err]}]
    check "timeout '$timeout' installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]
}

# Registration failure leaves no active stop and does not attempt deletion.
reset_stubs
set ::stub_stop_fail {stub stop failure}
set rc [catch {aip_wait_checkpoint tb.status 2 WAIT wait 10ns} err]
check "stop failure propagates" [expr {$rc == 1 && [one_prefix $err] && [string match {*cannot monitor*} $err]}]
check "stop failure leaves no active stop" [expr {$::stub_stop_active eq ""}]
check "stop failure counts" [expr {$::stub_stop_installs == 1 && $::stub_stop_deletes == 0}]

reset_stubs
set ::stub_stop_fail {aip_wait_checkpoint: underlying monitor failure}
set ::stub_stop_errorcode {AIP STOP REGISTER}
set ::stub_stop_errorinfo {AIP_STOP_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 2 WAIT wait 10ns} err opts]
check "stop failure avoids duplicate prefix" [expr {
    $rc == 1 && [one_prefix $err] && [string match {*cannot monitor*} $err] &&
    [preserved_options $opts {AIP STOP REGISTER} AIP_STOP_ERRORINFO]
}]

# Failures after registration preserve their cause and remove the monitor.
foreach {mode pattern} {run_error {*stub run failure*} no_progress {*without advancing*}} {
    reset_stubs
    set ::stub_mode $mode
    set rc [catch {aip_wait_checkpoint tb.status 2 WAIT wait 10ns} err]
    check "$mode errors" [expr {$rc == 1 && [one_prefix $err] && [string match $pattern $err]}]
    check "$mode deletes exact stop" [expr {
        $::stub_stop_installs == 1 && $::stub_stop_deletes == 1 &&
        $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
    }]
    check "$mode does not save" [expr {[llength $::stub_saved] == 0}]
}

reset_stubs
set ::stub_mode run_error
set ::stub_run_errorcode {AIP RUN FAILURE}
set ::stub_run_errorinfo {AIP_RUN_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 2 WAIT wait 10ns} err opts]
check "run failure preserves options" [expr {
    $rc == 1 && [one_prefix $err] &&
    [preserved_options $opts {AIP RUN FAILURE} AIP_RUN_ERRORINFO]
}]
check "coded run failure deletes exact stop" [expr {
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]

# Cleanup failure after a hit aborts before save and preserves cleanup options.
reset_stubs
set ::stub_stop_delete_fail {stub stop delete failure}
set ::stub_stop_delete_errorcode {AIP STOP DELETE}
set ::stub_stop_delete_errorinfo {AIP_STOP_DELETE_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 WAIT wait 10ns} err opts]
check "successful hit delete failure errors" [expr {
    $rc == 1 && [one_prefix $err] &&
    [string match {*cannot delete stop 73*stub stop delete failure*} $err]
}]
check "successful hit delete failure preserves options" [expr {
    $rc == 1 &&
    [preserved_options $opts {AIP STOP DELETE} AIP_STOP_DELETE_ERRORINFO]
}]
check "successful hit delete failure does not save" [expr {
    [llength $::stub_saved] == 0 && $::stub_stop_active eq {73}
}]

# A primary wait error remains authoritative when exact-stop cleanup also fails.
reset_stubs
set ::stub_mode run_error
set ::stub_run_errorcode {AIP RUN PRIMARY}
set ::stub_run_errorinfo {AIP_RUN_PRIMARY_ERRORINFO}
set ::stub_stop_delete_fail {stub stop delete failure}
set ::stub_stop_delete_errorcode {AIP STOP DELETE SECONDARY}
set ::stub_stop_delete_errorinfo {AIP_STOP_DELETE_SECONDARY_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 2 WAIT wait 10ns} err opts]
check "primary error survives delete failure" [expr {
    $rc == 1 && [one_prefix $err] && [string match {*stub run failure*} $err] &&
    [preserved_options $opts {AIP RUN PRIMARY} AIP_RUN_PRIMARY_ERRORINFO]
}]
check "delete diagnostic appears exactly once" [expr {
    [regexp -all {cleanup failed: stub stop delete failure} $err] == 1
}]
check "primary plus delete failure does not save" [expr {
    [llength $::stub_saved] == 0 && $::stub_stop_active eq {73}
}]

# Validation and initial read failures are fail-closed before monitor installation.
foreach {name command pattern} {
    {unsafe snapshot} {aip_wait_checkpoint tb.status 1 BAD ../bad 10ns} {*invalid snapshot*}
    {empty path} {aip_wait_checkpoint {} 1 BAD bad 10ns} {*path cannot be empty*}
} {
    reset_stubs
    set rc [catch $command err]
    check "$name rejected" [expr {$rc == 1 && [one_prefix $err] && [string match $pattern $err]}]
    check "$name installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]
}

reset_stubs
set ::stub_get_fail {stub get failure}
set rc [catch {aip_wait_checkpoint tb.status 1 BAD bad 10ns} err]
check "initial get failure prefixed" [expr {$rc == 1 && [one_prefix $err] && [string match {*cannot read*} $err]}]
check "initial get failure installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]

reset_stubs
set ::stub_get_fail {aip_wait_checkpoint: underlying get failure}
set ::stub_get_errorcode {AIP GET INITIAL}
set ::stub_get_errorinfo {AIP_GET_INITIAL_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 BAD bad 10ns} err opts]
check "get failure avoids duplicate prefix" [expr {
    $rc == 1 && [one_prefix $err] && [string match {*cannot read*} $err] &&
    [preserved_options $opts {AIP GET INITIAL} AIP_GET_INITIAL_ERRORINFO]
}]

reset_stubs
set ::stub_time_error {aip_wait_checkpoint: underlying time failure}
set ::stub_time_errorcode {AIP TIME DEADLINE}
set ::stub_time_errorinfo {AIP_TIME_DEADLINE_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 BAD bad 10ns} err opts]
check "time failure avoids duplicate prefix" [expr {
    $rc == 1 && [one_prefix $err] &&
    [preserved_options $opts {AIP TIME DEADLINE} AIP_TIME_DEADLINE_ERRORINFO]
}]
check "time failure installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]

reset_stubs
set ::stub_time_error {loop time failure}
set ::stub_time_errorcode {AIP TIME LOOP}
set ::stub_time_errorinfo {AIP_TIME_LOOP_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 WAIT wait} err opts]
check "loop time failure preserves options" [expr {
    $rc == 1 && [one_prefix $err] &&
    [preserved_options $opts {AIP TIME LOOP} AIP_TIME_LOOP_ERRORINFO]
}]
check "loop time failure deletes exact stop" [expr {
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]

reset_stubs
set ::stub_value 1
set ::stub_time_error {save time failure}
set ::stub_time_errorcode {AIP TIME SAVE}
set ::stub_time_errorinfo {AIP_TIME_SAVE_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 SAVE_TIME save_time} err opts]
check "save time failure preserves options" [expr {
    $rc == 1 && [one_prefix $err] &&
    [preserved_options $opts {AIP TIME SAVE} AIP_TIME_SAVE_ERRORINFO]
}]
check "save time failure installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]

reset_stubs
set ::stub_value 1
set ::stub_get_fail {save get failure}
set ::stub_get_fail_at 2
set ::stub_get_errorcode {AIP GET SAVE}
set ::stub_get_errorinfo {AIP_GET_SAVE_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 SAVE_GET save_get} err opts]
check "save get failure preserves options" [expr {
    $rc == 1 && [one_prefix $err] && [string match {*cannot read*} $err] &&
    [preserved_options $opts {AIP GET SAVE} AIP_GET_SAVE_ERRORINFO]
}]
check "save get failure installs nothing" [expr {$::stub_stop_installs == 0 && $::stub_stop_deletes == 0}]

# A save error after a delayed hit remains prefixed and cannot leak the monitor.
reset_stubs
set ::stub_save_fail 1
set ::stub_save_errorcode {AIP CHECKPOINT SAVE}
set ::stub_save_errorinfo {AIP_CHECKPOINT_SAVE_ERRORINFO}
set rc [catch {aip_wait_checkpoint tb.status 1 SAVE bad 10ns} err opts]
check "save failure prefixed" [expr {
    $rc == 1 && [one_prefix $err] && [string match {*stub save failure*} $err] &&
    [preserved_options $opts {AIP CHECKPOINT SAVE} AIP_CHECKPOINT_SAVE_ERRORINFO]
}]
check "save failure exact stop cleanup" [expr {
    $::stub_stop_installs == 1 && $::stub_stop_deletes == 1 &&
    $::stub_stop_delete_ids eq {73} && $::stub_stop_active eq ""
}]

puts "PASS: $pass FAIL: $fail TOTAL: [expr {$pass + $fail}]"
if {$fail == 0} {
    puts "CHECKPOINT_WAIT_TCL_PASS"
} else {
    error "CHECKPOINT_WAIT_TCL_FAIL failures=$fail"
}
