# tests/tcl：真实 UCLI -do 入口，只经公开 source/.so loader 初始化。
# 测试主体由普通 source 进入，保留真实 proc/for 调用栈；不修改生产 proc body，
# 不使用旧重放入口来模拟保栈。旧入口只在单独 legacy 模式验证原有错误重放。
if {$::env(AIP_LIVE_LOADER) eq "so"} {
    set ::live_loader [file join $::env(AIP_CORE) dist aip_init_so.tcl]
} elseif {$::env(AIP_LIVE_LOADER) eq "source"} {
    set ::live_loader [file join $::env(AIP_CORE) dist aip_init.tcl]
} else {
    error "AIP_LIVE_FAIL unknown loader $::env(AIP_LIVE_LOADER)"
}
source $::live_loader
source [file join $::env(AIP_CORE) tests tcl live_resume_body.tcl]
