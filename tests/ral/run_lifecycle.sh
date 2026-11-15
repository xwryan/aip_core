#!/usr/bin/env bash
# 命令生命周期验证入口（VCS/UVM 1.2）：每种宽度独占 build/lifecycle 下的编译与日志目录。
# 由真实 UCLI 驱动 bridge watchdog，SV 与 Tcl 完成标记必须同时成立。
set -euo pipefail

ral_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ral_root_dir=$(cd -- "$ral_script_dir/../.." && pwd)
ral_mode=${1:-default}
case "$ral_mode" in
    default) ral_width=64; ral_defines=() ;;
    width128) ral_width=128; ral_defines=(+define+UVM_REG_DATA_WIDTH=128) ;;
    *) printf 'Expected default or width128, got: %s\n' "$ral_mode" >&2; exit 2 ;;
esac

: "${VCS_HOME:?Use the VCS host bash environment with VCS_HOME configured}"
ral_uvm_dir="$VCS_HOME/etc/uvm-1.2"
test -f "$ral_uvm_dir/uvm_pkg.sv"
test -f "$ral_uvm_dir/dpi/uvm_dpi.cc"
command -v vcs >/dev/null
command -v timeout >/dev/null
ral_build_dir="$ral_script_dir/build/lifecycle/$ral_mode"
mkdir -p "$ral_build_dir"
cd -- "$ral_build_dir"

# 记录精确 argv、日志与返回码；失败立即终止，不能读旧日志假通过。
ral_record_command() {
    local ral_label=$1
    local ral_rc=0
    shift
    printf '%q ' "$@" > "$ral_label.command"
    printf '\n' >> "$ral_label.command"
    "$@" > "$ral_label.log" 2>&1 || ral_rc=$?
    printf '%s\n' "$ral_rc" > "$ral_label.rc"
    if ((ral_rc != 0)); then
        printf 'Lifecycle %s failed: %s/%s.log (rc=%s)\n' \
            "$ral_label" "$ral_build_dir" "$ral_label" "$ral_rc" >&2
        return "$ral_rc"
    fi
}

# UVM源码和DPI与测试同时重编；socket DPI支持统一package中已有C bridge声明。
ral_record_command compile vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+r+w+f \
    -top test_ral_lifecycle "${ral_defines[@]}" \
    "+incdir+$ral_root_dir" "+incdir+$ral_root_dir/src/sv" "+incdir+$ral_uvm_dir" \
    "$ral_uvm_dir/uvm_pkg.sv" "$ral_root_dir/tests/sv/test_ral_lifecycle.sv" \
    "$ral_uvm_dir/dpi/uvm_dpi.cc" "$ral_root_dir/src/c/runtime/sv_socket_dpi.c" \
    -CFLAGS -DVCS -CFLAGS "-I$ral_uvm_dir/dpi" -Mdir=csrc -o simv

# 每种永久latch场景启动全新sim进程；同宽只编译一次，绝不清空产品singleton。
for ral_case in action parse inventory quiesce reset resume sequence dirtycancel restore normalleak priorerror cancelleak; do
    ral_label="run_$ral_case"
    # VCS的-do入口不保证info script，显式传测试根路径供Tcl定位真实bridge。
    ral_record_command "$ral_label" env "AIP_RAL_TEST_ROOT=$ral_root_dir" \
        timeout --kill-after=10s "${RAL_TIMEOUT:-120s}" \
        ./simv -no_save -exitstatus "+LIFECYCLE_CASE=$ral_case" -ucli \
        -do "$ral_root_dir/tests/tcl/test_ral_lifecycle.tcl"

    # 位宽、case和检查数必须匹配；额外错误不能被PASS文字掩盖。
    grep -Eq "^RAL_LIFECYCLE_COMPLETE width=$ral_width checks=[1-9][0-9]* case=$ral_case[[:space:]]*$" "$ral_label.log"
    grep -Eq '^RAL_LIFECYCLE_TCL_PASS([[:space:]]|$)' "$ral_label.log"
    grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$' "$ral_label.log"
    grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$' "$ral_label.log"
    if grep -Eq '^Error-|^Fatal:|^UVM_(ERROR|FATAL)[[:space:]]+@' "$ral_label.log"; then
        printf 'Unexpected lifecycle error: %s/%s.log\n' "$ral_build_dir" "$ral_label" >&2
        exit 1
    fi
done
printf 'RAL_LIFECYCLE_VALIDATED mode=%s artifacts=%s\n' "$ral_mode" "$ral_build_dir"
