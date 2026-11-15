#!/usr/bin/env bash
set -euo pipefail

dist_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
repo_root=$(cd "$dist_dir/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/aip-ucli-pli.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "SKIP UCLI PLI smoke test: vcs was not found"
    exit 0
fi

cc=${CC:-gcc}
if ! command -v "$cc" >/dev/null 2>&1; then
    echo "SKIP UCLI PLI smoke test: $cc was not found"
    exit 0
fi

if [ ! -f "$dist_dir/tests/ucli_pli_smoke.c" ] ||
   [ ! -f "$dist_dir/tests/ucli_pli_smoke.sv" ] ||
   [ ! -f "$dist_dir/tests/ucli_pli_smoke.tcl" ]; then
    echo "UCLI PLI smoke test fixture is incomplete" >&2
    exit 1
fi

"$cc" -fPIC -shared -O2 -Wall -Wextra \
    -I"${VCS_HOME:?VCS_HOME must point to the VCS installation}"/include \
    -o "$build_dir/libaip_ucli_pli.so" \
    "$dist_dir/tests/ucli_pli_smoke.c"

vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
    -full64 -lca +incdir+"$repo_root" \
    -load "$build_dir/libaip_ucli_pli.so:aip_ucli_register" \
    -o "$build_dir/simv" -Mdir="$build_dir/csrc" \
    "$dist_dir/tests/ucli_pli_smoke.sv"

(cd "$dist_dir" && "$build_dir/simv" -ucli -do "$dist_dir/tests/ucli_pli_smoke.tcl") \
    >"$build_dir/run.log" 2>&1
cat "$build_dir/run.log"
grep -Fq UCLI_PLI_SMOKE_PASS "$build_dir/run.log"
