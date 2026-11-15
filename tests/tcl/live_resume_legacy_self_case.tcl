# tests/tcl：旧自接管入口的故意失败文件；只用于兼容测试，不推荐新脚本使用。
# runner 复制本文件到临时目录，生成的剩余脚本也只由该临时用例拥有。
aip_run_self
incr ::live_self_prefix
if {!$::live_self_allow} { error AIP_LIVE_SELF_INJECTED }
incr ::live_self_suffix
