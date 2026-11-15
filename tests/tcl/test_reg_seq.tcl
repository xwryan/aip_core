source ../../src/tcl/aip_cmd.tcl

set pass 0
set fail 0
proc check {name cond} {
    upvar pass p; upvar fail f
    if {$cond} { puts "\[PASS\] $name"; incr p } else { puts "\[FAIL\] $name"; incr f }
}

puts "\n=== R1: write addr=0x1000 data=0xdead ==="
reg_acc op=write addr=0x1000 len=4 mask=0xff data=0xdead
check "reg write status" [expr {[aip_check_status] == 0}]

puts "\n=== R2: read back addr=0x1000 ==="
reg_acc op=read addr=0x1000
set r [aip_read_result]
puts "  result: $r"
check "reg read status" [expr {[aip_check_status] == 0}]
check "reg readback == 0xdead" [expr {$r eq "rdata=0xdead"}]

puts "\n=== R3: write different addr, read tracks ==="
reg_acc op=write addr=0x2000 data=0xbeef
reg_acc op=read addr=0x2000
check "reg readback == 0xbeef" [expr {[aip_read_result] eq "rdata=0xbeef"}]

puts "\n=== R4: missing op -> error ==="
reg_acc addr=0x3000
check "missing op status==1" [expr {[aip_check_status] == 1}]
check "missing op ERROR msg" [expr {[string match "ERROR*" [aip_read_result]]}]

puts "\n=== R5: 64-bit data not truncated ==="
reg_acc op=write addr=0x4000 data=0x123456789
reg_acc op=read addr=0x4000
check "reg 64bit readback" [expr {[aip_read_result] eq "rdata=0x123456789"}]

puts "\n=== R6: unwritten addr reads 0 ==="
reg_acc op=read addr=0xdeadbeef
check "unwritten reads 0" [expr {[aip_read_result] eq "rdata=0x0"}]

puts "\n=== R7: illegal-char command name (reg.rw) ==="
reg.rw op=write addr=0x7000 data=0xf00d
check "reg.rw write status" [expr {[aip_check_status] == 0}]
reg.rw op=read addr=0x7000
check "reg.rw readback == 0xf00d" [expr {[aip_read_result] eq "rdata=0xf00d"}]

puts "\n=== R8: '::' in command name (xxx::reg_write) ==="
xxx::reg_write op=write addr=0x8000 data=0xabcd
check "xxx::reg_write write status" [expr {[aip_check_status] == 0}]
xxx::reg_write op=read addr=0x8000
check "xxx::reg_write readback == 0xabcd" [expr {[aip_read_result] eq "rdata=0xabcd"}]

puts "\n=========================================="
puts "  PASS: $pass  FAIL: $fail  TOTAL: [expr {$pass+$fail}]"
if {$fail == 0} { puts "  ALL TESTS PASSED" }
puts "=========================================="

quit
