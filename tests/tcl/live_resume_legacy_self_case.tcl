# 旧自接管入口（aip_run_self）的故意失败用例，只用于兼容测试；runner 会复制到临时目录。
aip_run_self
incr ::live_self_prefix
if {!$::live_self_allow} { error AIP_LIVE_SELF_INJECTED }
incr ::live_self_suffix
