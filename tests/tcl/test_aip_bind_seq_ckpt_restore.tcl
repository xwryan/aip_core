# 新 simv 进程恢复 generate 快照：快照前注册的命令随 SV 状态恢复，恢复前本进程注册的命令随之消失；
# restore 在顶层执行，之后重新 source 定义。
source [file join $::env(AIP_CORE) tests tcl test_aip_bind_seq_ckpt_common.tcl]
set A uvm_test_top.env.a.sqr
set B uvm_test_top.env.b.sqr
run 10ns
set r [aip_bind_seq cmd=rs_pre type=rs_plain_seq sqr=$A]
rsck_check "register before restore" [expr {[aip_check_status] == 0}]
rs_pre count=1
rsck_check "pre-restore command runs" [expr {[aip_read_result] eq "OK: rs_pre count=1"}]
aip_restore bindseq
source [file join $::env(AIP_CORE) tests tcl test_aip_bind_seq_ckpt_common.tcl]
set A uvm_test_top.env.a.sqr
set B uvm_test_top.env.b.sqr
set ::rsck_checks 0
rsck_check "name table re-read on reload" [expr {[dict exists $::_aip_known_cmds rs_ck] &&
                                                 [dict exists $::_aip_known_cmds rs_raw] &&
                                                 ![dict exists $::_aip_known_cmds rs_pre]}]
rsck_check "SV registry is the snapshot one" [expr {[rsck_state exists rs_ck] == 1 && [rsck_state exists rs_raw] == 1 &&
                                                    [rsck_state exists rs_pre] == 0}]
rsck_check "snapshot counters restored" [expr {[rsck_state items rs_ck] == 2 && [rsck_state items rs_pre] == 0 &&
                                               [rsck_state sqr_items a] == 0 && [rsck_state sqr_items b] == 2}]
rs_ck count=3
rsck_check "restored command runs" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: rs_ck count=3"}]
rsck_check "restored binding and path" [expr {[rsck_state items rs_ck] == 5 && [rsck_state len rs_ck] == 33 &&
                                              [rsck_state path rs_ck] eq "rs.ck" && [rsck_state sqr_items b] == 5}]
rs_raw count=2
rsck_check "raw-registered command restored" [expr {[aip_read_result] eq "OK: rs_raw count=2" && [rsck_state sqr_items b] == 7}]
rs_ck count=20 wait=0
rsck_check "restored command runs in background" [expr {[aip_read_result] eq "STARTED: rs_ck"}]
rs_ck count=1
rsck_check "restored command BUSY on re-entry" [expr {[aip_check_status] != 0 && [string match "*BUSY*" [aip_read_result]]}]
kill_seq name=rs_ck
rsck_check "kill_seq tracks restored command" [expr {[string match "killed=1*" [aip_read_result]]}]
run 50ns
rsck_check "pre-restore command gone" [expr {[catch {rs_pre count=1} msg] && [string match "invalid command name*" $msg]}]
set r [aip_bind_seq cmd=rs_ck type=rs_path_seq sqr=$B path=rs.ck]
rsck_check "restored name still taken" [expr {[aip_check_status] == 1 && [string match "*already exists*" $r]}]
set r [aip_bind_seq cmd=rs_pre type=rs_plain_seq sqr=$A]
rsck_check "freed name registers again" [expr {[aip_check_status] == 0}]
rs_pre count=1
rsck_check "re-registered command runs" [expr {[aip_read_result] eq "OK: rs_pre count=1" && [rsck_state sqr_items a] == 1}]
puts "RSCK_RESTORE_PASS checks=$::rsck_checks"
end_test
run
