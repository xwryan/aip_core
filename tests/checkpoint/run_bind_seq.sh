#!/usr/bin/env bash
# aip_bind_seq 快照回归：同一 binary 先注册命令再保存，新进程恢复后验证命令随 SV 状态恢复、Tcl 命令名表重读；
# 默认覆盖源码与 .so loader，产物放 mktemp 目录并保留作证据。save/restore 偶发停滞只在 timeout(124) 时重试。
set -euo pipefail
rsck_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export AIP_CORE="$rsck_root"
export RSCK_WORK
RSCK_WORK=$(mktemp -d "${TMPDIR:-/tmp}/aip-bind-seq-checkpoint.XXXXXX")
rsck_timeout=${CKPT_TIMEOUT:-120s}
rsck_attempts=${CKPT_ATTEMPTS:-3}
rsck_modes=${RSCK_MODES:-"source so"}
rsck_errors='RSCK_FAIL|^Error-|^Fatal[-:]|^UVM_(ERROR|FATAL) .*@'
echo "RSCK_ARTIFACTS=$RSCK_WORK"

if [[ " $rsck_modes " == *" so "* ]]; then
    make -C "$rsck_root/dist" tcl > "$RSCK_WORK/so_build.log" 2>&1 || {
        tail -n 100 "$RSCK_WORK/so_build.log"
        exit 1
    }
fi
cd "$RSCK_WORK"
vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -full64 -lca \
    "+incdir+$rsck_root" "+incdir+$rsck_root/src/sv" "+incdir+$rsck_root/src/sv/core" \
    "+incdir+$rsck_root/src/sv/bridge" "+incdir+$rsck_root/src/sv/util" \
    "+incdir+$rsck_root/src/sv/plugin" "+incdir+$rsck_root/src/sv/cpu_mem" \
    -top test_aip_bind_seq -o simv -Mdir=csrc \
    "$rsck_root/tests/sv/test_aip_bind_seq.sv" > build.log 2>&1 || {
        tail -n 120 build.log
        exit 1
    }

# 每阶段须走到 Tcl 与 UVM report 双标记；真实诊断失败不靠重试掩盖。
rsck_run() {
    local rsck_phase=$1 rsck_marker=$2
    local rsck_attempt=1 rsck_rc rsck_log
    rsck_log="$RSCK_WORK/${RSCK_LOADER}_${rsck_phase}.log"
    while :; do
        rsck_rc=0
        timeout --kill-after=10s "$rsck_timeout" ./simv -ucli \
            -do "$rsck_root/tests/tcl/test_aip_bind_seq_ckpt_${rsck_phase}.tcl" \
            +UVM_NO_RELNOTES > "$rsck_log" 2>&1 || rsck_rc=$?
        if [[ $rsck_rc -eq 0 ]]; then break; fi
        if [[ $rsck_rc -ne 124 || $rsck_attempt -ge $rsck_attempts ]] || grep -Eq "$rsck_errors" "$rsck_log"; then
            tail -n 120 "$rsck_log"
            return 1
        fi
        echo "RSCK_RETRY loader=$RSCK_LOADER phase=$rsck_phase attempt=$rsck_attempt"
        rsck_attempt=$((rsck_attempt + 1))
    done
    if grep -Eq "$rsck_errors" "$rsck_log" ||
       [[ $(grep -Ec "^${rsck_marker} checks=[0-9]+$" "$rsck_log") != 1 ]] ||
       [[ $(grep -Ec '^BIND_SEQ_SV_PASS ' "$rsck_log") != 1 ]]; then
        tail -n 120 "$rsck_log"
        return 1
    fi
    grep -E "^${rsck_marker}|^BIND_SEQ_SV_PASS" "$rsck_log"
}

for RSCK_LOADER in $rsck_modes; do
    if [[ $RSCK_LOADER != source && $RSCK_LOADER != so ]]; then
        echo "invalid RSCK_MODES entry: $RSCK_LOADER" >&2
        exit 1
    fi
    export RSCK_LOADER
    rsck_run generate RSCK_GENERATE_PASS
    rsck_run restore RSCK_RESTORE_PASS
done
echo AIP_BIND_SEQ_CHECKPOINT_PASS
