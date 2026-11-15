#!/usr/bin/env bash
set -euo pipefail

dist_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT

# Force make to print build recipes even when a previous invocation already
# produced the artifacts (as happens on a developer or CI host).
make -C "$dist_dir" -Bn all >"$plan"

grep -Fq 'libaip_soload.so' "$plan"
grep -Fq 'libaip_socket_dpi.so' "$plan"
grep -Fq 'libaip_tcl_bridge.so' "$plan"
grep -Fq 'packaging/aip_tcl_bridge.c' "$plan"
grep -Fq 'src/c/runtime/aip_soload.c' "$plan"
grep -Fq 'src/c/runtime/sv_socket_dpi.c' "$plan"
grep -Fq 'src/c/client/client.c' "$plan"
grep -Fq 'aip-client' "$plan"
grep -Fq 'aip_plugin.h' "$plan"

# Toolchain and linker flags must be overrideable when rebuilding on another
# Linux host (for example with clang or a non-default library search path).
make -C "$dist_dir" -Bn all \
    CC=custom-cc \
    CPPFLAGS=-DCUSTOM_CPPFLAG \
    CFLAGS=-O0 \
    LDFLAGS=-Wl,-z,now \
    >"$plan"
grep -Fq 'custom-cc' "$plan"
grep -Fq -- '-DCUSTOM_CPPFLAG' "$plan"
grep -Fq -- '-O0' "$plan"
grep -Fq -- '-Wl,-z,now' "$plan"

# The first release is intentionally x86-64-only and must reject an unrelated
# host architecture before attempting a build.
if make -C "$dist_dir" check-platform HOST_ARCH=aarch64 \
    >/dev/null 2>&1; then
    echo 'expected non-x86-64 platform check to fail' >&2
    exit 1
fi

echo DIST_MAKEFILE_PASS
