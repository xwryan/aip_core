# Checkpoint restore regression, stage 2: resume from the base snapshot.
# Launched by `make test_checkpoint_restore` from tests/sv/.
#
# Restoring is only useful if the whole AIP surface still works afterwards, so
# this checks the command table, the SV bridge round trip, the UCLI helpers,
# simulation progress, and taking a further snapshot from the restored session.
set ::env(AIP_CORE) [file normalize ../..]
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set ::aip_ckpt_dir ./ckpt_restore_artifacts
set ::aip_simv_path [file normalize ./simv_ckpt_restore]

aip_restore base
# VCS UCLI `restore` keeps Tcl globals but drops every command the loader
# defined, so the loader has to run again before anything else is called.
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set ::aip_ckpt_dir ./ckpt_restore_artifacts
set ::aip_simv_path [file normalize ./simv_ckpt_restore]

# The helper itself has to be defined after the restore: procs are commands, so
# `restore` drops them exactly like the ones the loader defines.
set fail 0
proc check {name condition} {
    upvar fail f
    if {$condition} {
        puts "PASS $name"
    } else {
        puts "FAIL $name"
        incr f
    }
}

# 1. The command table is back: bridge, checkpoint and UCLI-helper layers.
foreach cmd {aip_send_cmd aip_read_result aip_check_status aip_getparam
             aip_checkpoint aip_restore fv gv _aip_sim_time} {
    check "command '$cmd' exists after restore" [expr {[info commands $cmd] ne ""}]
}
if {$fail} {
    puts "RESTORE_TEST_ABORT commands missing"
    quit
}

# 2. Simulation time continues from the snapshot instead of restarting at 0.
set t_after_restore [_aip_sim_time]
puts "AFTER_RESTORE_SIMTIME=$t_after_restore"
check "simulation time resumed at the snapshot" \
      [regexp {^1000\.0*\s*ns$} $t_after_restore]

# 3. The SV bridge still answers: a registered command must complete and
#    return the value the design holds at the snapshot (dut_status = 0x4).
set rc [catch {dut_get path=test_checkpoint_wait.dut_status} err]
set dut_result [aip_read_result]
set dut_status [aip_check_status]
puts "AFTER_RESTORE_DUT_GET rc=$rc status=$dut_status result='$dut_result'"
check "bridge command completed after restore" [expr {$rc == 0 && $dut_status == 0}]
# dut_status is 32'h4 at the snapshot; dut_get returns it right-aligned in the
# bridge's fixed-width result buffer, so match the tail exactly.
check "bridge returned the restored design value" [string match *00000004 $dut_result]

# 4. The UCLI helper layer still reaches the design directly.
set gv_value [gv test_checkpoint_wait.dut_status -hex]
puts "AFTER_RESTORE_GV=$gv_value"
check "UCLI helper read the restored design" [string match *4* $gv_value]

# 5. The bridge still drives the simulation forward.
run 500ns
set t_after_run [_aip_sim_time]
puts "AFTER_RUN_SIMTIME=$t_after_run"
check "simulation advanced after restore" [regexp {^1500\.0*\s*ns$} $t_after_run]

# 6. A restored session can take its own snapshot (chained checkpoints).
set rc [catch {aip_checkpoint resumed "note=taken from a restored session"} err]
check "checkpoint from a restored session succeeded" [expr {$rc == 0}]
if {$rc} { puts "CHAINED_CHECKPOINT_ERROR=$err" }
check "chained snapshot file exists" \
      [file exists [file join $::aip_ckpt_dir resumed.vcssave]]
check "chained snapshot meta exists" \
      [file exists [file join $::aip_ckpt_dir resumed.meta]]

if {$fail == 0} {
    puts "RESTORE_COMMANDS_OK"
    puts "RESTORE_TEST_DONE"
} else {
    puts "RESTORE_TEST_FAILURES=$fail"
}
end_test
quit
