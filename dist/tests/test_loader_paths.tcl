# 真实 loader 在 VCS 缺失文件元数据时的路径恢复与诊断；frame cmd 视为不可信文本，不允许执行其中的替换或脚本。
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set channel [file tempfile temporary]
close $channel
file delete $temporary
set original_cwd [pwd]
set passed 0

# env_root 非空时设置明确 fallback；异常以普通结果返回，便于检查错误上下文。
proc probe {loader frame {env_root ""}} {
    set child [interp create]
    try {
        $child eval [list set ::test_frame $frame]
        $child eval {unset -nocomplain ::env(AIP_CORE)}
        if {$env_root ne ""} { $child eval [list set ::env(AIP_CORE) $env_root] }
        $child eval {
            rename info _test_info
            # 模拟 UCLI 无 info script/file，只保留调用命令文本；其他 info 语义保持原状。
            proc info {subcommand args} {
                if {$subcommand eq "script"} { return "" }
                if {$subcommand eq "frame"} {
                    if {[llength $args] == 0} { return 1 }
                    return [dict create cmd $::test_frame]
                }
                return [uplevel 1 [list _test_info $subcommand {*}$args]]
            }
            rename load _test_load
            # 只模拟.so导出的初始化入口；不运行 C、不推进仿真。
            proc load {path} {
                set ::aip_tcl_embedded 1
                set ::_aip_bridge_started 1
                proc aip_send_cmd {args} {}
                proc _aip_control_reconcile {} {}
                proc _aip_load_known_cmds {} {}
                proc _aip_advance {args} {}
            }
        }
        set rc [catch {$child eval [list source $loader]} result]
        if {$rc == 0} { set result [$child eval {set ::aip_init_root}] }
        return [list $rc $result]
    } finally {
        interp delete $child
    }
}

proc check {name condition} {
    if {!$condition} { error "FAIL $name" }
    incr ::passed
    puts "PASS $name"
}

try {
    set package [file join $temporary {tree with spaces}]
    set dist [file join $package dist]
    file mkdir [file join $dist lib] [file join $package src tcl] [file join $temporary caller]
    foreach name {aip_init.tcl aip_init_so.tcl aip_run.tcl} {
        file copy [file join $repo dist $name] [file join $dist $name]
    }
    close [open [file join $dist lib libaip_tcl_bridge.so] w]
    foreach name {aip_sim_control aip_watch aip_inject aip_cmd aip_checkpoint aip_ucli_utils} {
        set channel [open [file join $package src tcl $name.tcl] w]
        puts $channel {proc aip_send_cmd {args} {}}
        close $channel
    }
    cd [file join $temporary caller]
    foreach name {aip_init.tcl aip_init_so.tcl} {
        set loader [file join $dist $name]
        set relative [file join .. {tree with spaces} dist $name]
        foreach command [list [list source $relative] "source \"$relative\"" \
                [list source -encoding utf-8 $relative] [list ::source $relative] \
                [list source $loader]] {
            lassign [probe $loader $command] rc result
            check "$name literal $command" [expr {$rc == 0 && $result eq $package}]
        }
        set command {source [file join $::env(AIP_CORE) dist LOADER]}
        set command [string map [list LOADER $name] $command]
        lassign [probe $loader $command $package] rc result
        check "$name dynamic file join uses explicit environment" [expr {$rc == 0 && $result eq $package}]
        foreach command [list "source \[error EXECUTED\]/$name" "source $relative; error EXECUTED" \
                "source \"unterminated" "source \$missing/$name"] {
            lassign [probe $loader $command] rc result
            check "$name rejects nonliteral metadata safely" [expr {$rc != 0 &&
                [string first "not found (cwd=[pwd]; searched:" $result] >= 0 &&
                [string first EXECUTED $result] < 0}]
        }
    }
} finally {
    cd $original_cwd
    file delete -force $temporary
}
puts "LOADER_PATHS_PASS passed=$passed"
