# 独立命令注入入口：原 Tcl 栈暂停时插入 task/sequence，不写正常单槽 bridge。SV 持有不可变请求、FIFO 与结果，
# Tcl 只缓存 ticket/slot（release 后失效）；无隐式 kill/自动重放，timeout 或中断后用 ticket 查状态。
# 同绑定 FIFO、不同绑定并行；仿真推进会同时推进原任务和 DUT。

if {![info exists ::_aip_inject_serial]} { set ::_aip_inject_serial 0 }
if {![info exists ::_aip_inject_busy]} { set ::_aip_inject_busy 0 }
if {![info exists ::_aip_inject_slots]} { set ::_aip_inject_slots [dict create] }
if {![info exists ::_aip_inject_last_result]} { set ::_aip_inject_last_result {} }
if {![info exists ::aip_inject_poll_ns]} { set ::aip_inject_poll_ns 10 }

# 统一错误码便于脚本 catch；所有验证在 force/推进之前完成。
proc _aip_inject_error {kind message} {
    return -code error -errorcode [list AIP INJECT $kind] "AIP_INJECT_${kind}: $message"
}

# 懒检测协议，旧 SV/no-debug 加载仍可使用原入口；真正注入才要求重编 SV。
proc _aip_inject_available {} {
    if {[catch {get aip_core_pkg::__inject_protocol_version} raw]} { return 0 }
    return [expr {[_aip_control_scalar $raw] == 1}]
}

# 仅空闲交互或确认的 retained pause 可发送，stop 回调等活动栈不可重入。
# transport 持有共享请求槽期间再次进入必须失败，不取消已受理的 SV job。
proc _aip_inject_allowed {} {
    if {$::_aip_inject_busy} { _aip_inject_error BUSY "another injection handshake is active" }
    if {![_aip_control_is_paused_context]} { _aip_control_assert_idle "inject a command" }
    if {![_aip_inject_available]} {
        _aip_inject_error UNAVAILABLE "recompile the simulation with the matching AIP injection bridge and debug access"
    }
}

# SV 接收 32 位整数 ns，拒绝静默截断/溢出；0 只关闭 job 期限（Tcl 等待仍可另设期限）。
proc _aip_inject_timeout_ns {options default_ns} {
    set value "${default_ns}ns"
    if {[llength $options] > 1} { _aip_inject_error ARGUMENT "expected at most timeout=<duration>" }
    if {[llength $options] == 1 && ![regexp {^timeout=(.+)$} [lindex $options 0] -> value]} {
        _aip_inject_error ARGUMENT "expected timeout=<duration>"
    }
    set fs [_aip_control_time_fs $value 1000000]
    if {$fs % 1000000 != 0 || $fs / 1000000 > 4294967295} {
        _aip_inject_error ARGUMENT "timeout must be an integer ns in 0..4294967295"
    }
    return [expr {$fs / 1000000}]
}

# 原pause的推进入口不改normal bridge owner；空闲时使用普通helper控制层。
# 不用裸 _vcs_run，避免原请求ACK到达后trigger仍有效而重复派发。
proc _aip_inject_step {duration} {
    if {[_aip_control_is_paused_context]} {
        return [_aip_debug_advance $duration]
    }
    return [_aip_advance helper $duration]
}

# 读取有界字节结果；SV固定ASCII协议，未知/越界值不能当成空成功结果。
proc _aip_inject_text {prefix length {offset 0}} {
    if {$length < 0 || $length > 1024} { _aip_inject_error PROTOCOL "invalid result length $length" }
    set result ""
    for {set i 0} {$i < $length} {incr i} {
        set value [_aip_control_scalar [get [format {%s[%d]} $prefix [expr {$offset+$i}]]]]
        if {$value > 127} { _aip_inject_error PROTOCOL "non-ASCII result byte $value" }
        append result [format %c $value]
    }
    return $result
}

# 独立请求槽由本次调用独占；ACK 只表示接收/取消/回收，不表示业务完成。握手被断点打断时 finally 清 trigger，
# 已受理 ticket 仍可经 aip_job list 找回，绝不为错误恢复而重发可能已执行的命令。
proc _aip_inject_request {operation command ticket timeout_ns} {
    _aip_inject_allowed
    set length [string length $command]
    if {$length > 1024 || ($length > 0 && ![string is ascii -strict $command]) || [string first "\x00" $command] >= 0} {
        _aip_inject_error ARGUMENT "command must contain at most 1024 non-NUL ASCII characters"
    }
    set ack [_aip_control_scalar [get aip_core_pkg::__inject_ack_id]]
    set id [expr {max($ack, $::_aip_inject_serial)+1}]
    if {$id > 4294967295} { _aip_inject_error CAPACITY "request ID space exhausted; restart simulation" }
    set ::_aip_inject_serial $id
    set ::_aip_inject_busy 1
    try {
        force aip_core_pkg::__inject_request_trigger 0
        for {set i 0} {$i < $length} {incr i} {
            scan [string index $command $i] %c byte
            force [format {aip_core_pkg::__inject_request_ascii[%d]} $i] 32'd$byte
        }
        force aip_core_pkg::__inject_request_len 32'd$length
        force aip_core_pkg::__inject_request_op 32'd$operation
        force aip_core_pkg::__inject_request_ticket 64'd$ticket
        force aip_core_pkg::__inject_request_timeout_ns 32'd$timeout_ns
        force aip_core_pkg::__inject_request_id 32'd$id
        force aip_core_pkg::__inject_request_trigger 1
        set deadline [expr {[_aip_control_now_fs]+100000000}]
        while {[_aip_control_scalar [get aip_core_pkg::__inject_ack_id]] != $id} {
            if {[_aip_control_now_fs] >= $deadline} {
                _aip_inject_error HANDSHAKE "receiver did not ACK request $id within 100ns; inspect aip_job list before retrying"
            }
            _aip_inject_step 1ns
        }
        set status [_aip_control_scalar [get aip_core_pkg::__inject_ack_status]]
        set accepted [_aip_control_scalar [get aip_core_pkg::__inject_ack_ticket]]
        set slot [_aip_control_scalar [get aip_core_pkg::__inject_ack_slot]]
        set length [_aip_control_scalar [get aip_core_pkg::__inject_ack_text_len]]
        set message [_aip_inject_text aip_core_pkg::__inject_ack_text_ascii $length]
        if {$status != 0} { _aip_inject_error REJECTED "request $id rejected ($status): $message" }
        if {$operation in {1 4}} {
            set ::aip_last_inject_ticket $accepted
            dict set ::_aip_inject_slots $accepted $slot
        }
        set wait [_aip_control_scalar [get aip_core_pkg::__inject_ack_wait]]
        return [dict create ticket $accepted slot $slot message $message wait $wait]
    } finally {
        # 推进途中命中断点时ACK可能已发布；记录已受理ticket供用户找回，不能
        # 因为当前Tcl握手抛错就声称命令未执行。get失败仍保留原始错误。
        catch {
            if {$operation in {1 4} && [_aip_control_scalar [get aip_core_pkg::__inject_ack_id]] == $id &&
                [_aip_control_scalar [get aip_core_pkg::__inject_ack_status]] == 0} {
                set ::aip_last_inject_ticket [_aip_control_scalar [get aip_core_pkg::__inject_ack_ticket]]
            }
        }
        # 先撤trigger再释放Tcl互斥；不触碰normal cmd/result/free_run。
        catch {force aip_core_pkg::__inject_request_trigger 0}
        catch {force aip_core_pkg::__inject_request_len 32'd0}
        set ::_aip_inject_busy 0
    }
}

# 显式异步受理：返回ticket而非STARTED。相同注册绑定会排队，调用者可以
# 继续输入其他命令；仿真停止时job也不前进。业务串不得自带wait=字段。
proc aip_submit {command args} {
    if {[string trim $command] eq ""} { _aip_inject_error ARGUMENT "empty command" }
    set timeout [_aip_inject_timeout_ns $args $::aip_ack_timeout_ns]
    return [dict get [_aip_inject_request 1 $command 0 $timeout] ticket]
}

# ticket必须是正十进制64位值；slot复用后旧ticket永远不能指向新job。
proc _aip_inject_ticket {ticket} {
    if {![regexp {^[0-9]+$} $ticket]} { _aip_inject_error ARGUMENT "invalid ticket '$ticket'" }
    set value [_aip_control_decimal $ticket]
    if {$value < 1 || $value > 18446744073709551615} { _aip_inject_error ARGUMENT "invalid ticket '$ticket'" }
    return $value
}

# 只读ticket的当前快照；Tcl与仿真不同时执行，故多个get不会读到半次发布。
# terminal含DONE/CANCELLED/TIMED_OUT，RUNNING_TIMEOUT仍占资源，不得release。
proc _aip_inject_status {ticket} {
    set ticket [_aip_inject_ticket $ticket]
    if {![_aip_inject_available]} { _aip_inject_error UNAVAILABLE "injection bridge unavailable" }
    set candidates {}
    if {[dict exists $::_aip_inject_slots $ticket]} { lappend candidates [dict get $::_aip_inject_slots $ticket] }
    for {set i 0} {$i < 32} {incr i} { lappend candidates $i }
    foreach slot $candidates {
        set current [_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_ticket[%d]} $slot]]]
        set state [_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_state[%d]} $slot]]]
        if {$current != $ticket || $state == 0} { continue }
        if {$state > 6} { _aip_inject_error PROTOCOL "invalid state $state" }
        dict set ::_aip_inject_slots $ticket $slot
        set status [_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_status[%d]} $slot]]]
        if {$status > 2147483647} { incr status -4294967296 }
        set length [_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_result_len[%d]} $slot]]]
        set result [_aip_inject_text aip_core_pkg::__inject_result_ascii $length [expr {$slot*1024}]]
        return [dict create ticket $ticket slot $slot state [lindex {FREE QUEUED RUNNING DONE CANCELLED TIMED_OUT RUNNING_TIMEOUT} $state] status $status result $result]
    }
    dict unset ::_aip_inject_slots $ticket
    _aip_inject_error STALE "unknown or released ticket $ticket"
}

# 等待业务完成（或只等开始），只推进仿真而不resume原脚本。等待期限独立
# 于SV job期限；到期返回错误但不kill。出错文本带ticket供后续查询与回收。
proc _aip_inject_wait {ticket until_started options} {
    set timeout [_aip_inject_timeout_ns $options $::aip_ack_timeout_ns]
    if {$timeout == 0} { _aip_inject_error ARGUMENT "wait timeout must be positive" }
    set poll [_aip_control_time_fs "${::aip_inject_poll_ns}ns"]
    if {$poll <= 0} { _aip_inject_error ARGUMENT "aip_inject_poll_ns must be positive" }
    set deadline [expr {[_aip_control_now_fs]+$timeout*1000000}]
    while {1} {
        set result [_aip_inject_status $ticket]
        set state [dict get $result state]
        if {$state in {DONE CANCELLED TIMED_OUT} || ($until_started && $state eq "RUNNING")} { return $result }
        if {$state eq "RUNNING_TIMEOUT"} {
            _aip_inject_error TIMEOUT "ticket $ticket exceeded its job deadline; original task is still running (not killed)"
        }
        set remaining [expr {$deadline-[_aip_control_now_fs]}]
        if {$remaining <= 0} { _aip_inject_error TIMEOUT "wait expired for ticket $ticket; job remains $state, inspect aip_job status $ticket" }
        _aip_inject_step "[expr {min($remaining,$poll)}]fs"
    }
}

# 用户job管理入口。status/result/list不推进；wait受控推进；cancel只允许尚未
# 开始的请求；release只释放terminal结果，永不取消已经运行的SV task/seq。
proc aip_job {operation args} {
    if {$operation eq "list"} {
        if {[llength $args] != 0} { _aip_inject_error ARGUMENT "usage: aip_job list" }
        if {![_aip_inject_available]} { _aip_inject_error UNAVAILABLE "injection bridge unavailable" }
        set jobs {}
        for {set slot 0} {$slot < 32} {incr slot} {
            if {[_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_state[%d]} $slot]]] == 0} { continue }
            set ticket [_aip_control_scalar [get [format {aip_core_pkg::__inject_slot_ticket[%d]} $slot]]]
            lappend jobs [_aip_inject_status $ticket]
        }
        return $jobs
    }
    if {[llength $args] < 1 || [llength $args] > 2 || ($operation ne "wait" && [llength $args] != 1)} {
        _aip_inject_error ARGUMENT "usage: aip_job status|result|cancel|release <ticket>, or aip_job wait <ticket> ?timeout=<duration>?"
    }
    set ticket [_aip_inject_ticket [lindex $args 0]]
    switch -- $operation {
        status - result { return [_aip_inject_status $ticket] }
        wait { return [_aip_inject_wait $ticket 0 [lrange $args 1 end]] }
        cancel {
            _aip_inject_request 2 {} $ticket 0
            return [_aip_inject_status $ticket]
        }
        release {
            set result [_aip_inject_status $ticket]
            _aip_inject_request 3 {} $ticket 0
            dict unset ::_aip_inject_slots $ticket
            return $result
        }
        default { _aip_inject_error ARGUMENT "unknown job operation '$operation'" }
    }
}

# pause 内普通命令自动改走注入（wait=0 仍等到真正启动；只需排队用 aip_submit）。同步结果复制到 pause 专属
# overlay 并释放 SV slot；原调用恢复后 overlay 不可见，不会被误认为原 seq 结果。
proc _aip_inject_send {command} {
    set ::_aip_inject_last_result {}
    # op4在SV复用extract_wait，原始参数串不在Tcl分词重组；保留逗号、容器、
    # 空白等旧宏可见字节，并统一重复/非法wait的诊断与supports_async检查。
    set timeout [_aip_inject_timeout_ns {} $::aip_ack_timeout_ns]
    set accepted [_aip_inject_request 4 $command 0 $timeout]
    set ticket [dict get $accepted ticket]
    set wait [dict get $accepted wait]
    set snapshot [_aip_inject_wait $ticket [expr {!$wait}] {}]
    if {!$wait && [dict get $snapshot state] in {RUNNING DONE}} {
        regexp {^\s*(\S+)} $command -> name
        dict set snapshot result "STARTED: $name ticket=$ticket"
        dict set snapshot status 0
    } else {
        aip_job release $ticket
    }
    set ::_aip_inject_last_result $snapshot
}

# overlay只属于pause交互，原脚本恢复后无论变量是否仍存留都不得读取它。
proc _aip_inject_has_result {} {
    return [expr {$::_aip_inject_last_result ne "" && [_aip_control_is_paused_context]}]
}

# checkpoint/restore/plugin生命周期不得保存或销毁ticket资源。旧SV没有此桥
# 时保持兼容；有桥时必须先完成/取消并release全部slot，terminal也不能漏回收。
proc _aip_inject_assert_quiescent {operation} {
    if {![_aip_inject_available]} { return }
    if {[llength [aip_job list]] != 0} {
        _aip_inject_error BUSY "cannot $operation with retained injection tickets; inspect aip_job list and release terminal jobs"
    }
}
