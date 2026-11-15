#!/usr/bin/env bash
# 编译显式监听回归；simv/csrc/日志/快照均放独立 mktemp 目录，不清理仓库或其它仿真进程。
set -euo pipefail
socket_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export AIP_CORE="$socket_root"
export SOCKET_WORK
SOCKET_WORK=$(mktemp -d "${TMPDIR:-/tmp}/aip-socket-explicit.XXXXXX")
echo "C_BRIDGE_ARTIFACTS=$SOCKET_WORK"
export SOCKET_LOADER=source
if [[ "${1:-ordinary}" == checkpoint ]]; then
    export SOCKET_LOADER=so
    make -C "$socket_root/dist" tcl > "$SOCKET_WORK/so_build.log" 2>&1 || {
        tail -n 100 "$SOCKET_WORK/so_build.log"
        exit 1
    }
fi
cd "$SOCKET_WORK"
vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -full64 -lca \
    "+incdir+$socket_root" "+incdir+$socket_root/src/sv" "+incdir+$socket_root/src/sv/core" \
    "+incdir+$socket_root/src/sv/bridge" "+incdir+$socket_root/src/sv/util" \
    "+incdir+$socket_root/src/sv/plugin" "+incdir+$socket_root/src/sv/cpu_mem" \
    -o simv -Mdir=csrc -CFLAGS "-I$socket_root/include" -LDFLAGS "-ldl -pthread" \
    "$socket_root/tests/sv/test_c_bridge_socket.sv" "$socket_root/src/c/runtime/sv_socket_dpi.c" \
    > build.log 2>&1 || { tail -n 100 build.log; exit 1; }
python3 "$socket_root/tests/socket/run_explicit.py" "${1:-ordinary}"
