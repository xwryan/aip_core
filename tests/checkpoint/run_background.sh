#!/usr/bin/env bash
# tests/checkpoint：独立编译/运行后台在途快照回归，必须在配置好 VCS 的仿真主机执行。
# 依赖 bash、VCS、timeout 和文本门禁工具；本脚本只拥有专属 binary/csrc/log/快照目录，
# 不删除其他测试产物。save/restore 偶发宿主停滞只在正常 timeout(124) 时重试；
# VCS 不响应 TERM 时 10s 后强杀，137 必须失败，避免无限挂起或掩盖异常终止。
set -euo pipefail
ckb_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ckb_root/tests/sv"
ckb_timeout=${CKPT_TIMEOUT:-120s}
ckb_attempts=${CKPT_ATTEMPTS:-3}
ckb_error_pattern='^CKB_CHECK_FAIL|^CKB_QUERY_FAIL|^Error-|^Fatal[-:]|^UVM_(WARNING|ERROR|FATAL) .*@|^UVM_(WARNING|ERROR|FATAL) :[[:space:]]*[1-9]'

vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -full64 -lca \
    +incdir+../.. +incdir+../../src/sv +incdir+../../src/sv/core \
    +incdir+../../src/sv/bridge +incdir+../../src/sv/util \
    +incdir+../../src/sv/plugin +incdir+../../src/sv/cpu_mem \
    -o simv_checkpoint_background -Mdir=csrc_checkpoint_background \
    test_checkpoint_background.sv > checkpoint_background_build.log 2>&1 \
    || { tail -n 100 checkpoint_background_build.log; exit 1; }

# 一阶段必须完整走到 Tcl 和 UVM report 双门禁；真实诊断失败不通过重试掩盖。
ckb_run_stage() {
    local ckb_stage=$1
    local ckb_marker=$2
    local ckb_log="checkpoint_background_${ckb_stage}.log"
    local ckb_attempt=1
    local ckb_rc
    local ckb_severity
    while :; do
        ckb_rc=0
        timeout --kill-after=10s "$ckb_timeout" ./simv_checkpoint_background -ucli \
            -do "../tcl/checkpoint_background_${ckb_stage}.tcl" \
            +UVM_NO_RELNOTES > "$ckb_log" 2>&1 || ckb_rc=$?
        if [[ $ckb_rc -eq 0 ]]; then break; fi
        if [[ $ckb_rc -ne 124 || $ckb_attempt -ge $ckb_attempts ]] || \
           grep -Eq "$ckb_error_pattern" "$ckb_log"; then
            tail -n 120 "$ckb_log"
            return 1
        fi
        echo "CKB_RETRY stage=$ckb_stage attempt=$ckb_attempt (VCS save/restore timeout)"
        ckb_attempt=$((ckb_attempt + 1))
    done
    test "$(grep -Ec "^${ckb_marker} checks=[0-9]+$" "$ckb_log")" -eq 1
    test "$(grep -Ec '^CKB_SV_PASS driver_count=2$' "$ckb_log")" -eq 1
    if grep -Eq "$ckb_error_pattern" "$ckb_log"; then
        tail -n 120 "$ckb_log"
        return 1
    fi
    for ckb_severity in WARNING ERROR FATAL; do
        test "$(grep -Ec "^UVM_${ckb_severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$ckb_log")" -eq 1
    done
    grep '^CKB_COMPARE ' "$ckb_log" > "checkpoint_background_${ckb_stage}.summary"
    test "$(wc -l < "checkpoint_background_${ckb_stage}.summary")" -eq 8
    grep -E "^${ckb_marker}|^CKB_SV_PASS" "$ckb_log"
}

ckb_run_stage generate CKB_GENERATE_PASS
ckb_run_stage restore CKB_RESTORE_PASS
diff -u checkpoint_background_generate.summary checkpoint_background_restore.summary
echo CHECKPOINT_BACKGROUND_PASS
