# src/tcl：Tcl/UCLI 到 SV 命令桥的用户入口与兼容脚本重放层。
# package 持有单个请求/结果缓冲，本文件按 request ID 串行握手；仿真推进和
# 暂停期间普通命令改走 aip_inject.tcl 的独立FIFO，不覆写原请求/结果；
# 安全推进由 aip_sim_control.tcl 负责。原生 resume 不得被覆盖。
# 公开 run 只展示实际推进前后的时间并返回空值，内部推进字典仍归控制层调用者。
# 新脚本直接 source/-do 即可保栈续跑；aip_source/aip_run_self 只保留旧的
# 错误块重放能力，不代表恢复 Tcl 调用栈。二进制分发由 .so 内嵌全部实现。
# 正式 restore 后，参数源失效请求由本层在仿真推进前发出；真实 CLI 枚举由 SV 首次查询执行。

# 历史直接 source 用户没有外层 loader，也须在本文件重新定义 aip_send_cmd 前识别恢复。
# VCS 保留快照内 started、删除命令并丢弃快照后新设的 pending；此状态组合不会命中正常重载。
# 嵌入模式必须由 .so loader 在 load 前捕获真实 started，避免其初次加载的人工标志误判。
if {(![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded)
    && [info exists ::_aip_bridge_started] && [info commands aip_send_cmd] eq ""} {
    set ::_aip_cmdline_restore_pending 1
}

# 为历史直接 source aip_cmd.tcl 的用户定位必要模块。这里只加载定义，不能
# 推进仿真；二进制模式缺模块必须报错，禁止悄悄回退到磁盘上的其他版本。
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

# ---------- Helper: parse VCS get value to integer ----------
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

# ---------- 获取 TCL 调用者信息（绝对路径）----------
# source 子文件自动切换（info script）；顶层脚本需 _aip_set_script
# 用法：_aip_set_script [file normalize [info script]]   ;# -do 模式自动
#       _aip_set_script "/abs/path/test.tcl"              ;# -i 模式手动
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
    # source 子文件：info script 自动返回当前文件
    set s [info script]
    if {$s ne "" && [file tail $s] ne "aip_cmd.tcl"} {
        if {[file pathtype $s] eq "absolute"} { return $s }
        return $::_aip_pwd/$s
    }
    return $::_aip_script_name
}

# ---------- 统一时间格式化: 任意单位 → "X.XXX ns" ----------
proc _aip_fmt_ns {t} {
    if {![regexp {^\s*([0-9]+(?:\.[0-9]+)?)\s*(fs|ps|ns|us|ms|s)\s*$} $t _ n unit]} {
        return $t
    }
    array set scale_to_ns {fs 1e-6  ps 1e-3  ns 1.0  us 1e3  ms 1e6  s 1e9}
    if {![info exists scale_to_ns($unit)]} { return $t }
    set ns [expr {double($n) * $scale_to_ns($unit)}]
    return [format "%.3f ns" $ns]
}

# ---------- 获取仿真时间 ----------
# 优先 UCLI 原生 senv time, 兜底 SV __tcl_sim_time_ascii[]
# 统一格式 "X.XXX ns" (跟 aip_ucli_utils.tcl 对齐)
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

# ---------- 命令回显控制 ----------
# 0=关闭  1=开启（用户可 set ::aip_echo 0 关闭）
if {![info exists ::aip_echo]} { set ::aip_echo 1 }

# ---------- cmd_id ack 握手参数 ----------
# bounded retry: 每 iter _vcs_run 100ns + 检查 result_id 匹配
# 默认 50us cap (500 iter). 长 cmd 用户脚本可调:
#   set ::aip_ack_timeout_ns 5000000   ;# 5ms
if {![info exists ::aip_ack_timeout_ns]} { set ::aip_ack_timeout_ns 50000 }
if {![info exists ::_aip_cmd_seq]} { set ::_aip_cmd_seq 0 }

# run proc 进出标记: run 用 free_run 推进, Ctrl+C 打断会留 free_run=1 残留.
# settle 用此标记区分 "run 被打断"(无 pending seq, 只 settle) 与
# "命令 seq 被打断"(需 aip_recover 清理). 新保栈暂停不会展开当前调用栈。
if {![info exists ::_aip_interrupted_run]} { set ::_aip_interrupted_run 0 }

# 发一个串行SV请求；真正pause中的临时调用走独立注入槽，不取得原桥owner。
# 活动回调但非pause仍拒绝重入；新普通请求清overlay，避免异常展开后读旧结果。
proc aip_send_cmd {cmd_str} {
    if {[_aip_control_is_paused_context]} { return [_aip_inject_send $cmd_str] }
    _aip_control_assert_command_allowed
    set ::_aip_inject_last_result {}
    # 全局生命周期操作不能绕过注入票据；完成结果也须显式回收后才可卸载。
    if {[regexp {^\s*(end_test|so_load|so_reload|so_unload)(?:\s|$)} $cmd_str]} {
        _aip_inject_assert_quiescent "execute a lifecycle command"
    }
    # 记录调用者信息（在 run 之前，栈还在）
    set caller [_aip_caller_info]

    # 状态检测: 任一异常 → Ctrl+C 中断过, 必 settle.
    # 正常 cmd 末尾 cleanup 把 trigger 和 cmd_len 都置 0, idle=1, free_run=0.
    # Ctrl+C 中断 _vcs_run 后:
    #   - 中断 aip_send_cmd 内部: trigger=1, cmd_len=N, idle 可能 0
    #   - 中断 run proc 内部:    free_run=1 (force=0 那行没执行), bridge 永远空转
    # free_run 卡 1 必检, 否则 bridge 在 `#1; continue;` 不到 wait(trigger==1), 新 cmd 永远不被处理.
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
            # 被打断的是 run (free_run 推进), 非命令 seq. 无 pending seq 可排,
            # 不触发恢复清理，因为这个旧 run 没有在途命令。
            # 仅 settle, 下条 cmd 的 trigger+ack 重新同步.
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

    # 分配单调递增 id, SV bridge 处理完写 result_id, TCL 检查 result_id==my_id
    # 才确认 _vcs_run 返回是我们这条 cmd 的 ack (非 chip TB 别处 $stop 抢先).
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

        # 有界 ACK 等待。推进层在 watch 处保栈暂停，返回后继续校验同一 ID；
        # 已有 ACK 必须先清 trigger，不能把其 $stop 当成一般断点继续推进。
        # 期限在首次推进前固定；调试注入推进的时间也必须计入原请求，不可
        # 每次resume再增加若干重试窗口。ACK先检查，过期但已完成仍取真实结果。
        set ack_deadline [expr {[_aip_control_now_fs]+[_aip_control_time_fs "${::aip_ack_timeout_ns}ns"]}]
        set acked 0
        while {1} {
            set ack_id [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
            if {$ack_id == $my_id} { set acked 1; break }
            set remaining [expr {$ack_deadline-[_aip_control_now_fs]}]
            if {$remaining <= 0} { break }
            _aip_advance ack "[expr {min($remaining,100000000)}]fs"
        }
        force aip_core_pkg::__tcl_cmd_trigger 0
        force aip_core_pkg::__tcl_cmd_len 32'd0
    } send_result send_options]
    _aip_control_pending_end $my_id
    if {$send_code} { return -options $send_options $send_result }

    if {!$acked} {
        puts "\033\[31m\[AIP_TCL_BRIDGE\] WARN: cmd $my_id no ack after ${::aip_ack_timeout_ns}ns. result 可能陈旧.\033\[0m"
    }

    # UVM 风格回显：[tcl_cmd] file(line) @ time: command
    if {$::aip_echo} {
        set t [_aip_sim_time]
        puts "\033\[38;5;208m\[tcl_cmd\] ${caller} @ ${t}: $cmd_str\033\[0m"
    }
}

# ---------- Read result string from SV ----------
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

# ---------- Read execution status ----------
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

# ---------- aip_getparam <name> ----------
# 便捷读运行期 plusarg (+name=value): 封 get_param 命令 (send + read_result).
# 返回值字符串; 未传该 plusarg 时命令 status=1 且返回空串 (需辨则接着 aip_check_status).
proc aip_getparam {name} {
    aip_send_cmd "get_param name=$name"
    return [aip_read_result]
}

# ---------- 解析 TCL 脚本为 block list (语法完整单元) ----------
# 用 info complete 切分. 空 block (string trim 后空) 不入. 残尾不完整作最后一 block.
# 用于 aip_source / aip_run_self 的 block-level 跟踪执行.
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

# ---------- aip_flush_left: 把 stack 每帧未执行 blocks 写到 <base>_left<ext> ----------
# 自动 catch 路径调; 手动入口也行 (用户 Ctrl+C 后输 aip_flush_left).
# 覆盖式: 同名文件直接重写.
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

# ---------- aip_source <name>: 加载 + block-level 跟踪执行 TCL 文件 ----------
# 路径解析优先级:
#   1. 绝对路径 → 用之
#   2. 嵌套 (栈非空) → 相对栈顶 path 的 dir
#   3. last_script_dir 缓存非空且其下存在 name → 用之
#   4. 兜底 → [file normalize $name] (相对 pwd)
# 成功打开后更新 last_script_dir.
# 跑完无错 → 删除 <base>_left<ext>.
# 中途 catch 异常 (Ctrl+C / error) → aip_flush_left + break.
proc aip_source {name} {
    # 路径解析
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

    # 读 + parse
    set fh [open $abs r]
    set script [read $fh]
    close $fh
    set blocks [_aip_parse_blocks $script]
    set total [llength $blocks]

    # push frame
    set frame [dict create path $abs blocks $blocks idx 0]
    lappend ::_aip_source_stack $frame
    set ::_aip_last_script_dir [file dirname $abs]

    # 顺序 eval, catch 包裹
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

        # idx++ (回写 dict 到栈顶)
        set top [dict replace $top idx [expr {$idx + 1}]]
        lset ::_aip_source_stack end $top
    }

    # pop
    set ::_aip_source_stack [lrange $::_aip_source_stack 0 end-1]

    # 跑完无错 → 清 _left
    # case 1: abs 是 _left 文件 (续跑完) → 删 abs 自身
    # case 2: abs 是普通文件 (首次跑完) → 删可能存在的 <base>_left<ext> 残留
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

    # 子 aip_source 失败 → 把 error 上抛, 让父 aip_source 的 catch 也命中, 父亦中断 + flush.
    # 否则父会"以为"子成功, 继续跑后续 block.
    error "aip_source: interrupted in $abs"
}

# ---------- aip_run_self: -do 入口接管 + 自检 _left 续跑 ----------
# 用户在 xxx.tcl 内 source aip_cmd.tcl 后调本 proc 一行, 接管剩余 body 执行.
# 行为:
#   1. 取 $::_aip_script_name 作为脚本路径 (aip_cmd.tcl 已识别)
#   2. 检查同 dir 下 <base>_left<ext>: 存在 → 提示 + 切换 source 到 _left
#   3. 否则 → 跑自身, body 起点 = 含 "aip_run_self" 字串的首个 block 之后
#   4. 走 aip_source 同样的 block 顺序 eval + catch + flush + cleanup
#   5. return -code return 终止外层 source, 防止 body 被再次 eval
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

    # 检 _left 续跑
    if {[file exists $left]} {
        puts "\033\[33m\[AIP_SOURCE\] detected leftover $left; resuming from it\033\[0m"
        puts "\033\[33m\[AIP_SOURCE\] to ignore and restart fresh, rm $left and re-run\033\[0m"
        aip_source $left
        return -code return
    }

    # 跑自身, 跳 header
    set fh [open $self_path r]
    set script [read $fh]
    close $fh
    set blocks [_aip_parse_blocks $script]
    set total [llength $blocks]

    # 找 "aip_run_self" 首次出现的 block idx (body 起点 = idx + 1)
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

    # push frame, idx = body_start
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

# ---------- aip_source_status: 调试用 ----------
# 返回 stack 状态字符串. 空栈 → "(empty)"; 否则每帧一行 "<path>: <idx>/<total>".
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
    # 注意: 用 _tcl_join (rename 保留的 TCL 原生 join), 因 aip_cmd.tcl 覆写了 join 为 fork/join 关键字.
    return [_tcl_join $lines "\n"]
}

# ============================================================
# Multi-line fork/join syntax (SV-like)
#
# Usage (multi-line, like SV):
#   fork
#       cmd1 arg1=val1
#       cmd2 arg2=val2
#       cmd3
#   join                          ;# wait all
#   join_any                      ;# wait first
#   join_any disable_remaining=1  ;# wait first, kill rest
#   join_none                     ;# don't wait
#
# Usage (single-line, also supported):
#   fork cmd1, cmd2, cmd3 join
# ============================================================

# ============================================================
# set_param / clear_param — runtime parameter override
#
# Block mode ({} protects [] and special chars):
#   set_param {
#       axi.wr.addr  [1:10]
#       axi.wr.data  0xFF
#       axi.wr.len   1,2,4,8
#       axi.wr.mode  BURST
#       eth.pkt_len  {64:=30,128:=50,1500:=20}
#   }
#
# Single param mode:
#   set_param path=axi.wr.addr value=0x100
#
# Clear:
#   clear_param path=axi.wr.addr    ;# clear one
#   clear_param                      ;# clear all
# ============================================================

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

# ============================================================
# Multi-line fork/join
# ============================================================

if {![info exists ::_aip_fork_mode]} { set ::_aip_fork_mode 0 }
if {![info exists ::_aip_fork_cmds]} { set ::_aip_fork_cmds {} }

# ---------- aip_source 续跑机制全局状态 ----------
# stack: list of dict {path <abs> blocks <list> idx <int>}, top = 当前执行的脚本
if {![info exists ::_aip_source_stack]} { set ::_aip_source_stack {} }
# last_script_dir: 最近成功 source 的 dir, 用于 aip_source 仅传 name 时的路径解析
if {![info exists ::_aip_last_script_dir]} { set ::_aip_last_script_dir "" }

# Save original TCL join (list join function)
if {[info commands _tcl_join] eq ""} {
    rename join _tcl_join
}

# 单行fork直接派发，空参数启动旧多行收集；两者都不能在暂停中改写收集状态。
proc fork {args} {
    _aip_control_assert_idle fork
    if {[llength $args] == 0} {
        # Multi-line mode: start collecting commands
        set ::_aip_fork_mode 1
        set ::_aip_fork_cmds {}
    } else {
        # Single-line mode: fork cmd1, cmd2 join → send directly
        aip_send_cmd "fork $args"
    }
}

# 结束当前收集并同步等待；非fork模式保留Tcl原生list join，不施加推进限制。
proc join {args} {
    if {$::_aip_fork_mode} {
        _aip_control_assert_idle join
        # End multi-line fork block — wait all
        set ::_aip_fork_mode 0
        set cmd_str "fork [_tcl_join $::_aip_fork_cmds ", "] join"
        aip_send_cmd $cmd_str
    } else {
        # Original TCL join (list operation)
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

# ---------- Override unknown for seamless forwarding ----------
if {[info commands _original_unknown] eq ""} {
    rename unknown _original_unknown
}

proc unknown {cmd args} {
    if {$args ne ""} {
        set full_cmd "$cmd $args"
    } else {
        set full_cmd $cmd
    }

    # Fork mode: collect commands instead of executing
    if {$::_aip_fork_mode} {
        _aip_control_assert_idle "collect a fork command"
        lappend ::_aip_fork_cmds $full_cmd
        return
    }

    # 未注册命令快速失败: 本地查启动缓存的 SV 注册表 (后门 get 读, 零握手).
    # 不在表里 → 跳过 SV 握手 (省掉一次 sim-advancing ack 等待), 直接试 native
    # TCL, 再 fail. dict 未就绪 (老 SV / 读不到) → 落到下面原 SV-first 流程兜底.
    # 一旦运行时加载过 .so 插件 (aip_soload), 注册表会动态增删, 启动缓存的 dict
    # 不再权威 → 跳过快速失败, 全部走下面 SV-first (多一次握手换正确性)。
    if {[info exists ::_aip_known_cmds] && ![info exists ::_aip_dynamic_cmds] \
            && ![dict exists $::_aip_known_cmds $cmd]} {
        if {![catch {_original_unknown $cmd {*}$args} ucli_result]} {
            return $ucli_result
        }
        error "invalid command name \"$cmd\""
    }

    # SV-first dispatch: 防 UCLI 内置 cmd 静默抢词 (alias/前缀/auto_load 等机制).
    # 当前 bridge 用 live registry known 位判是否降级; 老 bridge 没有该对象时
    # 保留 status=-1 表示 unknown 的兼容规则.
    aip_send_cmd $full_cmd
    set known [_aip_result_known]
    set status [aip_check_status]
    if {$known == 1 || ($known < 0 && $status != -1)} {
        # 运行时插件 load/reload 改了 SV 注册表 → 置动态标志, 关掉后续快速失败
        if {$cmd eq "so_load" || $cmd eq "so_reload"} { set ::_aip_dynamic_cmds 1 }
        return [aip_read_result]
    }

    # SV 不认识 → 试 UCLI/Tcl 内置兜底
    if {![catch {_original_unknown $cmd {*}$args} ucli_result]} {
        return $ucli_result
    }

    # UCLI 也不认识
    error "invalid command name \"$cmd\""
}

# 保存原生 run 供统一推进层使用，重复加载不再次 rename。resume 始终保留
# VCS 原生命令，因为默认 onbreak 会按名称调用它，不能放桥接清理副作用。
if {[info commands _vcs_run] eq ""} {
    rename run _vcs_run
}
# 用户 run 原样转交参数给控制层，成功后以青色显示实际起止时间并返回空值；
# 暂停内只展示有限调试推进结果，内部 before/after/owner 字典不作为公开结果。
# 普通推进设置 free_run 避免空闲握手干扰；正常返回清标记，异常展开保留旧
# 诊断状态并传播错误，不输出成功摘要。暂停入口不改原请求状态、不恢复原 Tcl 栈。
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

        # free_run 使空闲 bridge 持续让出仿真时间。异常展开留下标记，供下次
        # aip_send_cmd 的 settle 区分被打断的 run 与尚未完成的命令请求。
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
        # VCS UCLI 即使在 UTF-8 locale 下也可能把中文输出替换为问号，运行提示使用 ASCII。
        puts [_aip_colorize "\[AIP\] Original script remains paused; enter resume to continue." cyan]
    }
    return
}

# 兼容入口（deprecated）：仅用于已异常展开后的桥状态清理，不恢复 Tcl
# 栈、不重放脚本、不等待业务完成。保栈暂停中的用户必须用原生 resume；
# 此时清 cmd_len 会破坏当前请求，因此入口守卫必须先于任何 force。之所以
# 暂不删除，是因为非TTY中断、restore孤立桥和旧脚本仍需要这个可诊断清理点；
# 新脚本不应主动调用它。
proc aip_recover {args} {
    _aip_control_assert_idle aip_recover
    # args 兼容旧 "resume max_iter <N>" 调用，现已无 block 轮询，参数忽略。
    force aip_core_pkg::__tcl_free_run 0
    force aip_core_pkg::__tcl_cmd_len 32'd0
    set ::_aip_interrupted_run 0
    set t [_aip_sim_time]
    puts "\033\[32m\[AIP_TCL_BRIDGE\] Bridge state recovered @ $t; no script replayed.\033\[0m"
}

# ---------- Startup ----------

puts "============================================"
puts " AIP Command TCL Bridge loaded"
puts " Supports: direct commands, fork/join blocks"
puts "============================================"

# 自动检测顶层脚本路径
# -do 模式：从 info frame 提取 -dofile 参数
# -i 模式：info frame 无文件信息，显示 "interactive"
# 用户可手动覆盖：_aip_set_script "/abs/path/test.tcl"
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

# ---------- 缓存已注册命令表 (后门 get 读, 零握手) ----------
# bridge 启动时把 get_all_cmd_names() 写进 __tcl_cmd_names_ascii[] reg.
# 这里纯 get 读回, 不推进 sim. 建成 dict ::_aip_known_cmds 供 unknown 快速失败.
# 老 SV 无此 reg → len=0 → 不建 dict → unknown 退回原 SV-first 行为.
proc _aip_load_known_cmds {} {
    # reg 不存在 (老 SV / SV 未用新 bridge 重编) → UCLI `get` 报错, 必须 catch 掉,
    # 否则抛错会崩掉 source aip_cmd.tcl, 后续脚本全不执行. catch 失败即静默跳过,
    # dict 不建 → unknown 退回原 SV-first 行为 (真后向兼容).
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

# 消费 loader 根据恢复状态重建的标记；只读写后门寄存器，不发 bridge 命令、不推进仿真。
# 以恢复后的 ACK 反值发请求，适用于重复恢复和已刷新过的快照，不依赖会回滚的序号。
# 完整 readback 后才清 pending；缺少新 SV 寄存器、X/Z 或写入失败均向调用方报错，
# 保留标记供重新 source 重试，禁止悄悄继续使用旧 CLI。普通重复 source 为无副作用空操作。
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

# 源码入口/直接 source 必须先使参数来源失效，再执行任何 bootstrap/reconcile。
# .so 的 load 仅定义函数，由二进制 loader 在 load 返回后执行同一零时间钩子。
if {![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded} {
    _aip_cmdline_restore_refresh
}

# Bridge 启动: 跑到 initial $stop, ucli prompt 出来.
# aip_send_cmd 顶部每次 1ns settle, 启动这里不需要重复.
# Idempotent guard: 二次 source 时 bridge 已过 initial $stop, 再 _vcs_run 会 hang.
if {![info exists ::_aip_bridge_started]} {
    set ::_aip_bridge_started 1
    _aip_advance bootstrap
    catch { _aip_load_known_cmds }   ;# 双保险: 任何失败都不许崩 source
}

# 直接source/源码loader在启动或restore重载后核对控制层孤立状态；.so加载
# 期间不能触发桥行为，由aip_init_so.tcl在load及独立启动之后执行同一核对。
if {![info exists ::aip_tcl_embedded] || !$::aip_tcl_embedded} {
    _aip_control_reconcile
}

# ---------- VCS 断点 procs (aip_checkpoint / aip_restore) ----------
# 与 aip_cmd.tcl 同目录. 多重 fallback 定位: VCS -do 模式下 info script 常返空
# (见本文件顶部 _aip_caller_info 注释), 故优先 $env(AIP_CORE) (脚本本就靠它 source
# 本文件), 再退 info script dir. catch 容错: 缺文件不崩 source (后向兼容).
proc _aip_load_checkpoint {} {
    # In binary mode checkpoint implementation is embedded in
    # libaip_tcl_bridge.so and evaluated by its Tcl extension initializer.
    # Do not source an on-disk implementation in that mode.
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
