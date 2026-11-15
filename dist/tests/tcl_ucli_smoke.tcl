# Run with: simv -ucli -do tcl_ucli_smoke.tcl
set script_path [info script]
if {$script_path eq ""} {
    # VCS -do may evaluate the file with an empty `info script`; the runner
    # deliberately starts from dist/ in that case.
    set dist_dir [file normalize [pwd]]
} else {
    set dist_dir [file normalize [file join [file dirname $script_path] ..]]
}

proc smoke_fail {message} {
    puts "TCL_UCLI_SMOKE_FAIL $message"
    if {[info commands quit] ne ""} {
        quit
    }
    exit 1
}

source [file join $dist_dir aip_init.tcl]
if {[info commands aip_parse_int] eq ""} {
    smoke_fail "command aip_parse_int is not registered"
}
set parsed [aip_parse_int 42]
if {$parsed != 42} {
    smoke_fail "aip_parse_int returned '$parsed'"
}

puts "TCL_UCLI_SMOKE_PASS parsed=$parsed"
quit
