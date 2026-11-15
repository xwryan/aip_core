source ../../src/tcl/aip_cmd.tcl

set checker_case [aip_getparam CHECKER_CASE]
set strict 1
set expected_status 0
set expected_nonzero 0
set timeout 2us

if {$checker_case eq "nonstrict_timeout"} {
    set strict 0
    set timeout 500ns
}
if {$checker_case eq "strict_timeout" ||
    $checker_case eq "multi_timeout" ||
    $checker_case eq "strict_missing" ||
    $checker_case eq "failure" ||
    $checker_case eq "failure_nonstrict" ||
    $checker_case eq "cleanup_failure"} {
    set expected_status 1
    set timeout 500ns
}
if {$checker_case eq "watchdog_end_test" ||
    $checker_case eq "watchdog_fork_end_test" ||
    $checker_case eq "watchdog_fork_end_test_drain" ||
    $checker_case eq "watchdog_fork_end_test_idle" ||
    $checker_case eq "watchdog_end_test_drain"} {
    set expected_nonzero 1
    set timeout 2ms
}
if {$checker_case eq "failure_nonstrict"} {
    set strict 0
}

if {$checker_case eq "cleanup_single"} {
    end_test cmd=cleanup_a
} elseif {$checker_case eq "cleanup_drain"} {
    end_test drain=100ns cmd=cleanup_a
} elseif {$checker_case eq "cleanup_multi"} {
    end_test cmd=cleanup_a cmd=cleanup_b
} elseif {$checker_case eq "cleanup_semicolon"} {
    aip_send_cmd {end_test {cmd=cleanup_a;cleanup_b}}
} elseif {$checker_case eq "cleanup_failure"} {
    end_test cmd=cleanup_fail cmd=cleanup_b
} elseif {$checker_case eq "watchdog_end_test_drain"} {
    end_test drain=2000000
} elseif {$checker_case eq "watchdog_fork_end_test_drain"} {
    fork end_test drain=2000000 join
} elseif {$checker_case eq "watchdog_fork_end_test_idle"} {
    fork end_test idle=2ms join
} elseif {$checker_case eq "watchdog_fork_end_test"} {
    fork end_test wait_done=1 timeout=2ms strict=1 join
} elseif {$checker_case eq "idle_compat"} {
    end_test wait_done=1 idle=500ns timeout=$timeout strict=$strict
} else {
    end_test wait_done=1 timeout=$timeout strict=$strict
}
set actual_status [aip_check_status]
set detail [aip_read_result]

if {($expected_nonzero && $actual_status == 0) ||
    (!$expected_nonzero && $actual_status != $expected_status)} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case expected=$expected_status actual=$actual_status detail=$detail"
    quit
}
if {($checker_case eq "watchdog_end_test" ||
     $checker_case eq "watchdog_fork_end_test" ||
     $checker_case eq "watchdog_fork_end_test_drain" ||
     $checker_case eq "watchdog_fork_end_test_idle" ||
     $checker_case eq "watchdog_end_test_drain") &&
    [string first "watchdog killed it" $detail] < 0} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_watchdog_detail detail=$detail"
    quit
}
if {($checker_case eq "failure" || $checker_case eq "failure_nonstrict") &&
    [string first "irreversible transport loss" $detail] < 0} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_failure_detail detail=$detail"
    quit
}
if {$checker_case eq "strict_timeout" &&
    [string first "pending" $detail] < 0} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_pending_name detail=$detail"
    quit
}
if {$checker_case eq "nonstrict_timeout" &&
    ([string first "timeout" $detail] < 0 ||
     [string first "pending" $detail] < 0)} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_timeout_detail detail=$detail"
    quit
}
if {$checker_case eq "multi_timeout" &&
    ([string first "first" $detail] < 0 || [string first "second" $detail] < 0)} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_pending_names detail=$detail"
    quit
}
if {$checker_case eq "strict_missing" &&
    [string first "strict end_test requires at least one checker" $detail] < 0} {
    puts "CHECKER_REGISTRY_FAIL case=$checker_case missing_strict_checker_detail detail=$detail"
    quit
}

puts "CHECKER_REGISTRY_PASS case=$checker_case status=$actual_status"
run
