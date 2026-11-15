#!/usr/bin/env bash
set -euo pipefail

dist_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
repo_root=$(cd "$dist_dir/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/aip-ucli-so.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "SKIP UCLI .so smoke test: vcs was not found"
    exit 0
fi

if [ ! -f "$dist_dir/lib/libaip_tcl_bridge.so" ]; then
    echo "UCLI .so smoke test requires lib/libaip_tcl_bridge.so; run make -C dist tcl first" >&2
    exit 1
fi

# -debug_access+r: the bridge reads SV state with UCLI `get` (command table,
# status/result).  Deliberately without +f so the test covers the stricter
# UCLI behavior (`run` returns with Tcl code `return` after the bridge's
# $stop, ending the sourced file), which the aip_run.tcl split exists for.
# Real testbenches build with -debug_access+r+w+f (aip_send_cmd uses `force`).
vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
    -full64 -lca -debug_access+r \
    +incdir+"$repo_root" \
    +incdir+"$repo_root/src/sv" \
    +incdir+"$repo_root/src/sv/core" \
    +incdir+"$repo_root/src/sv/bridge" \
    +incdir+"$repo_root/src/sv/util" \
    +incdir+"$repo_root/src/sv/plugin" \
    +incdir+"$repo_root/src/sv/cpu_mem" \
    -o "$build_dir/simv" -Mdir="$build_dir/csrc" \
    "$dist_dir/tests/tcl_ucli_smoke.sv"

# The bridge start ends in $stop and the smoke script quits explicitly; a
# hang (e.g. a crash inside `load` leaving UCLI at its prompt) is bounded.
(cd "$dist_dir" && timeout 300 "$build_dir/simv" -ucli -do tests/so_ucli_smoke_entry.tcl) \
    >"$build_dir/run.log" 2>&1 || true
cat "$build_dir/run.log"
if grep -Fq TCL_UCLI_SO_SMOKE_FAIL "$build_dir/run.log"; then
    echo "UCLI .so smoke test reported a failure" >&2
    exit 1
fi
grep -Fq TCL_UCLI_SO_SMOKE_PASS "$build_dir/run.log"
