# 真实 UCLI 入口：仅通过发布 loader 加载待测实现，不改写生产 proc。
if {$::env(AIP_INJECTION_LOADER) ni {source so}} {
    error "AIP_INJECTION_FAIL invalid loader"
}
set loader aip_init.tcl
if {$::env(AIP_INJECTION_LOADER) eq "so"} { set loader aip_init_so.tcl }
source [file join $::env(AIP_CORE) dist $loader]
source [file join $::env(AIP_CORE) tests paused_injection body.tcl]
