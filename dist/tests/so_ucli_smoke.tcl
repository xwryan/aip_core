# Run with: simv -ucli -do tests/so_ucli_smoke_entry.tcl  (from dist/)
# Exercises the binary Tcl bridge: `load lib/libaip_tcl_bridge.so` through
# aip_init_so.tcl, then the bridge start and a command lookup.
set script_path [info script]
if {$script_path eq ""} {
    set dist_dir [file normalize [pwd]]
} else {
    set dist_dir [file normalize [file join [file dirname $script_path] ..]]
}

proc smoke_fail {message} {
    puts "TCL_UCLI_SO_SMOKE_FAIL $message"
    if {[info commands quit] ne ""} {
        quit
    }
    exit 1
}

if {[catch {source [file join $dist_dir aip_init_so.tcl]} err]} {
    smoke_fail "aip_init_so.tcl failed: $err"
}
if {![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded} {
    smoke_fail "::aip_tcl_embedded not set by the extension"
}
foreach cmd {aip_parse_int aip_send_cmd aip_checkpoint aip_getparam} {
    if {[info commands $cmd] eq ""} {
        smoke_fail "command $cmd is not registered"
    }
}
set parsed [aip_parse_int 42]
if {$parsed != 42} {
    smoke_fail "aip_parse_int returned '$parsed'"
}
if {![info exists ::_aip_known_cmds] || [dict size $::_aip_known_cmds] == 0} {
    smoke_fail "bridge start did not load the SV command list"
}
if {![info exists ::aip_known_cmds_loaded] || !$::aip_known_cmds_loaded} {
    smoke_fail "::aip_known_cmds_loaded not set"
}
if {[info commands aip_init] eq "" || [aip_init] ne [file normalize [file join $dist_dir ..]]} {
    smoke_fail "aip_init does not return the repository root"
}

puts "TCL_UCLI_SO_SMOKE_PASS parsed=$parsed"
quit
