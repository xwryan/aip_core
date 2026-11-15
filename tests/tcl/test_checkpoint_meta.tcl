# L1 unit test for aip_checkpoint.tcl pure helpers (plain tclsh, no VCS)
set _here [file dirname [file normalize [info script]]]
source [file join $_here .. .. src tcl aip_checkpoint.tcl]

set _fail 0
proc check {cond msg} {
    global _fail
    if {[uplevel 1 [list expr $cond]]} { puts "PASS $msg" } else { puts "FAIL $msg"; set _fail 1 }
}

set tmp [file join $_here _ckpt_unit_tmp]
file delete -force $tmp
file mkdir $tmp

# meta roundtrip
array set w {simv_path /x/simv simv_mtime 100 simv_size 200 \
            sim_time {5.000 ns} note hi created {2026-06-26 00:00:00}}
_aip_ckpt_write_meta [file join $tmp a.meta] w
array set r [_aip_ckpt_read_meta [file join $tmp a.meta]]
check {$r(simv_mtime) == 100}        "meta mtime roundtrip"
check {$r(simv_size)  == 200}        "meta size roundtrip"
check {$r(sim_time) eq {5.000 ns}}   "meta sim_time (space value) roundtrip"
check {$r(note) eq {hi}}             "meta note roundtrip"

# validate: 匹配通过
set fake [file join $tmp fake_simv]
set ofh [open $fake w]; puts $ofh "x"; close $ofh
array set m2 [list simv_mtime [file mtime $fake] simv_size [file size $fake]]
check {![catch {_aip_ckpt_validate [array get m2] $fake}]} "validate match passes"

# validate: size 失配 → stale
array set m3 [list simv_mtime [file mtime $fake] simv_size 999999]
check {[catch {_aip_ckpt_validate [array get m3] $fake}]} "validate size-mismatch -> stale"

# validate: mtime 失配 → stale
array set m4 [list simv_mtime 1 simv_size [file size $fake]]
check {[catch {_aip_ckpt_validate [array get m4] $fake}]} "validate mtime-mismatch -> stale"

# read_meta: 缺文件 → error
check {[catch {_aip_ckpt_read_meta [file join $tmp nope.meta]}]} "missing meta -> error"

file delete -force $tmp
if {$_fail} { puts "L1 FAILED"; exit 1 } else { puts "ALL L1 PASS" }
