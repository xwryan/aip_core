#!/usr/bin/env bash
# tests/ral：Task1真实模型生成、独立宽度构建及基础验证入口。
# 本脚本只管理build/default或build/width128内产物，不删除其他构建；VCS必须在53运行。
# UVM源码/DPI与测试同次编译，避免用户宏与预编译UVM的位宽不一致。
set -euo pipefail

ral_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ral_root_dir=$(cd -- "$ral_script_dir/../.." && pwd)
ral_mode=${1:-default}
case "$ral_mode" in
    default) ral_model_bits=64; ral_defines=() ;;
    width128) ral_model_bits=128; ral_defines=(+define+UVM_REG_DATA_WIDTH=128) ;;
    *) printf 'Expected default or width128, got: %s\n' "$ral_mode" >&2; exit 2 ;;
esac

: "${VCS_HOME:?Use the VCS host bash environment with VCS_HOME configured}"
ral_uvm_dir="$VCS_HOME/etc/uvm-1.2"
test -f "$ral_uvm_dir/uvm_pkg.sv"
test -f "$ral_uvm_dir/dpi/uvm_dpi.cc"
command -v vcs >/dev/null
command -v ralgen >/dev/null
command -v timeout >/dev/null
ral_build_dir="$ral_script_dir/build/$ral_mode"
mkdir -p "$ral_build_dir"
cd -- "$ral_build_dir"

# 每次重新生成并编译指定宽度；不同目录隔离ralgen输出、csrc、simv及所有日志。
ralgen -full64 -uvm -l sv -t aip_fixture \
    "$ral_script_dir/aip_fixture${ral_model_bits}.ralf" > generate.log 2>&1
test -s ral_aip_fixture.sv
ral_compile=(vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+r+w+f
    -top test_ral_config "${ral_defines[@]}"
    "+incdir+$ral_root_dir" "+incdir+$ral_root_dir/src/sv"
    "+incdir+$ral_script_dir" "+incdir+$ral_build_dir" "+incdir+$ral_uvm_dir"
    "$ral_uvm_dir/uvm_pkg.sv" "$ral_root_dir/tests/sv/test_ral_config.sv"
    "$ral_uvm_dir/dpi/uvm_dpi.cc" -CFLAGS -DVCS
    -CFLAGS "-I$ral_uvm_dir/dpi" -Mdir=csrc -o simv)
printf '%q ' "${ral_compile[@]}" > compile.command
printf '\n' >> compile.command
"${ral_compile[@]}" > compile.log 2>&1
timeout --kill-after=10s "${RAL_TIMEOUT:-120s}" ./simv -no_save -exitstatus > run.log 2>&1

# 精确完成标记和零UVM错误同时成立；日志里的孤立PASS文字不能替代验证。
grep -Eq '^RAL_FOUNDATION_COMPLETE([[:space:]]|$)' run.log
grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$' run.log
grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$' run.log
if grep -Eq '^Error-|^Fatal:|^UVM_(ERROR|FATAL)[[:space:]]+@' run.log; then
    printf 'Unexpected simulator error: %s/run.log\n' "$ral_build_dir" >&2
    exit 1
fi
test -s ral_records.txt

# 使用VCS实际内嵌Tcl解释器校验同目录记录；不依赖远端不存在的独立tclsh。
# 脚本在UCLI启动时直接解析文件并quit，不再次run测试、覆盖第一次的记录。
timeout --kill-after=10s "${RAL_TIMEOUT:-120s}" ./simv -no_save -exitstatus -ucli \
    -do "$ral_root_dir/tests/tcl/test_ral_foundation.tcl" > tcl.log 2>&1
grep -Eq '^RAL_FOUNDATION_TCL_PASS([[:space:]]|$)' tcl.log
if grep -Eq '^Error-|^Fatal:|^UVM_(ERROR|FATAL)[[:space:]]+@' tcl.log; then
    printf 'Unexpected Tcl validation error: %s/tcl.log\n' "$ral_build_dir" >&2
    exit 1
fi
printf 'RAL_FOUNDATION_VALIDATED mode=%s artifacts=%s\n' "$ral_mode" "$ral_build_dir"
