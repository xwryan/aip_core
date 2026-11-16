# dist：二进制 Tcl 加载入口，负责.so装载后的SV启动与恢复状态核对。
# load本身只定义控制/观察/命令函数，不推进仿真；初次握手独立执行。
# 重复source不改活动调用，restore清空命令后重新加载并核对孤立桥状态。
# 恢复参数源必须在 load 返回后、任何 bootstrap/reconcile 前失效；失败 pending 保留供重试。
# AIP binary Tcl loader: the command implementation comes from
# lib/libaip_tcl_bridge.so instead of the src/tcl/*.tcl sources.
#
# Usage from a UCLI/Tcl script:
#   source /path/to/aip_core/dist/aip_init_so.tcl
#
# Requires `make -C dist tcl` (or `all`) and a VCS UCLI session: the extension
# evaluates its embedded Tcl through the UCLI API and does nothing elsewhere.
# The same ::aip_initialized / ::aip_init_root contract as aip_init.tcl.

# 定位 loader 自身目录：优先使用 Tcl 文件元数据，再读取可确定的 source 字面参数。
# VCS 可能缺少文件元数据；此时只按 Tcl list 解码单条 source（含 -encoding），
# 支持引号/花括号中的空格，不执行 frame cmd、变量替换或命令替换。
# 动态表达式路径由 AIP_CORE fallback 支持；所有候选规范化去重，保留原优先级。
proc _aip_init_so_locate {} {
    set cands {}
    catch {
        set s [info script]
        if {$s ne "" && $s ne "."} { lappend cands [file dirname [file normalize $s]] }
    }
    for {set i 1} {$i <= [info frame]} {incr i} {
        catch {
            set f [info frame $i]
            if {[dict exists $f file] && [file tail [dict get $f file]] eq "aip_init_so.tcl"} {
                lappend cands [file dirname [file normalize [dict get $f file]]]
            }
            if {[dict exists $f cmd]} {
                set command [dict get $f cmd]
                # 保守拒绝替换/多命令语法；list 解析只还原确定字面值，绝不 eval。
                if {![regexp {[$\[;\n\r]} $command] && ![catch {llength $command} count]
                    && [lindex $command 0] in {source ::source}
                    && ($count == 2 || ($count == 4 && [lindex $command 1] eq "-encoding"))} {
                    set path [lindex $command end]
                    if {[file tail $path] eq "aip_init_so.tcl"} {
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
        if {[file isfile [file join $d lib libaip_tcl_bridge.so]]} { return $d }
    }
    error "aip_init_so: lib/libaip_tcl_bridge.so not found (cwd=[pwd]; searched: [join $searched {, }]); check the source path relative to cwd or set AIP_CORE=<aip_core root>; run make -C <aip_core>/dist tcl to build the library"
}

# VCS UCLI `restore` retains snapshot-time globals but drops every command this
# loader defined, so ::aip_initialized alone is not proof that the commands are
# present.  Re-load whenever they are missing.
if {![info exists ::aip_initialized] || !$::aip_initialized
    || [info commands aip_send_cmd] eq ""
    || ([info exists ::_aip_cmdline_restore_pending] && $::_aip_cmdline_restore_pending)} {
    set ::aip_init_so_dir [_aip_init_so_locate]
    set _aip_so [file join $::aip_init_so_dir lib libaip_tcl_bridge.so]
    # After a `restore` the bridge is already past its initial $stop; the
    # surviving global says so, and `load` below overwrites it.
    set _aip_was_started [info exists ::_aip_bridge_started]
    # 恢复丢弃快照后新增 Tcl 变量，故在 load 重建命令前重建 pending。
    # 不能等嵌入脚本执行时再检查：extension 初次 load 也会人为设置 started。
    if {$_aip_was_started && [info commands aip_send_cmd] eq ""} {
        set ::_aip_cmdline_restore_pending 1
    }
    # Defines every aip_* proc; the extension pre-sets ::aip_tcl_embedded and
    # ::_aip_bridge_started so nothing runs the simulation during `load`.
    load $_aip_so

    # 普通启动无需刷新，保留旧 .so 的原路径；恢复时若库过旧缺少 helper，
    # 必须在调用 unknown/SV bridge 之前明确失败，不能为诊断版本错误而推进仿真。
    if {[info exists ::_aip_cmdline_restore_pending] && $::_aip_cmdline_restore_pending} {
        if {[info commands _aip_cmdline_restore_refresh] eq ""} {
            error "AIP_CMDLINE_REFRESH: Tcl library lacks restore support; rebuild libaip_tcl_bridge.so"
        }
        _aip_cmdline_restore_refresh
    }

    if {!$_aip_was_started} {
        # Start the SV bridge.  In a simv built without -debug_access+f, UCLI's
        # `run` returns from the $stop handshake with Tcl code `return`, ending
        # the file being sourced; the start therefore lives alone in aip_run.tcl
        # and this file continues afterwards.
        source [file join $::aip_init_so_dir aip_run.tcl]
    }
    _aip_control_reconcile
    # _aip_load_known_cmds swallows every failure; the dict it builds is the
    # real evidence that the bridge answered with its command table.
    catch { _aip_load_known_cmds }
    set ::aip_known_cmds_loaded [info exists ::_aip_known_cmds]

    set ::aip_init_root [file normalize [file join $::aip_init_so_dir ..]]
    set ::aip_initialized 1
    unset _aip_so _aip_was_started
}

# Same public entry point as aip_init.tcl; the work is done at file scope above.
if {[info commands aip_init] eq ""} {
    proc aip_init {{root ""}} {
        return $::aip_init_root
    }
}
# Keep the source command result empty for VCS UCLI -do callers.
puts -nonewline ""
