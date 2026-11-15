# 真实源码/二进制 loader 的恢复识别、失败阻断与重试回归：只模拟 UCLI 后门和仿真推进边界，每个用例用独立解释器。
set root [file normalize [file join [file dirname [info script]] .. ..]]
set passed 0

# 控制模块完整加载，只把推进/核对边界换成事件记录；返回的解释器由调用方销毁。
proc new_session {root} {
    set child [interp create]
    $child eval [list set ::env(AIP_CORE) $root]
    $child eval {
        set ::events {}
        set ::fault none
        set ::ack 0
        set ::request 0

        # 任何绕过已替换推进边界的原生 run 都立即报错。
        proc run {args} { error "unexpected native run $args" }

        # 模拟后门读；命令枚举返回空表，其余未知访问报错，避免掩盖意外依赖。
        proc get {path} {
            switch -- $path {
                aip_core_pkg::__aip_cmdline_refresh_ack {
                    lappend ::events ack
                    switch -- $::fault {
                        missing { error "register missing" }
                        empty { return "" }
                        malformed { return "1'bx" }
                        nonbit { return 2 }
                    }
                    return $::ack
                }
                aip_core_pkg::__aip_cmdline_refresh_request {
                    lappend ::events readback
                    if {$::fault eq "readback"} { return $::ack }
                    return $::request
                }
                aip_core_pkg::__tcl_cmd_names_len { return 0 }
                default { error "unexpected get $path" }
            }
        }

        # 只允许写刷新请求位；失败时不改变寄存器，成功写记录值供真实 helper 回读。
        proc force {path value} {
            if {$path ne "aip_core_pkg::__aip_cmdline_refresh_request"} {
                error "unexpected force $path"
            }
            lappend ::events force
            if {$::fault eq "write"} { error "force rejected" }
            set ::request [_aip_control_scalar $value]
        }

        rename source _test_native_source
        # 用原 source 完整装载生产文件，仅隔离真实 VCS 推进；每次重载均重装替身。
        proc source {path} {
            set result [uplevel 1 [list _test_native_source $path]]
            if {[file tail $path] eq "aip_sim_control.tcl"} {
                # 推进记录用于断言刷新必须在恢复后的首个推进/核对之前完成。
                proc _aip_advance {args} { lappend ::events advance }
                # 核对边界不访问模拟器，其顺序仍由实际 loader 决定。
                proc _aip_control_reconcile {} { lappend ::events reconcile }
            }
            return $result
        }
        source [file join $::env(AIP_CORE) dist aip_init.tcl]
    }
    return $child
}

proc check {name condition} {
    if {!$condition} { error "FAIL $name" }
    incr ::passed
    puts "PASS $name"
}

# 模拟实测 restore 状态：保留快照 started/initialized，命令消失且新增 pending 丢失。
# 同时遗留 embedded=1，检查从二进制快照切回源码入口时仍能正确识别并刷新。
proc restored_session {child} {
    $child eval {
        rename aip_send_cmd {}
        unset -nocomplain ::_aip_cmdline_restore_pending
        set ::aip_tcl_embedded 1
        set ::events {}
    }
}

set child [new_session $root]
check "initial load does not access refresh registers" [$child eval {
    expr {$::events eq {advance reconcile}}
}]
$child eval {set ::events {}; source [file join $::env(AIP_CORE) dist aip_init.tcl]}
check "ordinary repeated source has no side effects" [$child eval {expr {$::events eq {}}}]
restored_session $child
$child eval {source [file join $::env(AIP_CORE) dist aip_init.tcl]}
check "lost pending detected before reconcile and embedded mode reset" [$child eval {
    expr {$::events eq {ack force readback reconcile} && $::request == 1 &&
          !$::_aip_cmdline_restore_pending && !$::aip_tcl_embedded}
}]
interp delete $child

foreach fault {missing empty malformed nonbit write readback} {
    set child [new_session $root]
    restored_session $child
    $child eval [list set ::fault $fault]
    set rc [catch {$child eval {source [file join $::env(AIP_CORE) dist aip_init.tcl]}} message]
    check "$fault aborts loader before reconcile or advance" [expr {$rc != 0 && [$child eval {
        expr {[lsearch -exact $::events reconcile] < 0 &&
              [lsearch -exact $::events advance] < 0 && $::_aip_cmdline_restore_pending &&
              $::aip_initialized && [info commands aip_send_cmd] ne ""}
    }]}]
    $child eval {set ::fault none; set ::ack 1; set ::events {}}
    # 两种公开源码重试入口都必须越过旧 initialized/已有命令的快速返回。
    if {$fault in {empty nonbit readback}} {
        $child eval {aip_init}
    } else {
        $child eval {source [file join $::env(AIP_CORE) dist aip_init.tcl]}
    }
    check "$fault retry completes using restored ack" [$child eval {
        expr {$::events eq {ack force readback reconcile} && $::request == 0 &&
              !$::_aip_cmdline_restore_pending}
    }]
    interp delete $child
}

# 用临时占位库走真实二进制 loader 的定位流程，只替换 load 来模拟旧库缺少刷新 helper；实际 .so 刷新由 VCS 集成回归验证。
set channel [file tempfile binary_root]
close $channel
file delete $binary_root
set child [interp create]
try {
    file mkdir [file join $binary_root lib]
    foreach name {aip_init_so.tcl aip_run.tcl} {
        file copy [file join $root dist $name] [file join $binary_root $name]
    }
    close [open [file join $binary_root lib libaip_tcl_bridge.so] w]
    $child eval {
        set ::events {}
        rename load _test_native_load
        # 旧库只提供原有桥接入口，不提供新 helper；记录所有潜在推进和 unknown 调用。
        proc load {path} {
            lappend ::events load
            set ::aip_tcl_embedded 1
            set ::_aip_bridge_started 1
            proc aip_send_cmd {args} { error "unexpected bridge command" }
            proc _aip_advance {args} { lappend ::events advance }
            proc _aip_control_reconcile {} { lappend ::events reconcile }
            proc _aip_load_known_cmds {} {}
            # 捕获未知 helper 被路由至 SV 的错误路径，不能让 catch 隐藏它。
            proc unknown {args} { lappend ::events unknown; error "unexpected unknown $args" }
        }
    }
    set loader [file join $binary_root aip_init_so.tcl]
    $child eval [list source $loader]
    check "old binary ordinary startup needs no refresh helper" [$child eval {
        expr {$::events eq {load advance reconcile} && $::aip_initialized}
    }]
    $child eval {
        rename aip_send_cmd {}
        unset -nocomplain ::_aip_cmdline_restore_pending
        set ::events {}
    }
    set rc [catch {$child eval [list source $loader]} message]
    check "restored old binary fails before unknown or advance and retains pending" [expr {
        $rc != 0 && [string match {*rebuild libaip_tcl_bridge.so*} $message] &&
        [$child eval {expr {$::events eq {load} && $::_aip_cmdline_restore_pending}}]
    }]
} finally {
    interp delete $child
    file delete -force $binary_root
}

puts "CMDLINE_RESTORE_LOADER_PASS passed=$passed"
