#!/usr/bin/env bash
# ral_op 命名访问双宽 VCS 回归；每个宽度使用独立生成物和仿真目录。
set -euo pipefail
ral_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ral_root_dir=$(cd -- "$ral_script_dir/../.." && pwd)
ral_mode=${1:-default}
case "$ral_mode" in
  default) bits=64; defs=() ;;
  width128) bits=128; defs=(+define+UVM_REG_DATA_WIDTH=128) ;;
  *) echo "Expected default or width128" >&2; exit 2 ;;
esac
: "${VCS_HOME:?Run on the configured VCS host}"
uvm_dir="$VCS_HOME/etc/uvm-1.2"
build_dir="$ral_script_dir/build/op/$ral_mode"
model_dir="$ral_script_dir/build/$ral_mode"
mkdir -p "$model_dir" "$build_dir"
cd "$model_dir"
ralgen -full64 -uvm -l sv -t aip_fixture "$ral_script_dir/aip_fixture${bits}.ralf" > generate.log 2>&1
cd "$build_dir"
vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+r+w+f -top test_ral_op "${defs[@]}" \
  "+incdir+$ral_root_dir" "+incdir+$ral_root_dir/src/sv" "+incdir+$ral_script_dir" "+incdir+$model_dir" "+incdir+$uvm_dir" \
  "$uvm_dir/uvm_pkg.sv" "$ral_root_dir/tests/sv/test_ral_op.sv" "$uvm_dir/dpi/uvm_dpi.cc" \
  -CFLAGS -DVCS -CFLAGS "-I$uvm_dir/dpi" -Mdir=csrc -o simv > compile.log 2>&1
timeout --kill-after=10s "${RAL_TIMEOUT:-120s}" ./simv -no_save -exitstatus > run.log 2>&1
grep -Eq "^RAL_OP_COMPLETE width=$bits checks=[1-9][0-9]*$" run.log
grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$' run.log
grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$' run.log
printf 'RAL_OP_VALIDATED mode=%s artifacts=%s\n' "$ral_mode" "$build_dir"
