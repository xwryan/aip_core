# 逐命令 wait 的 UCLI 黑盒验证（命令由 test_cmd_wait.sv 注册）；任何失败都阻止 CMD_WAIT_TCL_PASS 标记。
source ../../src/tcl/aip_cmd.tcl
set ::aip_ack_timeout_ns 5000
set ::cw_checks 0

proc cw_check {name condition} {
    if {!$condition} { error "CMD_WAIT_FAIL $name" }
    incr ::cw_checks
    puts "CMD_WAIT_CHECK_PASS $name"
}

# 查询独立业务观察记录，不依赖调度器私有变量。
proc cw_state {name field} {
    aip_send_cmd "cw_state name=$name field=$field"
    if {[aip_check_status] != 0} { error "CMD_WAIT_FAIL observation $name $field" }
    return [aip_read_result]
}

# 用 SV 时间检查是否真正等待，不用 Tcl 的 wall clock 作仿真时序判断。
proc cw_now {} { return [cw_state none now] }

# 后台 ACK 只表示已启动，不能伪装成业务 DONE；必须早于自身工作完成。
proc cw_started {name} {
    cw_check "$name accepted" [expr {[aip_check_status] == 0}]
    cw_check "$name STARTED" [expr {[aip_read_result] eq "STARTED: $name"}]
}

puts "CMD_WAIT_STAGE task_async"
set start [cw_now]
cw_task ns=10000 tag=original code=7 wait=0
cw_started cw_task
cw_check "task immediate ACK" [expr {[cw_now] - $start < 1000}]
cw_check "task started but incomplete" [expr {[cw_state cw_task started] == 1 && [cw_state cw_task finished] == 0}]
cw_check "wait stripped" [expr {[cw_state cw_task enter] eq "ns=10000 tag=original code=7"}]
cw_task ns=0 tag=overwrite wait=0
cw_check "same command BUSY" [expr {[aip_check_status] != 0 && [string match -nocase "*BUSY*" [aip_read_result]]}]
cw_check "busy did not start new task" [expr {[cw_state cw_task started] == 1}]
# 此段没有任何 activity tick，超过 2000ns watchdog 和启动时的 5000ns
# ACK 窗口，不能靠下条前台命令的心跳意外保护一个仍被监控的后台 worker。
run 6000ns
cw_check "detached task still pending without heartbeat" [expr {[cw_state cw_task finished] == 0}]
set ::aip_ack_timeout_ns 30000
set start [cw_now]
cw_front ns=12000 tick=1 tag=front
set front_status [aip_check_status]
set front_result [aip_read_result]
cw_check "default next command waited" [expr {[cw_now] - $start >= 12000}]
cw_check "foreground status isolated" [expr {$front_status == 0 && $front_result eq "DONE:cw_front:front"}]
cw_check "background outlived watchdog and ACK window" [expr {[cw_state cw_task finished] == 1}]
cw_check "busy preserved in-flight args" [expr {[cw_state cw_task leave] eq "ns=10000 tag=original code=7"}]

puts "CMD_WAIT_STAGE result_isolation"
cw_task ns=2000 tag=late_failure code=9 wait=0
cw_started cw_task
set start [cw_now]
cw_front ns=4000 tick=1 tag=expected
set front_status [aip_check_status]
set front_result [aip_read_result]
cw_check "background failure cannot acknowledge foreground" [expr {[cw_now] - $start >= 4000}]
cw_check "background failure cannot overwrite foreground" [expr {$front_status == 0 && $front_result eq "DONE:cw_front:expected"}]
cw_check "background failure really completed" [expr {[cw_state cw_task finished] == 2}]
set start [cw_now]
cw_task ns=500 tag=reused wait=1
set result [aip_read_result]
cw_check "normal completion releases BUSY" [expr {$result eq "DONE:cw_task:reused" && [cw_now] - $start >= 500}]
set start [cw_now]
cw_task ns=500 tag=default_again
set result [aip_read_result]
cw_check "wait0 does not persist on same alias" [expr {$result eq "DONE:cw_task:default_again" && [cw_now] - $start >= 500}]

puts "CMD_WAIT_STAGE typed_and_seq"
cw_typed ns=6000 tag=typed wait=0
cw_started cw_typed
cw_front ns=7000 tick=1 tag=typed_drain
cw_check "typed task completed" [expr {[cw_state cw_typed finished] == 1}]
cw_check "typed task args retained" [expr {[cw_state cw_typed leave] eq "ns=6000 tag=typed"}]
set start [cw_now]
cw_seq ns=10000 tag=seq_async code=13 wait=0
cw_started cw_seq
cw_check "real sequence immediate ACK" [expr {[cw_now] - $start < 1000}]
cw_seq ns=0 tag=seq_bad wait=1
cw_check "sequence same-name BUSY" [expr {[aip_check_status] != 0 && [string match -nocase "*BUSY*" [aip_read_result]]}]
set start [cw_now]
cw_front ns=12000 tick=1 tag=seq_front
set front_status [aip_check_status]
set front_result [aip_read_result]
cw_check "seq completion cannot acknowledge next command" [expr {[cw_now] - $start >= 12000}]
cw_check "seq failure isolated" [expr {$front_status == 0 && $front_result eq "DONE:cw_front:seq_front"}]
cw_check "driver saw original sequence parameters" [expr {[cw_state none driver_count] == 1 && [cw_state none driver_tag] eq "seq_async"}]
cw_check "seq args not overwritten by BUSY" [expr {[cw_state cw_seq leave] eq "ns=10000 tag=seq_async code=13"}]
set start [cw_now]
cw_seq ns=400 tag=seq_default
set result [aip_read_result]
cw_check "seq default waits through driver completion" [expr {$result eq "DONE:cw_seq:seq_default" && [cw_now] - $start >= 700}]

puts "CMD_WAIT_STAGE parser"
set before [cw_state cw_task started]
foreach bad {wait= wait=2 wait=-1 wait=true wait=00 wait=0x0 {wait=0 wait=1} {wait=1 wait=1}} {
    aip_send_cmd "cw_task ns=0 tag=invalid $bad"
    cw_check "invalid reserved parameter $bad" [expr {[aip_check_status] != 0 && [string match -nocase "*wait*" [aip_read_result]]}]
}
cw_check "rejected arguments cause no side effect" [expr {[cw_state cw_task started] == $before}]
set literal {ns=0 tag={nested wait=0 {wait=1}}}
aip_send_cmd "cw_task $literal wait=1"
cw_check "brace contents preserved" [expr {[cw_state cw_task enter] eq $literal}]
set literal {ns=0 tag="quoted wait=0 text"}
aip_send_cmd "cw_task $literal wait=1"
cw_check "quoted contents preserved" [expr {[cw_state cw_task enter] eq $literal}]
cw_legacy text=background_compatible wait=0
cw_started cw_legacy
cw_check "legacy background executes original task" [expr {[cw_state cw_legacy started] == 1}]
cw_check "legacy background handle keeps business result" [expr {[cw_state cw_legacy command_status] == 0 && [cw_state cw_legacy command_result] eq "LEGACY:background_compatible"}]
cw_legacy text=compatible wait=1
cw_check "legacy synchronous behavior retained" [expr {[aip_check_status] == 0 && [aip_read_result] eq "LEGACY:compatible"}]
end_test wait=0
cw_check "bridge exit cannot detach" [expr {[aip_check_status] != 0}]
cw_front ns=0 tag=still_running
cw_check "rejected end_test left bridge usable" [expr {[aip_read_result] eq "DONE:cw_front:still_running"}]

puts "CMD_WAIT_STAGE cancellation"
cw_seq ns=20000 tag=cancel_me wait=0
cw_started cw_seq
kill_seq name=cw_seq
cw_check "kill found sequence" [expr {[string match "killed=1*" [aip_read_result]]}]
cw_front ns=10 tag=settle
cw_seq ns=0 tag=after_kill
cw_check "kill releases command for new invocation" [expr {[aip_check_status] == 0 && [aip_read_result] eq "DONE:cw_seq:after_kill"}]

# 前台 watchdog 必须只取消肇事命令；已经 ACK 的 task/sequence 继续存在。
cw_task ns=9000 tag=survive_wd wait=0
cw_started cw_task
cw_seq ns=9000 tag=seq_survive_wd wait=0
cw_started cw_seq
cw_seq_other ns=100000 tag=watchdog_victim
cw_check "foreground seq watchdog returned error" [expr {[aip_check_status] != 0 && [string match -nocase "*watchdog*" [aip_read_result]]}]
cw_seq_other ns=0 tag=after_wd
cw_check "watchdog releases same-name seq" [expr {[aip_check_status] == 0 && [aip_read_result] eq "DONE:cw_seq_other:after_wd"}]
cw_front ns=11000 tick=1 tag=wd_drain
cw_check "older background task survived foreground watchdog" [expr {[cw_state cw_task leave] eq "ns=9000 tag=survive_wd"}]
cw_check "older background sequence survived foreground watchdog" [expr {[cw_state cw_seq leave] eq "ns=9000 tag=seq_survive_wd"}]

cw_typed ns=100000 tag=task_watchdog
cw_check "typed task watchdog returned error" [expr {[aip_check_status] != 0 && [string match -nocase "*watchdog*" [aip_read_result]]}]
cw_typed ns=10 tag=typed_after_wd
cw_check "watchdog releases same-name task" [expr {[aip_check_status] == 0}]
cw_check "typed recovery executed" [expr {[cw_state cw_typed leave] eq "ns=10 tag=typed_after_wd"}]

# 跨过被 kill 的 sequence 原定完成时刻，防止仅清 BUSY 却遗留业务进程。
cw_front ns=15000 tick=1 tag=final_drain
cw_check "killed sequence never issued an extra item" [expr {[cw_state none driver_count] == 5}]
cw_check "only normally completed sequences counted" [expr {[cw_state cw_seq finished] == 4 && [cw_state cw_seq_other finished] == 1}]

puts "CMD_WAIT_STAGE process_scope"
set_cmd_watchdog ns=0
cw_task ns=10000 tag=scope_background wait=0
cw_started cw_task
set start [cw_now]
cw_cancel
set scope_status [aip_check_status]
set scope_result [aip_read_result]
set elapsed [expr {[cw_now] - $start}]
cw_check "user disable fork completes its own race" [expr {$scope_status == 0 && $scope_result eq "DONE:cw_cancel" && $elapsed >= 100 && $elapsed < 1000}]
set start [cw_now]
cw_wait_children
set scope_status [aip_check_status]
set scope_result [aip_read_result]
set elapsed [expr {[cw_now] - $start}]
cw_check "user wait fork ignores historical background" [expr {$scope_status == 0 && $scope_result eq "DONE:cw_wait_children" && $elapsed >= 200 && $elapsed < 1000}]
cw_front ns=11000 tag=scope_drain
cw_check "user disable fork did not kill historical background" [expr {[cw_state cw_task leave] eq "ns=10000 tag=scope_background"}]

puts "CMD_WAIT_STAGE fork_results"
set start [cw_now]
aip_send_cmd {fork cw_task ns=200 tag=fork_bad code=31, cw_front ns=600 tag=fork_ok join}
set fork_status [aip_check_status]
set fork_result [aip_read_result]
cw_check "fork join waits every child" [expr {[cw_now] - $start >= 600}]
cw_check "fork join aggregates failure status" [expr {$fork_status == 31}]
cw_check "fork join preserves failure message" [expr {[string match "*status=31,msg=DONE:cw_task:fork_bad*" $fork_result]}]

set start [cw_now]
aip_send_cmd {fork cw_task ns=2000 tag=fork_late_fail code=32 join_none}
cw_check "fork join_none returns startup acknowledgement" [expr {[aip_check_status] == 0 && [aip_read_result] eq "fork: 1 cmd(s) started"}]
cw_check "fork join_none does not wait for failure" [expr {[cw_now] - $start < 1000}]
set start [cw_now]
cw_front ns=4000 tag=after_join_none
set fork_status [aip_check_status]
set fork_result [aip_read_result]
cw_check "late fork child cannot acknowledge next command" [expr {[cw_now] - $start >= 4000}]
cw_check "late fork failure cannot overwrite next command" [expr {$fork_status == 0 && $fork_result eq "DONE:cw_front:after_join_none"}]
cw_check "late fork failure really executed" [expr {[cw_state cw_task command_status] == 32 && [cw_state cw_task command_result] eq "DONE:cw_task:fork_late_fail"}]

# join_any 取消本批未完成 sibling；先前已启动的另一个命令必须继续运行。
set canceled_before [cw_state cw_typed finished]
cw_task ns=8000 tag=survive_join_any wait=0
cw_started cw_task
set start [cw_now]
aip_send_cmd {fork cw_front ns=200 tag=winner, cw_typed ns=10000 tag=cancel_sibling join_any disable_remaining=1}
set fork_status [aip_check_status]
set fork_result [aip_read_result]
set elapsed [expr {[cw_now] - $start}]
cw_check "fork join_any returns winning child only" [expr {$fork_status == 0 && $fork_result eq "fork: 1 cmd(s) ok" && $elapsed >= 200 && $elapsed < 1000}]
cw_front ns=11000 tag=join_any_drain
cw_check "join_any cancellation leaves history alive" [expr {[cw_state cw_task leave] eq "ns=8000 tag=survive_join_any"}]
cw_check "join_any killed only unfinished sibling" [expr {[cw_state cw_typed finished] == $canceled_before}]
cw_typed ns=10 tag=sibling_reused
cw_check "join_any canceled alias can restart" [expr {[aip_check_status] == 0 && [cw_state cw_typed finished] == $canceled_before + 1}]

# 零耗时拒绝可能在另一个子命令尚未发布 worker 句柄时获胜；取消不能留下
# 永久 BUSY，也不能在重入后才冒出旧 worker 写回结果。
set canceled_before [cw_state cw_typed finished]
aip_send_cmd {fork cw_task wait=2, cw_typed ns=10000 tag=cancel_before_worker join_any disable_remaining=1}
cw_check "immediate fork rejection reported" [expr {[aip_check_status] != 0 && [string match -nocase "*wait*" [aip_read_result]]}]
cw_typed ns=10 tag=early_cancel_reused
cw_check "early cancellation releases child alias" [expr {[aip_check_status] == 0}]
cw_front ns=11000 tag=early_cancel_drain
cw_check "early cancellation leaves no stale worker" [expr {[cw_state cw_typed finished] == $canceled_before + 1 && [cw_state cw_typed leave] eq "ns=10 tag=early_cancel_reused"}]

# 父 fork 只能消费 join 控制词；wait=0 属于子命令，不能被父级剥离或忽略。
set child_before [cw_state cw_task finished]
set start [cw_now]
aip_send_cmd {fork cw_task ns=7000 tag=child_detached wait=0, cw_front ns=300 tag=child_sync join}
set fork_status [aip_check_status]
set fork_result [aip_read_result]
set elapsed [expr {[cw_now] - $start}]
cw_check "fork child wait0 retained" [expr {$fork_status == 0 && $fork_result eq "fork: 2 cmd(s) ok" && $elapsed >= 300 && $elapsed < 1000}]
cw_check "detached child still running after parent join" [expr {[cw_state cw_task finished] == $child_before}]
cw_check "child sees business args without wait" [expr {[cw_state cw_task enter] eq "ns=7000 tag=child_detached"}]
cw_front ns=8000 tag=child_drain
cw_check "detached child completes after parent" [expr {[cw_state cw_task finished] == $child_before + 1}]

puts "CMD_WAIT_STAGE legacy_slot"
aip_send_cmd {fork cw_legacy_late text=retained join_none}
cw_check "legacy fork started" [expr {[aip_check_status] == 0 && [aip_read_result] eq "fork: 1 cmd(s) started"}]
cw_front ns=2000 tag=legacy_interleaved_ack
cw_check "interleaved foreground ACK remains visible" [expr {[aip_check_status] == 0 && [aip_read_result] eq "DONE:cw_front:legacy_interleaved_ack"}]
cw_legacy text=must_not_run
cw_check "in-flight legacy calls are mutually exclusive" [expr {[aip_check_status] != 0 && [string match -nocase "*BUSY*" [aip_read_result]]}]
cw_front ns=5000 tag=legacy_drain
cw_check "legacy delayed invocation completed" [expr {[cw_state cw_legacy_late finished] == 1}]
cw_check "foreground ACK did not clobber legacy status" [expr {[cw_state cw_legacy_late command_status] == 23}]
cw_check "foreground ACK did not clobber legacy result" [expr {[cw_state cw_legacy_late command_result] eq "LEGACY_SAVED:retained"}]
cw_legacy text=slot_released
cw_check "legacy slot released after completion" [expr {[aip_check_status] == 0 && [aip_read_result] eq "LEGACY:slot_released"}]
cw_check "additional fork tests did not issue sequence items" [expr {[cw_state none driver_count] == 5}]

puts "CMD_WAIT_TCL_PASS checks=$::cw_checks"
end_test
run
