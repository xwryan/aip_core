#!/usr/bin/env bash
set -euo pipefail

dist_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
repo_root=$(cd "$dist_dir/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/aip-ucli-tcl.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "SKIP UCLI Tcl smoke test: vcs was not found"
    exit 0
fi

if [ ! -f "$dist_dir/lib/libaip_soload.so" ] ||
   [ ! -f "$dist_dir/lib/libaip_socket_dpi.so" ]; then
    echo "UCLI Tcl smoke test requires built C libraries; run make -C dist all first" >&2
    exit 1
fi

vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
    -full64 -lca \
    +incdir+"$repo_root" \
    +incdir+"$repo_root/src/sv" \
    +incdir+"$repo_root/src/sv/core" \
    +incdir+"$repo_root/src/sv/bridge" \
    +incdir+"$repo_root/src/sv/util" \
    +incdir+"$repo_root/src/sv/plugin" \
    +incdir+"$repo_root/src/sv/cpu_mem" \
    -o "$build_dir/simv" -Mdir="$build_dir/csrc" \
    -LDFLAGS "-L$dist_dir/lib -Wl,-rpath,$dist_dir/lib -laip_soload -laip_socket_dpi" \
    "$dist_dir/tests/tcl_ucli_smoke.sv"

# A script error leaves UCLI at its prompt waiting for input; bound that.
(cd "$dist_dir" && timeout 300 "$build_dir/simv" -ucli -do tests/tcl_ucli_smoke_entry.tcl) \
    >"$build_dir/run.log" 2>&1
cat "$build_dir/run.log"
grep -Fq TCL_UCLI_SMOKE_PASS "$build_dir/run.log"
