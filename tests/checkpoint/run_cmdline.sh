#!/usr/bin/env bash
# 在 VCS 主机编译并执行参数恢复矩阵（默认覆盖源码与 .so loader）；产物放 mktemp 目录并保留作证据。
# 仅真实 timeout 允许最多三次重试。
set -euo pipefail
ckpr_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export AIP_CORE="$ckpr_root"
export CKPR_WORK
CKPR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/aip-checkpoint-cmdline.XXXXXX")
ckpr_timeout=${CKPT_TIMEOUT:-120s}
ckpr_attempts=${CKPT_ATTEMPTS:-3}
ckpr_modes=${CKPR_MODES:-"source so"}
ckpr_errors='CKPR_FAIL|^Error-|^Fatal[-:]|^UVM_(ERROR|FATAL) .*@'
echo "CKPR_ARTIFACTS=$CKPR_WORK"

if [[ " $ckpr_modes " == *" so "* ]]; then
    make -C "$ckpr_root/dist" tcl > "$CKPR_WORK/so_build.log" 2>&1 || {
        tail -n 100 "$CKPR_WORK/so_build.log"
        exit 1
    }
fi
cd "$CKPR_WORK"
vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -full64 -lca \
    "+incdir+$ckpr_root" "+incdir+$ckpr_root/src/sv" "+incdir+$ckpr_root/src/sv/core" \
    "+incdir+$ckpr_root/src/sv/bridge" "+incdir+$ckpr_root/src/sv/util" \
    "+incdir+$ckpr_root/src/sv/plugin" "+incdir+$ckpr_root/src/sv/cpu_mem" \
    -top test_checkpoint_cmdline -o simv -Mdir=csrc \
    "$ckpr_root/tests/sv/test_checkpoint_cmdline.sv" > build.log 2>&1 || {
        tail -n 120 build.log
        exit 1
    }

# 阶段参数原样作为数组传给 simv（保留重复项、空后缀、空格和额外等号）；异常诊断绝不靠重试掩盖。
ckpr_run() {
    local ckpr_phase=$1 ckpr_samples=$2
    shift 2
    local ckpr_attempt=1 ckpr_rc ckpr_log
    ckpr_log="$CKPR_WORK/${CKPR_RUN_ID}_${ckpr_phase}.log"
    while :; do
        ckpr_rc=0
        timeout --kill-after=10s "$ckpr_timeout" ./simv -ucli \
            -do "$ckpr_root/tests/tcl/checkpoint_cmdline_${ckpr_phase}.tcl" \
            +UVM_NO_RELNOTES "$@" > "$ckpr_log" 2>&1 || ckpr_rc=$?
        cp "$ckpr_log" "${ckpr_log%.log}.attempt${ckpr_attempt}.log"
        if [[ $ckpr_rc -eq 0 ]]; then break; fi
        if [[ $ckpr_rc -ne 124 || $ckpr_attempt -ge $ckpr_attempts ]] || grep -Eq "$ckpr_errors" "$ckpr_log"; then
            tail -n 120 "$ckpr_log"
            return 1
        fi
        echo "CKPR_RETRY loader=$CKPR_RUN_ID phase=$ckpr_phase attempt=$ckpr_attempt"
        ckpr_attempt=$((ckpr_attempt + 1))
    done
    if grep -Eq "$ckpr_errors" "$ckpr_log" ||
       [[ $(grep -Ec '^CKPR_INIT ' "$ckpr_log") != 1 ]] ||
       [[ $(grep -Ec '^CKPR_SAMPLE ' "$ckpr_log") != "$ckpr_samples" ]] ||
       [[ $(grep -Ec "^CKPR_DONE phase=$ckpr_phase$" "$ckpr_log") != 1 ]]; then
        tail -n 120 "$ckpr_log"
        return 1
    fi
    grep -E '^CKPR_(SAMPLE|PENDING|DONE)' "$ckpr_log"
}

for ckpr_mode in $ckpr_modes; do
    if [[ $ckpr_mode != source && $ckpr_mode != so ]]; then
        echo "invalid CKPR_MODES entry: $ckpr_mode" >&2
        exit 1
    fi
    export CKPR_LOADER="$ckpr_mode" CKPR_RUN_ID="$ckpr_mode"
    ckpr_run generate 3 \
        +probe.count=11 +probe.label=BASE +probe.dupe=1 +probe.dupe=2 +probe.empty=OLD \
        +probe.oldonly=71 +probe.held=4 +choice=3 +probe.choice=5 +choice=9 \
        +probe.items.size=2 +probe.items.each=10 '+probe.items[1]=11' +probe.q=10,11 \
        +probe.tree.children.size=1 '+probe.tree.children[0].value=11' '+probe.tree.children[0].text=old = text'
    ckpr_run changed 7 \
        +probe.count=22 +probe.label=NEW +probe.dupe=8 +probe.dupe=9 +probe.empty= \
        +probe.newonly=33 +probe.held=22 +choice=13 +probe.choice=15 +choice=19 \
        +probe.items.size=2 +probe.items.each=20 '+probe.items[1]=21' +probe.q=20,21 \
        +probe.tree.children.size=1 '+probe.tree.children[0].value=22' '+probe.tree.children[0].text=new = text'
    ckpr_run absent 3
    ckpr_run chained 4 \
        +probe.count=31 +probe.label=CHAIN +probe.dupe=18 +probe.dupe=19 +probe.empty=CHAINEMPTY \
        +probe.newonly=44 +probe.held=31 +choice=23 +probe.choice=25 +choice=29 \
        +probe.items.size=2 +probe.items.each=30 '+probe.items[1]=31' +probe.q=30,31 \
        +probe.tree.children.size=1 '+probe.tree.children[0].value=31' '+probe.tree.children[0].text=chain = text'
done
echo CHECKPOINT_CMDLINE_PASS
