# aip_bind_seq 运行时绑定的 UCLI 黑盒验证（类型与环境见 test_aip_bind_seq.sv）；AIP_BIND_SEQ_LOADER=source|so 选择入口。
# 任何失败都阻止 BIND_SEQ_TCL_PASS 标记。
if {[info exists ::env(AIP_BIND_SEQ_LOADER)] && $::env(AIP_BIND_SEQ_LOADER) eq "so"} {
    source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} else {
    source [file join $::env(AIP_CORE) dist aip_init.tcl]
}
set ::rs_checks 0
set A uvm_test_top.env.a.sqr
set B uvm_test_top.env.b.sqr

proc rs_check {name condition} {
    if {!$condition} { error "BIND_SEQ_FAIL $name" }
    incr ::rs_checks
    puts "BIND_SEQ_CHECK_PASS $name"
}

# 查询本身也须成功，避免把错误文本当观测值。
proc rs_state {kind {name none}} {
    aip_send_cmd "rs_state kind=$kind name=$name"
    if {[aip_check_status] != 0} { error "BIND_SEQ_FAIL observation $kind $name: [aip_read_result]" }
    return [aip_read_result]
}

proc rs_now {} { return [rs_state now] }

# 失败注册：status=1、消息匹配，且不得建出命令（调用方另查）。
proc rs_reject {label pattern args} {
    set result [aip_bind_seq {*}$args]
    puts "  $label -> $result"
    rs_check "$label rejected" [expr {[aip_check_status] == 1 && [string match $pattern $result]}]
}

puts "BIND_SEQ_STAGE register loader=$::aip_tcl_embedded"
set r [aip_bind_seq cmd=rs_a1 type=rs_plain_seq sqr=$A]
rs_check "plain type on sqr A" [expr {[aip_check_status] == 0 && $r eq "OK: rs_a1 type=rs_plain_seq sqr=$A"}]
foreach spec [list "cmd=rs_a2 type=rs_plain_seq sqr=$A" "cmd=rs_b1 type=rs_plain_seq sqr=$B" \
                   "cmd=rs_p1 type=rs_path_seq sqr=$A path=rs.p1" "cmd=rs_p2 type=rs_path_seq sqr=$B path=rs.p2" \
                   "cmd=rs_pdef type=rs_path_seq sqr=$B" "cmd=rs.dot-name type=rs_plain_seq sqr=$B"] {
    set r [aip_bind_seq {*}$spec]
    rs_check "register $spec" [expr {[aip_check_status] == 0 && [string match "OK: *" $r]}]
}
set r [aip_bind_seq cmd=rs_hang type=rs_path_seq sqr=$A path=rs.hang]
rs_check "path shown in result" [expr {$r eq "OK: rs_hang type=rs_path_seq sqr=$A path=rs.hang"}]
rs_check "known-command cache refreshed" [expr {[dict exists $::_aip_known_cmds rs_a1] &&
                                                 [dict exists $::_aip_known_cmds rs_hang] &&
                                                 [info exists ::_aip_known_cmds_gen]}]
rs_check "fast-fail path stays enabled" [expr {![info exists ::_aip_dynamic_cmds]}]

puts "BIND_SEQ_STAGE count"
rs_a1 count=5
rs_check "count result" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: rs_a1 count=5"}]
rs_check "count items on sqr A" [expr {[rs_state items rs_a1] == 5 && [rs_state sqr_items a] == 5 && [rs_state sqr_items b] == 0}]
rs_b1
rs_check "default count=1" [expr {[aip_read_result] eq "OK: rs_b1 count=1" && [rs_state items rs_b1] == 1 &&
                                  [rs_state sqr_items b] == 1}]
rs.dot-name count=2
rs_check "dotted name dispatches" [expr {[aip_read_result] eq "OK: rs.dot-name count=2" && [rs_state items rs.dot-name] == 2}]
rs_static count=2
rs_check "compile-time aip_cmd_seq unchanged" [expr {[aip_read_result] eq "OK: rs_static count=2" && [rs_state items rs_static] == 2}]

puts "BIND_SEQ_STAGE param_path"
set_param path=rs.p1.len value=77
set_param path=rs.p2.len value=88
set_param path=rs.def.len value=55
rs_p1 count=3
rs_check "path=rs.p1 routes parameters" [expr {[aip_read_result] eq "OK: rs_p1 count=3" && [rs_state items rs_p1] == 3 &&
                                               [rs_state len rs_p1] == 77 && [rs_state path rs_p1] eq "rs.p1"}]
rs_p2 count=2
rs_check "path=rs.p2 routes parameters" [expr {[rs_state len rs_p2] == 88 && [rs_state path rs_p2] eq "rs.p2"}]
rs_pdef count=1
rs_check "path type without path= keeps seq default" [expr {[rs_state len rs_pdef] == 55 && [rs_state path rs_pdef] eq "rs.def"}]

puts "BIND_SEQ_STAGE time"
set n0 [rs_state items rs_a2]
set start [rs_now]
rs_a2 time=500ns
set r [aip_read_result]
set n [expr {[rs_state items rs_a2] - $n0}]
rs_check "time result" [expr {[aip_check_status] == 0 && $r eq "OK: rs_a2 time=500ns"}]
rs_check "time mode lasted 500ns" [expr {[rs_now] - $start >= 500}]
rs_check "time mode issued items ($n)" [expr {$n >= 40 && $n <= 51}]

puts "BIND_SEQ_STAGE wait0_busy"
set b0 [rs_state items rs_b1]
set start [rs_now]
rs_b1 count=50 wait=0
rs_check "wait=0 STARTED" [expr {[aip_check_status] == 0 && [aip_read_result] eq "STARTED: rs_b1"}]
rs_check "wait=0 returns at once" [expr {[rs_now] - $start < 10}]
rs_b1 count=1
rs_check "same-name re-entry BUSY" [expr {[aip_check_status] != 0 && [string match "*BUSY*" [aip_read_result]]}]
rs_check "background seq tracked" [expr {[rs_state active rs_b1] == 1}]
rs_a1 count=60
rs_check "foreground other name ran meanwhile" [expr {[aip_read_result] eq "OK: rs_a1 count=60"}]
rs_check "background finished its count" [expr {[rs_state items rs_b1] - $b0 == 50 && [rs_state active rs_b1] == 0}]
rs_b1 count=1
rs_check "BUSY released after completion" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: rs_b1 count=1"}]

puts "BIND_SEQ_STAGE fork"
set a0 [rs_state items rs_a1]
set b0 [rs_state items rs_b1]
set start [rs_now]
fork rs_a1 count=10, rs_b1 count=10 join
set r [aip_read_result]
set elapsed [expr {[rs_now] - $start}]
rs_check "fork different sequencers ok" [expr {[aip_check_status] == 0 && $r eq "fork: 2 cmd(s) ok"}]
rs_check "fork ran concurrently ($elapsed ns)" [expr {$elapsed >= 100 && $elapsed < 200}]
rs_check "fork counts" [expr {[rs_state items rs_a1] - $a0 == 10 && [rs_state items rs_b1] - $b0 == 10}]
set a0 [rs_state items rs_a1]
set a2 [rs_state items rs_a2]
set qa [rs_state sqr_items a]
fork rs_a1 count=4, rs_a2 count=4 join
rs_check "two registered commands share one sequencer" [expr {[aip_check_status] == 0 &&
    [rs_state items rs_a1] - $a0 == 4 && [rs_state items rs_a2] - $a2 == 4 && [rs_state sqr_items a] - $qa == 8}]
set s0 [rs_state items rs_static]
set p0 [rs_state items rs_p2]
fork rs_static count=2, rs_p2 count=2 join
rs_check "fork mixes aip_cmd_seq and registered command" [expr {[aip_check_status] == 0 &&
    [rs_state items rs_static] - $s0 == 2 && [rs_state items rs_p2] - $p0 == 2}]
set a0 [rs_state items rs_a1]
fork rs_a1 count=3, rs_a1 count=3 join
set r [aip_read_result]
rs_check "same name twice in one fork: one BUSY" [expr {[aip_check_status] != 0 && [string match "*BUSY*" $r] &&
                                                       [rs_state items rs_a1] - $a0 == 3}]

puts "BIND_SEQ_STAGE kill_seq"
rs_b1 count=100000 wait=0
rs_check "long background STARTED" [expr {[aip_read_result] eq "STARTED: rs_b1"}]
run 200ns
kill_seq name=rs_b1
rs_check "kill_seq finds registered command" [expr {[string match "killed=1*" [aip_read_result]]}]
run 20ns
rs_check "killed seq no longer active" [expr {[rs_state active rs_b1] == 0}]
set b0 [rs_state items rs_b1]
run 200ns
rs_check "killed seq issues no more items" [expr {[rs_state items rs_b1] == $b0}]
rs_b1 count=2
rs_check "killed command reusable" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: rs_b1 count=2"}]

puts "BIND_SEQ_STAGE watchdog"
set_param path=rs.hang.stall_ns value=20000
rs_hang count=1
set r [aip_read_result]
rs_check "watchdog cancels stalled registered command" [expr {[aip_check_status] != 0 && [string match "*watchdog*" $r]}]
rs_check "watchdog released the sequence" [expr {[rs_state active rs_hang] == 0}]
run 20000ns
rs_check "cancelled seq never issued its item" [expr {[rs_state items rs_hang] == 0}]
set_param path=rs.hang.stall_ns value=0
rs_hang count=2
rs_check "command reusable after watchdog" [expr {[aip_read_result] eq "OK: rs_hang count=2" && [rs_state items rs_hang] == 2}]

puts "BIND_SEQ_STAGE errors"
rs_reject "no arguments" "ERROR: aip_bind_seq: missing cmd= type= sqr=*"
rs_reject "missing cmd" "ERROR: aip_bind_seq: missing cmd=*" type=rs_plain_seq sqr=$A
rs_reject "missing type" "ERROR: aip_bind_seq: missing type=*" cmd=rs_x sqr=$A
rs_reject "missing sqr" "ERROR: aip_bind_seq: missing sqr=*" cmd=rs_x type=rs_plain_seq
rs_reject "registered name" "*command 'rs_a1' already exists*" cmd=rs_a1 type=rs_path_seq sqr=$B
rs_reject "aip_cmd_seq name" "*command 'rs_static' already exists*" cmd=rs_static type=rs_plain_seq sqr=$B
rs_reject "builtin name" "*command 'kill_seq' already exists*" cmd=kill_seq type=rs_plain_seq sqr=$B
rs_reject "undeclared type" "*sequence type 'rs_item' is not declared*rs_path_seq, rs_plain_seq*" cmd=rs_x type=rs_item sqr=$A
rs_reject "sqr not found" "*sqr 'uvm_test_top.env.c.sqr' is neither a registered sequencer name (registered: rs_a, rs_b) nor a UVM full name*" cmd=rs_x type=rs_plain_seq sqr=uvm_test_top.env.c.sqr
rs_reject "relative sqr path" "*sqr 'env.a.sqr' is neither*" cmd=rs_x type=rs_plain_seq sqr=env.a.sqr
rs_reject "wildcard sqr path" "*is neither*" cmd=rs_x type=rs_plain_seq {sqr=uvm_test_top.env.*.sqr}
rs_reject "driver is not a sequencer" "*is a rs_driver, not a uvm_sequencer*" cmd=rs_x type=rs_plain_seq sqr=uvm_test_top.env.a.drv
rs_reject "env is not a sequencer" "*is a rs_env, not a uvm_sequencer*" cmd=rs_x type=rs_plain_seq sqr=uvm_test_top.env
rs_reject "path= on type without param_path" "*declared without param_path support*" cmd=rs_x type=rs_plain_seq sqr=$A path=rs.x
rs_reject "unknown key" "*unknown key 'seq='*" cmd=rs_x type=rs_plain_seq sqr=$A seq=1
rs_reject "duplicate key" "*duplicate key 'cmd='*" cmd=rs_x cmd=rs_y type=rs_plain_seq sqr=$A
rs_reject "empty value" "*empty value for 'path='*" cmd=rs_x type=rs_path_seq sqr=$A path=
rs_reject "bare word" "*malformed argument 'extra'*" cmd=rs_x type=rs_plain_seq sqr=$A extra
rs_reject "invalid name" "*invalid command name '9abc'*" cmd=9abc type=rs_plain_seq sqr=$A
rs_reject "wait=0 on registration" "*wait=0 is not supported*" cmd=rs_x type=rs_plain_seq sqr=$A wait=0
aip_send_cmd "aip_bind_seq cmd=fork type=rs_plain_seq sqr=$A"
rs_check "fork is reserved in SV" [expr {[aip_check_status] == 1 && [string match "*invalid command name 'fork'*" [aip_read_result]]}]
rs_check "Tcl command name refused before SV" [expr {[catch {aip_bind_seq cmd=run type=rs_plain_seq sqr=$A} msg] &&
                                                      [string match "*already a Tcl command*" $msg]}]
fork
rs_check "registration inside fork block refused" [expr {[catch {aip_bind_seq cmd=rs_x type=rs_plain_seq sqr=$A} msg] &&
                                                         [string match "*inside a fork block*" $msg]}]
rs_a1 count=1
join
rs_check "fork block still runs after refusal" [expr {[aip_check_status] == 0}]
rs_check "rejections created no command" [expr {[rs_state exists rs_x] == 0 && [rs_state exists rs_y] == 0 &&
                                                [rs_state exists 9abc] == 0}]
set qa [rs_state sqr_items a]
set qb [rs_state sqr_items b]
rs_a1 count=1
rs_check "rejected duplicate did not override binding" [expr {[rs_state sqr_items a] - $qa == 1 && [rs_state sqr_items b] == $qb}]

puts "BIND_SEQ_STAGE dispatch_refresh"
aip_send_cmd "aip_bind_seq cmd=rs_raw type=rs_plain_seq sqr=$B"
rs_check "registration bypassing the Tcl proc" [expr {[aip_check_status] == 0 && ![dict exists $::_aip_known_cmds rs_raw]}]
rs_raw count=2
rs_check "unknown resyncs the table and dispatches" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: rs_raw count=2" &&
                                                          [dict exists $::_aip_known_cmds rs_raw]}]
rs_check "unregistered name still fails fast" [expr {[catch {rs_never_registered count=1} msg] &&
                                                     [string match "invalid command name*" $msg]}]
aip_send_cmd "help rs_p1"
rs_check "help knows registered command" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK"}]
aip_send_cmd "help"
rs_check "help lists all commands" [expr {[aip_check_status] == 0}]

puts "BIND_SEQ_STAGE seq_results"
set_param path=rs.rj.reject value=1
set_param path=rs.rj.len value=-5
aip_bind_seq cmd=rs_rj type=rs_path_seq sqr=$A path=rs.rj
rs_rj count=3
rs_check "seq rejection reaches aip_check_status" [expr {[aip_check_status] == 1 && [aip_read_result] eq "ERROR: rs_rj rejected len=-5"}]
rs_check "rejected seq issued nothing" [expr {[rs_state items rs_rj] == 0}]
set start [rs_now]
rs_rj time=1us
rs_check "rejection in time mode returns at once" [expr {[aip_check_status] == 1 && [aip_read_result] eq "ERROR: rs_rj rejected len=-5" &&
                                                        [rs_now] - $start < 10 && [rs_state kills rs_rj] == 0}]
set_param path=rs.ok.custom value=1
aip_bind_seq cmd=rs_ok type=rs_path_seq sqr=$B path=rs.ok
rs_ok count=2
rs_check "seq-set success text kept" [expr {[aip_check_status] == 0 && [aip_read_result] eq "DONE: rs_ok items=2"}]
set_param path=rs.so.status_only value=5
aip_bind_seq cmd=rs_so type=rs_path_seq sqr=$B path=rs.so
rs_so count=1
rs_check "status-only failure gets ERROR text" [expr {[aip_check_status] == 5 && [aip_read_result] eq "ERROR: rs_so count=1 status=5"}]
set_param path=rs.p1.child value=1
rs_p1 count=1 tag=hello
rs_check "seq reads its launching command and args" [expr {[aip_check_status] == 0 && [rs_state cmd rs_p1] eq "rs_p1" &&
                                                         [rs_state args rs_p1] eq "count=1 tag=hello"}]
rs_check "child seq finds the command through its parent" [expr {[rs_state child_cmd rs_p1] eq "rs_p1"}]
set_param path=rs.p1.child value=0
rs_p1 count=1 tag=background wait=0
rs_a1 count=5
rs_check "background seq sees args without wait" [expr {[rs_state args rs_p1] eq "count=1 tag=background"}]

puts "BIND_SEQ_STAGE strict_count"
set n0 [rs_state items rs_a1]
foreach {bad why} {two {not an unsigned integer literal} -1 {negative value*} 0x80000000 {exceeds the maximum 0x7fffffff}
                   2147483648 {exceeds the maximum 0x7fffffff} 1.5 {not an unsigned integer literal}} {
    rs_a1 count=$bad
    set r [aip_read_result]
    puts "  count=$bad -> $r"
    rs_check "count=$bad rejected" [expr {[aip_check_status] == 1 && [string match "ERROR: rs_a1: count=$bad: $why" $r]}]
}
rs_check "rejected counts started nothing" [expr {[rs_state items rs_a1] == $n0}]
rs_a1 count=0
rs_check "count=0 accepted" [expr {[aip_read_result] eq "OK: rs_a1 count=0" && [rs_state items rs_a1] == $n0}]
rs_a1 count=0x3
rs_check "hex count accepted" [expr {[aip_read_result] eq "OK: rs_a1 count=3" && [rs_state items rs_a1] == $n0 + 3}]
rs_static count=two
rs_check "aip_cmd_seq count is strict" [expr {[aip_check_status] == 1 && [string match "ERROR: rs_static: count=two: *" [aip_read_result]]}]
rs_cseq count=-2
rs_check "aip_cmd_cseq count is strict" [expr {[aip_check_status] == 1 && [string match "ERROR: rs_cseq: count=-2: negative*" [aip_read_result]]}]

puts "BIND_SEQ_STAGE time_limit"
set_param path=rs.fin.finish_ns value=100
aip_bind_seq cmd=rs_fin type=rs_path_seq sqr=$A path=rs.fin
set start [rs_now]
rs_fin time=1us
set r [aip_read_result]
set elapsed [expr {[rs_now] - $start}]
rs_check "seq ending early returns before the limit ($elapsed ns)" [expr {$r eq "OK: rs_fin time=1us" &&
                                                                        $elapsed >= 100 && $elapsed < 200}]
rs_check "finished seq not killed" [expr {[rs_state kills rs_fin] == 0}]
aip_bind_seq cmd=rs_tl type=rs_path_seq sqr=$A path=rs.tl
set start [rs_now]
rs_tl time=200ns
set r [aip_read_result]
set elapsed [expr {[rs_now] - $start}]
rs_check "running seq killed at the limit ($elapsed ns)" [expr {$r eq "OK: rs_tl time=200ns" &&
                                                              $elapsed >= 200 && $elapsed < 300 && [rs_state kills rs_tl] == 1}]

puts "BIND_SEQ_STAGE sqr_registry"
aip_sqr_list
rs_check "aip_sqr_list" [expr {[aip_check_status] == 0 && [aip_read_result] eq "OK: 2 sequencer(s)"}]
set r [aip_bind_seq cmd=rs_n1 type=rs_plain_seq sqr=rs_a]
rs_check "sqr= takes a registry name" [expr {[aip_check_status] == 0 && $r eq "OK: rs_n1 type=rs_plain_seq sqr=$A"}]
set qa [rs_state sqr_items a]
rs_n1 count=2
rs_check "registry-bound command runs on that sequencer" [expr {[aip_read_result] eq "OK: rs_n1 count=2" && [rs_state sqr_items a] - $qa == 2}]
rs_reject "unknown registry name" "*sqr 'rs_zz' is neither a registered sequencer name (registered: rs_a, rs_b)*" cmd=rs_n2 type=rs_plain_seq sqr=rs_zz
set qb [rs_state sqr_items b]
rs_reg_static count=3
rs_check "aip_cmd_seq resolves a registry name at launch" [expr {[aip_read_result] eq "OK: rs_reg_static count=3" && [rs_state sqr_items b] - $qb == 3}]
set qa [rs_state sqr_items a]
rs_cseq count=2
rs_check "aip_cmd_cseq resolves a registry name at launch" [expr {[aip_read_result] eq "OK: rs_cseq count=2" && [rs_state sqr_items a] - $qa == 2}]
rs_state arm 1
rs_reg_bad count=1
set r [aip_read_result]
rs_check "unknown name at launch fails the command" [expr {[aip_check_status] == 1 && [string match "ERROR: rs_reg_bad: sequencer is null*" $r]}]
rs_check "unknown name error lists registered names" [expr {[rs_state armed] == 0 &&
    [string match "*unknown sequencer name 'rs_none'; registered: rs_a, rs_b*" [rs_state caught_msg]]}]

puts "BIND_SEQ_STAGE unregister"
rs_b1 count=100 wait=0
set r [aip_unbind_seq cmd=rs_b1]
rs_check "running command cannot be removed" [expr {[aip_check_status] == 1 && [string match "*BUSY*still running*" $r]}]
run 1200ns
rs_check "background done before removal" [expr {[rs_state active rs_b1] == 0}]
set r [aip_unbind_seq cmd=rs_b1]
rs_check "idle registered command removed" [expr {[aip_check_status] == 0 && $r eq "OK: unregistered rs_b1"}]
rs_check "removed from SV registry and Tcl cache" [expr {[rs_state exists rs_b1] == 0 && ![dict exists $::_aip_known_cmds rs_b1]}]
rs_check "removed name is no longer a command" [expr {[catch {rs_b1 count=1} msg] && [string match "invalid command name*" $msg]}]
set r [aip_unbind_seq cmd=kill_seq]
rs_check "builtin cannot be removed" [expr {[aip_check_status] == 1 && [string match "*not created by aip_bind_seq*" $r]}]
set r [aip_unbind_seq cmd=rs_static]
rs_check "aip_cmd_seq command cannot be removed" [expr {[aip_check_status] == 1 && [string match "*not created by aip_bind_seq*" $r]}]
set r [aip_unbind_seq cmd=rs_gone]
rs_check "unknown name cannot be removed" [expr {[aip_check_status] == 1 && [string match "*does not exist*" $r]}]
set r [aip_unbind_seq]
rs_check "aip_unbind_seq needs cmd=" [expr {[aip_check_status] == 1 && [string match "*missing cmd=*" $r]}]
set r [aip_bind_seq cmd=rs_b1 type=rs_path_seq sqr=$B path=rs.p2]
rs_check "freed name can be registered again" [expr {[aip_check_status] == 0}]
rs_b1 count=1
rs_check "re-registered binding is the new one" [expr {[aip_read_result] eq "OK: rs_b1 count=1" && [rs_state len rs_b1] == 88}]

puts "BIND_SEQ_TCL_PASS checks=$::rs_checks"
end_test
run
