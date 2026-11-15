# src/tcl：VCS快照与状态触发保存。快照文件归调用用户所有，bridge寄存器仍
# 归SV package所有；保栈暂停时禁止保存/恢复/settle，避免破坏活跃调用栈。
# 只在统一控制层可用时启用守卫，保持独立纯Tcl元数据/解析测试可用。
# ============================================
# aip_checkpoint.tcl - VCS save/restore 声明式断点
# sourced by aip_cmd.tcl。恢复后的参数刷新依赖匹配版本的 SV request/ack 寄存器；
# Tcl 本身不枚举 CLI，不重写业务配置。重新加载入口在任何仿真推进前发出失效请求。
# 见 docs/superpowers/specs/2026-06-26-vcs-checkpoint-design.md
# ============================================

# ---------- config ----------
if {![info exists ::aip_ckpt_dir]} { set ::aip_ckpt_dir "./aip_ckpt" }
# ::aip_simv_path  — 可选, 覆盖 simv 自动探测

# ---------- simv 路径解析 ----------
proc _aip_simv_path {} {
    if {[info exists ::aip_simv_path] && $::aip_simv_path ne ""} {
        return $::aip_simv_path
    }
    set p [info nameofexecutable]
    if {$p eq ""} {
        error "aip_checkpoint: cannot detect simv path; set ::aip_simv_path"
    }
    return $p
}

# ---------- meta 写 (key\tvalue 每行) ----------
proc _aip_ckpt_write_meta {path arr_name} {
    upvar 1 $arr_name a
    if {[catch {set fh [open $path w]} err]} {
        error "aip_checkpoint: cannot open meta for writing ($path): $err"
    }
    if {[catch {
        foreach k [lsort [array names a]] {
            puts $fh "$k\t$a($k)"
        }
    } werr]} {
        catch {close $fh}
        error $werr
    }
    close $fh
}

# ---------- meta 读 (返回 array get list) ----------
proc _aip_ckpt_read_meta {path} {
    if {![file exists $path]} {
        error "aip_restore: meta not found: $path"
    }
    if {[catch {set fh [open $path r]} err]} {
        error "aip_checkpoint: cannot open meta for reading ($path): $err"
    }
    if {[catch {set data [read $fh]} rerr]} {
        catch {close $fh}
        error $rerr
    }
    close $fh
    array set meta {}
    foreach line [split $data "\n"] {
        if {[string trim $line] eq ""} continue
        set tab [string first "\t" $line]
        if {$tab < 0} continue
        set k [string range $line 0 [expr {$tab - 1}]]
        set v [string range $line [expr {$tab + 1}] end]
        set meta($k) $v
    }
    return [array get meta]
}

# ---------- 有效性检查: 当前 simv 的 mtime+size vs meta ----------
proc _aip_ckpt_validate {meta_list simv_path} {
    array set meta $meta_list
    if {![file exists $simv_path]} {
        error "aip_restore: simv not found: $simv_path"
    }
    set cur_mtime [file mtime $simv_path]
    set cur_size  [file size  $simv_path]
    if {$cur_mtime != $meta(simv_mtime) || $cur_size != $meta(simv_size)} {
        error "checkpoint stale: simv changed (mtime/size mismatch), rerun base-gen"
    }
    return 1
}

# ---------- bridge idle 检测 (4-reg, 同 aip_send_cmd 顶部逻辑) ----------
proc _aip_bridge_is_idle {} {
    if {![aip_parse_int [get aip_core_pkg::__tcl_bridge_idle]]}     { return 0 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_cmd_trigger]] != 0} { return 0 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_cmd_len]] != 0}     { return 0 }
    if {[aip_parse_int [get aip_core_pkg::__tcl_free_run]] != 0}    { return 0 }
    return 1
}

# ---------- 排干残留, 把 bridge 推回 idle ($stop) ----------
proc _aip_bridge_settle {} {
    if {[info commands _aip_control_assert_idle] ne ""} {
        _aip_control_assert_idle checkpoint_settle
    }
    if {[_aip_bridge_is_idle]} { return 1 }
    force aip_core_pkg::__tcl_cmd_trigger 0
    force aip_core_pkg::__tcl_cmd_len 32'd0
    force aip_core_pkg::__tcl_free_run 1
    if {[info commands _aip_advance] ne ""} {
        _aip_advance checkpoint 1ns
    } else { redirect /dev/null { _vcs_run 1ns } }
    force aip_core_pkg::__tcl_free_run 0
    set ::_aip_interrupted_run 0
    return [_aip_bridge_is_idle]
}

# ---------- aip_checkpoint <name> [note=...] ----------
# note 含空格时整体加引号: aip_checkpoint base "note=post linkup"
proc aip_checkpoint {name args} {
    if {[info commands _aip_inject_assert_quiescent] ne ""} { _aip_inject_assert_quiescent aip_checkpoint }
    if {[info commands _aip_control_assert_idle] ne ""} {
        _aip_control_assert_idle aip_checkpoint
    }
    if {[info commands _aip_watch_assert_quiescent] ne ""} {
        _aip_watch_assert_quiescent aip_checkpoint
    }
    set note ""
    foreach a $args {
        if {[regexp {^note=(.*)$} $a _ v]} { set note $v }
    }
    if {![_aip_bridge_settle]} {
        error "aip_checkpoint: bridge not idle (interrupted run?), refuse to save dirty ckpt"
    }
    file mkdir $::aip_ckpt_dir
    set ckpt      [file join $::aip_ckpt_dir $name.vcssave]
    set meta_path [file join $::aip_ckpt_dir $name.meta]
    set simv      [_aip_simv_path]

    # VCS 禁止在 $stop() 上下文 save (Error-[UCLI-SAVE-STOP]). bridge idle 点正是
    # run_loop 的 $stop(0), 故 save 前必须 `run 0` 脱离 $stop 任务上下文 (0 时间推进).
    if {[info commands _aip_advance] ne ""} {
        _aip_advance checkpoint 0
    } else { redirect /dev/null { _vcs_run 0 } }
    save $ckpt

    array set m {}
    set m(simv_path)  $simv
    set m(simv_mtime) [file mtime $simv]
    set m(simv_size)  [file size  $simv]
    set m(sim_time)   [_aip_sim_time]
    set m(note)       $note
    set m(created)    [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    _aip_ckpt_write_meta $meta_path m

    puts "\033\[36m\[AIP_CKPT\] saved '$name' @ $m(sim_time) -> $ckpt\033\[0m"
}

# ---------- aip_restore <name> ----------
# 前置校验 meta 新鲜度 (mtime/size, 纯 Tcl file 检查, 安全), 再复用 VCS restore.
# VCS restore 必须在 UCLI 顶层(全局帧)执行, 在 proc 内直接调会崩; 故用 uplevel #0 顶到
# 全局帧执行 restore. restore 后须重新 source loader，使 AIP 参数源在推进前失效；
# 后续 settle、发命令、run 仍交给用户脚本。成功恢复会丢弃快照之后新设的 Tcl
# 变量，因此 loader 还须根据 started 存在/命令缺失重建 pending。若原生 restore
# 报错，pending 留待重载；同一进程重取 CLI 无害，不能悄悄绕过参数源的版本检查。
# 校验 misfire (simv 路径探测不准) 时: set ::aip_simv_path /abs/simv 手动指定绕过.
proc aip_restore {name} {
    if {[info commands _aip_inject_assert_quiescent] ne ""} { _aip_inject_assert_quiescent aip_restore }
    if {[info commands _aip_control_assert_idle] ne ""} {
        _aip_control_assert_idle aip_restore
    }
    if {[info commands _aip_watch_assert_quiescent] ne ""} {
        _aip_watch_assert_quiescent aip_restore
    }
    set ckpt      [file join $::aip_ckpt_dir $name.vcssave]
    set meta_path [file join $::aip_ckpt_dir $name.meta]

    _aip_ckpt_validate [_aip_ckpt_read_meta $meta_path] [_aip_simv_path]

    if {![file exists $ckpt]} {
        error "aip_restore: snapshot not found: $ckpt"
    }
    set ::_aip_watch_restore_pending 1
    set ::_aip_cmdline_restore_pending 1
    uplevel #0 [list restore $ckpt]
    puts "\033\[32m\[AIP_CKPT\] restored '$name' -> $ckpt\033\[0m"
}

# ---------- aip_wait_checkpoint <path> <expected> <message> <snapshot> [timeout] ----------
# Parse only unambiguous two-state integer spellings. An empty result means reject.
proc _aip_wait_ckpt_accumulate_digits {digits base} {
    set number 0
    foreach digit [split [string tolower $digits] ""] {
        set digit_value [string first $digit 0123456789abcdef]
        if {$digit_value < 0 || $digit_value >= $base} { return "" }
        set number [expr {$number * $base + $digit_value}]
    }
    return $number
}

proc _aip_wait_ckpt_parse_value {raw} {
    set value [string trim $raw]
    set sign 1
    if {$value eq ""} { return "" }

    set first [string index $value 0]
    if {$first eq "-"} {
        set sign -1
        set value [string range $value 1 end]
    } elseif {$first eq "+"} {
        set value [string range $value 1 end]
    }
    if {$value eq ""} { return "" }

    if {[regexp -nocase {^0x([0-9a-f]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 16]
    } elseif {[regexp -nocase {^0b([01]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 2]
    } elseif {[regexp -nocase {^[0-9]*'h([0-9a-f]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 16]
    } elseif {[regexp -nocase {^[0-9]*'d([0-9]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 10]
    } elseif {[regexp -nocase {^[0-9]*'b([01]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 2]
    } elseif {[regexp -nocase {^[0-9]*'o([0-7]+)$} $value _ digits]} {
        set number [_aip_wait_ckpt_accumulate_digits $digits 8]
    } elseif {[regexp {^[0-9]+$} $value]} {
        set number [_aip_wait_ckpt_accumulate_digits $value 10]
    } else {
        return ""
    }
    return [expr {$sign * $number}]
}

proc _aip_wait_ckpt_duration_ns {duration} {
    if {![regexp -nocase {^\s*([0-9]+(?:\.[0-9]+)?)\s*(fs|ps|ns|us|ms|s)?\s*$} \
            $duration _ number unit]} {
        error "aip_wait_checkpoint: invalid timeout '$duration'"
    }
    if {$unit eq ""} { set unit ns }
    switch -nocase -- $unit {
        fs { set scale 0.000001 }
        ps { set scale 0.001 }
        ns { set scale 1.0 }
        us { set scale 1000.0 }
        ms { set scale 1000000.0 }
        s  { set scale 1000000000.0 }
    }
    return [expr {double($number) * $scale}]
}

proc _aip_wait_ckpt_time_ns {} {
    if {[info commands senv] ne "" &&
            ![catch {set native_time [senv time]}] &&
            [string trim $native_time] ne ""} {
        if {[catch {
            set native_ns [_aip_wait_ckpt_duration_ns $native_time]
        }]} {
            error "aip_wait_checkpoint: cannot parse native simulation time '$native_time'"
        }
        return $native_ns
    }

    if {[catch {set formatted [_aip_sim_time]} time_error time_options]} {
        regsub {^aip_wait_checkpoint:\s*} $time_error {} time_error
        set time_error "aip_wait_checkpoint: cannot read simulation time: $time_error"
        return -options $time_options $time_error
    }
    if {![regexp {^\s*([0-9]+(?:\.[0-9]+)?)\s*ns\s*$} $formatted _ number]} {
        error "aip_wait_checkpoint: cannot parse simulation time '$formatted'"
    }
    return [expr {double($number)}]
}

proc _aip_wait_ckpt_save {path expected message snapshot} {
    if {[catch {set trigger_time [_aip_sim_time]} time_error time_options]} {
        regsub {^aip_wait_checkpoint:\s*} $time_error {} time_error
        set time_error "aip_wait_checkpoint: cannot read simulation time: $time_error"
        return -options $time_options $time_error
    }
    if {[catch {set actual [string trim [get $path]]} get_error get_options]} {
        regsub {^aip_wait_checkpoint:\s*} $get_error {} get_error
        set get_error "aip_wait_checkpoint: cannot read '$path': $get_error"
        return -options $get_options $get_error
    }
    if {[catch {
        puts [format \
            {[AIP_STATE_CKPT] %s path=%s value=%s expected=%s trigger_time=%s} \
            $message $path $actual $expected $trigger_time]
    } log_error log_options]} {
        if {![string match {aip_wait_checkpoint:*} $log_error]} {
            set log_error "aip_wait_checkpoint: $log_error"
        }
        return -options $log_options $log_error
    }
    if {[catch {
        aip_checkpoint $snapshot \
            "note=$message; trigger_time=$trigger_time; path=$path; expected=$expected"
    } save_error save_options]} {
        if {![string match {aip_wait_checkpoint:*} $save_error]} {
            set save_error "aip_wait_checkpoint: $save_error"
        }
        return -options $save_options $save_error
    }
    return $snapshot
}

# 状态触发保存仍使用独立原生条件断点，不是后台watch。先拒绝保栈暂停
# 期间的重入和活动watch，避免先装断点/打印成功、后在save处才失败。
proc aip_wait_checkpoint {path expected message snapshot {timeout ""}} {
    if {[info commands _aip_inject_assert_quiescent] ne ""} { _aip_inject_assert_quiescent aip_wait_checkpoint }
    if {[info commands _aip_control_assert_idle] ne ""} {
        _aip_control_assert_idle aip_wait_checkpoint
    }
    if {[info commands _aip_watch_assert_quiescent] ne ""} {
        _aip_watch_assert_quiescent aip_wait_checkpoint
    }
    if {$path eq ""} {
        error "aip_wait_checkpoint: path cannot be empty"
    }
    if {![regexp {^[A-Za-z0-9][A-Za-z0-9_.-]*$} $snapshot]} {
        error "aip_wait_checkpoint: invalid snapshot name '$snapshot'"
    }
    foreach required {get stop run aip_checkpoint _aip_sim_time} {
        if {[info commands $required] eq ""} {
            error "aip_wait_checkpoint: required command '$required' is unavailable; source aip_cmd.tcl first"
        }
    }

    set expected_number [_aip_wait_ckpt_parse_value $expected]
    if {$expected_number eq ""} {
        error "aip_wait_checkpoint: expected value '$expected' is not a supported two-state integer"
    }
    if {[catch {set current_raw [get $path]} get_error get_options]} {
        regsub {^aip_wait_checkpoint:\s*} $get_error {} get_error
        set get_error "aip_wait_checkpoint: cannot read '$path': $get_error"
        return -options $get_options $get_error
    }
    set current_number [_aip_wait_ckpt_parse_value $current_raw]
    if {$current_number ne "" && $current_number == $expected_number} {
        return [_aip_wait_ckpt_save $path $expected $message $snapshot]
    }

    set deadline_ns -1.0
    if {$timeout ne ""} {
        set timeout_ns [_aip_wait_ckpt_duration_ns $timeout]
        if {$timeout_ns <= 0.0} {
            error "aip_wait_checkpoint: timeout must be greater than zero"
        }
        set deadline_ns [expr {[_aip_wait_ckpt_time_ns] + $timeout_ns}]
    }

    if {[catch {
        puts [format \
            {[AIP_STATE_CKPT] waiting path=%s expected=%s snapshot=%s timeout=%s} \
            $path $expected $snapshot \
            [expr {$timeout eq "" ? "unlimited" : $timeout}]]
    } log_error log_options]} {
        if {![string match {aip_wait_checkpoint:*} $log_error]} {
            set log_error "aip_wait_checkpoint: $log_error"
        }
        return -options $log_options $log_error
    }

    set condition "$path == $expected_number"
    if {[catch {set stop_id [stop -condition $condition]} stop_error stop_options]} {
        regsub {^aip_wait_checkpoint:\s*} $stop_error {} stop_error
        set stop_error "aip_wait_checkpoint: cannot monitor '$path': $stop_error"
        return -options $stop_options $stop_error
    }

    set wait_rc [catch {
        while {1} {
            set before_ns [_aip_wait_ckpt_time_ns]
            if {$deadline_ns < 0.0} {
                run
            } else {
                set remaining_ns [expr {$deadline_ns - $before_ns}]
                if {$remaining_ns <= 0.0} {
                    if {[catch {set last_value [string trim [get $path]]}]} {
                        set last_value "<unavailable>"
                    }
                    error "timeout waiting for '$path' == '$expected'; last value=$last_value"
                }
                run [format "%.9fns" $remaining_ns]
            }

            if {[catch {set current_raw [get $path]} get_error get_options]} {
                regsub {^aip_wait_checkpoint:\s*} $get_error {} get_error
                set get_error "aip_wait_checkpoint: cannot read '$path': $get_error"
                return -options $get_options $get_error
            }
            set current_number [_aip_wait_ckpt_parse_value $current_raw]
            if {$current_number ne "" && $current_number == $expected_number} {
                break
            }

            set after_ns [_aip_wait_ckpt_time_ns]
            if {$deadline_ns >= 0.0 && $after_ns >= $deadline_ns} {
                set last_value [string trim $current_raw]
                error "timeout waiting for '$path' == '$expected'; last value=$last_value"
            }
            if {$after_ns <= $before_ns} {
                error "simulation stopped without advancing while waiting for '$path'"
            }
        }
    } wait_error wait_options]

    set cleanup_rc [catch {
        stop -delete $stop_id
    } cleanup_error cleanup_options]
    if {$wait_rc} {
        if {![string match {aip_wait_checkpoint:*} $wait_error]} {
            set wait_error "aip_wait_checkpoint: $wait_error"
        }
        if {$cleanup_rc} {
            regsub {^aip_wait_checkpoint:\s*} $cleanup_error {} cleanup_error
            append wait_error "; cleanup failed: $cleanup_error"
        }
        return -options $wait_options $wait_error
    }
    if {$cleanup_rc} {
        regsub {^aip_wait_checkpoint:\s*} $cleanup_error {} cleanup_error
        set cleanup_error \
            "aip_wait_checkpoint: cannot delete stop $stop_id for '$path': $cleanup_error"
        return -options $cleanup_options $cleanup_error
    }
    return [_aip_wait_ckpt_save $path $expected $message $snapshot]
}
