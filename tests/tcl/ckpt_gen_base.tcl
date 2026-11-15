# Checkpoint restore regression, stage 1: create the base snapshot.
# Launched by `make test_checkpoint_restore` from tests/sv/.
set ::env(AIP_CORE) [file normalize ../..]
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set ::aip_ckpt_dir ./ckpt_restore_artifacts
set ::aip_simv_path [file normalize ./simv_ckpt_restore]
file delete -force $::aip_ckpt_dir

# Stand in for boot / init / link-up.
run 1000ns

# Baseline for stage 2: the same bridge round trip, taken before any snapshot
# exists, so the restored session can be compared against it byte for byte.
dut_get path=test_checkpoint_wait.dut_status
puts "BASE_GEN_DUT_GET status=[aip_check_status] result='[aip_read_result]'"

aip_checkpoint base "note=after 1000ns boot"
puts "BASE_GEN_SIMTIME=[_aip_sim_time]"
puts "BASE_GEN_DONE"
end_test
quit
