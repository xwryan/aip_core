# 真实 UCLI -do 入口：只经公开 source/.so loader 初始化；主体用普通 source 进入以保留真实 proc/for 调用栈。
if {$::env(AIP_LIVE_LOADER) eq "so"} {
    set ::live_loader [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} elseif {$::env(AIP_LIVE_LOADER) eq "source"} {
    set ::live_loader [file join $::env(AIP_CORE) dist aip_init.tcl]
} else {
    error "AIP_LIVE_FAIL unknown loader $::env(AIP_LIVE_LOADER)"
}
source $::live_loader
source [file join $::env(AIP_CORE) tests tcl live_resume_body.tcl]
