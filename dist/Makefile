# Linux x86-64 binary distribution build (dist/lib, dist/bin, dist/include); override ROOT, CC, PYTHON,
# CFLAGS, LDFLAGS and library variables elsewhere. All Tcl sources are embedded into one .so.
# C 产物须保持 C ABI，socket 返回缓冲依赖 C11 TLS，故显式指定 GNU C11（避免编译器包装器默认按 C++ 编译）。

# Resolve paths from this Makefile rather than the caller's current directory,
# so both `make -C dist` and `make -f dist/Makefile` behave identically.
# 保存实际读入的构建文件路径，不能从可覆盖的 DIST_DIR 推导重建依赖。
DIST_BUILD_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
MAKEFILE_DIR := $(dir $(DIST_BUILD_MAKEFILE))
DIST_DIR    ?= $(MAKEFILE_DIR)
DIST_DIR    := $(abspath $(DIST_DIR))
ROOT        ?= $(abspath $(DIST_DIR)/..)

# GNU make's built-in CC=cc: default to gcc only when the caller did not set CC (overrides stay authoritative).
ifeq ($(origin CC),default)
CC          := gcc
endif
PYTHON      ?= python3
TCLSH       ?= tclsh
CFLAGS      ?= -O2 -Wall -Wextra
CPPFLAGS    ?=
LDFLAGS     ?=
PICFLAGS    ?= -fPIC
SHARED      ?= -shared
PKG_CONFIG  ?= pkg-config
# No Tcl headers/runtime: the wrapper dlsym()s the UCLI API (mhpi_ucliTclExecNoPrint); linking a second
# Tcl runtime into a VCS extension can corrupt the host interpreter's allocator, so only libdl is needed.
TCL_BRIDGE_LIBS ?= -ldl
READLINE_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags readline 2>/dev/null || true)
READLINE_LIBS ?= $(shell $(PKG_CONFIG) --libs readline 2>/dev/null || printf '%s' '-lreadline -lhistory')
LDLIBS_SOLOAD ?= -ldl
LDLIBS_SOCKET ?= -ldl -pthread
LDLIBS_CLIENT ?= $(READLINE_LIBS)

# Deliberately Linux x86-64 only: a clear platform error beats an incompatible .so. Override HOST_ARCH
# only for a cross-toolchain known to emit x86-64 binaries.
TARGET_ARCH ?= x86_64
HOST_ARCH   ?= $(shell uname -m 2>/dev/null || printf '%s' unknown)

LIB_DIR     := $(abspath $(DIST_DIR)/lib)
BIN_DIR     := $(abspath $(DIST_DIR)/bin)
INCLUDE_DIR := $(abspath $(DIST_DIR)/include)
GEN_DIR     := $(abspath $(DIST_DIR)/.generated)

TCL_SOURCES := \
    $(ROOT)/src/tcl/aip_sim_control.tcl \
    $(ROOT)/src/tcl/aip_watch.tcl \
    $(ROOT)/src/tcl/aip_inject.tcl \
    $(ROOT)/src/tcl/aip_cmd.tcl \
    $(ROOT)/src/tcl/aip_checkpoint.tcl \
    $(ROOT)/src/tcl/aip_ucli_utils.tcl
TCL_PAYLOAD := $(GEN_DIR)/aip_tcl_payload.h

.PHONY: all check-platform libs tcl socket soload client test test-ucli-tcl test-ucli-so test-ucli-pli clean help

all: check-platform libs client $(INCLUDE_DIR)/aip_plugin.h

check-platform:
	@case "$(HOST_ARCH):$(TARGET_ARCH)" in \
		x86_64:x86_64|amd64:x86_64) ;; \
		*) echo "AIP distribution supports Linux x86-64 only (host=$(HOST_ARCH), target=$(TARGET_ARCH)); set HOST_ARCH/TARGET_ARCH only for a compatible cross-build." >&2; exit 1 ;; \
	esac

libs: \
	check-platform \
	$(LIB_DIR)/libaip_soload.so \
	$(LIB_DIR)/libaip_socket_dpi.so \
	$(LIB_DIR)/libaip_tcl_bridge.so

tcl: check-platform $(LIB_DIR)/libaip_tcl_bridge.so
socket: check-platform $(LIB_DIR)/libaip_socket_dpi.so
soload: check-platform $(LIB_DIR)/libaip_soload.so
client: check-platform $(BIN_DIR)/aip-client

test:
	$(DIST_DIR)/tests/test_makefile.sh
	@# 两组 Tcl 检查串联，任一失败立即向 make 返回非零，不能被后续成功覆盖。
	@if command -v "$(TCLSH)" >/dev/null 2>&1; then \
		"$(TCLSH)" $(DIST_DIR)/tests/test_aip_init.tcl && \
		"$(TCLSH)" $(DIST_DIR)/tests/test_loader_paths.tcl; \
	else \
		echo "SKIP Tcl loader test: $(TCLSH) was not found (set TCLSH=... to run it)"; \
	fi

test-ucli-tcl: check-platform libs
	$(DIST_DIR)/tests/test_ucli_tcl.sh

# Binary Tcl bridge: `load lib/libaip_tcl_bridge.so` inside VCS UCLI.
test-ucli-so: check-platform tcl
	$(DIST_DIR)/tests/test_ucli_so.sh

test-ucli-pli: check-platform
	$(DIST_DIR)/tests/test_ucli_pli_load.sh

$(LIB_DIR) $(BIN_DIR) $(INCLUDE_DIR) $(GEN_DIR):
	mkdir -p $@

$(TCL_PAYLOAD): $(TCL_SOURCES) $(ROOT)/packaging/scripts/embed_tcl.py | $(GEN_DIR)
	$(PYTHON) $(ROOT)/packaging/scripts/embed_tcl.py $@ $(TCL_SOURCES)

# 构建文件本身是依赖（语言模式变化会重建）；在调用者选项之后把每个源码限定为 GNU C11，
# 源码后立即恢复按后缀识别语言，避免额外链接的 .o/归档被当作 C 源码。
$(LIB_DIR)/libaip_tcl_bridge.so: $(ROOT)/packaging/aip_tcl_bridge.c $(TCL_PAYLOAD) $(DIST_BUILD_MAKEFILE) | $(LIB_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(PICFLAGS) $(LDFLAGS) $(SHARED) \
		-I$(GEN_DIR) -o $@ -x c -std=gnu11 $(ROOT)/packaging/aip_tcl_bridge.c -x none $(TCL_BRIDGE_LIBS)

$(LIB_DIR)/libaip_soload.so: $(ROOT)/src/c/runtime/aip_soload.c $(ROOT)/include/aip_plugin.h $(DIST_BUILD_MAKEFILE) | $(LIB_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(PICFLAGS) $(LDFLAGS) $(SHARED) \
		-I$(ROOT)/include -o $@ -x c -std=gnu11 $(ROOT)/src/c/runtime/aip_soload.c -x none $(LDLIBS_SOLOAD)

$(LIB_DIR)/libaip_socket_dpi.so: $(ROOT)/src/c/runtime/sv_socket_dpi.c $(DIST_BUILD_MAKEFILE) | $(LIB_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(PICFLAGS) $(LDFLAGS) $(SHARED) \
		-o $@ -x c -std=gnu11 $(ROOT)/src/c/runtime/sv_socket_dpi.c -x none $(LDLIBS_SOCKET)

$(BIN_DIR)/aip-client: $(ROOT)/src/c/client/client.c $(DIST_BUILD_MAKEFILE) | $(BIN_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(READLINE_CFLAGS) $(LDFLAGS) \
		-o $@ -x c -std=gnu11 $(ROOT)/src/c/client/client.c -x none $(LDLIBS_CLIENT)

$(INCLUDE_DIR)/aip_plugin.h: $(ROOT)/include/aip_plugin.h | $(INCLUDE_DIR)
	cp $< $@

clean:
	rm -rf $(GEN_DIR) \
		$(LIB_DIR)/libaip_soload.so \
		$(LIB_DIR)/libaip_socket_dpi.so \
		$(LIB_DIR)/libaip_tcl_bridge.so \
		$(BIN_DIR)/aip-client \
		$(INCLUDE_DIR)/aip_plugin.h

help:
	@echo 'AIP Linux x86-64 distribution targets:'
	@echo '  make -C dist all       build all libraries, client and header'
	@echo '  make -C dist libs      build the three runtime C shared libraries'
	@echo '  make -C dist clean     remove generated distribution artifacts'
	@echo '  make -C dist test      run loader and Makefile contract tests'
	@echo '  make -C dist test-ucli-tcl  compile and run the VCS UCLI Tcl smoke test'
	@echo '  make -C dist test-ucli-so   load lib/libaip_tcl_bridge.so inside VCS UCLI'
	@echo '  make -C dist test-ucli-pli  load a standalone C UCLI/PLI shared library'
	@echo 'Overrides: CC=clang CFLAGS=... CPPFLAGS=... LDFLAGS=...'
