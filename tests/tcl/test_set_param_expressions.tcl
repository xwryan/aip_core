# tests/tcl：真实 UCLI 验证 Tcl 引用、单项/块写法及运行期覆盖的即时可见性。
# 依赖配套 SV 和 src/tcl/aip_cmd.tcl；所有失败抛出 error，外层必须同时检查 Tcl/SV PASS。
source ../../src/tcl/aip_cmd.tcl

# 只读取本条命令的结果，拒绝非零状态，防止上一次成功掩盖本次失败。
proc sp_read {kind} {
    aip_send_cmd "sp_sample kind=$kind"
    if {[aip_check_status] != 0} {error "SET_PARAM_TCL_READ_FAILED"}
    return [aip_read_result]
}

# 单项写入通过原始正文核对，再验证抽样范围；整个 value= 单词必须被花括号保护。
set_param path=tclcfg.value {value=[50:200]}
if {[sp_read raw] ne {[50:200]}} {error "SET_PARAM_TCL_RANGE_QUOTING"}
set seen {}
for {set i 0} {$i < 64} {incr i} {
    set v [sp_read int]
    if {$v < 50 || $v > 200} {error "SET_PARAM_TCL_RANGE"}
    lappend seen $v
}
if {[llength [lsort -unique $seen]] < 2} {error "SET_PARAM_TCL_CACHED"}

set_param path=tclcfg.value {value={0:=0,50:=20,[100:200]:/80}}
if {[sp_read raw] ne {{0:=0,50:=20,[100:200]:/80}}} {error "SET_PARAM_TCL_WEIGHT_QUOTING"}
for {set i 0} {$i < 64} {incr i} {
    set v [sp_read int]
    if {$v != 50 && ($v < 100 || $v > 200)} {error "SET_PARAM_TCL_WEIGHT"}
}

# 块模式保留内部表达式括号，外层 Tcl 括号只负责保护整段文本。
set_param {
    tclcfg.value [1.25:2.5]
    tclcfg.unused {10:=1,20:=2}
}
for {set i 0} {$i < 32} {incr i} {
    set v [sp_read real]
    if {$v < 1.25 || $v >= 2.5} {error "SET_PARAM_TCL_REAL"}
}
set_param path=tclcfg.value value=red,blue
for {set i 0} {$i < 32} {incr i} {
    if {[sp_read string] ni {red blue}} {error "SET_PARAM_TCL_STRING_LIST"}
}

# 更新立即影响下一次读取，空值清零，clear 删除后回退 plusarg。
set_param path=tclcfg.value value=99
if {[sp_read int] != 99} {error "SET_PARAM_TCL_UPDATE"}
set_param path=tclcfg.value value=
if {[sp_read real] != 0.0} {error "SET_PARAM_TCL_EMPTY"}
clear_param path=tclcfg.value
if {[sp_read int] != 19} {error "SET_PARAM_TCL_CLEAR"}
puts SET_PARAM_TCL_PASS
end_test
run
