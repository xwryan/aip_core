# 一次性逻辑信号观察（VCS get/stop）：只拥有自己注册的 stop ID 与状态，不改用户 onbreak，安装时不推进仿真。
# stop=1 请求受控原生 pause；TCP 注册复用同一 native stop 回调。活动观察不随 checkpoint 保存，保存/恢复前必须取消。

if {![info exists ::_aip_watch_next_id]} { set ::_aip_watch_next_id 0 }
if {![info exists ::_aip_watches]} { set ::_aip_watches [dict create] }
if {![info exists ::_aip_watch_deferred_output]} { set ::_aip_watch_deferred_output {} }

# ACK/helper advances may redirect native stdout (to hide an internal $stop(0) diagnostic), so their
# notifications are emitted after the run returns; other runs print immediately. The queue survives re-source.
proc _aip_watch_flush_deferred_output {} {
    set output $::_aip_watch_deferred_output
    set ::_aip_watch_deferred_output {}
    foreach line $output { puts $line }
    return [llength $output]
}

# Diagnostics and warnings share the deferred channel so they stay visible and precede a queued pause.
proc _aip_watch_emit {line} {
    set color green
    if {[string first {[AIP_WATCH] warning:} $line] == 0} { set color yellow }
    if {[info commands _aip_colorize] ne ""} {
        set line [_aip_colorize $line $color]
    }
    if {[info exists ::_aip_control_state] &&
        [dict exists $::_aip_control_state mode] &&
        [dict get $::_aip_control_state mode] in {ack helper}} {
        lappend ::_aip_watch_deferred_output $line
    } else {
        puts $line
    }
}

# 严格解析无符号二态整数（拒绝 X/Z、负数、下划线和表达式）；逐位用 Tcl 大整数累计，不截断宽向量。
proc _aip_watch_number {raw} {
    set value [string trim $raw]
    set base 10
    if {[regexp -nocase {^0x([0-9a-f]+)$} $value -> digits]} {
        set base 16
    } elseif {[regexp -nocase {^0b([01]+)$} $value -> digits]} {
        set base 2
    } elseif {[regexp -nocase {^[0-9]*'([hdbo])([0-9a-f]+)$} $value -> radix digits]} {
        switch -nocase -- $radix {
            h { set base 16 }
            d { set base 10 }
            b { set base 2 }
            o { set base 8 }
            default { return "" }
        }
    } elseif {[regexp {^[0-9]+$} $value]} {
        set digits $value
    } else { return "" }
    set number 0
    foreach digit [split [string tolower $digits] ""] {
        set item [string first $digit 0123456789abcdef]
        if {$item < 0 || $item >= $base} { return "" }
        set number [expr {$number * $base + $item}]
    }
    return $number
}

# aip_watch 的目标既可以是传统的二态数值，也可以直接写 x/z，表示
# “当前值中包含该未知态”。未知态观察使用 stop -change 作为唤醒点，
# 再在 Tcl 回调中检查完整 get 文本，因此不需要猜测 DUT 的位宽。
proc _aip_watch_expected {raw} {
    set value [string trim $raw]
    if {[string equal -nocase $value x] || [string equal -nocase $value z]} {
        return [dict create kind unknown expected [string tolower $value]]
    }
    set number [_aip_watch_number $value]
    if {$number eq ""} { return "" }
    return [dict create kind numeric expected $number]
}

proc _aip_watch_unknown_match {raw target} {
    set value [string tolower [string trim $raw]]
    return [expr {[string first $target $value] >= 0}]
}

# 生成显式宽度的二进制常量，防止原生条件解析器把大十进制值解释成有符号
# 32bit数。输入已经过非负整数校验；零至少保留一位。
proc _aip_watch_literal {number} {
    set digits ""
    while {$number > 0} {
        set digits "[expr {$number % 2}]$digits"
        set number [expr {$number / 2}]
    }
    if {$digits eq ""} { set digits 0 }
    return "[string length $digits]'b$digits"
}

# 检查调用方提供的观察 ID；不把未知 ID 当成已取消，避免掩盖拼写错误。
proc _aip_watch_require {id} {
    if {![dict exists $::_aip_watches $id]} { error "aip_watch: unknown watch id '$id'" }
    return [dict get $::_aip_watches $id]
}

# Write the optional marker before any pause/queue action. Existing files are
# overwritten without an implicit newline. Missing paths and I/O failures are
# warning-only: the watch remains matched and its stop behavior is unchanged.
proc _aip_watch_write_file {id record} {
    if {![dict exists $record file] || [dict get $record file] eq ""} {
        dict set record file_status none
        dict set ::_aip_watches $id $record
        return $record
    }
    set path [dict get $record file]
    if {![file exists $path]} {
        _aip_watch_emit "\[AIP_WATCH\] warning: file '$path' does not exist; content was not written"
        dict set record file_status missing
        dict set record file_error "file does not exist"
        dict set ::_aip_watches $id $record
        return $record
    }
    if {![file isfile $path]} {
        _aip_watch_emit "\[AIP_WATCH\] warning: path '$path' is not a regular file; content was not written"
        dict set record file_status error
        dict set record file_error "path is not a regular file"
        dict set ::_aip_watches $id $record
        return $record
    }
    set channel ""
    set code [catch {
        set channel [open $path w]
        fconfigure $channel -translation binary -encoding binary
        puts -nonewline $channel [dict get $record ctx]
        flush $channel
        close $channel
        set channel ""
    } result options]
    if {$channel ne ""} { catch {close $channel} }
    if {$code} {
        _aip_watch_emit "\[AIP_WATCH\] warning: cannot write file '$path': $result"
        dict set record file_status error
        dict set record file_error $result
    } else {
        dict set record file_status written
        dict set record file_error {}
    }
    dict set ::_aip_watches $id $record
    return $record
}

# Parse opaque key/value options. Content is never evaluated as Tcl; callers
# can use a braced argument to preserve spaces or newlines. file/ctx are
# paired so a typo cannot silently skip the requested write.
proc _aip_watch_parse_options {arguments} {
    set stop 0
    set stop_set 0
    set file_set 0
    set ctx_set 0
    set file ""
    set ctx ""
    foreach option $arguments {
        if {[regexp {^stop=([01])$} $option -> value]} {
            if {$stop_set} { error "usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?" }
            set stop $value
            set stop_set 1
        } elseif {[regexp {^file=(.*)$} $option -> value]} {
            if {$file_set} { error "usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?" }
            set file $value
            set file_set 1
        } elseif {[regexp {^ctx=(.*)$} $option -> value]} {
            if {$ctx_set} { error "usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?" }
            set ctx $value
            set ctx_set 1
        } else {
            error "usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?"
        }
    }
    if {$file_set != $ctx_set || ($file_set && $file eq "")} {
        error "usage: aip_watch path expected ?stop=0|1? ?file=path ctx=content?"
    }
    return [dict create stop $stop file $file ctx $ctx]
}

# 回调只消费自己的观察：先删除断点并发布终态。AIP run/ack/helper 执行中只排队，由推进层在 _vcs_run 返回后暂停
# （有限 run 可补完剩余窗口且不重入原请求）；无 AIP owner 的自主/SV/TCP 推进则在回调中直接进入受控 pause，
# 否则 VCS 只报普通 Stop point，无法保留 Tcl 调用栈。
proc _aip_watch_hit {id {immediate 0}} {
    set record [_aip_watch_require $id]
    if {[dict get $record state] ne "armed"} { return }
    set path [dict get $record path]
    set raw [get $path]
    set target_kind [dict get $record target_kind]
    if {$target_kind eq "unknown"} {
        if {![_aip_watch_unknown_match $raw [dict get $record expected]]} {
            # stop -change also wakes on ordinary transitions: mark it AIP-owned so the managed run resumes the
            # same deadline; nothing is printed until the requested X/Z state is actually present.
            if {!$immediate} {
                _aip_control_signal_watch "watch $id: $path probe" 0
            }
            return
        }
    } else {
        set current [_aip_watch_number $raw]
        if {$current eq "" || $current != [dict get $record expected]} { return }
    }
    set native_id [dict get $record native_id]
    if {$native_id ne ""} { stop -delete $native_id }
    dict set record native_id ""
    dict set record state matched
    dict set record value $raw
    dict set record time [senv time]
    dict set ::_aip_watches $id $record
    set record [_aip_watch_write_file $id $record]
    set should_pause [dict get $record stop]
    if {$immediate} {
        _aip_watch_emit "\[AIP_WATCH\] id=$id path=$path value=$raw time=[dict get $record time]"
        if {$should_pause} { _aip_control_pause "watch $id: $path" }
    } else {
        set state $::_aip_control_state
        set autonomous_context [expr {
            [dict get $state depth] == 0 &&
            [dict get $state pending_id] eq "" &&
            ![dict get $state watch_paused]}]
        if {$autonomous_context} {
            _aip_watch_emit "\[AIP_WATCH\] id=$id path=$path value=$raw time=[dict get $record time]"
            # No AIP owner will drain a stop=1 event after a simulator-owned stop, so pause immediately;
            # notify-only watches keep the queued stop, which a later AIP advance consumes.
            if {$should_pause} {
                _aip_control_pause "watch $id: $path"
            } else {
                _aip_control_signal_watch "watch $id: $path" 0
            }
        } else {
            set notification "\[AIP_WATCH\] id=$id path=$path value=$raw time=[dict get $record time]"
            _aip_watch_emit $notification
            _aip_control_signal_watch "watch $id: $path" $should_pause
        }
    }
}

# 立即注册一次性观察并返回 ID。expected 为二态无符号数或 x/z（首次出现该未知态）；默认只通知，stop=1 才保栈暂停。
# 路径只允许层次名/数组索引，不拼入表达式或脚本；路径不存在/原生注册失败原样报错。
proc aip_watch {path expected args} {
    # A TCP registration may arrive while a user script is inside `run`; only this read-only registration
    # is allowed there (no advancing, force, bridge handshake or pause/recovery).
    _aip_control_assert_watch_registration_allowed
    set tcp_registration [expr {[info exists ::_aip_watch_tcp_mode] && $::_aip_watch_tcp_mode}]
    if {![regexp {^[A-Za-z_$][A-Za-z0-9_$]*(\[[0-9]+\])*(\.[A-Za-z_$][A-Za-z0-9_$]*(\[[0-9]+\])*)*$} $path]} {
        error "aip_watch: expected a plain HDL hierarchy path, got '$path'"
    }
    set expected_info [_aip_watch_expected $expected]
    if {$expected_info eq ""} {
        error "aip_watch: expected must be an unsigned two-state integer or x/z, got '$expected'"
    }
    set target_kind [dict get $expected_info kind]
    set target [dict get $expected_info expected]
    set options [_aip_watch_parse_options $args]
    set should_pause [dict get $options stop]
    set file_path [dict get $options file]
    set context [dict get $options ctx]
    set file_status [expr {$file_path eq "" ? "none" : "pending"}]
    set raw [get $path]
    set current_match 0
    if {$target_kind eq "unknown"} {
        set current_match [_aip_watch_unknown_match $raw $target]
    } else {
        set current [_aip_watch_number $raw]
        set current_match [expr {$current ne "" && $current == $target}]
    }
    incr ::_aip_watch_next_id
    set id $::_aip_watch_next_id
    dict set ::_aip_watches $id [dict create id $id path $path target_kind $target_kind expected $target \
        stop $should_pause file $file_path ctx $context file_status $file_status file_error {} \
        state armed value "" time "" native_id ""]
    if {$current_match} {
        # Idle registration resolves an already-matched value without a transient native stop; a TCP
        # registration inside an active run queues the event instead of pausing from the nested MHPI call.
        _aip_watch_hit $id [expr {!$tcp_registration}]
        return $id
    }
    # The transport annotation is owned by the TCP bridge and remains set
    # until that bridge call returns. A callback cannot safely resume the
    # simulator from inside the stop callback itself.
    set native_id ""
    set code [catch {
        if {$target_kind eq "unknown"} {
            set native_id [stop -change $path]
        } else {
            set native_id [stop -condition "$path == [_aip_watch_literal $target]"]
        }
        dict set ::_aip_watches $id native_id $native_id
        # VCS evaluates stop callbacks from a simulator-owned Tcl context;
        # qualify the global proc so MHPI-registered callbacks resolve there
        # just as they do when invoked from the UCLI prompt.
        stop -command [list ::_aip_watch_hit $id] $native_id
    } result options]
    if {$code} {
        if {$native_id ne ""} { catch {stop -delete $native_id} }
        dict set ::_aip_watches $id state error
        dict set ::_aip_watches $id native_id ""
        return -options $options "aip_watch: cannot monitor '$path': $result"
    }
    return $id
}

# 只取消自己仍 armed 的断点，重复取消或已完成观察不再通知；省略 ID 取消全部并返回被取消的 ID 列表。
# 调试暂停时允许取消，不调用桥、不推进仿真、不改变原 pending 请求。
proc aip_watch_cancel {{id ""}} {
    if {$id eq ""} {
        set canceled {}
        dict for {watch_id record} $::_aip_watches {
            if {[dict get $record state] ne "armed"} { continue }
            set native_id [dict get $record native_id]
            if {$native_id ne ""} { stop -delete $native_id }
            dict set record native_id ""
            dict set record state canceled
            dict set ::_aip_watches $watch_id $record
            lappend canceled $watch_id
        }
        return $canceled
    }
    set record [_aip_watch_require $id]
    if {[dict get $record state] eq "armed"} {
        set native_id [dict get $record native_id]
        if {$native_id ne ""} { stop -delete $native_id }
        dict set record native_id ""
        dict set record state canceled
        dict set ::_aip_watches $id $record
    }
    return [dict get $record state]
}

# 返回只读状态快照：给定 ID 返回单条 dict，省略则返回 ID 到记录的 dict。
# 查询不消费通知，不改变断点/仿真时间，允许在保栈暂停提示符内调用。
proc aip_watch_status {{id ""}} {
    if {$id eq ""} {
        # Never return an empty string: MHPI's no-print API uses it for both an empty result and an error,
        # so `{}` is the unambiguous empty table for remote callers.
        if {[dict size $::_aip_watches] == 0} { return "{}" }
        return $::_aip_watches
    }
    return [_aip_watch_require $id]
}

# 防止快照和 Tcl 注册表产生断点所有权歧义；旧 checkpoint 无活动 watch
# 时行为不变。调用方必须在保存/恢复前显式取消仍 armed 的观察。
proc _aip_watch_assert_quiescent {operation} {
    dict for {id record} $::_aip_watches {
        if {[dict get $record state] eq "armed"} {
            error "$operation: watch $id is active; cancel it with aip_watch_cancel before checkpoint/restore"
        }
    }
}

# aip_restore 之前置位，下一次加载恢复命令时使旧观察历史失效。记录保留供
# 用户诊断，但不把未来时刻的 matched/canceled 状态伪装成快照内的有效观察。
if {[info exists ::_aip_watch_restore_pending] && $::_aip_watch_restore_pending} {
    dict for {_aip_watch_id _aip_watch_record} $::_aip_watches {
        dict set ::_aip_watches $_aip_watch_id state invalidated
        dict set ::_aip_watches $_aip_watch_id native_id ""
    }
    set ::_aip_watch_restore_pending 0
    unset -nocomplain _aip_watch_id _aip_watch_record
}
