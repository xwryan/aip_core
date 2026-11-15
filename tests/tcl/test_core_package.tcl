proc must_get {path} {
    if {[catch {get $path} value]} {
        error "must_get failed for $path: $value"
    }
    return $value
}

proc must_force {path value} {
    if {[catch {force $path $value} result]} {
        error "must_force failed for $path: $result"
    }
}

must_get aip_core_pkg::__tcl_cmd_len
must_get {aip_core_pkg::__tcl_cmd_ascii[0]}
must_get aip_core_pkg::__tcl_result_known
must_get aip_core_pkg::__cpu_bridge_irq
must_force aip_core_pkg::__tcl_cmd_len 32'd1
must_force {aip_core_pkg::__tcl_cmd_ascii[0]} 32'd65

puts "CORE_PACKAGE_UCLI_PASS"
run
