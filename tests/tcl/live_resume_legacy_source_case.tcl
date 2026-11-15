# tests/tcl：旧分块重放入口的故意失败文件；runner 会复制到专属临时目录。
# 前缀不能因剩余脚本重放而重复，故障块和后缀则应在解除故障后继续一次。
incr ::live_legacy_prefix
if {!$::live_legacy_allow} { error AIP_LIVE_LEGACY_INJECTED }
incr ::live_legacy_suffix
