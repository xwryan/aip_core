# 注册运行时命令并跑一次后保存快照。rs_raw 绕过 Tcl proc 注册，快照内的 Tcl 缓存没有它，
# restore 阶段据此确认重新 source 时从 SV 命令名表重读，而不是沿用旧缓存。
source [file join $::env(AIP_CORE) tests tcl test_aip_reg_seq_ckpt_common.tcl]
set B uvm_test_top.env.b.sqr
set r [aip_reg_seq cmd=rs_ck type=rs_path_seq sqr=$B path=rs.ck]
rsck_check "register before snapshot" [expr {[aip_check_status] == 0}]
set_param path=rs.ck.len value=33
rs_ck count=2
rsck_check "run before snapshot" [expr {[aip_read_result] eq "OK: rs_ck count=2" && [rsck_state items rs_ck] == 2}]
aip_send_cmd "aip_reg_seq cmd=rs_raw type=rs_plain_seq sqr=$B"
rsck_check "raw registration not cached yet" [expr {[aip_check_status] == 0 && ![dict exists $::_aip_known_cmds rs_raw]}]
aip_checkpoint regseq "note=aip_reg_seq rs_ck rs_raw registered"
rs_ck count=1
rsck_check "session continues after save" [expr {[aip_read_result] eq "OK: rs_ck count=1" && [rsck_state items rs_ck] == 3}]
puts "RSCK_GENERATE_PASS checks=$::rsck_checks"
end_test
run
