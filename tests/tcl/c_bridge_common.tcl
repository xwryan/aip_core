# tests/tcl：显式监听/快照恢复回归共用入口，依赖 runner 注入 AIP_CORE 和 SOCKET_WORK。
# 脚本拥有断言与路径配置，SV 持有工作线程，OS fd 由独立 Python 检查；不伪造 socket。
if {$::env(SOCKET_LOADER) eq "so"} {
    source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} else {
    source [file join $::env(AIP_CORE) dist aip_init.tcl]
}
set ::aip_ckpt_dir [file join $::env(SOCKET_WORK) snapshots]
set ::aip_simv_path [file join $::env(SOCKET_WORK) simv]

# 同步发送命令并检查真实返回状态，失败停止 Tcl 脚本，不能继续打印阶段通过标记。
proc socket_checked {command} {
    aip_send_cmd $command
    if {[aip_check_status] != 0} { error "C_BRIDGE_LIFECYCLE_FAIL $command: [aip_read_result]" }
    return [aip_read_result]
}

# 公开命令不接受 enable 或任何业务参数；拒绝后再由 SV/宿主检查尚未打开监听。
proc socket_reject_arguments {} {
    aip_send_cmd {c_bridge_listen enable=1}
    if {[aip_check_status] == 0 || [aip_read_result] ne "ERROR: socket listen takes no arguments"} {
        error "C_BRIDGE_LIFECYCLE_FAIL listen accepted unexpected arguments"
    }
    puts "C_BRIDGE_ARGUMENTS_REJECTED"
}

# 在不推进仿真的 Tcl 等待点让宿主读取 /proc socket inode；宿主验完真实 fd 才写 gate。
# 该 gate 不进入快照，最多等待 15 秒，超时作为测试失败而不是默认继续监听。
proc socket_host_gate {} {
    puts "C_BRIDGE_HOST_INSPECT_READY"
    flush stdout
    set deadline [expr {[clock milliseconds] + 15000}]
    while {![file exists [file join $::env(SOCKET_WORK) inspect.done]]} {
        if {[clock milliseconds] >= $deadline} { error "C_BRIDGE_LIFECYCLE_FAIL host inspection timeout" }
        after 10
    }
}

# 两次调用公开无参命令必须返回同一端口/fd/auth；调用结束后 listener 仍由持久线程驱动。
proc socket_start_checked {} {
    # 首次使用用户文档中的直接命令，验证 known_cmd/unknown 转发链路确实已注册。
    c_bridge_listen
    if {[aip_check_status] != 0} { error "C_BRIDGE_LIFECYCLE_FAIL direct listen: [aip_read_result]" }
    set first [aip_read_result]
    set second [socket_checked c_bridge_listen]
    if {$first ne $second || ![string match {OK: Listening on 127.0.0.1:*, fd=*, auth_key=*} $first]} {
        error "C_BRIDGE_LIFECYCLE_FAIL non-idempotent listen: $first / $second"
    }
    puts "C_BRIDGE_EXPLICIT_LISTEN $first"
    flush stdout
}
