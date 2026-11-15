# 后台快照测试的共用断言 helper（不启动任何 task/sequence）；restore 会清除 Tcl proc，恢复脚本须重新 source。
set ::ckb_checks 0

proc ckb_check {label condition} {
    if {!$condition} { error "CKB_CHECK_FAIL: $label" }
    incr ::ckb_checks
}

# 同时检查查询本身成功，避免把错误文本当作观测值。
proc ckb_get {name field} {
    aip_send_cmd "ckb_state name=$name field=$field"
    if {[aip_check_status] != 0} { error "CKB_QUERY_FAIL: [aip_read_result]" }
    return [aip_read_result]
}

# 在快照点/恢复点验证三条命令确实在途；BUSY 请求不能改写原参数和次数。
proc ckb_inflight {} {
    foreach name {ckb_local ckb_legacy ckb_seq} tag {local_original legacy_original seq_original} {
        ckb_check "$name entered once" [expr {[ckb_get $name started] == 1}]
        ckb_check "$name unfinished" [expr {[ckb_get $name finished] == 0}]
        ckb_check "$name busy" [expr {[ckb_get $name busy] == 1}]
        aip_send_cmd "$name text=must_not_replace wait=0"
        ckb_check "$name rejects concurrent call" \
            [expr {[aip_check_status] != 0 && [string match *BUSY* [aip_read_result]]}]
        ckb_check "$name arguments retained" [expr {[ckb_get $name args] eq "text=$tag"}]
    }
    ckb_peer text=must_not_run
    ckb_check "legacy slot remains owned" \
        [expr {[aip_check_status] != 0 && [string match *BUSY* [aip_read_result]]}]
    ckb_check "legacy peer did not enter" [expr {[ckb_get ckb_peer started] == 0}]
    ckb_check "sequence remains registered" [expr {[ckb_get none active_seq] == 1}]
    ckb_check "driver holds one pending item at snapshot" [expr {[ckb_get none driver_started] == 1}]
    ckb_check "pending item not completed before snapshot" [expr {[ckb_get none driver] == 0}]
    ckb_front text=inflight
    ckb_check "foreground result independent of old slot" \
        [expr {[aip_check_status] == 0 && [aip_read_result] eq "FRONT:inflight"}]
}

# 输出无路径/进程号的确定性观察，runner 比较连续执行与恢复执行的业务结果。
proc ckb_compare {stage} {
    foreach name {ckb_local ckb_legacy ckb_seq} {
        set fields {}
        foreach field {started finished enter leave busy args status result} {
            lappend fields "$field=[ckb_get $name $field]"
        }
        puts "CKB_COMPARE $stage $name [_tcl_join $fields |]"
    }
    puts "CKB_COMPARE $stage totals now=[ckb_get none now] driver_started=[ckb_get none driver_started] driver=[ckb_get none driver] active_seq=[ckb_get none active_seq]"
}

# 从同一快照时刻继续，检查首次完成结果，再逐条默认同步复用并检查真实耗时。
proc ckb_complete {} {
    run 1500ns
    foreach name {ckb_local ckb_legacy ckb_seq} tag {local_original legacy_original seq_original} \
            code {7 17 9} prefix {LOCAL_DONE LEGACY_DONE SEQ_DONE} {
        ckb_check "$name completed once" [expr {[ckb_get $name finished] == 1 && [ckb_get $name started] == 1}]
        ckb_check "$name released ownership" [expr {[ckb_get $name busy] == 0}]
        ckb_check "$name kept original arguments" [expr {[ckb_get $name leave] eq "text=$tag"}]
        ckb_check "$name final status retained" [expr {[ckb_get $name status] == $code}]
        ckb_check "$name final result retained" [expr {[ckb_get $name result] eq "${prefix}:$tag"}]
    }
    ckb_check "first real item executed once" [expr {[ckb_get none driver] == 1}]
    ckb_compare completed

    foreach name {ckb_local ckb_legacy ckb_seq} code {7 17 9} \
            prefix {LOCAL_DONE LEGACY_DONE SEQ_DONE} duration {800 1200 1000} {
        set before [ckb_get none now]
        aip_send_cmd "$name text=reused"
        set status [aip_check_status]
        set result [aip_read_result]
        ckb_check "$name defaults to synchronous completion" \
            [expr {[ckb_get none now] - $before == $duration}]
        ckb_check "$name synchronous result" [expr {$status == $code && $result eq "${prefix}:reused"}]
        ckb_check "$name reused exactly once" [expr {[ckb_get $name started] == 2 && [ckb_get $name finished] == 2}]
    }
    ckb_peer text=released
    ckb_check "legacy slot released after completion" \
        [expr {[aip_check_status] == 0 && [aip_read_result] eq "PEER:released"}]
    ckb_compare reused
}
