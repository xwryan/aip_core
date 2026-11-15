# 源码分发的统一 Tcl 加载入口（source dist/aip_init.tcl），按依赖顺序加载控制、观察与命令层；
# 重复 source 不重置活动会话，restore 清除命令后重新装载。公开能力与 aip_init_so.tcl 相同。

# VCS restore 保留快照中的 bridge_started，却删除命令和快照之后新写的 Tcl 变量，所以必须在重新定义命令前
# 识别恢复（首次加载无 started、普通重复 source 仍有命令，均不发刷新请求）。
if {[info exists ::_aip_bridge_started] && [info commands aip_send_cmd] eq ""} {
    set ::_aip_cmdline_restore_pending 1
}

# 定位 loader 目录：优先用文件元数据；VCS 缺元数据时只按 Tcl list 解码单条字面 source 命令（绝不 eval），
# 动态路径靠 AIP_CORE fallback。
proc _aip_init_locate {} {
    set cands {}
    catch {
        set s [info script]
        if {$s ne "" && $s ne "."} { lappend cands [file dirname [file normalize $s]] }
    }
    for {set i 1} {$i <= [info frame]} {incr i} {
        catch {
            set f [info frame $i]
            if {[dict exists $f file] && [file tail [dict get $f file]] eq "aip_init.tcl"} {
                lappend cands [file dirname [file normalize [dict get $f file]]]
            }
            if {[dict exists $f cmd]} {
                set command [dict get $f cmd]
                # 保守拒绝替换/多命令语法；list 解析只还原确定字面值，绝不 eval。
                if {![regexp {[$\[;\n\r]} $command] && ![catch {llength $command} count]
                    && [lindex $command 0] in {source ::source}
                    && ($count == 2 || ($count == 4 && [lindex $command 1] eq "-encoding"))} {
                    set path [lindex $command end]
                    if {[file tail $path] eq "aip_init.tcl"} {
                        lappend cands [file dirname [file normalize $path]]
                    }
                }
            }
        }
    }
    if {[info exists ::env(AIP_CORE)]} { lappend cands [file join $::env(AIP_CORE) dist] }
    lappend cands [pwd] [file join [pwd] dist]
    set searched {}
    foreach candidate $cands {
        if {[catch {file normalize $candidate} d] || $d in $searched} { continue }
        lappend searched $d
        if {[file isfile [file join $d .. src tcl aip_cmd.tcl]]} { return $d }
    }
    error "aip_init: src/tcl/aip_cmd.tcl not found (cwd=[pwd]; searched: [join $searched {, }]); check the source path relative to cwd or set AIP_CORE=<aip_core root>"
}
set ::aip_init_loader_dir [_aip_init_locate]

# 已初始化时不重置会话；模块加载错误保留原错误选项向外报告。
proc aip_init {{root ""}} {
    # VCS UCLI `restore` retains snapshot-time globals but drops every command
    # defined by this loader, so ::aip_initialized alone is not proof that the
    # commands are present.  Re-initialize whenever they are missing.
    if {[info exists ::aip_initialized] && $::aip_initialized
        && [info commands aip_send_cmd] ne ""
        && (![info exists ::_aip_cmdline_restore_pending] || !$::_aip_cmdline_restore_pending)} {
        return $::aip_init_root
    }

    if {$root eq ""} {
        # dist/aip_init.tcl lives one directory below the repository root.
        set root [file normalize [file join $::aip_init_loader_dir ..]]
    } else {
        set root [file normalize $root]
    }

    # 快照内的 embedded 标志可能随 restore 恢复；若之前使用 .so，须明确切回源码模式，
    # 使 aip_cmd.tcl 在 bootstrap 前执行刷新，而非误以为仍处于 extension load。
    set ::aip_tcl_embedded 0
    set scripts {
        src/tcl/aip_sim_control.tcl
        src/tcl/aip_watch.tcl
        src/tcl/aip_inject.tcl
        src/tcl/aip_cmd.tcl
        src/tcl/aip_checkpoint.tcl
        src/tcl/aip_ucli_utils.tcl
    }

    foreach name $scripts {
        set path [file join $root $name]
        if {![file exists $path]} {
            error "aip_init: Tcl source file '$path' not found"
        }
        if {![file readable $path]} {
            error "aip_init: Tcl source file '$path' is not readable"
        }
        # Use a direct source call.  VCS UCLI's -do evaluator can stop
        # consuming the caller script after an indirect `uplevel #0 source`.
        if {[catch {source $path} err opts]} {
            return -options $opts \
                "aip_init: failed to source '$path': $err"
        }
    }

    set ::aip_init_root $root
    set ::aip_initialized 1
    return $root
}

# Default load at file scope: VCS UCLI's bridge startup can unwind a procedure call that indirectly
# sources aip_cmd.tcl. Commands are re-checked because `restore` keeps globals but drops commands.
if {![info exists ::aip_initialized] || !$::aip_initialized
    || [info commands aip_send_cmd] eq ""
    || ([info exists ::_aip_cmdline_restore_pending] && $::_aip_cmdline_restore_pending)} {
    set _aip_default_root [file normalize [file join $::aip_init_loader_dir ..]]
    set ::aip_tcl_embedded 0
    set _aip_default_scripts {
        src/tcl/aip_sim_control.tcl
        src/tcl/aip_watch.tcl
        src/tcl/aip_inject.tcl
        src/tcl/aip_cmd.tcl
        src/tcl/aip_checkpoint.tcl
        src/tcl/aip_ucli_utils.tcl
    }
    foreach _aip_name $_aip_default_scripts {
        set _aip_path [file join $_aip_default_root $_aip_name]
        if {![file exists $_aip_path]} {
            error "aip_init: Tcl source file '$_aip_path' not found"
        }
        if {![file readable $_aip_path]} {
            error "aip_init: Tcl source file '$_aip_path' is not readable"
        }
        source $_aip_path
    }
    set ::aip_init_root $_aip_default_root
    set ::aip_initialized 1
    unset _aip_default_root _aip_default_scripts _aip_name _aip_path
}
# Keep the source command result empty for VCS UCLI -do callers.
puts -nonewline ""
