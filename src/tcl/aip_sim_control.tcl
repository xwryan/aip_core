# AIP 同会话仿真推进与暂停控制（先于 aip_cmd.tcl 加载）：用原生 pause/resume 保存活跃 Tcl 调用栈，绝不靠重新
# source 或重发命令“恢复”；不改写用户 source/for/proc/continue，也不替换 onbreak。期限一律由 senv time 原始值换算为整数 fs。
# 正常调用独占 depth/mode/pending_id；暂停中的有限调试推进只拥有 debug_active，不释放原请求、不覆盖结果。

# 重复 source 或 restore 后重载只补缺省字段，不擅自清除未消费的 watch 事件。
# restore 的过期深度/在途请求由显式 _aip_control_reconcile 核对真实桥接槽。
if {![info exists ::_aip_control_state]} { set ::_aip_control_state [dict create] }
foreach {_aip_control_key _aip_control_default} {
    depth 0 mode {} pending_id {} orphan_id {} watch_paused 0 pause_reason {} events {} resume_serial 0
    tty_mode unknown tty_probe_error {} run_keep_support unknown
    debug_active 0 debug_event {}
} {
    if {![dict exists $::_aip_control_state $_aip_control_key]} {
        dict set ::_aip_control_state $_aip_control_key $_aip_control_default
    }
}
unset _aip_control_key _aip_control_default

# 按十进制逐位累积，避免 Tcl 把 08 解释成八进制，亦不受 64 位 scan 限制。
proc _aip_control_decimal {digits} {
    if {![regexp {^[0-9]+$} $digits]} {
        return -code error -errorcode {AIP CONTROL TIME} "AIP_CONTROL_TIME: invalid decimal '$digits'"
    }
    set value 0
    foreach digit [split $digits ""] {
        scan $digit %d number
        set value [expr {$value * 10 + $number}]
    }
    return $value
}

# 精确解析非负时间；允许小数单位，但结果必须能用整数 fs 表示。
# unitless_scale 是 VCS timePrecision 对应的整数 fs，不是当前作用域 timeunit。
proc _aip_control_time_fs {value {unitless_scale 1}} {
    set value [string trim $value]
    if {![regexp {^\+?([0-9]+)(?:\.([0-9]+))?\s*(fs|ps|ns|us|ms|s)?$} $value -> whole fraction unit]} {
        return -code error -errorcode {AIP CONTROL TIME} "AIP_CONTROL_TIME: invalid time '$value'"
    }
    if {$unit eq ""} {
        set scale $unitless_scale
    } else {
        set scale [dict get {fs 1 ps 1000 ns 1000000 us 1000000000 ms 1000000000000 s 1000000000000000} $unit]
    }
    set denominator [expr {10 ** [string length $fraction]}]
    set numerator [expr {[_aip_control_decimal "$whole$fraction"] * $scale}]
    if {$numerator % $denominator != 0} {
        return -code error -errorcode {AIP CONTROL TIME} "AIP_CONTROL_TIME: '$value' is finer than 1 fs"
    }
    return [expr {$numerator / $denominator}]
}

# 只读原生的精确时间；不退回可能已舍入的 _aip_sim_time 或日志字符串。
proc _aip_control_now_fs {} {
    return [_aip_control_time_fs [senv time]]
}

# 独立解码桥接标量。X/Z 或格式错误必须报错，不能误判成 ACK=0/空闲。
proc _aip_control_scalar {raw} {
    set value [string trim $raw]
    if {[regexp {^[0-9]+$} $value]} { return [_aip_control_decimal $value] }
    if {![regexp {^[0-9]*'([bBdDhH])([0-9a-fA-F]+)$} $value -> kind digits]} {
        return -code error -errorcode {AIP CONTROL STATE} "AIP_CONTROL_STATE: invalid bridge value '$raw'"
    }
    set base [dict get {b 2 d 10 h 16} [string tolower $kind]]
    set result 0
    foreach digit [split [string tolower $digits] ""] {
        set number [string first $digit 0123456789abcdef]
        if {$number < 0 || $number >= $base} {
            return -code error -errorcode {AIP CONTROL STATE} "AIP_CONTROL_STATE: invalid bridge value '$raw'"
        }
        set result [expr {$result * $base + $number}]
    }
    return $result
}

# 只读快照。watch_paused 仅表示本模块显式 pause（原生 -keep 内的 Ctrl+C 暂停由执行帧识别）；
# active 本身不能证明当前正在 pause% 求值。
proc aip_sim_status {} {
    set status $::_aip_control_state
    dict set status pause_requested [expr {[llength [dict get $status events]] != 0}]
    dict set status active [expr {[dict get $status depth] != 0}]
    return $status
}

# Shared ANSI palette for AIP diagnostics (defined here because this module loads first).
proc _aip_colorize {line color} {
    switch -- $color {
        green  { set code "\033\[32m" }
        yellow { set code "\033\[33m" }
        red    { set code "\033\[31m" }
        cyan   { set code "\033\[36m" }
        orange { set code "\033\[38;5;208m" }
        default { return $line }
    }
    return "${code}${line}\033\[0m"
}

# 正常共享桥接槽、checkpoint、recover 仍须空闲。有限调试推进走独立门禁，
# 不能为了允许 pause% 的操作而将任意正深度回调误认为空闲。
proc _aip_control_assert_idle {operation} {
    if {[dict get $::_aip_control_state depth] != 0 ||
        [dict get $::_aip_control_state pending_id] ne ""} {
        return -code error -errorcode {AIP CONTROL BUSY} \
            "AIP_CONTROL_BUSY: cannot $operation while a simulation command is suspended or pending; use native resume"
    }
}

# Watch registration is read-only (reads the HDL value, installs a stop condition). A TCP request may arrive
# while a user script is inside `run`; ::_aip_watch_tcp_mode marks that narrow path so registration is not
# rejected as BUSY. No advance, handshake, force or pause is allowed by this exception.
proc _aip_control_assert_watch_registration_allowed {} {
    if {[dict get $::_aip_control_state depth] == 0 &&
        [dict get $::_aip_control_state pending_id] eq ""} {
        return
    }
    if {[info exists ::_aip_watch_tcp_mode] && $::_aip_watch_tcp_mode &&
        [dict get $::_aip_control_state mode] eq "run" &&
        [dict get $::_aip_control_state depth] != 0 &&
        [dict get $::_aip_control_state pending_id] eq "" &&
        ![dict get $::_aip_control_state watch_paused]} {
        return
    }
    return -code error -errorcode {AIP CONTROL BUSY} \
        "AIP_CONTROL_BUSY: cannot aip_watch while a simulation command is suspended or pending; use native resume"
}

# 检查真实暂停执行帧而非 info level/depth：pause% 以 uplevel #0 求值，普通回调也可能在全局层执行，只有活跃 AIP owner
# 之后的 ::synopsys::pause 才证明保留了交互暂停栈；暂停内再次进入 native run 的回调须拒绝，未知栈布局保守返回假。
proc _aip_control_is_paused_context {} {
    if {[dict get $::_aip_control_state depth] == 0 ||
        [dict get $::_aip_control_state debug_active]} { return 0 }
    set owner 0
    set paused 0
    set count [info frame]
    for {set index 1} {$index <= $count} {incr index} {
        set frame [info frame $index]
        if {![dict exists $frame proc]} { continue }
        set proc_name [dict get $frame proc]
        if {$proc_name in {::_aip_advance ::_aip_control_pause}} { set owner 1 }
        if {$owner && $proc_name eq "::synopsys::pause"} { set paused 1 }
        if {$paused && $proc_name in {::synopsys::run ::run::run ::_vcs_run}} {
            return 0
        }
    }
    return $paused
}

# 辅助流程在第一次 get/force 前检查上下文；duration 非空时还预检有限时长，
# 避免 pulse 先 force 再因非法 run 参数失败。普通非暂停调用保持原空闲要求。
proc _aip_control_assert_helper_allowed {operation {duration ""}} {
    if {[_aip_control_is_paused_context]} {
        if {$duration ne ""} { _aip_control_debug_plan [list $duration] }
        return
    }
    _aip_control_assert_idle $operation
}

# aip_send_cmd 的统一门禁；在写入 payload、清理 force 或分配 ID 之前调用。
proc _aip_control_assert_command_allowed {} {
    _aip_control_assert_idle "send another AIP command"
}

# 每次发送只登记一次，ACK 中途暂停不清理它；由命令层 finally 成对释放。
proc _aip_control_pending_begin {id} {
    _aip_control_assert_idle "begin command $id"
    dict set ::_aip_control_state pending_id [_aip_control_decimal $id]
    dict set ::_aip_control_state orphan_id {}
}

# 严格核对拥有者，防止异常恢复/嵌套调用把另一条请求的保护标志清掉。
proc _aip_control_pending_end {id} {
    if {[dict get $::_aip_control_state pending_id] ne [_aip_control_decimal $id]} {
        return -code error -errorcode {AIP CONTROL STATE} "AIP_CONTROL_STATE: pending command does not match $id"
    }
    dict set ::_aip_control_state pending_id {}
}

# AIP 自己拥有活动推进栈时，native stop 回调只排队（禁止在静音层/回调栈中重入 pause），推进层返回后再消费，
# 才能补完有限 run；只通知的事件也要标记，推进层才知道应补完被截断的 run。空闲自主推进由 aip_watch 直接 pause。
proc _aip_control_signal_watch {reason should_pause} {
    if {![string is boolean -strict $should_pause]} {
        return -code error -errorcode {AIP CONTROL ARGUMENT} "AIP_CONTROL_ARGUMENT: should_pause must be boolean"
    }
    dict lappend ::_aip_control_state events [dict create reason $reason pause [expr {!!$should_pause}]]
}

proc _aip_control_signal_pause {reason} {
    _aip_control_signal_watch $reason 1
}

# 临时 execution trace 只记录原生 resume 被执行：VCS 在无输入/EOF 时可能让 pause 以成功码返回，
# 仅看返回码会让脚本偷跑，必须以真实 resume 调用为继续凭据。
proc _aip_control_resume_observed {command code result operation} {
    # enter 太早：resume badarg 会报错，resume -help 虽成功也不恢复。
    # 仅无参原生 resume 的成功 leave 才是有效凭据。
    if {$code == 0 && [llength $command] == 1} {
        dict incr ::_aip_control_state resume_serial
    }
}

# 原生 pause 的唯一封装。空闲时可立即调用（例如新注册的 watch 已匹配），
# 推进中则由本文件内部调用；期间始终保留一个正深度，避免交互重入。
proc _aip_control_pause {reason} {
    if {[dict get $::_aip_control_state watch_paused]} {
        return -code error -errorcode {AIP CONTROL BUSY} "AIP_CONTROL_BUSY: already paused"
    }
    if {[info commands pause] eq ""} {
        return -code error -errorcode {AIP CONTROL UNAVAILABLE} "AIP_CONTROL_UNAVAILABLE: native UCLI pause is unavailable"
    }
    set owns_depth [expr {[dict get $::_aip_control_state depth] == 0}]
    if {$owns_depth} {
        _aip_control_assert_idle pause
        dict set ::_aip_control_state depth 1
        dict set ::_aip_control_state mode pause
    }
    dict set ::_aip_control_state watch_paused 1
    dict set ::_aip_control_state pause_reason $reason
    set serial [dict get $::_aip_control_state resume_serial]
    set traced 0
    try {
        trace add execution resume leave _aip_control_resume_observed
        set traced 1
        puts [_aip_colorize "\[AIP_SIM_CONTROL\] paused: $reason; use native resume to continue" green]
        pause
        if {[dict get $::_aip_control_state resume_serial] == $serial} {
            set message "AIP_CONTROL_PAUSE_ABORTED: native pause returned without resume (EOF or cancelled interactive input); script continuation is refused"
            return -code error -errorcode {AIP CONTROL PAUSE_ABORTED} \
                [_aip_colorize $message red]
        }
    } finally {
        if {$traced} { trace remove execution resume leave _aip_control_resume_observed }
        dict set ::_aip_control_state watch_paused 0
        dict set ::_aip_control_state pause_reason {}
        if {$owns_depth} {
            dict set ::_aip_control_state depth 0
            dict set ::_aip_control_state mode {}
        }
    }
}

# 取出本批事件再执行 pause，避免恢复后的同一事件被重复消费。
# 暂停期间新增的事件仍留在全局队列，下一轮继续处理，不依赖 /dev/tty。
proc _aip_control_drain_events {} {
    if {[info commands _aip_watch_flush_deferred_output] ne ""} {
        _aip_watch_flush_deferred_output
    }
    set count [llength [dict get $::_aip_control_state events]]
    for {set i 0} {$i < $count} {incr i} {
        set events [dict get $::_aip_control_state events]
        set event [lindex $events 0]
        dict set ::_aip_control_state events [lrange $events 1 end]
        if {[dict get $event pause]} { _aip_control_pause [dict get $event reason] }
    }
    return $count
}

# ACK 的真实完成条件只比较当前请求 ID。完成后即使刚从 watch 暂停恢复，
# 也必须立即返回命令层，不能为了补一个 run 窗口继续推进仿真。
proc _aip_control_ack_complete {} {
    set pending [dict get $::_aip_control_state pending_id]
    if {$pending eq ""} { return 0 }
    return [expr {[_aip_control_scalar [get aip_core_pkg::__tcl_result_id]] == $pending}]
}

# 自动 -keep 只用于确有交互终端且 VCS 支持该选项的会话：batch 下 native -keep 遇 SIGINT+EOF 会自行续跑，
# 改变旧中断语义。显式 -keep 始终尊重；检测只用已有 stdin，不打开 /dev/tty、不消费用户输入。
proc _aip_control_detect_keep_support {} {
    if {![dict exists $::_aip_control_state run_keep_support]} {
        dict set ::_aip_control_state run_keep_support unknown
    }
    if {[dict get $::_aip_control_state run_keep_support] ne "unknown"} { return }

    # Explicit override is portable for custom VCS wrapper paths.
    if {[info exists ::env(AIP_VCS_RUN_KEEP)]} {
        set value [string tolower [string trim $::env(AIP_VCS_RUN_KEEP)]]
        if {$value in {0 no off false disabled}} {
            dict set ::_aip_control_state run_keep_support unsupported
            return
        }
        if {$value in {1 yes on true enabled}} {
            dict set ::_aip_control_state run_keep_support supported
            return
        }
        puts stderr [_aip_colorize "\[AIP_SIM_CONTROL\] warning: invalid AIP_VCS_RUN_KEEP='$::env(AIP_VCS_RUN_KEEP)'; ignoring override" yellow]
    }

    # Q-2020 rejects `run -keep` before entering the simulation.  Detect its
    # conventional installation name without issuing a risky probe command.
    if {[info exists ::env(VCS_HOME)] &&
        [regexp -nocase {/(?:Q|P)-20[0-9]{2}(?:[./-]|$)} $::env(VCS_HOME)]} {
        dict set ::_aip_control_state run_keep_support unsupported
    }
}

proc _aip_control_auto_keep {} {
    _aip_control_detect_keep_support
    if {[dict exists $::_aip_control_state run_keep_support] &&
        [dict get $::_aip_control_state run_keep_support] eq "unsupported"} {
        return 0
    }
    if {[dict get $::_aip_control_state tty_mode] eq "unknown"} {
        set code [catch {exec test -t 0 <@ stdin} value options]
        if {$code == 0} {
            dict set ::_aip_control_state tty_mode tty
        } elseif {$code == 1 && [dict exists $options -errorcode] &&
                  [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS" &&
                  [lindex [dict get $options -errorcode] end] eq "1"} {
            dict set ::_aip_control_state tty_mode non_tty
        } else {
            # 工具不存在/重定向失败等不是“确定非TTY”。保守不注入 -keep，
            # 同时保留诊断且只警告一次，不能伪装为检测成功。
            dict set ::_aip_control_state tty_mode probe_failed
            dict set ::_aip_control_state tty_probe_error $value
            puts stderr [_aip_colorize "\[AIP_SIM_CONTROL\] warning: cannot detect interactive stdin; automatic -keep disabled: $value" yellow]
        }
    }
    return [expr {[dict get $::_aip_control_state tty_mode] eq "tty"}]
}

# 普通/无单位时长、absolute/relative 与无限 run 可保存期限；边沿/源码行/倒退等高级模式原样交给原生命令，
# 若被 watch 截断则明确报不支持精确恢复。
proc _aip_control_run_plan {arguments {allow_auto_keep 1}} {
    set args $arguments
    set explicit_keep [expr {[lsearch -exact $args -keep] >= 0}]
    if {$explicit_keep} {
        set pos [lsearch -exact $args -keep]
        set args [lreplace $args $pos $pos]
    }
    # -keep is a user-facing Ctrl+C/retained-stack policy.  Internal ACK
    # advances must preserve the historical plain `_vcs_run` form: older VCS
    # releases can reject `run -keep` from a nested UCLI Tcl procedure.
    set keep [expr {$explicit_keep || ($allow_auto_keep && [_aip_control_auto_keep])}]
    set mode relative
    if {[llength $args] == 2 && [lindex $args 0] in {-absolute absolute -relative relative}} {
        set mode [string trimleft [lindex $args 0] -]
        set args [lrange $args 1 end]
    }
    set plan [dict create kind opaque native $arguments keep $keep]
    if {[llength $args] == 0} {
        set native {}
        if {$keep} { set native [list -keep] }
        return [dict create kind unlimited native $native keep $keep]
    }
    if {[llength $args] == 1 && [regexp {^\+?[0-9]+(?:\.[0-9]+)?\s*(?:fs|ps|ns|us|ms|s)?$} [lindex $args 0]]} {
        set value [lindex $args 0]
        set precision 1
        if {![regexp {(fs|ps|ns|us|ms|s)$} [string trim $value]]} {
            set precision [_aip_control_time_fs [senv timePrecision]]
        }
        set duration [_aip_control_time_fs $value $precision]
        set deadline $duration
        if {$mode eq "relative"} { set deadline [expr {[_aip_control_now_fs] + $duration}] }
        set native $arguments
        # VCS 对相对 run 0 会明确告警 -keep 被忽略；零时推进无长时间
        # 等待，不自动添加它。用户显式给的 -keep 仍原样传递。
        if {!$explicit_keep && $keep && !($mode eq "relative" && $duration == 0)} {
            set native [linsert $native 0 -keep]
        }
        return [dict create kind timed native $native deadline $deadline keep $keep]
    }
    # 原生 -keep 支持这些模式的 Ctrl+C 保栈，但不额外承诺 watch 的目标续等。
    if {!$explicit_keep && $keep && [llength $arguments] != 0 &&
        [lindex $arguments 0] in {-line -posedge rising -rising -negedge falling -falling -change event -event}} {
        dict set plan native [linsert $arguments 0 -keep]
    }
    return $plan
}

# 暂停调试只接受可精确求截止点的有限 run。解析不探测 TTY、不修改状态，
# 因而非法/无限/边沿/源码行参数在任何 HDL 或控制状态变更前失败。显式
# -keep 只表示保栈意图；外层 pause 已拥有栈，内层不再创建第二个 -keep。
proc _aip_control_debug_plan {arguments} {
    set args $arguments
    set keep_pos [lsearch -exact $args -keep]
    if {$keep_pos >= 0} { set args [lreplace $args $keep_pos $keep_pos] }
    set mode relative
    if {[llength $args] == 2 && [lindex $args 0] in {-absolute absolute -relative relative}} {
        set mode [string trimleft [lindex $args 0] -]
        set args [lrange $args 1 end]
    }
    if {[llength $args] != 1 ||
        ![regexp {^\+?[0-9]+(?:\.[0-9]+)?\s*(?:fs|ps|ns|us|ms|s)?$} [lindex $args 0]]} {
        return -code error -errorcode {AIP CONTROL DEBUG_UNSUPPORTED} \
            "AIP_CONTROL_DEBUG_UNSUPPORTED: retained-pause advance requires a finite time duration"
    }
    set value [lindex $args 0]
    set precision 1
    if {![regexp {(fs|ps|ns|us|ms|s)$} [string trim $value]]} {
        set precision [_aip_control_time_fs [senv timePrecision]]
    }
    set amount [_aip_control_time_fs $value $precision]
    set now [_aip_control_now_fs]
    set deadline $amount
    if {$mode eq "relative"} { set deadline [expr {$now + $amount}] }
    if {$deadline < $now} {
        return -code error -errorcode {AIP CONTROL DEBUG_UNSUPPORTED} \
            "AIP_CONTROL_DEBUG_UNSUPPORTED: retained-pause advance cannot run backwards"
    }
    return [dict create before $now deadline $deadline]
}

# 原命令 ACK 后桥循环可能立即重新看到仍被 force 的 trigger，调试推进须及时清尾：严格核对 Tcl owner、真实
# result_id 与 cmd_id 后只清 trigger/len，pending owner 与返回值留给原 caller。返回是否匹配 ACK。
proc _aip_control_debug_ack {owner} {
    if {[dict get $::_aip_control_state pending_id] ne $owner} {
        return -code error -errorcode {AIP CONTROL STATE} "AIP_CONTROL_STATE: debug advance lost the original pending owner"
    }
    if {$owner eq ""} { return 0 }
    if {[_aip_control_scalar [get aip_core_pkg::__tcl_result_id]] != $owner} { return 0 }
    if {[_aip_control_scalar [get aip_core_pkg::__tcl_cmd_id]] != $owner} {
        return -code error -errorcode {AIP CONTROL STATE} "AIP_CONTROL_STATE: debug ACK command ID does not match the pending owner"
    }
    force aip_core_pkg::__tcl_cmd_trigger 0
    force aip_core_pkg::__tcl_cmd_len 32'd0
    return 1
}

# 调试期间的新 watch 不能递归 pause 或 resume 原脚本：只把调试期间新增的事件移到 debug_event（stop=1 以错误
# 返回当前 pause%，通知型允许补完窗口）；前 prefix_count 个旧事件属于外层 drain，原样保留。
proc _aip_control_debug_events {prefix_count} {
    if {[info commands _aip_watch_flush_deferred_output] ne ""} {
        _aip_watch_flush_deferred_output
    }
    set queued [dict get $::_aip_control_state events]
    set events [lrange $queued $prefix_count end]
    if {[llength $events] == 0} { return 0 }
    dict set ::_aip_control_state events [lrange $queued 0 [expr {$prefix_count - 1}]]
    dict set ::_aip_control_state debug_event [dict create kind watch events $events time_fs [_aip_control_now_fs]]
    foreach event $events {
        if {[dict get $event pause]} {
            return -code error -errorcode {AIP CONTROL DEBUG_INTERRUPTED} \
                "AIP_CONTROL_DEBUG_INTERRUPTED: watch stopped debug advance: [dict get $event reason]; original script remains paused"
        }
    }
    return [llength $events]
}

# 唯一的保栈调试推进实现：只拥有 debug_active 和局部期限，不写外层 depth/mode/owner，不调用 pause/resume/onbreak。
# ACK/通知可截断原生 run，其余提前返回（含 Ctrl+C）报安全中断；TCL_RETURN 等非局部控制码转成错误，避免展开原脚本。
proc _aip_control_debug_run {arguments} {
    if {![_aip_control_is_paused_context]} {
        return -code error -errorcode {AIP CONTROL BUSY} "AIP_CONTROL_BUSY: debug advance requires the retained native pause prompt"
    }
    set plan [_aip_control_debug_plan $arguments]
    if {[info commands _vcs_run] eq ""} {
        return -code error -errorcode {AIP CONTROL UNAVAILABLE} "AIP_CONTROL_UNAVAILABLE: native _vcs_run is unavailable"
    }
    set owner [dict get $::_aip_control_state pending_id]
    set deadline [dict get $plan deadline]
    set event_prefix [llength [dict get $::_aip_control_state events]]
    dict set ::_aip_control_state debug_active 1
    dict set ::_aip_control_state debug_event {}
    try {
        set acknowledged [_aip_control_debug_ack $owner]
        set stagnant 0
        while {1} {
            set before [_aip_control_now_fs]
            set remaining [expr {$deadline - $before}]
            set code [catch {_vcs_run "${remaining}fs"} result options]
            # 即使 watch/取消同时到达也先收尾真实 ACK，避免用户下一次调试
            # 推进时重复派发。原生错误仍保留 errorcode，非局部返回则安全降级。
            set ack_now [_aip_control_debug_ack $owner]
            if {$code != 0} {
                dict set ::_aip_control_state debug_event [dict create kind native code $code result $result time_fs [_aip_control_now_fs]]
                if {$code == 1} { return -options $options $result }
                return -code error -errorcode {AIP CONTROL DEBUG_INTERRUPTED} \
                    "AIP_CONTROL_DEBUG_INTERRUPTED: native advance cancelled (code $code); original script remains paused"
            }
            set saw_watch [_aip_control_debug_events $event_prefix]
            set now [_aip_control_now_fs]
            if {$now >= $deadline} {
                return [dict create before [dict get $plan before] after $now owner $owner]
            }
            if {!$saw_watch && !($ack_now && !$acknowledged)} {
                dict set ::_aip_control_state debug_event [dict create kind native_stop result $result time_fs $now]
                return -code error -errorcode {AIP CONTROL DEBUG_INTERRUPTED} \
                    "AIP_CONTROL_DEBUG_INTERRUPTED: native advance stopped before its deadline; original script remains paused"
            }
            set acknowledged $ack_now
            if {$now == $before} { incr stagnant } else { set stagnant 0 }
            if {$stagnant > 64} {
                return -code error -errorcode {AIP CONTROL NO_PROGRESS} "AIP_CONTROL_NO_PROGRESS: debug advance repeatedly stopped at the same simulation time"
            }
        }
    } finally {
        dict set ::_aip_control_state debug_active 0
    }
}

# sideband 等待者使用的有限相对步进入口；返回 before/after/owner 字典。
# 与普通 run 的暂停路由共用实现，禁止后台回调或嵌套推进绕过真实暂停检查。
proc _aip_debug_advance {duration} {
    return [_aip_control_debug_run [list $duration]]
}

# 初始握手内部执行一次 SV `$stop(0)`；VCS Q-2020 会把它打印成 `aip_tcl_bridge.sv: $stop(0)`（较新 VCS 默认静默），
# 所以只对启动握手静音，不包裹用户显式 run，也不吞掉调试中断。
proc _aip_control_quiet_run {args} {
    if {[info commands redirect] eq ""} {
        return [_vcs_run {*}$args]
    }
    set code [catch {
        redirect /dev/null [list _vcs_run {*}$args]
    } value options]
    if {$code != 0} {
        return -options $options $value
    }
    return $value
}

# Native `run -keep` is evaluated from the UCLI top-level frame on VCS
# versions that support it. Q-2020 is filtered before this path by
# `_aip_control_detect_keep_support`; no unsupported probe is issued.
proc _aip_control_native_run {args} {
    if {[lsearch -exact $args -keep] < 0} {
        return [_vcs_run {*}$args]
    }
    return [uplevel #0 [linsert $args 0 _vcs_run]]
}

# 统一仿真推进。bootstrap/checkpoint 保留原始返回语义（不消费 watch、不补跑、不加 -keep），兼容仅 +r 时启动握手的
# Tcl return；run/helper 仅在真实暂停帧内路由到有限调试入口，ACK/存档不能借此重入。run/helper/ack 不用 redirect：
# 重定向整个 native run 会吞掉 Ctrl+C 的 pause% 与用户 onbreak 输出，造成“假死”。
proc _aip_advance {mode args} {
    if {$mode ni {run ack helper bootstrap checkpoint settle}} {
        return -code error -errorcode {AIP CONTROL ARGUMENT} "AIP_CONTROL_ARGUMENT: unknown advance mode '$mode'"
    }
    if {[dict get $::_aip_control_state depth] != 0} {
        if {$mode in {run helper} && [_aip_control_is_paused_context]} {
            return [_aip_control_debug_run $args]
        }
        return -code error -errorcode {AIP CONTROL BUSY} "AIP_CONTROL_BUSY: cannot advance inside a suspended simulation command"
    }
    if {$mode ne "ack"} { _aip_control_assert_idle "advance ($mode)" }
    if {[info commands _vcs_run] eq ""} {
        return -code error -errorcode {AIP CONTROL UNAVAILABLE} "AIP_CONTROL_UNAVAILABLE: native _vcs_run is unavailable"
    }
    dict set ::_aip_control_state depth 1
    dict set ::_aip_control_state mode $mode
    # 原生启动握手可能产生 TCL_RETURN。额外的 Tcl 封装层不可吞掉这个
    # 返回码，因此内部辅助路径显式将 -level 加一后原样交回调用者。
    if {$mode in {bootstrap checkpoint settle}} {
        set code [catch {
            if {$mode in {bootstrap checkpoint settle}} {
                _aip_control_quiet_run {*}$args
            } else {
                _vcs_run {*}$args
            }
        } value options]
        dict set ::_aip_control_state depth 0
        dict set ::_aip_control_state mode {}
        if {$code != 0} {
            dict incr options -level 1
            return -options $options $value
        }
        return $value
    }
    try {
        set plan [_aip_control_run_plan $args [expr {$mode ni {ack helper}}]]
        set native [dict get $plan native]
        set initial_watch [_aip_control_drain_events]
        if {$mode eq "ack" && [_aip_control_ack_complete]} { return {} }
        if {$initial_watch && [dict get $plan kind] eq "timed"} {
            set remaining [expr {[dict get $plan deadline] - [_aip_control_now_fs]}]
            if {$remaining <= 0} { return {} }
            set native [list "${remaining}fs"]
            if {[dict get $plan keep]} { set native [linsert $native 0 -keep] }
        }
        set stagnant 0
        while {1} {
            set before [_aip_control_now_fs]
            if {$mode in {ack helper}} {
                # ACK/helper 推进仅用于内部握手/辅助流程，静音以免 VCS Q-2020 打印内部 $stop(0)。
                set result [_aip_control_quiet_run {*}$native]
            } else {
                set result [_aip_control_native_run {*}$native]
            }
            set saw_watch [_aip_control_drain_events]
            if {$mode eq "ack" && [_aip_control_ack_complete]} { return $result }
            if {!$saw_watch} { return $result }
            set now [_aip_control_now_fs]
            if {$now == $before} { incr stagnant } else { set stagnant 0 }
            if {$stagnant > 64} {
                return -code error -errorcode {AIP CONTROL NO_PROGRESS} "AIP_CONTROL_NO_PROGRESS: watch repeatedly stopped at the same simulation time"
            }
            switch -- [dict get $plan kind] {
                timed {
                    set remaining [expr {[dict get $plan deadline] - $now}]
                    if {$remaining <= 0} { return $result }
                    set native [list "${remaining}fs"]
                    if {[dict get $plan keep]} { set native [linsert $native 0 -keep] }
                }
                unlimited {
                    set native {}
                    if {[dict get $plan keep]} { set native [list -keep] }
                }
                default {
                    return -code error -errorcode {AIP CONTROL UNSUPPORTED_RESUME} \
                        "AIP_CONTROL_UNSUPPORTED_RESUME: watch interrupted an advanced run mode; use a time-bounded or unlimited run for managed watch continuation"
                }
            }
        }
    } finally {
        dict set ::_aip_control_state depth 0
        dict set ::_aip_control_state mode {}
    }
}

# restore 保留 Tcl 全局值但移除命令：重载后丢弃旧会话深度，按真实 trigger/len 把无人等待的旧请求记为 orphan_id
# （pending_id 只代表仍有调用栈等待的请求），不永久锁住 aip_recover；这里不 force、不推进、不删 watch。
# 活跃调用栈内禁止 reconcile，不能把真实暂停当成过期状态。
proc _aip_control_reconcile {} {
    # native pause 的交互层以 uplevel #0 求值，info level 会变成零；但
    # info frame 仍保留外层真实执行帧，必须检查它而不是仅检查逻辑层级。
    set frame_count [info frame]
    for {set index 1} {$index <= $frame_count} {incr index} {
        set frame [info frame $index]
        if {[dict exists $frame proc] &&
            [namespace tail [dict get $frame proc]] in {_aip_advance _aip_control_pause _aip_control_debug_run _aip_debug_advance}} {
            return -code error -errorcode {AIP CONTROL BUSY} "AIP_CONTROL_BUSY: cannot reconcile an active simulation stack"
        }
    }
    # stdin 是当前进程的外部资源，不是仿真快照状态。正式初始/restore
    # 重载时重置检测缓存，下一次推进重新识别TTY；正常每次推进仍用缓存。
    dict set ::_aip_control_state tty_mode unknown
    dict set ::_aip_control_state tty_probe_error {}
    # debug_active 仅属于当前进程执行栈；无活跃帧时它是 restore 的陈旧值。
    dict set ::_aip_control_state debug_active 0
    dict set ::_aip_control_state debug_event {}
    # 首次加载/正常空闲快照没有需要修复的 Tcl 所有权。此时不读取 HDL，
    # 保留无 debug_access 的旧解析/加载能力；不是吞掉 get 错误。只有确实
    # 存在残留状态时才严格读取桥接寄存器，读失败仍向调用方报错。
    if {[dict get $::_aip_control_state depth] == 0 &&
        [dict get $::_aip_control_state pending_id] eq "" &&
        [dict get $::_aip_control_state orphan_id] eq "" &&
        ![dict get $::_aip_control_state watch_paused] &&
        [llength [dict get $::_aip_control_state events]] == 0} {
        return [aip_sim_status]
    }
    set trigger [_aip_control_scalar [get aip_core_pkg::__tcl_cmd_trigger]]
    set length [_aip_control_scalar [get aip_core_pkg::__tcl_cmd_len]]
    set pending {}
    if {$trigger != 0 || $length != 0} {
        set pending [_aip_control_scalar [get aip_core_pkg::__tcl_cmd_id]]
    }
    dict set ::_aip_control_state depth 0
    dict set ::_aip_control_state mode {}
    dict set ::_aip_control_state watch_paused 0
    dict set ::_aip_control_state pause_reason {}
    dict set ::_aip_control_state pending_id {}
    dict set ::_aip_control_state orphan_id $pending
    return [aip_sim_status]
}
