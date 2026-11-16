# Tcl/UCLI 到 SV 命令桥的用户入口，安全推进由 aip_sim_control.tcl（_aip_advance）负责。
# SV 侧只有单个请求/结果缓冲，本文件按 request ID 串行握手；推进/暂停期间的普通命令改走
# aip_inject.tcl 的独立 FIFO，不覆写原请求/结果。

# 识别 restore：VCS 保留快照内 started、删除命令并丢弃快照后设的 pending，正常重载不会如此。
# 须在本文件重定义 aip_send_cmd 前判断，以兼容无外层 loader 的直接 source。
# 嵌入模式由 .so loader 在 load 前捕获真实 started，免受其初次加载的人工标志误判。
if {(![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded)
    && [info exists ::_aip_bridge_started] && [info commands aip_send_cmd] eq ""} {
    set ::_aip_cmdline_restore_pending 1
}

# 直接 source 时加载依赖模块（只定义、不推进仿真）；二进制模式缺模块即报错，不回退磁盘版本。
proc _aip_load_tcl_module {name entry} {
    if {[info commands $entry] ne ""} { return }
    if {[info exists ::aip_tcl_embedded] && $::aip_tcl_embedded} {
        error "AIP Tcl library is incomplete: missing $entry; rebuild libaip_tcl_bridge.so"
    }
    set candidates {}
    if {[info exists ::env(AIP_CORE)]} {
        lappend candidates [file join $::env(AIP_CORE) src tcl $name]
    }
    catch {
        if {[info script] ne ""} {
            lappend candidates [file join [file dirname [file normalize [info script]]] $name]
        }
    }
    for {set i 1} {$i <= [info frame]} {incr i} {
        catch {
            set frame [info frame $i]
            if {[dict exists $frame file]} {
                lappend candidates [file join [file dirname [dict get $frame file]] $name]
            }
            if {[dict exists $frame cmd] &&
                [regexp {source\s+"?(\S*aip_cmd\.tcl)"?} [dict get $frame cmd] -> path]} {
                lappend candidates [file join [file dirname [string trim $path \" ]] $name]
            }
        }
    }
    foreach relative [list $name [file join src tcl $name] [file join .. .. src tcl $name]] {
        lappend candidates [file join [pwd] $relative]
    }
    foreach path $candidates {
        if {[file isfile $path] && [file readable $path]} {
            uplevel #0 [list source $path]
            if {[info commands $entry] ne ""} { return }
            error "AIP Tcl module '$path' did not define $entry"
        }
    }
    error "AIP Tcl module '$name' not found; set AIP_CORE to the repository root"
}
_aip_load_tcl_module aip_sim_control.tcl _aip_advance
_aip_load_tcl_module aip_watch.tcl aip_watch
_aip_load_tcl_module aip_inject.tcl aip_submit

# VCS get 值（'h/'d/'b/十进制）转整数；无法识别时返回 0。
proc aip_parse_int {vcs_val} {
    set v [string trim $vcs_val]
    if {[regexp {^[0-9]*'h([0-9a-fA-F]+)$} $v _ hex]} {
        return [expr "0x$hex"]
    } elseif {[regexp {^[0-9]*'d([0-9]+)$} $v _ dec]} {
        return $dec
    } elseif {[regexp {^[0-9]*'b([01]+)$} $v _ bin]} {
        set num 0
        foreach bit [split $bin ""] { set num [expr {$num * 2 + $bit}] }
        return $num
    } elseif {[regexp {^(-?[0-9]+)$} $v _ num]} {
        return $num
    }
    return 0
}

# 回显用的调用者路径：source 的子文件由 info script 自动识别；顶层脚本在 -do 模式下启动时
# 自动探测，-i 模式需手动 _aip_set_script "/abs/path/test.tcl"。
if {![info exists ::_aip_script_name]} { set ::_aip_script_name "interactive" }
if {![info exists ::_aip_pwd]} { set ::_aip_pwd [pwd] }

proc _aip_set_script {name} {
    if {$name eq ""} return
    if {[file pathtype $name] eq "absolute"} {
        set ::_aip_script_name $name
    } else {
        set ::_aip_script_name $::_aip_pwd/$name
    }
}

proc _aip_caller_info {} {
    set s [info script]
    if {$s ne "" && [file tail $s] ne "aip_cmd.tcl"} {
        if {[file pathtype $s] eq "absolute"} { return $s }
        return $::_aip_pwd/$s
    }
    return $::_aip_script_name
}

# 任意单位时间统一为 "X.XXX ns"（与 aip_ucli_utils.tcl 一致），不识别则原样返回。
proc _aip_fmt_ns {t} {
    if {![regexp {^\s*([0-9]+(?:\.[0-9]+)?)\s*(fs|ps|ns|us|ms|s)\s*$} $t _ n unit]} {
        return $t
    }
    array set scale_to_ns {fs 1e-6  ps 1e-3  ns 1.0  us 1e3  ms 1e6  s 1e9}
    if {![info exists scale_to_ns($unit)]} { return $t }
    set ns [expr {double($n) * $scale_to_ns($unit)}]
    return [format "%.3f ns" $ns]
}

proc _aip_sim_time {} {
    set raw ""
    if {![catch {set t [senv time]} _]} {
        if {$t ne ""} { set raw $t }
    }
    if {$raw eq ""} {
        set rlen [aip_parse_int [get aip_core_pkg::__tcl_sim_time_len]]
        if {$rlen == 0} { return "0.000 ns" }
        for {set i 0} {$i < $rlen} {incr i} {
            set val [aip_parse_int [get aip_core_pkg::__tcl_sim_time_ascii\[$i\]]]
            append raw [format %c $val]
        }
    }
    return [_aip_fmt_ns $raw]
}

# 命令回显开关，用户可 set ::aip_echo 0 关闭。
if {![info exists ::aip_echo]} { set ::aip_echo 1 }

# ACK 等待的无进展上限（ns）：只计 aip_activity 计数不变的仿真时间，持续有进展的命令一直等到 ACK。
# 默认 52000 = SV watchdog 默认 stall 50000 + 2×poll 1000；需容忍更长的静默段可调大，如 set ::aip_ack_timeout_ns 5000000。
if {![info exists ::aip_ack_timeout_ns]} { set ::aip_ack_timeout_ns 52000 }
if {![info exists ::_aip_cmd_seq]} { set ::_aip_cmd_seq 0 }

# 本次 ACK 的无进展预算（fs）：SV watchdog 启用时不低于 SV 发布的 stall+2×poll，保证其强杀结果先于
# Tcl 放弃到达；watchdog 禁用或旧 SV 未发布配置时即 ::aip_ack_timeout_ns，等待始终有界。
proc _aip_ack_budget_fs {} {
    set budget [_aip_control_time_fs "${::aip_ack_timeout_ns}ns"]
    if {![catch {
        set stall [_aip_control_scalar [get aip_core_pkg::__tcl_cmd_watchdog_stall_ns]]
        set poll [_aip_control_scalar [get aip_core_pkg::__tcl_cmd_watchdog_poll_ns]]
    }] && $stall > 0} {
        set budget [expr {max($budget, ($stall + 2 * $poll) * 1000000)}]
    }
    return $budget
}

# run 推进中的标记：被异常打断时残留为 1，供 settle 区分被打断的 run 与被打断的命令。
if {![info exists ::_aip_interrupted_run]} { set ::_aip_interrupted_run 0 }

# 串行发一个 SV 请求。真正 pause 中改走独立注入槽、不取得原桥 owner；非 pause 的活动回调拒绝重入。
# 普通请求先清注入结果 overlay，避免异常展开后读到旧结果。
proc aip_send_cmd {cmd_str} {
    if {[_aip_control_is_paused_context]} { return [_aip_inject_send $cmd_str] }
    _aip_control_assert_command_allowed
    set ::_aip_inject_last_result {}
    # 全局生命周期操作不能绕过注入票据；完成结果也须显式回收后才可卸载。
    if {[regexp {^\s*(end_test|so_load|so_reload|so_unload)(?:\s|$)} $cmd_str]} {
        _aip_inject_assert_quiescent "execute a lifecycle command"
    }
    # 须在推进前记录调用者，此时调用栈还在。
    set caller [_aip_caller_info]

    # 正常命令结束时 trigger/cmd_len=0、idle=1、free_run=0，任一不符即曾被 Ctrl+C 打断，须 settle。
    # free_run 卡 1 也必须检查，否则 bridge 停在 `#1; continue;` 空转，到不了 wait(trigger==1)。
    set need_settle 0
    if {![aip_parse_int [get aip_core_pkg::__tcl_bridge_idle]]}      { set need_settle 1 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_cmd_trigger]] != 0}  { set need_settle 1 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_cmd_len]] != 0}      { set need_settle 1 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_free_run]] != 0}     { set need_settle 1 }

    if {$need_settle} {
        # 仅处理已异常展开的旧请求；保栈暂停已在函数入口拒绝重入。
        force aip_core_pkg::__tcl_cmd_trigger 0
        force aip_core_pkg::__tcl_cmd_len 32'd0
        force aip_core_pkg::__tcl_free_run 1
        _aip_advance settle 1ns
        force aip_core_pkg::__tcl_free_run 0
        if {$::_aip_interrupted_run} {
            # 被打断的是 run：没有在途命令，无需 aip_recover，下条命令的 trigger+ACK 会重新同步。
            set ::_aip_interrupted_run 0
        } elseif {![aip_parse_int [get aip_core_pkg::__tcl_bridge_idle]]} {
            puts "\033\[33m\[AIP_TCL_BRIDGE\] Auto-resuming after interrupt...\033\[0m"
            aip_recover
        }
    }

    set len [string length $cmd_str]

    # bridge buffer 上限 (aip_tcl_bridge.sv:__tcl_cmd_ascii[0:1023])
    if {$len > 1024} {
        error "aip_send_cmd: cmd length $len exceeds 1024 byte buffer; truncate or split"
    }

    # 单调递增 id：只有 result_id==my_id 才算本命令的 ACK，以免把 TB 别处的 $stop 误认作 ACK。
    incr ::_aip_cmd_seq
    set my_id $::_aip_cmd_seq

    _aip_control_pending_begin $my_id
    set send_code [catch {
        for {set i 0} {$i < $len} {incr i} {
            scan [string index $cmd_str $i] %c ascii
            force aip_core_pkg::__tcl_cmd_ascii\[$i\] 32'd$ascii
        }
        force aip_core_pkg::__tcl_cmd_len 32'd$len
        force aip_core_pkg::__tcl_cmd_id 32'd$my_id
        force aip_core_pkg::__tcl_cmd_trigger 1

        # 只有无进展的仿真时间计入预算（watch 暂停期间的调试推进同样计入）：活动计数一变即重新计时。
        # 每轮先查 ACK，预算耗尽的同一时刻已完成仍取真实结果；收到 ACK 即退出并清 trigger，
        # 不能把其 $stop 当普通断点继续推进。进展基准在首次推进后才取：零耗时命令不多读寄存器，
        # 起点偏晚只会多等（至多一步）。
        set budget [_aip_control_time_fs "${::aip_ack_timeout_ns}ns"]
        set idle 0
        set acked 0
        set advanced 0
        while {1} {
            set ack_id [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
            if {$ack_id == $my_id} { set acked 1; break }
            if {$advanced} { set idle [_aip_control_idle_fs progress] }
            if {$idle >= $budget} {
                # 放弃前计入 SV watchdog 的下限（受理命令时 SV 已重发其配置）。
                set budget [_aip_ack_budget_fs]
                if {$idle >= $budget} { break }
            }
            # 步长取预算的 1/8：ACK 的 $stop 会提前结束推进，步长只决定发现空闲的迟滞（不超过 1/8 预算）
            # 与长命令的往返次数（每个预算 8 次）。
            _aip_advance ack "[expr {min($budget - $idle, max(1, $budget / 8))}]fs"
            set advanced 1
        }
        force aip_core_pkg::__tcl_cmd_trigger 0
        force aip_core_pkg::__tcl_cmd_len 32'd0
    } send_result send_options]
    _aip_control_pending_end $my_id
    if {$send_code} { return -options $send_options $send_result }

    if {!$acked} {
        puts "\033\[31m\[AIP_TCL_BRIDGE\] WARN: cmd $my_id no ack after [expr {$budget / 1000000}]ns without activity progress. result 可能陈旧.\033\[0m"
    }

    if {$::aip_echo} {
        set t [_aip_sim_time]
        puts "\033\[38;5;208m\[tcl_cmd\] ${caller} @ ${t}: $cmd_str\033\[0m"
    }
}

proc aip_read_result {} {
    if {[_aip_inject_has_result]} { return [dict get $::_aip_inject_last_result result] }
    set rlen [aip_parse_int [get aip_core_pkg::__tcl_result_len]]
    set result ""
    for {set i 0} {$i < $rlen} {incr i} {
        set val [aip_parse_int [get aip_core_pkg::__tcl_result_ascii\[$i\]]]
        append result [format %c $val]
    }
    return $result
}

proc aip_check_status {} {
    if {[_aip_inject_has_result]} { return [dict get $::_aip_inject_last_result status] }
    set raw [aip_parse_int [get aip_core_pkg::__tcl_result_status]]
    if {$raw > 0x7FFFFFFF} {
        return [expr {$raw - 0x100000000}]
    }
    return $raw
}

proc _aip_result_known {} {
    if {[_aip_inject_has_result]} { return 1 }
    if {[catch {get aip_core_pkg::__tcl_result_known} raw]} { return -1 }
    return [expr {[aip_parse_int $raw] != 0}]
}

# 读运行期 plusarg（+name=value）；未传时返回空串且 status=1，需区分时再查 aip_check_status。
proc aip_getparam {name} {
    aip_send_cmd "get_param name=$name"
    return [aip_read_result]
}

# 按 info complete 切成语法完整的块，供 aip_source/aip_run_self 逐块执行。
proc _aip_parse_blocks {script} {
    set blocks {}
    set buf ""
    foreach line [split $script "\n"] {
        append buf "$line\n"
        if {[info complete $buf]} {
            if {[string trim $buf] ne ""} { lappend blocks $buf }
            set buf ""
        }
    }
    if {[string trim $buf] ne ""} { lappend blocks $buf }
    return $blocks
}

# 把每帧未执行的块写到 <base>_left<ext>（覆盖同名文件）；出错时自动调用，Ctrl+C 后也可手动执行。
proc aip_flush_left {} {
    if {[llength $::_aip_source_stack] == 0} {
        puts "\[AIP_SOURCE\] no active script to flush"
        return
    }

    foreach frame $::_aip_source_stack {
        set path [dict get $frame path]
        set blocks [dict get $frame blocks]
        set idx [dict get $frame idx]
        set total [llength $blocks]

        if {$idx >= $total} continue

        set dir [file dirname $path]
        set base [file rootname [file tail $path]]
        set ext [file extension $path]
        set left "$dir/${base}_left$ext"

        set fh [open $left w]
        puts $fh "# Auto-generated leftover from interrupted: $path"
        puts $fh "# Resume blocks: [expr {$idx+1}]..$total of [llength $blocks]"
        puts $fh "# Generated @ [clock format [clock seconds]]"
        puts $fh ""
        for {set i $idx} {$i < $total} {incr i} {
            puts $fh [lindex $blocks $i]
        }
        close $fh
        puts "\033\[32m\[AIP_SOURCE\] flushed $left ([expr {$total - $idx}] blocks)\033\[0m"
    }
}

# 旧式错误块重放（新脚本直接 source/-do 即可保栈续跑）：逐块执行，出错（含 Ctrl+C）即写出
# _left 续跑文件并中断，跑完删除 _left。不恢复 Tcl 调用栈。
proc aip_source {name} {
    if {[file pathtype $name] eq "absolute"} {
        set abs $name
    } elseif {[llength $::_aip_source_stack] > 0} {
        set parent [lindex $::_aip_source_stack end]
        set abs [file join [file dirname [dict get $parent path]] $name]
    } elseif {$::_aip_last_script_dir ne "" && \
              [file exists [file join $::_aip_last_script_dir $name]]} {
        set abs [file join $::_aip_last_script_dir $name]
    } else {
        set abs [file normalize $name]
    }

    if {![file exists $abs]} {
        error "aip_source: file not found: $abs"
    }

    set fh [open $abs r]
    set script [read $fh]
    close $fh
    set blocks [_aip_parse_blocks $script]
    set total [llength $blocks]

    set frame [dict create path $abs blocks $blocks idx 0]
    lappend ::_aip_source_stack $frame
    set ::_aip_last_script_dir [file dirname $abs]

    set ok 1
    while 1 {
        set top [lindex $::_aip_source_stack end]
        set idx [dict get $top idx]
        if {$idx >= $total} break

        set block [lindex $blocks $idx]
        if {[catch {uplevel #0 $block} err]} {
            puts "\033\[31m\[AIP_SOURCE\] interrupted at block [expr {$idx+1}]/$total of $abs\033\[0m"
            puts "\033\[31m\[AIP_SOURCE\] error: $err\033\[0m"
            aip_flush_left
            set ok 0
            break
        }

        set top [dict replace $top idx [expr {$idx + 1}]]
        lset ::_aip_source_stack end $top
    }

    set ::_aip_source_stack [lrange $::_aip_source_stack 0 end-1]

    # 跑完无错：续跑的 _left 文件删自身，普通文件删残留的 <base>_left<ext>。
    if {$ok} {
        set dir [file dirname $abs]
        set base [file rootname [file tail $abs]]
        set ext [file extension $abs]

        if {[string match "*_left" $base]} {
            if {[file exists $abs]} {
                file delete -force $abs
                puts "\033\[32m\[AIP_SOURCE\] completed; removed $abs\033\[0m"
            }
        } else {
            set left "$dir/${base}_left$ext"
            if {[file exists $left]} {
                file delete -force $left
                puts "\033\[32m\[AIP_SOURCE\] completed; removed $left\033\[0m"
            }
        }
        return 1
    }

    # 向上抛错，让嵌套的父 aip_source 也中断并 flush，而不是当作子脚本成功继续执行。
    error "aip_source: interrupted in $abs"
}

# 旧式 -do 入口：脚本 source aip_cmd.tcl 后调用一行，由本 proc 逐块执行脚本中此调用之后的部分；
# 同目录存在 <base>_left<ext> 时改从它续跑。
proc aip_run_self {} {
    if {$::_aip_script_name eq "" || $::_aip_script_name eq "interactive"} {
        puts "\033\[31m\[AIP_SOURCE\] aip_run_self: cannot detect script path (use -do mode)\033\[0m"
        return -code error "aip_run_self: no script path"
    }

    set self_path $::_aip_script_name
    set dir [file dirname $self_path]
    set base [file rootname [file tail $self_path]]
    set ext [file extension $self_path]
    set left "$dir/${base}_left$ext"

    if {[file exists $left]} {
        puts "\033\[33m\[AIP_SOURCE\] detected leftover $left; resuming from it\033\[0m"
        puts "\033\[33m\[AIP_SOURCE\] to ignore and restart fresh, rm $left and re-run\033\[0m"
        aip_source $left
        return -code return
    }

    set fh [open $self_path r]
    set script [read $fh]
    close $fh
    set blocks [_aip_parse_blocks $script]
    set total [llength $blocks]

    set body_start -1
    for {set i 0} {$i < $total} {incr i} {
        if {[string first "aip_run_self" [lindex $blocks $i]] >= 0} {
            set body_start [expr {$i + 1}]
            break
        }
    }
    if {$body_start < 0} {
        set body_start 0
    }

    set frame [dict create path $self_path blocks $blocks idx $body_start]
    lappend ::_aip_source_stack $frame
    set ::_aip_last_script_dir $dir

    set ok 1
    while 1 {
        set top [lindex $::_aip_source_stack end]
        set idx [dict get $top idx]
        if {$idx >= $total} break

        set block [lindex $blocks $idx]
        if {[catch {uplevel #0 $block} err]} {
            puts "\033\[31m\[AIP_SOURCE\] interrupted at block [expr {$idx+1}]/$total of $self_path\033\[0m"
            puts "\033\[31m\[AIP_SOURCE\] error: $err\033\[0m"
            aip_flush_left
            set ok 0
            break
        }

        set top [dict replace $top idx [expr {$idx + 1}]]
        lset ::_aip_source_stack end $top
    }

    set ::_aip_source_stack [lrange $::_aip_source_stack 0 end-1]

    if {$ok && [file exists $left]} {
        file delete -force $left
        puts "\033\[32m\[AIP_SOURCE\] completed; removed $left\033\[0m"
    }

    # 终止外层 source, 防 body 二次 eval
    return -code return
}

proc aip_source_status {} {
    if {[llength $::_aip_source_stack] == 0} {
        return "(empty)"
    }
    set lines {}
    foreach frame $::_aip_source_stack {
        set path [dict get $frame path]
        set idx [dict get $frame idx]
        set total [llength [dict get $frame blocks]]
        lappend lines "  $path: $idx/$total"
    }
    # join 已被覆写为 fork/join 关键字，列表拼接须用保留的原生 _tcl_join。
    return [_tcl_join $lines "\n"]
}

# Runtime parameter override: set_param {<"path value" lines>} ({} protects [] and special chars)
# or set_param path=P value=V; clear_param path=P clears one, bare clear_param clears all.
proc set_param {args} {
    if {[llength $args] == 1} {
        set content [lindex $args 0]
        if {[string first "\n" $content] >= 0 || [string first "=" $content] < 0} {
            # Block mode: each line is "path value". Accumulate per-line failures
            # so a mid-block error isn't masked by a later OK line.
            set ok_count 0
            set fail_count 0
            set fail_msgs ""
            foreach line [split $content "\n"] {
                set line [string trim $line]
                if {$line eq "" || [string index $line 0] eq "#"} continue
                if {[regexp {^(\S+)\s+(.+)$} $line _ path value]} {
                    set value [string trim $value]
                    aip_send_cmd "set_param path=$path value=$value"
                    set st [aip_check_status]
                    if {$st != 0} {
                        incr fail_count
                        append fail_msgs "  $path -> $value (status=$st): [aip_read_result]\n"
                    } else {
                        incr ok_count
                    }
                }
            }
            if {$fail_count > 0} {
                return "set_param block: $ok_count ok, $fail_count fail:\n$fail_msgs"
            }
            return "set_param block: $ok_count ok"
        }
    }
    # Single param mode: set_param path=xxx value=xxx
    set full_cmd "set_param"
    foreach a $args { append full_cmd " $a" }
    aip_send_cmd $full_cmd
    return [aip_read_result]
}

proc clear_param {args} {
    if {[llength $args] == 0} {
        aip_send_cmd "clear_param"
    } else {
        set full_cmd "clear_param"
        foreach a $args { append full_cmd " $a" }
        aip_send_cmd $full_cmd
    }
    return [aip_read_result]
}

# SV-like fork/join: "fork cmd1, cmd2 join" on one line, or a bare fork, one command per line,
# then join (wait all) / join_any [disable_remaining=1] (wait first) / join_none (don't wait).
if {![info exists ::_aip_fork_mode]} { set ::_aip_fork_mode 0 }
if {![info exists ::_aip_fork_cmds]} { set ::_aip_fork_cmds {} }

# aip_source 栈：每帧 dict {path <abs> blocks <list> idx <int>}，栈顶为当前执行的脚本。
if {![info exists ::_aip_source_stack]} { set ::_aip_source_stack {} }
if {![info exists ::_aip_last_script_dir]} { set ::_aip_last_script_dir "" }

# Keep Tcl's list join as _tcl_join; join is redefined below for fork blocks.
if {[info commands _tcl_join] eq ""} {
    rename join _tcl_join
}

# 单行 fork 直接派发，空参数启动旧式多行收集；暂停中两者都不得改写收集状态。
proc fork {args} {
    _aip_control_assert_idle fork
    if {[llength $args] == 0} {
        set ::_aip_fork_mode 1
        set ::_aip_fork_cmds {}
    } else {
        aip_send_cmd "fork $args"
    }
}

# 结束当前收集并同步等待；非fork模式保留Tcl原生list join，不施加推进限制。
proc join {args} {
    if {$::_aip_fork_mode} {
        _aip_control_assert_idle join
        set ::_aip_fork_mode 0
        set cmd_str "fork [_tcl_join $::_aip_fork_cmds ", "] join"
        aip_send_cmd $cmd_str
    } else {
        return [_tcl_join {*}$args]
    }
}

# 派发当前批次并等待首个完成，保留disable_remaining参数；暂停态不清收集表。
proc join_any {args} {
    _aip_control_assert_idle join_any
    if {!$::_aip_fork_mode} {
        puts "\[AIP_TCL\] Error: join_any without fork"
        return
    }
    set ::_aip_fork_mode 0
    set cmd_str "fork [_tcl_join $::_aip_fork_cmds ", "] join_any"
    if {[llength $args] > 0 && [lindex $args 0] eq "disable_remaining=1"} {
        append cmd_str " disable_remaining=1"
    }
    aip_send_cmd $cmd_str
}

# 派发已收集批次且不等业务完成，框架ACK仍须串行；失败前不得覆盖收集状态。
proc join_none {} {
    _aip_control_assert_idle join_none
    if {!$::_aip_fork_mode} {
        puts "\[AIP_TCL\] Error: join_none without fork"
        return
    }
    set ::_aip_fork_mode 0
    set cmd_str "fork [_tcl_join $::_aip_fork_cmds ", "] join_none"
    aip_send_cmd $cmd_str
}

# Unknown Tcl commands go to the SV bridge (inside a fork block they are collected instead).
if {[info commands _original_unknown] eq ""} {
    rename unknown _original_unknown
}

proc unknown {cmd args} {
    if {$args ne ""} {
        set full_cmd "$cmd $args"
    } else {
        set full_cmd $cmd
    }

    if {$::_aip_fork_mode} {
        _aip_control_assert_idle "collect a fork command"
        lappend ::_aip_fork_cmds $full_cmd
        return
    }

    # 快速失败：不在启动缓存的 SV 注册表中的命令跳过会推进仿真的 SV 握手，直接试原生 Tcl。
    # 缓存未建（老 SV）或运行时加载过 .so 插件（注册表已变）时不走此路，全部 SV-first。
    if {[info exists ::_aip_known_cmds] && ![info exists ::_aip_dynamic_cmds] \
            && ![dict exists $::_aip_known_cmds $cmd]} {
        if {![catch {_original_unknown $cmd {*}$args} ucli_result]} {
            return $ucli_result
        }
        error "invalid command name \"$cmd\""
    }

    # SV 优先，防止 UCLI 内置命令经 alias/前缀/auto_load 静默抢词；SV 是否认识由 known 位判断，
    # 老 bridge 无该寄存器时沿用 status=-1 表示未知。
    aip_send_cmd $full_cmd
    set known [_aip_result_known]
    set status [aip_check_status]
    if {$known == 1 || ($known < 0 && $status != -1)} {
        # 插件 load/reload 改变了 SV 注册表，此后关闭快速失败。
        if {$cmd eq "so_load" || $cmd eq "so_reload"} { set ::_aip_dynamic_cmds 1 }
        return [aip_read_result]
    }

    if {![catch {_original_unknown $cmd {*}$args} ucli_result]} {
        return $ucli_result
    }

    error "invalid command name \"$cmd\""
}

# 原生 run 改名 _vcs_run 供推进层使用（重复加载不再 rename）。resume 保持 VCS 原生，
# 因为默认 onbreak 按名称调用它，不能夹带桥接清理副作用。
if {[info commands _vcs_run] eq ""} {
    rename run _vcs_run
}
# 参数原样交给控制层，成功后显示实际起止时间并返回空值，内部推进字典不公开。
# 出错时保留诊断标记并传播错误；暂停中只做有限调试推进，不改原请求状态、不恢复原 Tcl 栈。
proc run {args} {
    # 记录入口上下文：普通 run 途中暂停再 resume 后，不应误报原脚本仍暂停。
    set paused [_aip_control_is_paused_context]
    if {$paused} {
        # 只消费调试推进已有的 fs 时间快照；不修改原 run 的期限、owner 或标记。
        set result [_aip_advance run {*}$args]
        set before [_aip_fmt_ns "[dict get $result before]fs"]
        set after [_aip_fmt_ns "[dict get $result after]fs"]
    } else {
        _aip_control_assert_idle run
        set before [_aip_sim_time]

        # free_run 让空闲 bridge 持续让出仿真时间，避免空闲握手干扰推进。
        set ::_aip_interrupted_run 1
        force aip_core_pkg::__tcl_free_run 1
        _aip_advance run {*}$args
        force aip_core_pkg::__tcl_free_run 0
        set ::_aip_interrupted_run 0

        # 下次请求的 trigger 会自然唤醒 bridge；这里不得额外推进到 $stop。
        set after [_aip_sim_time]
    }

    set command [string trimright "run [_tcl_join $args { }]"]
    puts [_aip_colorize "\[AIP\] $command: $before -> $after" cyan]
    if {$paused} {
        # VCS UCLI 在 UTF-8 locale 下也可能把中文输出成问号，故提示用 ASCII。
        puts [_aip_colorize "\[AIP\] Original script remains paused; enter resume to continue." cyan]
    }
    return
}

# deprecated：仅清理异常展开后的桥状态，不恢复 Tcl 栈、不重放脚本、不等待业务完成；
# 保留给非 TTY 中断、restore 孤立桥和旧脚本，新脚本不应调用。保栈暂停中须用原生 resume，
# 此时清 cmd_len 会破坏当前请求，故入口守卫须先于任何 force。
proc aip_recover {args} {
    _aip_control_assert_idle aip_recover
    # args 仅为兼容旧 "resume max_iter <N>" 调用，已忽略。
    force aip_core_pkg::__tcl_free_run 0
    force aip_core_pkg::__tcl_cmd_len 32'd0
    set ::_aip_interrupted_run 0
    set t [_aip_sim_time]
    puts "\033\[32m\[AIP_TCL_BRIDGE\] Bridge state recovered @ $t; no script replayed.\033\[0m"
}

puts "============================================"
puts " AIP Command TCL Bridge loaded"
puts " Supports: direct commands, fork/join blocks"
puts "============================================"

# -do 模式从 info frame 的 -dofile 参数取顶层脚本路径；-i 模式取不到，保持 "interactive"。
for {set _i 1} {$_i <= [info frame]} {incr _i} {
    catch {
        set _f [info frame $_i]
        if {[dict exists $_f cmd]} {
            if {[regexp {\-dofile\s+(\S+)} [dict get $_f cmd] _ _path]} {
                _aip_set_script [string trim $_path "\""]
            }
        }
    }
}
catch {unset _i _f _path}

# 读回 bridge 启动时写入 __tcl_cmd_names_ascii[] 的命令表（只 get、不推进），供 unknown 快速失败。
proc _aip_load_known_cmds {} {
    # 老 SV 无此寄存器时 get 报错：须静默返回、不建表（unknown 退回 SV-first），以免中断 source。
    if {[catch {aip_parse_int [get aip_core_pkg::__tcl_cmd_names_len]} n]} return
    if {$n <= 0} return
    set s ""
    for {set i 0} {$i < $n} {incr i} {
        if {[catch {aip_parse_int [get aip_core_pkg::__tcl_cmd_names_ascii\[$i\]]} v]} return
        append s [format %c $v]
    }
    set ::_aip_known_cmds [dict create]
    foreach name [split $s ","] {
        set name [string trim $name]
        if {$name ne ""} { dict set ::_aip_known_cmds $name 1 }
    }
}

# restore 后的参数源失效请求（CLI 由 SV 首次查询时枚举）；只读写后门寄存器，不推进仿真。
# 请求取恢复后 ACK 的反值，不依赖会随快照回滚的序号，重复恢复或已刷新过的快照都适用。
# readback 一致才清 pending；缺寄存器、X/Z 或写入失败均报错并保留标记，供重新 source 重试。
proc _aip_cmdline_restore_refresh {} {
    if {![info exists ::_aip_cmdline_restore_pending] || !$::_aip_cmdline_restore_pending} { return }
    set ack [_aip_control_scalar [get aip_core_pkg::__aip_cmdline_refresh_ack]]
    if {$ack ni {0 1}} { error "AIP_CMDLINE_REFRESH: invalid acknowledge bit '$ack'" }
    set request [expr {1 - $ack}]
    force aip_core_pkg::__aip_cmdline_refresh_request "1'b$request"
    set actual [_aip_control_scalar [get aip_core_pkg::__aip_cmdline_refresh_request]]
    if {$actual != $request} { error "AIP_CMDLINE_REFRESH: request readback mismatch" }
    set ::_aip_cmdline_restore_pending 0
}

# 须先于任何 bootstrap/reconcile 执行；.so 模式由二进制 loader 在 load 返回后调用同一钩子。
if {![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded} {
    _aip_cmdline_restore_refresh
}

# 推进到 bridge 的 initial $stop；只做一次，二次 source 时已过该点，再推进会挂住。
if {![info exists ::_aip_bridge_started]} {
    set ::_aip_bridge_started 1
    _aip_advance bootstrap
    catch { _aip_load_known_cmds }   ;# 双保险: 任何失败都不许崩 source
}

# 启动或 restore 重载后核对控制层孤立状态；.so 加载期间不能触发桥行为，
# 改由 aip_init_so.tcl 在 load 及独立启动之后核对。
if {![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded} {
    _aip_control_reconcile
}

# 加载 aip_checkpoint.tcl：VCS -do 模式下 info script 常返空，故优先 $env(AIP_CORE)，
# 再退 info script 所在目录；缺文件不报错（后向兼容）。
proc _aip_load_checkpoint {} {
    # Binary mode embeds this implementation in libaip_tcl_bridge.so; never source a disk copy.
    if {[info exists ::aip_tcl_embedded] && $::aip_tcl_embedded} {
        return
    }
    set candidates {}
    if {[info exists ::env(AIP_CORE)]} {
        lappend candidates [file join $::env(AIP_CORE) src tcl aip_checkpoint.tcl]
    }
    catch {
        set d [file dirname [info script]]
        if {$d ne "" && $d ne "."} {
            lappend candidates [file join $d aip_checkpoint.tcl]
        }
    }
    foreach f $candidates {
        if {[file exists $f]} { source $f; return }
    }
}
catch { _aip_load_checkpoint }
