# tests/tcl：真实 VCS 四态 X/Z watch 回归；由 Makefile 在 VCS 主机运行。
set loader [expr {[info exists ::env(AIP_X_WATCH_LOADER)] && $::env(AIP_X_WATCH_LOADER) eq "so" ? "aip_init_so.tcl" : "aip_init.tcl"}]
source [file join $::env(AIP_CORE) dist $loader]

set xid [aip_watch test_x_watch_fixture.x_data x stop=0]
set zid [aip_watch test_x_watch_fixture.z_data z stop=0]
run 100ns

set xr [aip_watch_status $xid]
set zr [aip_watch_status $zid]
if {[dict get $xr state] ne "matched" ||
    [string first x [string tolower [dict get $xr value]]] < 0} {
    error "AIP_X_WATCH_FAIL x_state=$xr"
}
if {[dict get $zr state] ne "matched" ||
    [string first z [string tolower [dict get $zr value]]] < 0} {
    error "AIP_X_WATCH_FAIL z_state=$zr"
}
puts "AIP_X_WATCH_PASS x=[dict get $xr value] z=[dict get $zr value]"
finish
