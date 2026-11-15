# 旧分块重放入口的故意失败用例：前缀不能因重放而重复，故障块和后缀在解除故障后各继续一次。
incr ::live_legacy_prefix
if {!$::live_legacy_allow} { error AIP_LIVE_LEGACY_INJECTED }
incr ::live_legacy_suffix
