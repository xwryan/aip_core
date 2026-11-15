# Run with: simv -ucli -do ucli_pli_smoke.tcl
if {[info commands ucli_pli_ping] eq ""} {
    puts "UCLI_PLI_SMOKE_FAIL command is not registered"
    quit
}

if {[catch {ucli_pli_ping} err]} {
    puts "UCLI_PLI_SMOKE_FAIL command failed: $err"
    quit
}

if {![info exists ::ucli_pli_embedded_value] ||
        $::ucli_pli_embedded_value != 42 ||
        $::ucli_pli_embedded_status ne "pass"} {
    puts "UCLI_PLI_SMOKE_FAIL embedded Tcl did not execute"
    quit
}

puts "UCLI_PLI_SMOKE_PASS value=$::ucli_pli_embedded_value"
quit
