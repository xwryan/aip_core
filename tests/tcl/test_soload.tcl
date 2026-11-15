source ../../src/tcl/aip_cmd.tcl

set pass 0
set fail 0
proc check {name cond} {
    upvar pass p; upvar fail f
    if {$cond} { puts "\[PASS\] $name"; incr p } else { puts "\[FAIL\] $name"; incr f }
}

puts "\n=== S1: so_load hello.so ==="
so_load path=../hello.so
check "so_load status" [expr {[aip_check_status] == 0}]

puts "\n=== S2: hello world ==="
hello world
check "hello readback" [expr {[aip_read_result] eq "hello world"}]

puts "\n=== S3: upper abc ==="
upper abc
check "upper readback" [expr {[aip_read_result] eq "ABC"}]

puts "\n=== S4: so_unload ==="
so_unload path=../hello.so
check "so_unload status" [expr {[aip_check_status] == 0}]

puts "\n=== S5: hello after unload -> unknown ==="
catch {hello world}
check "hello unknown after unload" [expr {[aip_check_status] != 0}]

puts "\n=== S6: so_reload ==="
so_reload path=../hello.so
check "so_reload status" [expr {[aip_check_status] == 0}]
hello again
check "hello works after reload" [expr {[aip_read_result] eq "hello again"}]

puts "\n=== S7: load nonexistent -> error ==="
so_load path=./nope.so
check "load nonexist status==1" [expr {[aip_check_status] == 1}]
check "load nonexist ERROR msg" [expr {[string match "ERROR*" [aip_read_result]]}]

puts "\n=== S8: crc (real function via plugin) ==="
crc 123456789
check "crc 123456789 == cbf43926" [expr {[aip_read_result] eq "crc=0xcbf43926"}]

puts "\n=== S9: hex_enc ==="
hex_enc ABC
check "hex_enc ABC == 414243" [expr {[aip_read_result] eq "414243"}]

puts "\n=== S10: hex_dec (round-trip) ==="
hex_dec 414243
check "hex_dec 414243 == ABC" [expr {[aip_read_result] eq "ABC"}]

puts "\n=========================================="
puts "  PASS: $pass  FAIL: $fail  TOTAL: [expr {$pass+$fail}]"
if {$fail == 0} { puts "  ALL TESTS PASSED" }
puts "=========================================="

quit
