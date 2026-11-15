# tests/paused_injection：真实UCLI入口，仅通过发布loader加载待测实现。
# 本文件拥有测试初始化顺序，不改写生产proc；fixture与运行日志归runner所有。
if {$::env(AIP_INJECTION_LOADER) ni {source so}} {
    error "AIP_INJECTION_FAIL invalid loader"
}
set loader aip_init.tcl
if {$::env(AIP_INJECTION_LOADER) eq "so"} { set loader aip_init_so.tcl }
source [file join $::env(AIP_CORE) dist $loader]
source [file join $::env(AIP_CORE) tests paused_injection body.tcl]
