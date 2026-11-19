# AIP core — VCS regression targets (run `make help` for the list).
# 每个目标拥有自己的 simv、csrc 和日志，clean 统一清理。
MAKEFILE_DIR        := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
AIP_ROOT_DIR        := $(abspath $(MAKEFILE_DIR))
AIP_INCLUDE_DIR     := $(AIP_ROOT_DIR)/include
# Per-case wall-clock guard for the checker matrix; override on slower hosts.
CHECKER_CASE_TIMEOUT ?= 60s
# UCLI `save` forks a child and waits for it, and intermittently that child
# never finishes, so a snapshot step can hang (see docs/KNOWN_ISSUES.md).
# The checkpoint targets therefore run under a timeout and retry.
CKPT_TIMEOUT  ?= 120s
CKPT_ATTEMPTS ?= 3
TEST_DIR             := tests
TEST_SV_DIR          := $(TEST_DIR)/sv
TEST_TCL_DIR         := $(TEST_DIR)/tcl
TEST_PLUGIN_DIR      := $(TEST_DIR)/plugins

# VCS commands below run from tests/sv/, so include every canonical SV component
# directory plus the root compatibility entry point.
AIP_TEST_INCDIRS := +incdir+../.. +incdir+../../src/sv +incdir+../../src/sv/core \
	+incdir+../../src/sv/bridge +incdir+../../src/sv/util +incdir+../../src/sv/plugin \
	+incdir+../../src/sv/cpu_mem

.PHONY: all help test_reg_seq test_user_seq test_soload test_tcl_watchdog test_checkpoint_wait_tcl test_checkpoint_wait_vcs test_checkpoint_restore test_end_checker_registry test_cmdline_negative test_cmdline_container_syntax test_cmdline_print_control test_cmdline_wide test_cmdline_array_random test_cmdline_struct_schema_scalar test_cmdline_struct_schema_containers test_cmdline_struct_schema_typed_postprocess test_cmdline_struct_schema_nested test_cmdline_struct_schema_nested_canonical test_cmdline_struct_schema_final_review test_cmdline_struct_schema_queue test_cmdline_struct_schema_integration test_cmdline_struct_schema_negative test_cmdline_strict_queue test_cmdline_struct_schema_lifecycle test_cmdline_struct_schema_width_fail test_cmdline_struct_schema_primitive_arrays test_cmdline_struct_schema_size_budget test_cmdline_struct_schema test_core_package test_core_package_preinclude test_cpu_bridge test_cseq_arbitration test_c_bridge_socket test_dut_control test_str_delim test_cmd_str_result test_x_watch_vcs clean
.PHONY: test_cmdline_zero_weight test_cmdline_diagnostics
.PHONY: test_cmd_wait test_cmd_ack_progress test_wait_policy test_cmdline_query test_parse_uint_arg test_aip_flags
.PHONY: test_seq_registry_active test_aip_bind_seq test_aip_bind_seq_checkpoint
.PHONY: test_scb test_mon_hub
.PHONY: test_reg_wide
.PHONY: test_cmd_result_context
.PHONY: test_cmd_compat test_checkpoint_background test_checkpoint_cmdline test_cmdline_restore_loader_tcl ci-cmd
.PHONY: test_sim_control_tcl test_watch_tcl test_live_resume
.PHONY: test_paused_injection test_inject_tcl test_inject_queue
.PHONY: test_cmdline_zero_weight test_cmdline_diagnostics test_cmdline_split test_cmdline_split_positive test_cmdline_split_internal_reject test_cmdline_split_legacy_selftest
.PHONY: bench_cmdline bench_cmdline_build
.PHONY: test_ral_config test_ral_config_128 test_ral_foundation test_ral test_ral_128
.PHONY: test_ral_lifecycle test_ral_lifecycle_128 test_ral_op test_ral_op_128 test_ral_transport test_ral_transport_128

all: help

# RAL 基础契约与配置索引；每个目标重编 UVM 源码，不复用预编译 UVM 或跨宽度缓存。
test_ral_config:
	bash tests/ral/run_foundation.sh default

test_ral_config_128:
	bash tests/ral/run_foundation.sh width128

test_ral_foundation:
	$(MAKE) test_ral_config
	$(MAKE) test_ral_config_128

test_ral:
	$(MAKE) test_ral_config
	$(MAKE) test_ral_transport
	$(MAKE) test_ral_op

test_ral_128:
	$(MAKE) test_ral_config_128
	$(MAKE) test_ral_transport_128
	$(MAKE) test_ral_op_128

# RAL 命令生命周期：独立目录与真实 UCLI 入口，不并入 foundation 覆盖。
test_ral_lifecycle:
	bash tests/ral/run_lifecycle.sh default

test_ral_lifecycle_128:
	bash tests/ral/run_lifecycle.sh width128

# RAL transport 与命名访问（ral_op）；每个目标在独立宽度目录中重编 UVM/DPI。
test_ral_transport:
	bash tests/ral/run_transport.sh default

test_ral_transport_128:
	bash tests/ral/run_transport.sh width128

test_ral_op:
	bash tests/ral/run_op.sh default

test_ral_op_128:
	bash tests/ral/run_op.sh width128

help:
	@echo "RAL foundation: test_ral_config test_ral_config_128 test_ral_foundation (VCS host only)"
	@echo "RAL lifecycle: test_ral_lifecycle test_ral_lifecycle_128 (VCS/UCLI host only)"
	@echo "RAL transport: test_ral_transport test_ral_transport_128 (VCS host only)"
	@echo "RAL op: test_ral_op test_ral_op_128 (VCS host only)"
	@echo "RAL aggregate: test_ral test_ral_128 (VCS host only)"
	@echo "SV regression targets (VCS on PATH): test_core_package test_core_package_preinclude"
	@echo "  test_cpu_bridge test_reg_seq test_reg_wide test_user_seq test_soload test_tcl_watchdog test_checkpoint_wait_vcs"
	@echo "  test_wait_policy (shared wait/timeout policy: multiplier, timeouts, attempt cap, load_params)"
	@echo "  test_parse_uint_arg (strict unsigned command arguments: default, negative, non-numeric, max)"
	@echo "  test_aip_flags (enum bit flags by name or mask: plusarg, set_param, hierarchy, fatal on unknown names)"
	@echo "  test_seq_registry_active (aip_cmd_seq_registry::active: running, unregistered, killed owner, stale entry)"
	@echo "  test_aip_bind_seq (Tcl aip_bind_seq/aip_unbind_seq, seq results, strict count, time= limit, aip_sqr_registry, errors; source+.so)"
	@echo "  test_aip_bind_seq_checkpoint (runtime-registered commands across save/restore in a new process; source+.so)"
	@echo "  test_scb (aip_scb ordered/lossy/unordered/keyed matching and the 14-case report-limit matrix)"
	@echo "  test_mon_hub (aip_mon_hub/aip_sample_seq: per-subscriber copies, blocking/timeout, reset, overflow, readers)"
	@echo "  test_cmd_wait (per-command async wait=0 and synchronous default)"
	@echo "  test_cmd_ack_progress (Tcl ACK wait counts only time without activity progress)"
	@echo "  test_cmd_result_context (isolated results, legacy compatibility, expired-context rejection)"
	@echo "  test_cmd_compat (direct SV calls, nested legacy results, raw argument preservation)"
	@echo "  test_checkpoint_background (save/restore with active local, legacy and UVM workers)"
	@echo "  test_live_resume (real VCS source/.so, native pause/resume, watch, pending seq and legacy replay)"
	@echo "  test_x_watch_vcs (real VCS four-state X/Z watch callbacks)"
	@echo "  test_paused_injection (real VCS paused command FIFO, results, cancellation and capacity)"
	@echo "  test_sim_control_tcl test_watch_tcl test_inject_tcl (host-only control/parser tests)"
	@echo "  test_end_checker_registry test_checkpoint_restore test_cmdline_negative test_cmdline_container_syntax"
	@echo "  test_cmdline_print_control test_cmdline_wide test_cmdline_array_random"
	@echo "  test_cmdline_zero_weight (zero weights and source diagnostics)"
	@echo "  test_cmdline_diagnostics (fatal parse errors and user source locations)"
	@echo "  test_cmdline_opt (optional _opt reads, path aliases, array root selection, enum rand/values, unused keys)"
	@echo "  test_cmdline_unsigned (unsigned targets reject negative and out-of-range values on every parse path)"
	@echo "  test_cmdline_signed (signed targets: decimal range check, based literals as two's-complement bit patterns)"
	@echo "  test_cmdline_split (standalone/package compatibility and internal include rejection)"
	@echo "  bench_cmdline (parser performance baseline for the reference server; no production optimizations)"
	@echo "  test_cmdline_struct_schema (focused aggregate), including integration and negative matrices"
	@echo "  test_cmdline_strict_queue"
	@echo "  test_cseq_arbitration test_c_bridge_socket test_dut_control test_str_delim test_cmd_str_result"
	@echo "Host-only: test_checkpoint_wait_tcl (tclsh), ci-host (gcc)"
	@echo "CI bundles: ci-host ci-sv ci-cmd ci-regress ci; distribution: make -C dist all|test"

# 控制层 host 状态机单测，不能替代真实 VCS 回归；二者都属于暂停续跑门禁。
test_sim_control_tcl:
	tclsh $(TEST_TCL_DIR)/test_sim_control_unit.tcl

test_watch_tcl:
	tclsh $(TEST_TCL_DIR)/test_watch_unit.tcl

# 纯Tcl协议/参数检查不需要VCS；真实暂停与队列调度另由PTY目标覆盖。
test_inject_tcl:
	tclsh $(TEST_TCL_DIR)/test_inject_unit.tcl

# runner每次重建真实.so及专属simv，source/二进制入口均实际PTY交互。
test_live_resume:
	python3 tests/live_resume/run_live_resume.py

# 真实 VCS 四态变化回归；验证 x/z 目标走 stop -change 并保留部分未知值。
test_x_watch_vcs:
	$(MAKE) -C dist tcl
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca -debug_access+all \
	    $(AIP_TEST_INCDIRS) -top test_x_watch_fixture -o simv_x_watch \
	    -Mdir=csrc_x_watch test_x_watch_fixture.sv
	cd $(TEST_SV_DIR) && AIP_CORE=$(CURDIR) AIP_X_WATCH_LOADER=source ./simv_x_watch \
	    -ucli -do ../tcl/test_x_watch_vcs.tcl -no_save -exitstatus > x_watch_vcs_source.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fq 'AIP_X_WATCH_PASS' x_watch_vcs_source.log
	cd $(TEST_SV_DIR) && AIP_CORE=$(CURDIR) AIP_X_WATCH_LOADER=so ./simv_x_watch \
	    -ucli -do ../tcl/test_x_watch_vcs.tcl -no_save -exitstatus > x_watch_vcs_so.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fq 'AIP_X_WATCH_PASS' x_watch_vcs_so.log

# 独立PTY与构建目录，必须在VCS主机运行；不复用已编译的旧SV队列。
test_paused_injection:
	python3 tests/paused_injection/run_paused_injection.py

# SV级准入/队列机制与真实UVM driver独立验证；不依赖Tcl轮询伪造完成。
test_inject_queue:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -top test_inject_queue -o simv_inject_queue -Mdir=csrc_inject_queue test_inject_queue.sv
	cd $(TEST_SV_DIR) && timeout --kill-after=10s 90s ./simv_inject_queue -no_save -exitstatus \
	    > inject_queue.log 2>&1 || { cat inject_queue.log; exit 1; }
	@cat $(TEST_SV_DIR)/inject_queue.log
	@grep -Eq '^INJECT_QUEUE_PASS checks=[0-9]+ driver_count=3$$' $(TEST_SV_DIR)/inject_queue.log
	@! grep -Eq '^Error-|^Fatal:|^UVM_(ERROR|FATAL) @' $(TEST_SV_DIR)/inject_queue.log
	@grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0$$' $(TEST_SV_DIR)/inject_queue.log
	@grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0$$' $(TEST_SV_DIR)/inject_queue.log
	@grep -Eq '^UVM_WARNING[[:space:]]*:[[:space:]]*0$$' $(TEST_SV_DIR)/inject_queue.log

test_checkpoint_wait_tcl:
	@tclsh $(TEST_TCL_DIR)/test_checkpoint_wait.tcl > $(TEST_TCL_DIR)/checkpoint_wait_tcl.log 2>&1 \
	    || { cat $(TEST_TCL_DIR)/checkpoint_wait_tcl.log; exit 1; }
	@cat $(TEST_TCL_DIR)/checkpoint_wait_tcl.log
	@grep -Fxq CHECKPOINT_WAIT_TCL_PASS $(TEST_TCL_DIR)/checkpoint_wait_tcl.log

# save/restore only needs the +r that the bridge already requires; +r+w+f is
# the documented user build, so the checkpoint regression runs with exactly that.
test_checkpoint_wait_vcs: $(TEST_SV_DIR)/test_checkpoint_wait.sv $(TEST_TCL_DIR)/test_checkpoint_wait_vcs.tcl
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_checkpoint_wait -Mdir=csrc_checkpoint_wait \
	    test_checkpoint_wait.sv
	cd $(TEST_SV_DIR) && attempt=1; while : ; do \
	    if timeout $(CKPT_TIMEOUT) ./simv_checkpoint_wait \
	           -ucli -do ../tcl/test_checkpoint_wait_vcs.tcl \
	           > checkpoint_wait_vcs.log 2>&1; then break; fi; \
	    if [ $$attempt -ge $(CKPT_ATTEMPTS) ]; then \
	        cat checkpoint_wait_vcs.log; \
	        echo "test_checkpoint_wait_vcs failed after $(CKPT_ATTEMPTS) attempts"; \
	        exit 1; \
	    fi; \
	    echo "attempt $$attempt failed (UCLI save hangs intermittently); retrying"; \
	    attempt=$$((attempt+1)); \
	done
	cd $(TEST_SV_DIR) && cat checkpoint_wait_vcs.log \
	    && test "$$(grep -Fxc CHECKPOINT_WAIT_VCS_PASS checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Ec '^\[AIP_STATE_CKPT\] STATE_(ONE|TWO|THREE|FOUR) ' checkpoint_wait_vcs.log)" -eq 4 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_ONE ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_TWO ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_THREE ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_FOUR ' checkpoint_wait_vcs.log)" -eq 1 \
	    && ! grep -Eq '^FAIL ' checkpoint_wait_vcs.log

test_end_checker_registry:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
		-debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
		-o simv_end_checker -Mdir=csrc_end_checker \
		test_end_checker_registry.sv
	cd $(TEST_SV_DIR) && set -e; \
		for case_name in legacy direct_legacy idle_compat multi legacy_named same_handle \
			failure failure_nonstrict \
			cleanup_single cleanup_drain cleanup_multi cleanup_semicolon cleanup_failure \
			nonstrict_timeout strict_timeout multi_timeout strict_missing \
			watchdog_end_test watchdog_fork_end_test watchdog_end_test_drain \
			watchdog_fork_end_test_drain watchdog_fork_end_test_idle \
			invalid remove frozen; do \
			log="end_checker_$${case_name}.log"; \
			if ! timeout $(CHECKER_CASE_TIMEOUT) ./simv_end_checker \
				-ucli -do ../tcl/test_end_checker_registry.tcl \
				+CHECKER_CASE=$${case_name} +UVM_NO_RELNOTES > $$log 2>&1; then \
				cat $$log; \
				exit 1; \
			fi; \
			cat $$log; \
			grep -Fq "CHECKER_REGISTRY_PASS case=$${case_name}" $$log; \
			grep -Fq "CHECKER_REGISTRY_REPORT_PASS case=$${case_name}" $$log; \
		done

# Checkpoint save + restore round trip — requires VCS on PATH.
test_checkpoint_restore: $(TEST_SV_DIR)/test_checkpoint_wait.sv $(TEST_TCL_DIR)/ckpt_gen_base.tcl $(TEST_TCL_DIR)/ckpt_test_restore.tcl
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_ckpt_restore -Mdir=csrc_ckpt_restore \
	    test_checkpoint_wait.sv
	cd $(TEST_SV_DIR) && attempt=1; while : ; do \
	    if timeout $(CKPT_TIMEOUT) ./simv_ckpt_restore \
	           -ucli -do ../tcl/ckpt_gen_base.tcl > ckpt_gen.log 2>&1; then break; fi; \
	    if [ $$attempt -ge $(CKPT_ATTEMPTS) ]; then \
	        cat ckpt_gen.log; \
	        echo "snapshot creation failed after $(CKPT_ATTEMPTS) attempts"; \
	        exit 1; \
	    fi; \
	    echo "attempt $$attempt failed (UCLI save hangs intermittently); retrying"; \
	    attempt=$$((attempt+1)); \
	done
	cd $(TEST_SV_DIR) && cat ckpt_gen.log && grep -Fxq BASE_GEN_DONE ckpt_gen.log
	@# The restored session must reproduce the pre-snapshot bridge result exactly.
	cd $(TEST_SV_DIR) && grep -o "BASE_GEN_DUT_GET.*" ckpt_gen.log | tail -1 \
	    | sed 's/^BASE_GEN_DUT_GET //' > ckpt_dut_get.base
	@# The restore stage takes a chained snapshot of its own, so it can hang too.
	cd $(TEST_SV_DIR) && attempt=1; while : ; do \
	    if timeout $(CKPT_TIMEOUT) ./simv_ckpt_restore \
	           -ucli -do ../tcl/ckpt_test_restore.tcl > ckpt_restore.log 2>&1; then break; fi; \
	    if [ $$attempt -ge $(CKPT_ATTEMPTS) ]; then \
	        cat ckpt_restore.log; \
	        echo "restore stage failed after $(CKPT_ATTEMPTS) attempts"; \
	        exit 1; \
	    fi; \
	    echo "attempt $$attempt failed (UCLI save hangs intermittently); retrying"; \
	    attempt=$$((attempt+1)); \
	done
	cd $(TEST_SV_DIR) && cat ckpt_restore.log \
	    && grep -Fxq RESTORE_COMMANDS_OK ckpt_restore.log \
	    && grep -Fxq RESTORE_TEST_DONE ckpt_restore.log \
	    && ! grep -Eq '^FAIL ' ckpt_restore.log
	cd $(TEST_SV_DIR) && grep -o "AFTER_RESTORE_DUT_GET.*" ckpt_restore.log | tail -1 \
	    | sed 's/^AFTER_RESTORE_DUT_GET rc=[0-9]* //' > ckpt_dut_get.restored
	cd $(TEST_SV_DIR) && diff ckpt_dut_get.base ckpt_dut_get.restored \
	    && echo "RESTORE_MATCHES_BASELINE"

# 后台在途快照使用专属binary/csrc/快照目录，不与原空闲checkpoint用例共享产物。
test_checkpoint_background:
	CKPT_TIMEOUT=$(CKPT_TIMEOUT) CKPT_ATTEMPTS=$(CKPT_ATTEMPTS) bash tests/checkpoint/run_background.sh

# 当前进程 CLI 恢复来源矩阵，默认源码/.so 双入口；产物留在专属临时目录供审查。
test_checkpoint_cmdline:
	CKPT_TIMEOUT=$(CKPT_TIMEOUT) CKPT_ATTEMPTS=$(CKPT_ATTEMPTS) bash tests/checkpoint/run_cmdline.sh

# 纯 Tcl 加载生命周期与失败重试，不需要 VCS；实际 restore 另由上面的集成矩阵覆盖。
test_cmdline_restore_loader_tcl:
	tclsh tests/tcl/test_cmdline_restore_loader.tcl

# Register R/W seq macro test — requires VCS on PATH
test_reg_seq:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_reg_seq \
	    -Mdir=csrc_reg_seq \
	    test_reg_seq.sv
	cd $(TEST_SV_DIR) && ./simv_reg_seq -ucli -do ../tcl/test_reg_seq.tcl

# 宽寄存器解析和结果回传；仅在配置了 VCS/license 的验证主机执行。
test_reg_wide:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_reg_wide -Mdir=csrc_reg_wide test_reg_wide.sv
	cd $(TEST_SV_DIR) && ./simv_reg_wide +UVM_NO_RELNOTES > reg_wide.log 2>&1
	cd $(TEST_SV_DIR) && cat reg_wide.log \
	    && grep -q '\[REG_WIDE_PASS\]' reg_wide.log \
	    && grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$$' reg_wide.log \
	    && grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$$' reg_wide.log

# Zero-adaptation user sequence registration test — requires VCS on PATH
test_user_seq:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_user_seq \
	    -Mdir=csrc_user_seq \
	    test_user_seq.sv
	cd $(TEST_SV_DIR) && ./simv_user_seq -ucli -do ../tcl/test_user_seq.tcl > user_seq.log 2>&1 \
	    || { cat user_seq.log; exit 1; }
	cd $(TEST_SV_DIR) && cat user_seq.log && grep -Fxq USER_SEQ_PASS user_seq.log && ! grep -q '^\[FAIL\]' user_seq.log

# Tcl 运行时绑定 seq 命令（aip_bind_seq/aip_unbind_seq）：同一脚本分别经源码与 .so loader 运行；
# Tcl/SV 双标记，另核对 help 列表中的运行时命令分组与绑定描述。
test_aip_bind_seq:
	$(MAKE) -C dist tcl
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) -top test_aip_bind_seq \
	    -o simv_aip_bind_seq -Mdir=csrc_aip_bind_seq test_aip_bind_seq.sv
	cd $(TEST_SV_DIR) && set -e; for loader in source so; do \
	    log=aip_bind_seq_$$loader.log; \
	    AIP_CORE=$(CURDIR) AIP_BIND_SEQ_LOADER=$$loader timeout 300s ./simv_aip_bind_seq -no_save -ucli \
	        -do ../tcl/test_aip_bind_seq.tcl +UVM_NO_RELNOTES > $$log 2>&1 || { cat $$log; exit 1; }; \
	    if ! grep -Eq '^BIND_SEQ_TCL_PASS checks=[0-9]+$$' $$log \
	        || ! grep -Fxq BIND_SEQ_SV_PRECHECK_PASS $$log \
	        || ! grep -Eq '^BIND_SEQ_SV_PASS a=[0-9]+ b=[0-9]+$$' $$log \
	        || ! grep -Fxq '[aip_bind_seq]' $$log \
	        || ! grep -Eq '^  rs_p1 +- type=rs_path_seq sqr=uvm_test_top\.env\.a\.sqr path=rs\.p1$$' $$log \
	        || ! grep -Eq '^  rs_a +uvm_test_top\.env\.a\.sqr$$' $$log \
	        || ! grep -Eq '^  rs_b +uvm_test_top\.env\.b\.sqr$$' $$log \
	        || ! grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$$' $$log \
	        || ! grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$$' $$log \
	        || grep -Eq '^BIND_SEQ_FAIL|^Error-|no ack after' $$log; then \
	        cat $$log; echo "test_aip_bind_seq failed (loader=$$loader)"; exit 1; \
	    fi; \
	    grep -E '^BIND_SEQ_(TCL|SV)_PASS' $$log; \
	done

# 运行时绑定的 seq 命令随快照保存/恢复：新进程 restore 后核对注册表、Tcl 命令名表重读与命令行为；源码/.so 两种 loader。
test_aip_bind_seq_checkpoint:
	CKPT_TIMEOUT=$(CKPT_TIMEOUT) CKPT_ATTEMPTS=$(CKPT_ATTEMPTS) bash tests/checkpoint/run_bind_seq.sh

# set_param 表达式须与 plusarg 共用语义并经真实 Tcl/UCLI 验证；Python runner 保留每条负例日志。
.PHONY: test_set_param_expressions bench_set_param_build
# 只构建微基准；运行时用 BENCH_KIND/SOURCE/ITERS 与 bench.iv/rv 控制输入。
bench_set_param_build:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_set_param_benchmark -Mdir=csrc_set_param_benchmark test_set_param_benchmark.sv ../bench/cmdline_bench_clock.c

test_set_param_expressions:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_set_param_expressions -Mdir=csrc_set_param_expressions test_set_param_expressions.sv
	cd $(TEST_SV_DIR) && python3 ../param/run_set_param_expressions.py
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca -debug_access+r+w+f $(AIP_TEST_INCDIRS) -o simv_set_param_tcl -Mdir=csrc_set_param_tcl test_set_param_tcl.sv
	cd $(TEST_SV_DIR) && timeout 90s ./simv_set_param_tcl -no_save -exitstatus -ucli -do ../tcl/test_set_param_expressions.tcl +tclcfg.value=19 > set_param_tcl.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq SET_PARAM_TCL_PASS set_param_tcl.log && grep -Fxq SET_PARAM_TCL_SV_PASS set_param_tcl.log

# 逐命令异步控制端到端回归；Tcl 与 SV 双标记，避免 UCLI 回显脚本文字造成假 PASS。
test_cmd_wait:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_cmd_wait -Mdir=csrc_cmd_wait test_cmd_wait.sv
	cd $(TEST_SV_DIR) && timeout 180s ./simv_cmd_wait -no_save -ucli \
	    -do ../tcl/test_cmd_wait.tcl +UVM_NO_RELNOTES > cmd_wait.log 2>&1 \
	    || { cat cmd_wait.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmd_wait.log \
	    && grep -Eq '^CMD_WAIT_TCL_PASS checks=[0-9]+$$' cmd_wait.log \
	    && grep -Eq '^CMD_WAIT_SV_PASS driver_count=[0-9]+$$' cmd_wait.log \
	    && grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$$' cmd_wait.log \
	    && grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$$' cmd_wait.log \
	    && ! grep -Eq '^CMD_WAIT_FAIL|^Error-|no ack after' cmd_wait.log

# Tcl ACK 只计无活动进展时间：长命令等到真实结果、watchdog 结果先于 Tcl 放弃、禁用 watchdog 时
# 按预算放弃（全日志恰一条告警）、快命令时序不变。
test_cmd_ack_progress:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) -top test_cmd_ack_progress \
	    -o simv_cmd_ack_progress -Mdir=csrc_cmd_ack_progress test_cmd_ack_progress.sv
	cd $(TEST_SV_DIR) && timeout 300s ./simv_cmd_ack_progress -no_save -ucli \
	    -do ../tcl/test_cmd_ack_progress.tcl > cmd_ack_progress.log 2>&1 \
	    || { cat cmd_ack_progress.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmd_ack_progress.log \
	    && grep -Eq '^CMD_ACK_PROGRESS_PASS checks=[0-9]+$$' cmd_ack_progress.log \
	    && test "$$(grep -c 'no ack after' cmd_ack_progress.log)" -eq 1 \
	    && ! grep -Eq '^CMD_ACK_PROGRESS_FAIL|^Error-' cmd_ack_progress.log

# 通用等待策略：倍率/饱和、poll/事件超时、次数上限、自行轮询与 load_params；纯 SV，无需 DPI 库。
test_wait_policy:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_wait_policy -o simv_wait_policy -Mdir=csrc_wait_policy test_wait_policy.sv
	cd $(TEST_SV_DIR) && ./simv_wait_policy +twp.wait.poll_ns=7 +twp.wait.timeout_ns=500 +twp.wait.multiplier=4 +twp.wait.max_polls=99 > wait_policy.log 2>&1 || { cat wait_policy.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TWP_|TEST_WAIT_POLICY|^UVM_(ERROR|FATAL) *:' wait_policy.log && grep -q TEST_WAIT_POLICY_PASS wait_policy.log

# aip_uint 负数拒绝与 aip_cmdline_query::present 键匹配；负数路径单独运行，预期 hard fatal。
test_cmdline_query:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_cmdline_query -o simv_cmdline_query -Mdir=csrc_cmdline_query test_cmdline_query.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_query +q.cnt=5 "+q.list[1]=3" +q.sub.x=1 +leaf=7 > cmdline_query.log 2>&1 || { cat cmdline_query.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TCQ_|TEST_CMDLINE_QUERY' cmdline_query.log && grep -q TEST_CMDLINE_QUERY_PASS cmdline_query.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_query +tcq_neg +q.neg=-3 > cmdline_query_neg.log 2>&1 || true; }
	cd $(TEST_SV_DIR) && grep -q 'requires an unsigned value' cmdline_query_neg.log && ! grep -q TCQ_FAIL cmdline_query_neg.log && echo 'TCQ_OK:   negative unsigned input is a hard fatal'

# 可选参数 _opt、aip_cmdline_alias 别名链、选根容器、枚举 rand/数值候选、aip_cmdline_usage 未用键；负例逐项 hard fatal。
.PHONY: test_cmdline_opt test_cmdline_unsigned test_cmdline_signed
test_cmdline_opt:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_cmdline_opt -o simv_cmdline_opt -Mdir=csrc_cmdline_opt test_cmdline_opt.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_opt -no_save -exitstatus +o.outer_x.v=21 +o.x.v=22 +v=23 +o.x.pa=22 +pa=23 +pl=23 \
	    +o.outer_x.pe= +o.x.pe=5 +o.outer_x.arr2=1,2 +u.y.typo=1 > cmdline_opt.log 2>&1 || { cat cmdline_opt.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TCO_|TEST_CMDLINE_OPT' cmdline_opt.log && grep -q TEST_CMDLINE_OPT_PASS cmdline_opt.log && ! grep -q TCO_FAIL cmdline_opt.log
	cd $(TEST_SV_DIR) && set -e; \
	    for c in enum_number enum_range enum_rand_list opt_syntax; do \
	        case $$c in \
	            enum_number)    expect="candidate[1] '7' not found in enum"; where="parameter='+bad.e' value='A,7'";; \
	            enum_range)     expect="candidate[0] '[1:5]' not found in enum"; where="parameter='+bad.e'";; \
	            enum_rand_list) expect="candidate[0] 'rand' not found in enum"; where="parameter='+bad.e'";; \
	            opt_syntax)     expect="Range min > max"; where="parameter='+bad.x.v' value='[5:1]'";; \
	        esac; \
	        rc=0; ./simv_cmdline_opt -no_save -exitstatus +tco_neg=$$c > cmdline_opt_neg_$$c.log 2>&1 || rc=$$?; \
	        test $$rc -ne 0 || { cat cmdline_opt_neg_$$c.log; echo "TCO_FAIL: negative $$c was accepted"; exit 1; }; \
	        grep -F '[FATAL]' cmdline_opt_neg_$$c.log | grep -F "$$expect" | grep -Fq "$$where" \
	            || { cat cmdline_opt_neg_$$c.log; echo "TCO_FAIL: negative $$c diagnostics"; exit 1; }; \
	        ! grep -q TCO_FAIL cmdline_opt_neg_$$c.log; \
	        echo "TCO_OK:   negative $$c is a hard fatal: $$expect"; \
	    done

# 无符号目标拒绝负数与越界（plusarg、set_param、列表/索引/.each、严格 queue、schema、旧版 struct、flags、_opt）。
test_cmdline_unsigned:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_cmdline_unsigned -o simv_cmdline_unsigned -Mdir=csrc_cmdline_unsigned test_cmdline_unsigned.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_unsigned -no_save -exitstatus +tu.u8=255 "+tu.u8h=8'hFF" +tu.u8x=0xff +tu.u32=4294967295 \
	    +tu.u64=18446744073709551615 "+tu.u128=128'hffffffffffffffffffffffffffffffff" +tu.i32=-2147483648 +tu.s8=-128 \
	    "+tu.r8=[250:255]" "+tu.w8={0:=1,255:=1}" +tu.arr8=0,255 +tu.cfg.u8f=255 +tu.cfg.s32f=-7 +tu.flags=F1,F7 \
	    > cmdline_unsigned.log 2>&1 || { cat cmdline_unsigned.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TCU_|TEST_CMDLINE_UNSIGNED' cmdline_unsigned.log && grep -q TEST_CMDLINE_UNSIGNED_PASS cmdline_unsigned.log && ! grep -q TCU_FAIL cmdline_unsigned.log
	cd $(TEST_SV_DIR) && set -e; \
	    for c in plusarg zero sized wrap64 over over_sized over_hex over64 range weight_value weight_negative inc \
	             override override_expr list each index queue schema legacy flags opt; do \
	        neg8="negative value"; rng="for unsigned 8-bit bit[7:0] (allowed 0..255)"; where="parameter='+tu.bad8'"; \
	        case $$c in \
	            plusarg)         set -- "+tu.bad8=-1";       expect="$$neg8 -1 $$rng"; where="$$where value='-1'";; \
	            zero)            set -- "+tu.bad8=-0";       expect="$$neg8 -0 $$rng";; \
	            sized)           set -- "+tu.bad8=-8'h1";    expect="$$neg8 -8'h1 $$rng";; \
	            wrap64)          set -- "+tu.bad64=-18446744073709551615"; where="parameter='+tu.bad64'"; \
	                             expect="$$neg8 -18446744073709551615 for unsigned 64-bit longint unsigned (allowed 0..18446744073709551615)";; \
	            over)            set -- "+tu.bad8=256";      expect="value 256 exceeds 8-bit bit[7:0] (allowed 0..255)";; \
	            over_sized)      set -- "+tu.bad8=9'h100";   expect="value 9'h100 exceeds 8-bit bit[7:0] (allowed 0..255)";; \
	            over_hex)        set -- "+tu.bad8=0x100";    expect="value 0x100 exceeds 8-bit bit[7:0] (allowed 0..255)";; \
	            over64)          set -- "+tu.bad64=0x1_0000_0000_0000_0000"; where="parameter='+tu.bad64'"; \
	                             expect="value 0x1_0000_0000_0000_0000 exceeds 64-bit longint unsigned (allowed 0..18446744073709551615)";; \
	            range)           set -- "+tu.bad8=[-1:5]";   expect="$$neg8 -1 $$rng";; \
	            weight_value)    set -- "+tu.bad8={-1:=1,2:=1}"; expect="$$neg8 -1 $$rng";; \
	            weight_negative) set -- "+tu.bad8={1:=-1,2:=1}"; expect="Weight must be >= 0";; \
	            inc)             set -- "+tu.bad8=inc:-4:4:2"; expect="$$neg8 -4 $$rng";; \
	            override)        set -- ;                     expect="$$neg8 -1 $$rng"; where="$$where value='-1'";; \
	            override_expr)   set -- ;                     expect="$$neg8 -3 $$rng";; \
	            list)            set -- "+tu.arr8=1,-1";      expect="$$neg8 -1 $$rng"; where="parameter='+tu.arr8[1]'";; \
	            each)            set -- "+tu.arr8.size=2" "+tu.arr8.each=-1"; expect="$$neg8 -1 $$rng"; where="parameter='+tu.arr8.each'";; \
	            index)           set -- "+tu.arr8[0]=-1";     expect="$$neg8 -1 $$rng"; where="parameter='+tu.arr8[0]'";; \
	            queue)           set -- "+tu.q8=1,-1";        where="[AIP_STRUCT]"; \
	                             expect="tu.q8[1] integral token '-1' is negative for unsigned 8-bit target (allowed 0..255)";; \
	            schema)          set -- "+tu.ncfg.u8f=-1";    where="[AIP_STRUCT]"; \
	                             expect="tu.ncfg.u8f integral token '-1' is negative for unsigned 8-bit target (allowed 0..255)";; \
	            legacy)          set -- "+tu.leg.f8=-1";      expect="$$neg8 -1 $$rng"; where="parameter='+tu.leg.f8'";; \
	            flags)           set -- "+tu.flags8=-1";      expect="negative mask -1; flags are unsigned (allowed 0..0xff)"; where="parameter='+tu.flags8'";; \
	            opt)             set -- "+tu.opt8=-5";        expect="$$neg8 -5 $$rng"; where="parameter='+tu.opt8' value='-5'";; \
	        esac; \
	        rc=0; ./simv_cmdline_unsigned -no_save -exitstatus +tcu_neg=$$c "$$@" > cmdline_unsigned_neg_$$c.log 2>&1 || rc=$$?; \
	        test $$rc -ne 0 || { cat cmdline_unsigned_neg_$$c.log; echo "TCU_FAIL: negative $$c was accepted"; exit 1; }; \
	        grep -F '[FATAL]' cmdline_unsigned_neg_$$c.log | grep -F -- "$$expect" | grep -Fq -- "$$where" \
	            || { cat cmdline_unsigned_neg_$$c.log; echo "TCU_FAIL: negative $$c diagnostics"; exit 1; }; \
	        ! grep -q TCU_FAIL cmdline_unsigned_neg_$$c.log; \
	        echo "TCU_OK:   negative $$c is a hard fatal: $$expect"; \
	    done

# 有符号目标：十进制按 [-2^(N-1), 2^(N-1)-1] 检查，带基数/位宽的写法按补码位模式解释；负例逐项核对参数名、原文与允许范围。
test_cmdline_signed:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_cmdline_signed -o simv_cmdline_signed -Mdir=csrc_cmdline_signed test_cmdline_signed.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_signed -no_save -exitstatus +ts.imax=2147483647 +ts.imin=-2147483648 "+ts.ipat=32'hFFFF_FFFF" \
	    +ts.ihex=0xFFFFFFFF +ts.imsb=0x80000000 "+ts.itick='h7fffffff" +ts.ineg=-0x10 +ts.bmax=127 +ts.bmin=-128 "+ts.bpat=8'hff" \
	    "+ts.bmsb=8'h80" "+ts.bneg=-8'h1" "+ts.bnegmsb=-8'h80" "+ts.bbin='b1111_1111" +ts.sv8=-128 +ts.lmax=9223372036854775807 \
	    +ts.lmin=-9223372036854775808 "+ts.lpat=64'hFFFF_FFFF_FFFF_FFFF" "+ts.w128=128'hffffffffffffffffffffffffffffffff" \
	    +ts.wmax=170141183460469231731687303715884105727 "+ts.brange=[8'h80:8'h81]" +ts.ilist=2147483647,-2147483648 \
	    "+ts.bq=127,-128,8'hff" "+ts.cfg.s8f=8'h80" +ts.cfg.u32f=4294967295 +ts.leg.s8=-128 \
	    > cmdline_signed.log 2>&1 || { cat cmdline_signed.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TCS_|TEST_CMDLINE_SIGNED' cmdline_signed.log && grep -q TEST_CMDLINE_SIGNED_PASS cmdline_signed.log && ! grep -q '^TCS_FAIL' cmdline_signed.log
	cd $(TEST_SV_DIR) && set -e; \
	    for c in dec_over32 dec_under32 dec_u32 dec_over8 dec_under8 based_over8 neg_based_under8 range weight_value \
	             dec_over64 override list queue schema legacy opt; do \
	        r8="for signed 8-bit byte (allowed -128..127)"; r32="for signed 32-bit int (allowed -2147483648..2147483647)"; \
	        where="parameter='+ts.bad8'"; \
	        case $$c in \
	            dec_over32)       set -- "+ts.bad32=2147483648";  expect="value 2147483648 out of range $$r32"; where="parameter='+ts.bad32'";; \
	            dec_under32)      set -- "+ts.bad32=-2147483649"; expect="value -2147483649 out of range $$r32"; where="parameter='+ts.bad32'";; \
	            dec_u32)          set -- "+ts.bad32=4294967295";  expect="value 4294967295 out of range $$r32"; where="parameter='+ts.bad32' value='4294967295'";; \
	            dec_over8)        set -- "+ts.bad8=128";          expect="value 128 out of range $$r8";; \
	            dec_under8)       set -- "+ts.bad8=-129";         expect="value -129 out of range $$r8";; \
	            based_over8)      set -- "+ts.bad8=0x100";        expect="value 0x100 exceeds 8-bit byte (allowed -128..127)";; \
	            neg_based_under8) set -- "+ts.bad8=-8'hff";       expect="value -8'hff out of range $$r8";; \
	            range)            set -- "+ts.bad8=[-129:0]";     expect="value -129 out of range $$r8";; \
	            weight_value)     set -- "+ts.bad8={200:=1,1:=1}"; expect="value 200 out of range $$r8";; \
	            dec_over64)       set -- "+ts.bad64=9223372036854775808"; where="parameter='+ts.bad64'"; \
	                              expect="value 9223372036854775808 out of range for signed 64-bit longint (allowed -9223372036854775808..9223372036854775807)";; \
	            override)         set -- ;                         expect="value 200 out of range $$r8"; where="$$where value='200'";; \
	            list)             set -- "+ts.arr=1,4294967295";  expect="value 4294967295 out of range $$r32"; where="parameter='+ts.arr[1]'";; \
	            queue)            set -- "+ts.q8=1,200";          where="[AIP_STRUCT]"; \
	                              expect="ts.q8[1] integral token '200' is out of range for signed 8-bit target (allowed -128..127)";; \
	            schema)           set -- "+ts.ncfg.s8f=128";      where="[AIP_STRUCT]"; \
	                              expect="ts.ncfg.s8f integral token '128' is out of range for signed 8-bit target (allowed -128..127)";; \
	            legacy)           set -- "+ts.leg.s8=-129";       expect="value -129 out of range $$r8"; where="parameter='+ts.leg.s8'";; \
	            opt)              set -- "+ts.opt8=200";          expect="value 200 out of range $$r8"; where="parameter='+ts.opt8' value='200'";; \
	        esac; \
	        rc=0; ./simv_cmdline_signed -no_save -exitstatus +tcs_neg=$$c "$$@" > cmdline_signed_neg_$$c.log 2>&1 || rc=$$?; \
	        test $$rc -ne 0 || { cat cmdline_signed_neg_$$c.log; echo "TCS_FAIL: negative $$c was accepted"; exit 1; }; \
	        grep -F '[FATAL]' cmdline_signed_neg_$$c.log | grep -F -- "$$expect" | grep -Fq -- "$$where" \
	            || { cat cmdline_signed_neg_$$c.log; echo "TCS_FAIL: negative $$c diagnostics"; exit 1; }; \
	        ! grep -q '^TCS_FAIL' cmdline_signed_neg_$$c.log; \
	        echo "TCS_OK:   negative $$c is a hard fatal: $$expect"; \
	    done

# aip_cmd::parse_uint_arg 严格无符号解析；同时核对 parse_int64_arg 的旧行为不变。
test_parse_uint_arg:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_parse_uint_arg -o simv_parse_uint_arg -Mdir=csrc_parse_uint_arg test_parse_uint_arg.sv
	cd $(TEST_SV_DIR) && ./simv_parse_uint_arg > parse_uint_arg.log 2>&1 || { cat parse_uint_arg.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TPU_|TEST_PARSE_UINT_ARG|^UVM_(ERROR|FATAL) *:' parse_uint_arg.log && grep -q TEST_PARSE_UINT_ARG_PASS parse_uint_arg.log && ! grep -q TPU_FAIL parse_uint_arg.log

# aip_cmd_seq_registry::active：执行中为 1，正常注销、登记进程被杀、进程结束未注销、未知名称为 0。
test_seq_registry_active:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_seq_registry_active -o simv_seq_registry_active -Mdir=csrc_seq_registry_active test_seq_registry_active.sv
	cd $(TEST_SV_DIR) && ./simv_seq_registry_active > seq_registry_active.log 2>&1 || { cat seq_registry_active.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TSRA_|TEST_SEQ_REGISTRY_ACTIVE|^UVM_(ERROR|FATAL) *:' seq_registry_active.log && grep -q TEST_SEQ_REGISTRY_ACTIVE_PASS seq_registry_active.log && ! grep -q TSRA_FAIL seq_registry_active.log

# aip_scb 语义与报告矩阵：同一 simv 跑 14 组报告上限参数，逐组核对标记、问题流汇总和 UVM 日志。
test_scb:
	bash tests/scb/run_scb_unit.sh

# aip_mon_hub/aip_sample_seq：订阅副本、阻塞/超时/取消、复位清队列与通知、溢出、单读者独占、seq 采样路径。
test_mon_hub:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_mon_hub -o simv_mon_hub -Mdir=csrc_mon_hub test_mon_hub.sv
	cd $(TEST_SV_DIR) && ./simv_mon_hub > mon_hub.log 2>&1 || { cat mon_hub.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TMH_|TEST_MON_HUB|^UVM_(ERROR|FATAL) *:' mon_hub.log && grep -q TEST_MON_HUB_PASS mon_hub.log && ! grep -q TMH_FAIL mon_hub.log

# aip_flags：成员名、整数掩码、set_param override 与层级路径；负例逐个单独运行，须非零退出并报出参数名与非法项。
test_aip_flags:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -top test_aip_flags -o simv_aip_flags -Mdir=csrc_aip_flags test_aip_flags.sv
	cd $(TEST_SV_DIR) && ./simv_aip_flags -exitstatus +taf.names=b,A,b "+taf.spaced= A , HIGH " +taf.num=0x8000_0000_0000_0011 "+taf.sized=8'b1010_0101" \
	    +taf.neg=0xffff_ffff_ffff_ffff +taf.dname=d0 +taf.narrow=B,D0 +taf.h0.pf1.vf2.i0.mask=D0,HIGH +mask=B > aip_flags.log 2>&1 || { cat aip_flags.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -E '^TAF_|TEST_AIP_FLAGS|^UVM_(ERROR|FATAL) *:' aip_flags.log && grep -q TEST_AIP_FLAGS_PASS aip_flags.log && ! grep -q TAF_FAIL aip_flags.log
	cd $(TEST_SV_DIR) && grep -Fq "param 'names' (scope='taf') = 0x3 (A|B)" aip_flags.log && echo "TAF_OK:   registration log shows hex and names"
	cd $(TEST_SV_DIR) && set -e; \
	    for c in unknown hier empty mixed bit_range value_range negative; do \
	        arg=+taf_neg=$$c; where="parameter='+taf.bad'"; \
	        case $$c in \
	            unknown)     arg="$$arg +taf.bad=A,BOGUS"; expect="unknown flag 'BOGUS'"; where="parameter='+taf.bad' value='A,BOGUS'";; \
	            hier)        expect="unknown flag 'nope'"; where="parameter='+taf.h0.pf1.vf2.i0.bad' value='nope'";; \
	            empty)       expect="empty flag name at item[1]";; \
	            mixed)       expect="unknown flag '0x2'";; \
	            bit_range)   expect="flag 'HIGH' is bit 63, outside the 8-bit target";; \
	            value_range) expect="value 0x100 exceeds the 8-bit target";; \
	            negative)    expect="negative mask -1; flags are unsigned (allowed 0..0xff)";; \
	        esac; \
	        rc=0; ./simv_aip_flags -exitstatus $$arg > aip_flags_neg_$$c.log 2>&1 || rc=$$?; \
	        test $$rc -ne 0 || { cat aip_flags_neg_$$c.log; echo "TAF_FAIL: negative $$c was accepted"; exit 1; }; \
	        grep -F '[FATAL]' aip_flags_neg_$$c.log | grep -F "AIP_CORE[cmdline_flags] Error: $$expect" | grep -Fq "$$where" \
	            || { cat aip_flags_neg_$$c.log; echo "TAF_FAIL: negative $$c diagnostics"; exit 1; }; \
	        ! grep -q TAF_FAIL aip_flags_neg_$$c.log; \
	        echo "TAF_OK:   negative $$c is a hard fatal: $$expect"; \
	    done

# Signed integer command-line parsing regression — requires VCS on PATH
test_cmdline_negative:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_negative -Mdir=csrc_cmdline_negative test_cmdline_negative.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_negative "+neg_dec=-10" "+neg_hex=-0x10" "+neg_sv=-8'd10" "+plus_dec=+10" "+neg_range=[-10:-1]" "+cross_range=[-2:2]" "+neg_list=-3,-2,-1" "+neg_inc=inc:-10:10:2" "+neg_dec_seq=dec:10:-10:2" "+neg_weight={-3:=10,[-2:-1]:=20}" "+neg_bits=-1" "+positive=0x2a" > cmdline_negative.log 2>&1 || { cat cmdline_negative.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_negative.log && grep -q CMDLINE_NEGATIVE_PASS cmdline_negative.log

# 性能基准单独编译/串行运行，不纳入功能回归总目标，也不修改生产解析器。
# DPI 只读取主机时钟；编译、启动、预热和正确性校验均不计入热路径耗时。
bench_cmdline_build:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -top test_cmdline_benchmark -o simv_cmdline_benchmark -Mdir=csrc_cmdline_benchmark \
	    test_cmdline_benchmark.sv ../bench/cmdline_bench_clock.c \
	    > cmdline_benchmark_compile.log 2>&1 \
	    || { cat cmdline_benchmark_compile.log; exit 1; }

bench_cmdline: bench_cmdline_build
	bash tests/bench/run_cmdline_benchmark.sh

# 物理拆分的定向兼容性检查：旧 standalone 与 canonical package 各编译一次。
# 相同 seed 的可比较轨迹独立保存；positive 子目标也能配合拆分前源码执行基线比较。
# 编译和 FATAL 日志均按入口隔离，负例验证用户宏调用行而不是内部宏定义行。
test_cmdline_split_positive:
	cd $(TEST_SV_DIR) && set -e; \
	    for entry in standalone package; do \
	        defines=''; dpi=''; \
	        if [ "$$entry" = package ]; then \
	            defines='+define+AIP_CMDLINE_SPLIT_PACKAGE'; dpi='../../src/c/runtime/sv_socket_dpi.c'; \
	        fi; \
	        compile_log="cmdline_split_$${entry}_compile.log"; \
	        vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+all -full64 -lca \
	            $(AIP_TEST_INCDIRS) $$defines -top test_cmdline_split \
	            -o "simv_cmdline_split_$$entry" -Mdir="csrc_cmdline_split_$$entry" \
	            test_cmdline_split.sv $$dpi > "$$compile_log" 2>&1 \
	            || { cat "$$compile_log"; exit 1; }; \
	        for seed in 7 17; do \
	            log="cmdline_split_$${entry}_seed_$${seed}.log"; \
	            ./simv_cmdline_split_$$entry -no_save -exitstatus +ntb_random_seed=$$seed > "$$log" 2>&1 \
	                || { cat "$$log"; exit 1; }; \
	            cat "$$log"; \
	            grep -Fxq CMDLINE_SPLIT_PASS "$$log"; \
	            grep '^CMDLINE_SPLIT_TRACE ' "$$log" > "cmdline_split_$${entry}_seed_$${seed}.trace"; \
	            test "$$(grep -c '^CMDLINE_SPLIT_TRACE ' "$$log")" -eq 16; \
	        done; \
	        log="cmdline_split_$${entry}_fatal.log"; diag="cmdline_split_$${entry}_fatal_diag.log"; \
	        rc=0; ./simv_cmdline_split_$$entry -no_save -exitstatus +ntb_random_seed=17 +AIP_SPLIT_FATAL > "$$log" 2>&1 || rc=$$?; \
	        cat "$$log"; \
	        test $$rc -ne 0; \
	        if grep -Eq '^CMDLINE_SPLIT_(UNEXPECTED_CONTINUE|PASS)$$' "$$log"; then exit 1; fi; \
	        line=$$(sed -n 's/^SPLIT_EXPECT_LINE //p' "$$log"); test -n "$$line"; \
	        sed '/^SPLIT_EXPECT_/d' "$$log" > "$$diag"; \
	        grep -Fq FATAL "$$diag"; \
	        grep -Fq "test_cmdline_split.sv($$line)" "$$diag"; \
	        grep -Fq "parameter='+split.bad'" "$$diag"; \
	        grep -Fq "value='not_an_int'" "$$diag"; \
	        log="cmdline_split_$${entry}_direct_fatal.log"; \
	        rc=0; ./simv_cmdline_split_$$entry -no_save -exitstatus +ntb_random_seed=17 +AIP_SPLIT_DIRECT_FATAL > "$$log" 2>&1 || rc=$$?; \
	        cat "$$log"; \
	        test $$rc -ne 0; \
	        if grep -Eq '^CMDLINE_SPLIT_(UNEXPECTED_CONTINUE|PASS)$$|test_cmdline_split[.]sv|parameter=' "$$log"; then exit 1; fi; \
	        grep -Fq FATAL "$$log"; \
	        grep -Eq 'aip_cmdline(_scalar)?[.]sv\([0-9]+\)' "$$log"; \
	        grep -Fq "value='not_an_int'" "$$log"; \
	    done
	@echo CMDLINE_SPLIT_POSITIVE_PASS

# 片段仅为聚合入口的内部实现；类和纯宏都必须主动报出相同的 analysis-time 错误。
# 显式指定无关空 top，可防止通过缺失类型或 elaboration 错误偶然获得失败结果。
test_cmdline_split_internal_reject:
	cd $(TEST_SV_DIR) && set -e; \
	    for fragment in class macro; do \
	        defines=''; \
	        if [ "$$fragment" = macro ]; then defines='+define+AIP_SPLIT_INTERNAL_MACRO'; fi; \
	        log="cmdline_split_internal_$${fragment}.log"; \
	        if vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca \
	            $(AIP_TEST_INCDIRS) $$defines -top test_cmdline_split_internal_reject \
	            -o "simv_cmdline_split_internal_$$fragment" -Mdir="csrc_cmdline_split_internal_$$fragment" \
	            test_cmdline_split_internal_reject.sv > "$$log" 2>&1; then \
	            cat "$$log"; echo "internal $$fragment include unexpectedly compiled"; exit 1; \
	        fi; \
	        cat "$$log"; \
	        grep -Fq AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV "$$log"; \
	    done
	@echo CMDLINE_SPLIT_INTERNAL_REJECT_PASS

# 保持旧 standalone 自测开关可用；只验证默认演示顺利完成，不扩充旧演示的语义覆盖。
# 不借助新片段路径，因此该 fixture 也可直接放入拆分前源码进行兼容性对照。
test_cmdline_split_legacy_selftest:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca \
	    $(AIP_TEST_INCDIRS) -top test_param_parser_full \
	    -o simv_cmdline_split_legacy_selftest -Mdir=csrc_cmdline_split_legacy_selftest \
	    test_cmdline_split_legacy_selftest.sv > cmdline_split_legacy_selftest_compile.log 2>&1 \
	    || { cat cmdline_split_legacy_selftest_compile.log; exit 1; }
	cd $(TEST_SV_DIR) && ./simv_cmdline_split_legacy_selftest -no_save -exitstatus \
	    > cmdline_split_legacy_selftest.log 2>&1 \
	    || { cat cmdline_split_legacy_selftest.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_split_legacy_selftest.log \
	    && grep -Fq '所有测试完成' cmdline_split_legacy_selftest.log \
	    && ! grep -Fq '[FATAL]' cmdline_split_legacy_selftest.log
	@echo CMDLINE_SPLIT_LEGACY_SELFTEST_PASS

test_cmdline_split: test_cmdline_split_positive test_cmdline_split_internal_reject test_cmdline_split_legacy_selftest
	@echo CMDLINE_SPLIT_SMOKE_PASS

# 零权重和诊断定位的定向回归：负例必须以非零退出码终止，并包含真实 FATAL。
# 期望键、原始值和源码行号从测试标记取得；移除标记再检查，避免期望值自身造成假通过。
test_cmdline_zero_weight:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_zero_weight -Mdir=csrc_cmdline_zero_weight test_cmdline_zero_weight.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_zero_weight +ntb_random_seed=17 \
	    '+weighted.eq={1:=0,7:=3,9:=0}' '+weighted.slash={[1:4]:/0,8:/2}' \
	    '+weighted.mixed={[-10:-5]:=0,12:=7,[20:30]:/0}' \
	    '+weighted.rand_off={rand:/0,13:=1}' '+weighted.rate={[1.0:2.0]:/0,3.5:=2,8.0:=0}' \
	    > cmdline_zero_weight_positive.log 2>&1 || { cat cmdline_zero_weight_positive.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_zero_weight_positive.log && grep -Fxq CMDLINE_ZERO_WEIGHT_PASS cmdline_zero_weight_positive.log
	cd $(TEST_SV_DIR) && set -e; \
	    for case_name in scalar_zero scalar_negative real_zero real_negative each_zero index_negative \
	        size_zero queue_zero queue_negative real_queue_zero real_queue_negative queue_size_zero struct_zero struct_size_zero \
	        single_zero fallback_zero disabled_malformed real_disabled_malformed scalar_malformed real_array_zero legacy_int_zero legacy_real_zero; do \
	        log="cmdline_zero_weight_$${case_name}.log"; diag="cmdline_zero_weight_$${case_name}_diag.log"; \
	        scalar_arg='+weighted.bad={1:=0,2:/0}'; real_arg='+weighted.bad_real={1.0:=0,2.0:/0}'; \
	        case "$$case_name" in \
	            scalar_negative) scalar_arg='+weighted.bad={1:=-1,2:=3}';; \
	            single_zero) scalar_arg='+weighted.bad=7:=0';; \
	            fallback_zero) scalar_arg='+bad={1:=0,2:/0}';; \
	            disabled_malformed) scalar_arg='+weighted.bad={broken:=0,2:=1}';; \
	            scalar_malformed) scalar_arg='+weighted.bad=not_an_int';; \
	            real_negative) real_arg='+weighted.bad_real={1.0:=-1,2.0:=3}';; \
	            real_disabled_malformed) real_arg='+weighted.bad_real={broken:=0,2.0:=1}';; \
	        esac; \
	        rc=0; ./simv_cmdline_zero_weight -no_save -exitstatus +AIP_WEIGHT_CASE=$$case_name "$$scalar_arg" "$$real_arg" > "$$log" 2>&1 || rc=$$?; \
	        cat "$$log"; \
	        test $$rc -ne 0; \
	        if grep -Fq CMDLINE_ZERO_WEIGHT_UNEXPECTED_PASS "$$log"; then exit 1; fi; \
	        key=$$(sed -n 's/^WEIGHT_EXPECT_KEY //p' "$$log"); \
	        value=$$(sed -n 's/^WEIGHT_EXPECT_VALUE //p' "$$log"); \
	        line=$$(sed -n 's/^WEIGHT_EXPECT_LINE //p' "$$log"); \
	        test -n "$$key" && test -n "$$value" && test -n "$$line"; \
	        sed '/^WEIGHT_EXPECT_/d' "$$log" > "$$diag"; \
	        grep -Fq FATAL "$$diag"; \
	        grep -Fq "parameter='+$$key'" "$$diag"; \
	        grep -Fq "value='$$value'" "$$diag"; \
	        grep -Fq "test_cmdline_zero_weight.sv($$line)" "$$diag"; \
	        case "$$case_name" in \
	            *malformed) grep -Eiq 'parser Error.*(invalid|unexpected)' "$$diag";; \
	            *) grep -Eiq '(weight.*(zero|total|negative|[><=])|total.*weight)' "$$diag";; \
	        esac; \
	    done
	cd $(TEST_SV_DIR) && { ./simv_cmdline_zero_weight -no_save -exitstatus +AIP_WEIGHT_CASE=context_cleared > cmdline_zero_weight_context_cleared.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_zero_weight_context_cleared.log \
	    && grep -Fq FATAL cmdline_zero_weight_context_cleared.log \
	    && ! grep -Fq CMDLINE_ZERO_WEIGHT_UNEXPECTED_PASS cmdline_zero_weight_context_cleared.log \
	    && ! grep -Fq weighted.good cmdline_zero_weight_context_cleared.log \
	    && ! grep -Fq test_cmdline_zero_weight.sv cmdline_zero_weight_context_cleared.log \
	    && grep -Fq aip_cmdline_scalar.sv cmdline_zero_weight_context_cleared.log \
	    && grep -Fq '{1:=0,2:=0}' cmdline_zero_weight_context_cleared.log

# 非权重路径的统一诊断矩阵：同时要求正确来源、原文、FATAL 和没有继续执行。
# 期望标记仅供驱动器取值，断言之前全部删除，避免标记制造假通过。
test_cmdline_diagnostics:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_diagnostics -Mdir=csrc_cmdline_diagnostics test_cmdline_diagnostics.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_diagnostics -no_save -exitstatus +AIP_DIAG_CASE=positive '+diag.rate=1.25e3' > cmdline_diagnostics_positive.log 2>&1 || { cat cmdline_diagnostics_positive.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_diagnostics_positive.log \
	    && grep -Fxq CMDLINE_DIAGNOSTICS_POSITIVE_PASS cmdline_diagnostics_positive.log \
	    && ! grep -Fq CMDLINE_DIAGNOSTICS_UNEXPECTED_CONTINUE cmdline_diagnostics_positive.log
	cd $(TEST_SV_DIR) && set -e; \
	    for case_name in legacy_enum legacy_real real_literal real_range real_inc real_list real_overflow real_override real_array \
	        real_array_size_malformed real_array_size_negative \
	        enum_literal enum_list enum_range legacy_compact \
	        required_int required_real required_string required_enum required_array_size array_sort \
	        int_queue_sort int_queue_unique real_queue_sort real_queue_unique int_queue_fixed_invalid real_queue_fixed_invalid \
	        string_queue_sort string_queue_unique string_queue_size string_queue_literal \
	        enum_queue_sort enum_queue_unique enum_queue_size enum_queue_literal \
	        schema_compact schema_real schema_enum schema_sort direct_int direct_real context_after_success fatal_cannot_be_suppressed; do \
	        log="cmdline_diagnostics_$${case_name}.log"; diag="cmdline_diagnostics_$${case_name}_diag.log"; \
	        raw=''; \
	        case "$$case_name" in \
	            real_literal) raw='1.0junk';; \
	            real_range) raw='[broken:2.0]';; \
	            real_inc) raw='inc:0.0:2.0:broken';; \
	            real_list) raw='broken,also_bad';; \
	            real_overflow) raw='1e999';; \
	        esac; \
	        set -- +AIP_DIAG_CASE=$$case_name; \
	        if [ -n "$$raw" ]; then set -- "$$@" "+diag.rate=$$raw"; fi; \
	        rc=0; ./simv_cmdline_diagnostics -no_save -exitstatus "$$@" > "$$log" 2>&1 || rc=$$?; \
	        cat "$$log"; test $$rc -ne 0; \
	        ! grep -Fq CMDLINE_DIAGNOSTICS_UNEXPECTED_CONTINUE "$$log"; \
	        key=$$(sed -n 's/^DIAG_EXPECT_KEY //p' "$$log"); \
	        value=$$(sed -n 's/^DIAG_EXPECT_VALUE //p' "$$log"); \
	        file=$$(sed -n 's/^DIAG_EXPECT_FILE //p' "$$log"); \
	        line=$$(sed -n 's/^DIAG_EXPECT_LINE //p' "$$log"); \
	        test -n "$$key" && test -n "$$file" && test -n "$$line"; \
	        sed '/^DIAG_EXPECT_/d' "$$log" > "$$diag"; \
	        grep -Fq FATAL "$$diag"; \
	        grep -Fq "parameter='+$$key'" "$$diag"; \
	        grep -Fq "$$file($$line)" "$$diag"; \
	        if [ -n "$$value" ]; then grep -Fq "value='$$value'" "$$diag"; fi; \
	    done

test_cmdline_struct_schema_scalar:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_scalar -Mdir=csrc_cmdline_struct_schema_scalar test_cmdline_struct_schema_scalar.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_scalar '+plus.cfg={addr=17,label="x,y\\z",bus={id=51,width=202}}' '+plus.empty.label=""' '+plus.cfg2.addr=999' > cmdline_struct_schema_scalar.log 2>&1 || { cat cmdline_struct_schema_scalar.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_scalar.log && grep -Fxq CMDLINE_STRUCT_SCHEMA_SCALAR_PASS cmdline_struct_schema_scalar.log

test_cmdline_struct_schema_containers:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_containers -Mdir=csrc_cmdline_struct_schema_containers test_cmdline_struct_schema_containers.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_containers '+cfg.seqv.value=seq:0:5:2' '+cfg.permv.value=perm:10:13' '+cfg.ordered={value=3},{value=1},{value=2},{value=2}' '+cfg.ordered.each.value.sort=asc' '+cfg.records={id=30,rank=3,label=z,meta={score=6}},{id=20,rank=1,label=a,meta={score=4}},{id=10,rank=2,label=b,meta={score=8}},{id=40,rank=2,label=c,meta={score=2}}' '+cfg.records.each.rank.sort=asc' '+cfg.records.each.id.unique=1' '+cfg.precedence={value=4},{value=5},{value=6}' '+cfg.precedence.value=1,2,3' '+cfg.precedence.each.value=7' '+cfg.precedence[1].value=9' '+cfg.inferred_records.id=11,22,33' '+cfg.inferred_records.rank=4,5' '+cfg.inferred_seq.value=seq:2:6:2' '+cfg.inferred_q.value=7,8,9' '+cfg.runtime_inferred.value=1,2,3' '+cfg.explicit_empty.size=0' > cmdline_struct_schema_containers.log 2>&1 || { cat cmdline_struct_schema_containers.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_containers.log && grep -Fxq CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS cmdline_struct_schema_containers.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_containers -no_save -exitstatus +AIP_TEST_GENERATOR_CONFLICT '+cfg.conflicting.id=seq:0:1' '+cfg.conflicting.rank=seq:0:2' > cmdline_struct_schema_generator_conflict.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_generator_conflict.log; test $$rc -ne 0; ! grep -Fq 'expected conflicting field generators to fail' cmdline_struct_schema_generator_conflict.log; grep -Fq '[AIP_STRUCT] cfg.conflicting conflicting field generator lengths 2 and 3' cmdline_struct_schema_generator_conflict.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_containers -no_save -exitstatus +AIP_TEST_RUNTIME_INDEX_BOUNDS '+cfg.runtime_bounds.size=1' > cmdline_struct_schema_runtime_index_bounds.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_runtime_index_bounds.log \
	    && ! grep -Fxq CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS cmdline_struct_schema_runtime_index_bounds.log \
	    && grep -Fq 'out of range for cfg.runtime_bounds' cmdline_struct_schema_runtime_index_bounds.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_containers -no_save -exitstatus +AIP_TEST_RUNTIME_INDEX_NONCANONICAL '+cfg.runtime_bounds.size=3' > cmdline_struct_schema_runtime_index_noncanonical.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_runtime_index_noncanonical.log \
	    && ! grep -Fxq CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS cmdline_struct_schema_runtime_index_noncanonical.log \
	    && grep -Fq 'noncanonical index in runtime key' cmdline_struct_schema_runtime_index_noncanonical.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_containers -no_save -exitstatus +AIP_TEST_RUNTIME_INDEX_NEGATIVE '+cfg.runtime_bounds.size=3' > cmdline_struct_schema_runtime_index_negative.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_runtime_index_negative.log \
	    && ! grep -Fxq CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS cmdline_struct_schema_runtime_index_negative.log \
	    && grep -Fq 'noncanonical index in runtime key' cmdline_struct_schema_runtime_index_negative.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_containers -no_save -exitstatus +AIP_TEST_EACH_UNKNOWN '+cfg.each_unknown.each.value=7' > cmdline_struct_schema_each_unknown.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_each_unknown.log \
	    && ! grep -Fxq CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS cmdline_struct_schema_each_unknown.log \
	    && grep -Fq 'size unknown' cmdline_struct_schema_each_unknown.log

# Focused typed struct-container postprocessing checks.  Negative selectors
# intentionally terminate with an [AIP_STRUCT] diagnostic; keep those runs
# bounded and validate the exact diagnostic rather than masking it.
test_cmdline_struct_schema_typed_postprocess:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_typed_postprocess -Mdir=csrc_cmdline_struct_schema_typed_postprocess test_cmdline_struct_schema_typed_postprocess.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +AIP_TEST_TYPED_STABLE \
	    '+typed.stable={id=10,rank=1,label=z,meta={score=5},wide=-1,precise=1.0000000000000001,mode=MODE_HIGH},{id=20,rank=2,label=a,meta={score=4},wide=2,precise=1.0000000000000002,mode=MODE_MID},{id=40,rank=2,label=c,meta={score=7},wide=4,precise=3.0,mode=MODE_LOW},{id=30,rank=3,label=b,meta={score=6},wide=3,precise=2.0,mode=MODE_LOW}' \
	    '+typed.stable.each.rank.sort=DeSc' > cmdline_struct_schema_typed_stable.log 2>&1 || { cat cmdline_struct_schema_typed_stable.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_TYPED_STABLE_PASS cmdline_struct_schema_typed_stable.log

	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +AIP_TEST_TYPED_NESTED \
	    '+typed.nested={id=13,meta={score=2}},{id=11,meta={score=1}},{id=12,meta={score=2}}' \
	    '+typed.nested.each.meta.score.sort=asc' > cmdline_struct_schema_typed_nested.log 2>&1 || { cat cmdline_struct_schema_typed_nested.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_TYPED_NESTED_PASS cmdline_struct_schema_typed_nested.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +AIP_TEST_TYPED_REAL \
	    '+typed.real={precise=2.0},{precise=1.0000000000000002},{precise=1.0000000000000001}' \
	    '+typed.real.each.precise.sort=asc' > cmdline_struct_schema_typed_real.log 2>&1 || { cat cmdline_struct_schema_typed_real.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_TYPED_REAL_PASS cmdline_struct_schema_typed_real.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +AIP_TEST_TYPED_ENUM \
	    '+typed.enum={mode=MODE_HIGH},{mode=MODE_LOW},{mode=MODE_MID}' \
	    '+typed.enum.each.mode.sort=asc' > cmdline_struct_schema_typed_enum.log 2>&1 || { cat cmdline_struct_schema_typed_enum.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_TYPED_ENUM_PASS cmdline_struct_schema_typed_enum.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +AIP_TEST_TYPED_UNIQUE_OVERRIDE \
	    '+typed.override={rank=1},{rank=1},{rank=1}' '+typed.override.each.rank.unique=1' \
	    > cmdline_struct_schema_typed_override.log 2>&1 || { cat cmdline_struct_schema_typed_override.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_TYPED_UNIQUE_OVERRIDE_PASS cmdline_struct_schema_typed_override.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +ntb_random_seed=17 +AIP_TEST_TYPED_EACH_REDRAW \
	    '+typed.redraw={id=100},{id=101},{id=102}' \
	    '+typed.redraw.each.rank=1,2,3' '+typed.redraw.each.rank.unique=1' \
	    > cmdline_struct_schema_typed_redraw.log 2>&1 || { cat cmdline_struct_schema_typed_redraw.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_redraw.log \
	    && grep -Fxq CMDLINE_STRUCT_TYPED_EACH_REDRAW_PASS cmdline_struct_schema_typed_redraw.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +ntb_random_seed=1 +AIP_TEST_TYPED_FIXED_LATER \
	    '+typed.fixed_later={id=10},{id=11},{id=12}' \
	    '+typed.fixed_later.each.rank=1,2,3' '+typed.fixed_later[1].rank=1' \
	    '+typed.fixed_later.each.rank.unique=1' \
	    > cmdline_struct_schema_typed_fixed_later.log 2>&1 || { cat cmdline_struct_schema_typed_fixed_later.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_fixed_later.log \
	    && grep -Fxq CMDLINE_STRUCT_TYPED_FIXED_LATER_PASS cmdline_struct_schema_typed_fixed_later.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +ntb_random_seed=23 +AIP_TEST_TYPED_EACH_REAL \
	    '+typed.real_each.each.precise=inc:0.1:0.3:0.1' '+typed.real_each.each.precise.unique=1' \
	    > cmdline_struct_schema_typed_real_each.log 2>&1 || { cat cmdline_struct_schema_typed_real_each.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_real_each.log \
	    && grep -Fxq CMDLINE_STRUCT_TYPED_REAL_EACH_PASS cmdline_struct_schema_typed_real_each.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +ntb_random_seed=29 +AIP_TEST_TYPED_WIDE_EACH \
	    '+typed.wide_each.each.wide=0x10000000000000000,0x20000000000000000,0x30000000000000000' \
	    '+typed.wide_each.each.wide.unique=1' \
	    > cmdline_struct_schema_typed_wide_each.log 2>&1 || { cat cmdline_struct_schema_typed_wide_each.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_wide_each.log \
	    && grep -Fxq CMDLINE_STRUCT_TYPED_WIDE_EACH_PASS cmdline_struct_schema_typed_wide_each.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_typed_postprocess +ntb_random_seed=31 +AIP_TEST_TYPED_EACH_ENUM \
	    '+typed.enum_each.each.mode=MODE_LOW,MODE_MID,MODE_HIGH' '+typed.enum_each[1].mode=MODE_MID' \
	    '+typed.enum_each.each.mode.unique=1' \
	    > cmdline_struct_schema_typed_enum_each.log 2>&1 || { cat cmdline_struct_schema_typed_enum_each.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_enum_each.log \
	    && grep -Fxq CMDLINE_STRUCT_TYPED_ENUM_EACH_PASS cmdline_struct_schema_typed_enum_each.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_EACH_SHORTAGE \
	    '+typed.shortage.size=3' '+typed.shortage.each.rank=0,1' '+typed.shortage.each.rank.unique=1' \
	    > cmdline_struct_schema_typed_shortage.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_typed_shortage.log; test $$rc -ne 0; ! grep -Fq 'expected finite each candidate shortage to fail' cmdline_struct_schema_typed_shortage.log; grep -Fq '[AIP_STRUCT] typed.shortage.each.rank.unique: only 2 candidates for 3 elements' cmdline_struct_schema_typed_shortage.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_FIXED_COLLISION \
	    '+typed.fixed_collision={rank=1},{rank=1},{rank=2}' \
	    '+typed.fixed_collision.each.rank=1,2,3' '+typed.fixed_collision.each.rank.unique=1' \
	    > cmdline_struct_schema_typed_fixed_collision.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_fixed_collision.log \
	    && ! grep -Fxq CMDLINE_STRUCT_TYPED_FIXED_COLLISION_UNEXPECTED_PASS cmdline_struct_schema_typed_fixed_collision.log \
	    && grep -Fq '[AIP_STRUCT] typed.fixed_collision.each.rank.unique: duplicate fixed value at indices 0 and 1' cmdline_struct_schema_typed_fixed_collision.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_INDEXED_REJECT \
	    '+typed.indexed[0].rank.sort=asc' \
	    > cmdline_struct_schema_typed_indexed.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_indexed.log \
	    && ! grep -Fxq CMDLINE_STRUCT_TYPED_INDEXED_UNEXPECTED_PASS cmdline_struct_schema_typed_indexed.log \
	    && grep -Fq '[AIP_STRUCT] typed.indexed[0].rank.sort is invalid for a struct-container key; use typed.indexed.each.rank.sort' cmdline_struct_schema_typed_indexed.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_SIZE_ZERO_CONTROL \
	    '+typed.zero.size=0' '+typed.zero.each.rank.sort=bogus' \
	    > cmdline_struct_schema_typed_zero.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_zero.log \
	    && ! grep -Fxq CMDLINE_STRUCT_TYPED_SIZE_ZERO_UNEXPECTED_PASS cmdline_struct_schema_typed_zero.log \
	    && grep -Fq '[AIP_STRUCT] typed.zero.each.rank.sort must be asc, desc, or none' cmdline_struct_schema_typed_zero.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_MULTI_SORT \
	    '+typed.multi.each.rank.sort=asc' '+typed.multi.each.id.sort=desc' \
	    > cmdline_struct_schema_typed_multi.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_multi.log \
	    && ! grep -Fxq CMDLINE_STRUCT_TYPED_MULTI_SORT_UNEXPECTED_PASS cmdline_struct_schema_typed_multi.log \
	    && grep -Fq '[AIP_STRUCT]' cmdline_struct_schema_typed_multi.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_typed_postprocess -no_save -exitstatus +AIP_TEST_TYPED_WIDE_UNIQUE \
	    '+typed.wide={wide=-1},{wide=0xffffffffffffffffffffffffffffffff}' \
	    '+typed.wide.each.wide.unique=1' > cmdline_struct_schema_typed_wide.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_typed_wide.log \
	    && ! grep -Fxq CMDLINE_STRUCT_TYPED_WIDE_UNIQUE_UNEXPECTED_PASS cmdline_struct_schema_typed_wide.log \
	    && grep -Fq '[AIP_STRUCT]' cmdline_struct_schema_typed_wide.log

test_cmdline_struct_schema_primitive_arrays:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_primitive_arrays -Mdir=csrc_cmdline_struct_schema_primitive_arrays test_cmdline_struct_schema_primitive_arrays.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_SORT '+prim.ia=3,1,2' '+prim.ia.sort=asc' '+prim.sa="b","A","a"' '+prim.sa.sort=ASC' '+prim.ra=1.7976931348623157e308,1.25,2.5' '+prim.ra.sort=asc' '+prim.mode=EHIGH' '+prim.ea=EHIGH,ELOW,EMID' '+prim.ea.sort=asc' > cmdline_struct_schema_primitive_arrays.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_SORT_PASS cmdline_struct_schema_primitive_arrays.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_INNER_SORT '+cfgs[0].id=20' '+cfgs[0].tags=3,1,2' '+cfgs[1].id=10' '+cfgs[1].tags=6,4,5' '+cfgs.each.tags.sort=asc' > cmdline_struct_schema_primitive_arrays_inner_sort.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_inner_sort.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_INNER_SORT_PASS cmdline_struct_schema_primitive_arrays_inner_sort.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_UNSUPPORTED '+prim.sa=seq:a:b' > cmdline_struct_schema_primitive_arrays_unsupported_string.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_unsupported_string.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_PRIM_.*PASS' cmdline_struct_schema_primitive_arrays_unsupported_string.log; grep -Fq '[AIP_STRUCT] prim.sa seq/perm unsupported for string primitive schema array' cmdline_struct_schema_primitive_arrays_unsupported_string.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_UNSUPPORTED_REAL '+prim.ra=seq:1:3' > cmdline_struct_schema_primitive_arrays_unsupported_real.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_unsupported_real.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_unsupported_real.log; grep -Fq '[AIP_STRUCT] prim.ra seq/perm unsupported for real primitive schema array' cmdline_struct_schema_primitive_arrays_unsupported_real.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_UNSUPPORTED_ENUM '+prim.ea=perm:ELOW:EHIGH' > cmdline_struct_schema_primitive_arrays_unsupported_enum.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_unsupported_enum.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_unsupported_enum.log; grep -Fq '[AIP_STRUCT] prim.ea seq/perm unsupported for enum primitive schema array' cmdline_struct_schema_primitive_arrays_unsupported_enum.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=1.0junk' > cmdline_struct_schema_primitive_arrays_real_bad.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_bad.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_bad.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal '1.0junk'" cmdline_struct_schema_primitive_arrays_real_bad.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=NaN' > cmdline_struct_schema_primitive_arrays_real_nan.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_nan.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_nan.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal 'NaN'" cmdline_struct_schema_primitive_arrays_real_nan.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=infinity' > cmdline_struct_schema_primitive_arrays_real_inf.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_inf.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_inf.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal 'infinity'" cmdline_struct_schema_primitive_arrays_real_inf.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=1e999' > cmdline_struct_schema_primitive_arrays_real_overflow.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_overflow.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_overflow.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal '1e999'" cmdline_struct_schema_primitive_arrays_real_overflow.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=1.8e308' > cmdline_struct_schema_primitive_arrays_real_boundary_overflow.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_boundary_overflow.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_boundary_overflow.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal '1.8e308'" cmdline_struct_schema_primitive_arrays_real_boundary_overflow.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=0.18e309' > cmdline_struct_schema_primitive_arrays_real_leading_zero_overflow.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_leading_zero_overflow.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_leading_zero_overflow.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal '0.18e309'" cmdline_struct_schema_primitive_arrays_real_leading_zero_overflow.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[1]=00018e308' > cmdline_struct_schema_primitive_arrays_real_zero_prefix_overflow.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_zero_prefix_overflow.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_zero_prefix_overflow.log; grep -Fq "[AIP_STRUCT] prim.ra[1] invalid real literal '00018e308'" cmdline_struct_schema_primitive_arrays_real_zero_prefix_overflow.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[01]=1.0' > cmdline_struct_schema_primitive_arrays_real_index_noncanonical.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_index_noncanonical.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_index_noncanonical.log; grep -Fq '[AIP_STRUCT] noncanonical index in +prim.ra[01]' cmdline_struct_schema_primitive_arrays_real_index_noncanonical.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_REAL_BAD '+prim.ra[3]=1.0' > cmdline_struct_schema_primitive_arrays_real_index_range.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_real_index_range.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_.*PASS' cmdline_struct_schema_primitive_arrays_real_index_range.log; grep -Fq '[AIP_STRUCT] prim.ra indexed value out of range' cmdline_struct_schema_primitive_arrays_real_index_range.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_DYN '+dyn.ia.size=3' '+dyn.ia=3,1,2' '+dyn.ia.sort=asc' '+dyn.ia.unique=1' '+dyn.mode=EHIGH' '+dyn.sa.size=2' '+dyn.sa="b","a"' '+dyn.sa.sort=asc' '+dyn.ea.size=2' '+dyn.ea=EHIGH,ELOW' '+dyn.ea.sort=asc' > cmdline_struct_schema_primitive_arrays_dyn.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_dyn.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_DYN_PASS cmdline_struct_schema_primitive_arrays_dyn.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_DEFAULT_EACH '+defaults.ia.each=7' '+defaults.sa.each=fill' '+defaults.ra.each=2.5' '+defaults.ea.each=EMID' > cmdline_struct_schema_primitive_arrays_default_each.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_default_each.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_DEFAULT_EACH_PASS cmdline_struct_schema_primitive_arrays_default_each.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_EACH_UNKNOWN '+unknown.ia.each=7' > cmdline_struct_schema_primitive_arrays_each_unknown.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_primitive_arrays_each_unknown.log; test $$rc -ne 0; ! grep -Eq 'CMDLINE_STRUCT_PRIM_.*PASS' cmdline_struct_schema_primitive_arrays_each_unknown.log; grep -Fq '[AIP_STRUCT] unknown.ia.each given but size unknown' cmdline_struct_schema_primitive_arrays_each_unknown.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_INT_GENERATOR '+igen_static.ia=seq:1:3' '+igen_dynamic.ia.size=4' '+igen_dynamic.ia=perm:1:4' > cmdline_struct_schema_primitive_arrays_int_generator.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_int_generator.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_INT_GENERATOR_PASS cmdline_struct_schema_primitive_arrays_int_generator.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_EMPTY '+empty.sa=' > cmdline_struct_schema_primitive_arrays_empty.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_empty.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_EMPTY_PASS cmdline_struct_schema_primitive_arrays_empty.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_REAL_GRAMMAR '+grammar.ra.size=8' '+grammar.ra=[1:3],2,3,{4:=1,5:=1},inc:6:6,dec:7:7,8,9' > cmdline_struct_schema_primitive_arrays_real_grammar.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_real_grammar.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_REAL_GRAMMAR_PASS cmdline_struct_schema_primitive_arrays_real_grammar.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_REAL_SPARSE '+sparse.ra[5]=5.5' > cmdline_struct_schema_primitive_arrays_real_sparse.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_real_sparse.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_REAL_SPARSE_PASS cmdline_struct_schema_primitive_arrays_real_sparse.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_REFILL '+refill.ra.each=0,1,2' '+refill.ra.unique=1' '+refill.ra[2]=2' '+refill.ea.each=ELOW,EMID,EHIGH' '+refill.ea.unique=1' '+refill.ea[2]=EHIGH' > cmdline_struct_schema_primitive_arrays_refill.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_refill.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_REFILL_PASS cmdline_struct_schema_primitive_arrays_refill.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays +AIP_TEST_PRIM_STRING_REFILL '+strfill.sa.each=[a,b,c]' '+strfill.sa.unique=1' '+strfill.sa[2]=c' > cmdline_struct_schema_primitive_arrays_string_refill.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_string_refill.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_STRING_REFILL_PASS cmdline_struct_schema_primitive_arrays_string_refill.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_primitive_arrays -no_save -exitstatus +AIP_TEST_PRIM_STRING_BRACKET_EMPTY_UNIQUE '+emptybr.sa.size=1' '+emptybr.sa.each=[]' '+emptybr.sa.unique=1' > cmdline_struct_schema_primitive_arrays_string_bracket_empty_unique.log 2>&1 || { cat cmdline_struct_schema_primitive_arrays_string_bracket_empty_unique.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_PRIM_STRING_BRACKET_EMPTY_UNIQUE_PASS cmdline_struct_schema_primitive_arrays_string_bracket_empty_unique.log

test_cmdline_struct_schema_nested:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_nested -Mdir=csrc_cmdline_struct_schema_nested test_cmdline_struct_schema_nested.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested '+cfg.tags=1,2,3' '+cfg.labels=a,b' '+cfg.kids={value=7},{value=8}' '+cfg.dynkids.size=2' '+cfg.dynkids[0].value=4' '+cfg.dynkids[1].value=9' '+cfg.weights=1.5,2.5' '+cfg.dynweights.size=2' '+cfg.dynweights[0]=3.5' '+cfg.dynweights[1]=4.5' '+cfg.status=HOT,WARM' '+cfg.dynstatus.size=2' '+cfg.dynstatus[0]=COLD' '+cfg.dynstatus[1]=HOT' > cmdline_struct_schema_nested.log 2>&1 || { cat cmdline_struct_schema_nested.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_nested.log && grep -Fxq CMDLINE_STRUCT_SCHEMA_NESTED_PASS cmdline_struct_schema_nested.log

test_cmdline_struct_schema_nested_canonical:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_nested_canonical -Mdir=csrc_cmdline_struct_schema_nested_canonical test_cmdline_struct_schema_nested_canonical.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_LEAF +cfg.value=11 +value=99 > cmdline_struct_schema_nested_canonical_leaf.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_leaf.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_LEAF_PASS cmdline_struct_schema_nested_canonical_leaf.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_COMPACT '+cfg={values=[1,2,3,4]}' > cmdline_struct_schema_nested_canonical_compact.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_compact.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_COMPACT_PASS cmdline_struct_schema_nested_canonical_compact.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_DOTTED_SHADOW '+cfg={values=[1,2,3,4]}' '+cfg.values=5,6' > cmdline_struct_schema_nested_canonical_dotted.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_dotted.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_DOTTED_PASS cmdline_struct_schema_nested_canonical_dotted.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_INDEXED_SHADOW '+cfg={values=[1,2,3,4]}' '+cfg.values[1]=9' > cmdline_struct_schema_nested_canonical_indexed.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_indexed.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_INDEXED_PASS cmdline_struct_schema_nested_canonical_indexed.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_SPARSE '+cfg.values[1]=9' > cmdline_struct_schema_nested_canonical_sparse.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_sparse.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_SPARSE_PASS cmdline_struct_schema_nested_canonical_sparse.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_STRING '+cfg.labels[0]="a,b"' '+cfg.labels[1]=c' > cmdline_struct_schema_nested_canonical_string.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_string.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_STRING_PASS cmdline_struct_schema_nested_canonical_string.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_METADATA_FILTER '+cfgs.bus.id=10,20' '+cfgs.unknown=1,2,3,4' '+cfgs[4].unknown=99' > cmdline_struct_schema_nested_canonical_metadata.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_metadata.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_METADATA_PASS cmdline_struct_schema_nested_canonical_metadata.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_nested_canonical -no_save -exitstatus +AIP_CANON_BARE_CHILD '+cfgs.channels.size=2' > cmdline_struct_schema_nested_canonical_bare_child.log 2>&1; rc=$$?; cat cmdline_struct_schema_nested_canonical_bare_child.log; test $$rc -ne 0; } \
	    && ! grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_BARE_CHILD_UNEXPECTED_PASS cmdline_struct_schema_nested_canonical_bare_child.log \
	    && grep -Fq '[AIP_STRUCT] cfgs.channels.size is an array-valued child' cmdline_struct_schema_nested_canonical_bare_child.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_nested_canonical -no_save +AIP_CANON_OUTER_EACH '+cfgs.size=3' '+cfgs.each.channels.size=[2:4]' '+cfgs[2].channels.size=3' '+cfgs.each.nested.size=2' '+cfgs.each.nested.each.base=7' '+cfgs[1].nested[0].base=9' > cmdline_struct_schema_nested_canonical_outer.log 2>&1 || { cat cmdline_struct_schema_nested_canonical_outer.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_CANON_OUTER_PASS cmdline_struct_schema_nested_canonical_outer.log

test_cmdline_struct_schema_final_review:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_final_review -Mdir=csrc_cmdline_struct_schema_final_review test_cmdline_struct_schema_final_review.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SELECTOR_PRECEDENCE \
	    '+f1.cfgs.each.channels.each.addr=1' \
	    '+f1.cfgs.each.channels[1].addr=11' \
	    '+f1.cfgs[2].channels.each.addr=22' \
	    '+f1.cfgs[2].channels[1].addr=221' \
	    '+f1.cfgs.each.channels.each.tags.each=5' \
	    '+f1.cfgs.each.channels.each.tags[1]=9' \
	    '+f1.cfgs.each.channels.each.values.size=1' \
	    '+f1.cfgs.each.channels[1].values.size=2' \
	    '+f1.cfgs[2].channels.each.values.size=3' \
	    '+f1.cfgs[2].channels[1].values.size=4' \
	    > cmdline_struct_schema_final_selector.log 2>&1 || { cat cmdline_struct_schema_final_selector.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SELECTOR_PASS cmdline_struct_schema_final_selector.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_INHERITED_SORT \
	    '+f1sort.cfgs.each.channels.each.children.value=3,1,2' \
	    '+f1sort.cfgs.each.channels.each.children.each.value.sort=asc' \
	    > cmdline_struct_schema_final_inherited_sort.log 2>&1 || { cat cmdline_struct_schema_final_inherited_sort.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_INHERITED_SORT_PASS cmdline_struct_schema_final_inherited_sort.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus +AIP_FINAL_INHERITED_UNIQUE_FIXED \
	    '+f1fixed.cfgs.each.channels.each.children.value=7,7,9' \
	    '+f1fixed.cfgs.each.channels.each.children.each.value.unique=1' \
	    > cmdline_struct_schema_final_inherited_unique_fixed.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_final_inherited_unique_fixed.log; test $$rc -ne 0; ! grep -Fq CMDLINE_STRUCT_FINAL_INHERITED_UNIQUE_FIXED_UNEXPECTED_PASS cmdline_struct_schema_final_inherited_unique_fixed.log; grep -Fq '[AIP_STRUCT] f1fixed.cfgs[0].channels[0].children.each.value.unique: duplicate fixed value' cmdline_struct_schema_final_inherited_unique_fixed.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus +AIP_FINAL_INHERITED_PREFLIGHT \
	    '+f1pre.cfgs.each.channels.each.children.each.value=0,1' \
	    '+f1pre.cfgs.each.channels.each.children.each.value.unique=1' \
	    > cmdline_struct_schema_final_inherited_preflight.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_final_inherited_preflight.log; test $$rc -ne 0; ! grep -Fq CMDLINE_STRUCT_FINAL_INHERITED_PREFLIGHT_UNEXPECTED_PASS cmdline_struct_schema_final_inherited_preflight.log; grep -Fq '[AIP_STRUCT] f1pre.cfgs[0].channels[0].children.each.value.unique: only 2 candidates for 3 elements' cmdline_struct_schema_final_inherited_preflight.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +ntb_random_seed=1 +AIP_FINAL_INHERITED_REDRAW \
	    '+f1redraw.cfgs.each.channels.each.children.each.value=0,1,2' \
	    '+f1redraw.cfgs.each.channels.each.children[2].value=2' \
	    '+f1redraw.cfgs.each.channels.each.children.each.value.unique=1' \
	    > cmdline_struct_schema_final_inherited_redraw.log 2>&1 || { cat cmdline_struct_schema_final_inherited_redraw.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_INHERITED_REDRAW_PASS cmdline_struct_schema_final_inherited_redraw.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SHADOW_INVALID_INT '+f2badint.ints=10,11,12' '+f2badint.ints.each=12oops' > cmdline_struct_schema_final_shadow_invalid_int.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SHADOW_INVALID_INT_PASS cmdline_struct_schema_final_shadow_invalid_int.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SHADOW_INVALID_STRING '+f2badstr.strings=a,b,c' '+f2badstr.strings.each="bad\q"' > cmdline_struct_schema_final_shadow_invalid_string.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SHADOW_INVALID_STRING_PASS cmdline_struct_schema_final_shadow_invalid_string.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SHADOW_INVALID_REAL '+f2badreal.reals=1.0,2.0,3.0' '+f2badreal.reals.each=1.0junk' > cmdline_struct_schema_final_shadow_invalid_real.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SHADOW_INVALID_REAL_PASS cmdline_struct_schema_final_shadow_invalid_real.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SHADOW_INVALID_ENUM '+f2badenum.enums=FINAL_LOW,FINAL_MID,FINAL_HIGH' '+f2badenum.enums.each=NOT_A_MODE' > cmdline_struct_schema_final_shadow_invalid_enum.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SHADOW_INVALID_ENUM_PASS cmdline_struct_schema_final_shadow_invalid_enum.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_SHADOW_RNG > cmdline_struct_schema_final_shadow_rng.log 2>&1 || { cat cmdline_struct_schema_final_shadow_rng.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_SHADOW_RNG_PASS cmdline_struct_schema_final_shadow_rng.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_PERM_PREWARM > cmdline_struct_schema_final_perm_prewarm.log 2>&1 || { cat cmdline_struct_schema_final_perm_prewarm.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_PERM_PREWARM_PASS cmdline_struct_schema_final_perm_prewarm.log
	cd $(TEST_SV_DIR) && run_f3() { name="$$1"; arg="$$2"; expect="$$3"; set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus +AIP_FINAL_STRICT_ARRAY_ERROR "$$arg" > "cmdline_struct_schema_final_strict_$$name.log" 2>&1; rc=$$?; set -e; cat "cmdline_struct_schema_final_strict_$$name.log"; test $$rc -ne 0; ! grep -Fq CMDLINE_STRUCT_FINAL_STRICT_ARRAY_UNEXPECTED_PASS "cmdline_struct_schema_final_strict_$$name.log"; grep -Fq "$$expect" "cmdline_struct_schema_final_strict_$$name.log"; }; \
	    run_f3 int_malformed "+f3.ints[0]=12oops" "[AIP_STRUCT] f3.ints[0] invalid integral literal '12oops'"; \
	    run_f3 int_x "+f3.ints[0]=4'b10x0" "[AIP_STRUCT] f3.ints[0] invalid integral literal '4'b10x0'"; \
	    run_f3 int_z "+f3.ints[0]=4'b10z0" "[AIP_STRUCT] f3.ints[0] invalid integral literal '4'b10z0'"; \
	    run_f3 int_overflow "+f3.ints[0]=33'h100000000" "[AIP_STRUCT] f3.ints[0] integral token '33'h100000000' exceeds 32-bit target"; \
	    run_f3 enum_invalid "+f3.enums[0]=NOT_A_MODE" "[AIP_STRUCT] f3.enums[0] invalid enum value 'NOT_A_MODE'"; \
	    run_f3 index_malformed "+f3.ints[0]junk=1" "[AIP_STRUCT] malformed index in +f3.ints[0]junk"; \
	    run_f3 index_noncanonical "+f3.ints[01]=1" "[AIP_STRUCT] noncanonical index in +f3.ints[01]"; \
	    run_f3 index_negative "+f3.ints[-1]=1" "[AIP_STRUCT] noncanonical index in +f3.ints[-1]"; \
	    run_f3 index_range "+f3.ints[3]=1" "[AIP_STRUCT] f3.ints indexed value out of range"
	cd $(TEST_SV_DIR) && run_f4() { name="$$1"; selector="$$2"; expect="$$3"; set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus "$$selector" > "cmdline_struct_schema_final_unique_$$name.log" 2>&1; rc=$$?; set -e; cat "cmdline_struct_schema_final_unique_$$name.log"; test $$rc -ne 0; ! grep -Fq UNEXPECTED_PASS "cmdline_struct_schema_final_unique_$$name.log"; grep -Fq "$$expect" "cmdline_struct_schema_final_unique_$$name.log"; }; \
	    run_f4 static_shortage +AIP_FINAL_UNIQUE_STATIC_SHORTAGE "[AIP_STRUCT] f4static.ints.unique: only 2 candidates for 3 elements"; \
	    run_f4 static_fixed +AIP_FINAL_UNIQUE_STATIC_FIXED "[AIP_STRUCT] f4fixed.strings.unique: duplicate fixed value at indices 0 and 2"; \
	    run_f4 dynamic_cast +AIP_FINAL_UNIQUE_DYNAMIC_CAST "[AIP_STRUCT] f4cast.narrow_values.unique: only 2 candidates for 3 elements"; \
	    run_f4 real_shortage +AIP_FINAL_UNIQUE_REAL_SHORTAGE "[AIP_STRUCT] f4q.final_real_q.unique: only 2 candidates for 3 elements"; \
	    run_f4 queue_fixed +AIP_FINAL_UNIQUE_QUEUE_FIXED "[AIP_STRUCT] f4q.final_fixed_q.unique: duplicate fixed value at indices 0 and 2"
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +ntb_random_seed=13 +AIP_FINAL_UNIQUE_TYPED_POSITIVE > cmdline_struct_schema_final_unique_typed.log 2>&1 || { cat cmdline_struct_schema_final_unique_typed.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_UNIQUE_TYPED_POSITIVE_PASS cmdline_struct_schema_final_unique_typed.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_UNIQUE_CUTOFF > cmdline_struct_schema_final_unique_cutoff.log 2>&1 || { cat cmdline_struct_schema_final_unique_cutoff.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_UNIQUE_CUTOFF_PASS cmdline_struct_schema_final_unique_cutoff.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_UNIQUE_NO_PREFLIGHT_RNG > cmdline_struct_schema_final_unique_rng.log 2>&1 || { cat cmdline_struct_schema_final_unique_rng.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_UNIQUE_NO_PREFLIGHT_RNG_PASS cmdline_struct_schema_final_unique_rng.log
	cd $(TEST_SV_DIR) && run_f5() { name="$$1"; selector="$$2"; expect="$$3"; set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus "$$selector" > "cmdline_struct_schema_final_static_$$name.log" 2>&1; rc=$$?; set -e; cat "cmdline_struct_schema_final_static_$$name.log"; test $$rc -ne 0; ! grep -Fq UNEXPECTED_PASS "cmdline_struct_schema_final_static_$$name.log"; grep -Fq "$$expect" "cmdline_struct_schema_final_static_$$name.log"; }; \
	    run_f5 top_asc +AIP_FINAL_STATIC_TOP_ASC "[AIP_STRUCT] f5.top_asc static array range [3:5] must be [0:2]"; \
	    run_f5 top_desc +AIP_FINAL_STATIC_TOP_DESC "[AIP_STRUCT] f5.top_desc static array range [2:0] must be [0:2]"; \
	    run_f5 nested_asc +AIP_FINAL_STATIC_NESTED_ASC "[AIP_STRUCT] f5.nested_asc.values static array range [3:5] must be [0:2]"; \
	    run_f5 nested_desc +AIP_FINAL_STATIC_NESTED_DESC "[AIP_STRUCT] f5.nested_desc.values static array range [2:0] must be [0:2]"; \
	    run_f5 int_asc +AIP_FINAL_STATIC_INT_ASC "[AIP_STRUCT] f5.int_asc.values static array range [3:5] must be [0:2]"; \
	    run_f5 int_desc +AIP_FINAL_STATIC_INT_DESC "[AIP_STRUCT] f5.int_desc.values static array range [2:0] must be [0:2]"; \
	    run_f5 string_asc +AIP_FINAL_STATIC_STRING_ASC "[AIP_STRUCT] f5.string_asc.values static array range [3:5] must be [0:2]"; \
	    run_f5 string_desc +AIP_FINAL_STATIC_STRING_DESC "[AIP_STRUCT] f5.string_desc.values static array range [2:0] must be [0:2]"; \
	    run_f5 real_asc +AIP_FINAL_STATIC_REAL_ASC "[AIP_STRUCT] f5.real_asc.values static array range [3:5] must be [0:2]"; \
	    run_f5 real_desc +AIP_FINAL_STATIC_REAL_DESC "[AIP_STRUCT] f5.real_desc.values static array range [2:0] must be [0:2]"; \
	    run_f5 enum_asc +AIP_FINAL_STATIC_ENUM_ASC "[AIP_STRUCT] f5.enum_asc.values static array range [3:5] must be [0:2]"; \
	    run_f5 enum_desc +AIP_FINAL_STATIC_ENUM_DESC "[AIP_STRUCT] f5.enum_desc.values static array range [2:0] must be [0:2]"
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_STATIC_ZERO_PROBE > cmdline_struct_schema_final_static_zero_probe.log 2>&1 || { cat cmdline_struct_schema_final_static_zero_probe.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_STATIC_ZERO_PROBE_PASS cmdline_struct_schema_final_static_zero_probe.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_final_review -no_save -exitstatus +AIP_FINAL_RECURSION_GUARD_INTERNAL > cmdline_struct_schema_final_recursion_guard.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_final_recursion_guard.log; test $$rc -ne 0; ! grep -Fq CMDLINE_STRUCT_FINAL_RECURSION_GUARD_UNEXPECTED_PASS cmdline_struct_schema_final_recursion_guard.log; grep -Fq '[AIP_STRUCT] recursive schema registration detected for' cmdline_struct_schema_final_recursion_guard.log
	cd $(TEST_SV_DIR) && set +e; vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca +define+AIP_FINAL_RECURSIVE_VALUE_COMPILE $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_final_recursive_value -Mdir=csrc_cmdline_struct_schema_final_recursive_value test_cmdline_struct_schema_final_review.sv > cmdline_struct_schema_final_recursive_value.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_final_recursive_value.log; test $$rc -ne 0; grep -Fq 'Error-[CTD] Cyclical type dependency' cmdline_struct_schema_final_recursive_value.log; grep -Fq "Type 'final_recursive_value_t' is involved in a cyclical type dependency." cmdline_struct_schema_final_recursive_value.log
	cd $(TEST_SV_DIR) && /usr/bin/time -f '%M' -o cmdline_struct_schema_final_darray_baseline.rss ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_DARRAY_MEMORY_BASELINE > cmdline_struct_schema_final_darray_baseline.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_DARRAY_MEMORY_BASELINE_PASS cmdline_struct_schema_final_darray_baseline.log
	cd $(TEST_SV_DIR) && /usr/bin/time -f '%M' -o cmdline_struct_schema_final_darray_top.rss ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_DARRAY_TOP_SHRINK > cmdline_struct_schema_final_darray_top.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_DARRAY_TOP_SHRINK_PASS cmdline_struct_schema_final_darray_top.log
	cd $(TEST_SV_DIR) && /usr/bin/time -f '%M' -o cmdline_struct_schema_final_darray_nested.rss ./simv_cmdline_struct_schema_final_review -no_save +AIP_FINAL_DARRAY_NESTED_SHRINK > cmdline_struct_schema_final_darray_nested.log 2>&1
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_FINAL_DARRAY_NESTED_SHRINK_PASS cmdline_struct_schema_final_darray_nested.log
	cd $(TEST_SV_DIR) && baseline=$$(cat cmdline_struct_schema_final_darray_baseline.rss); top=$$(cat cmdline_struct_schema_final_darray_top.rss); nested=$$(cat cmdline_struct_schema_final_darray_nested.rss); limit=$$((baseline + 65536)); echo CMDLINE_STRUCT_FINAL_DARRAY_RSS_KB baseline=$$baseline top=$$top nested=$$nested limit=$$limit; test $$top -le $$limit; test $$nested -le $$limit; echo CMDLINE_STRUCT_FINAL_DARRAY_MEMORY_PASS

test_cmdline_struct_schema_queue:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_queue -Mdir=csrc_cmdline_struct_schema_queue test_cmdline_struct_schema_queue.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_queue > cmdline_struct_schema_queue.log 2>&1 || { cat cmdline_struct_schema_queue.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_queue.log && grep -Fxq CMDLINE_STRUCT_SCHEMA_QUEUE_PASS cmdline_struct_schema_queue.log
	cd $(TEST_SV_DIR) && set +e; ./simv_cmdline_struct_schema_queue -no_save -exitstatus +QUEUE_OVERFLOW > cmdline_struct_schema_queue_overflow.log 2>&1; rc=$$?; set -e; cat cmdline_struct_schema_queue_overflow.log; test $$rc -ne 0; ! grep -Fq 'bounded queue overflow was silently accepted' cmdline_struct_schema_queue_overflow.log; grep -Fq '[AIP_STRUCT] dut.bounded_items.size invalid candidate 4 (expected 0..3)' cmdline_struct_schema_queue_overflow.log

test_cmdline_strict_queue:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_strict_queue -Mdir=csrc_cmdline_strict_queue test_cmdline_strict_queue.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_POSITIVE '+strict.plus_precedence_q=29' '+plus_precedence_q=19' '+strict.plus_precedence_q=31' > cmdline_strict_queue_positive.log 2>&1 || { cat cmdline_strict_queue_positive.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_POSITIVE_PASS cmdline_strict_queue_positive.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_EVAL_ONCE > cmdline_strict_queue_eval_once.log 2>&1 || { cat cmdline_strict_queue_eval_once.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_EVAL_ONCE_PASS cmdline_strict_queue_eval_once.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_STRUCT_REAPPLY > cmdline_strict_queue_struct_reapply.log 2>&1 || { cat cmdline_strict_queue_struct_reapply.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_STRUCT_REAPPLY_PASS cmdline_strict_queue_struct_reapply.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_SUMMARY > cmdline_strict_queue_summary.log 2>&1 || { cat cmdline_strict_queue_summary.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_SUMMARY_PASS cmdline_strict_queue_summary.log \
	    && test $$(grep -Fc "queue_summary root='strict.summary_q'" cmdline_strict_queue_summary.log) -eq 1 \
	    && grep -Fq "type='int' kind='primitive_queue' size=2 rules=4 controls=3 flags=size,sort" cmdline_strict_queue_summary.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_SHADOW_INVALID > cmdline_strict_queue_shadow_invalid.log 2>&1 || { cat cmdline_strict_queue_shadow_invalid.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_SHADOW_INVALID_PASS cmdline_strict_queue_shadow_invalid.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_SHADOW_RNG > cmdline_strict_queue_shadow_rng.log 2>&1 || { cat cmdline_strict_queue_shadow_rng.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_SHADOW_RNG_PASS cmdline_strict_queue_shadow_rng.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_PERM_RNG > cmdline_strict_queue_perm_rng.log 2>&1 || { cat cmdline_strict_queue_perm_rng.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_PERM_RNG_PASS cmdline_strict_queue_perm_rng.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_UNIQUE_LATER_FIXED > cmdline_strict_queue_unique_later_fixed.log 2>&1 || { cat cmdline_strict_queue_unique_later_fixed.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_UNIQUE_LATER_FIXED_PASS cmdline_strict_queue_unique_later_fixed.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save +STRICT_QUEUE_LARGE_STRUCT_SHRINK > cmdline_strict_queue_large_struct_shrink.log 2>&1 || { cat cmdline_strict_queue_large_struct_shrink.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_LARGE_STRUCT_SHRINK_PASS cmdline_strict_queue_large_struct_shrink.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_STRING_BRACKET_UNIQUE '+strict.str_q.size=3' '+strict.str_q.each=[a,b,c]' '+strict.str_q.unique=1' '+strict.str_q[2]=c' > cmdline_strict_queue_string_bracket_unique.log 2>&1 || { cat cmdline_strict_queue_string_bracket_unique.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_STRING_BRACKET_UNIQUE_PASS cmdline_strict_queue_string_bracket_unique.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_STRING_BRACKET_EMPTY_UNIQUE '+strict.str_q.size=1' '+strict.str_q.each=[]' '+strict.str_q.unique=1' > cmdline_strict_queue_string_bracket_empty_unique.log 2>&1 || { cat cmdline_strict_queue_string_bracket_empty_unique.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRICT_QUEUE_STRING_BRACKET_EMPTY_UNIQUE_PASS cmdline_strict_queue_string_bracket_empty_unique.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_INT_OOB > cmdline_strict_queue_int_oob.log 2>&1; rc=$$?; cat cmdline_strict_queue_int_oob.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_INT_OOB_UNEXPECTED_PASS cmdline_strict_queue_int_oob.log \
	    && grep -Fq '[AIP_STRUCT] strict.int_q indexed value out of range' cmdline_strict_queue_int_oob.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_SEQ_SIZE > cmdline_strict_queue_seq_size.log 2>&1; rc=$$?; cat cmdline_strict_queue_seq_size.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_SEQ_SIZE_UNEXPECTED_PASS cmdline_strict_queue_seq_size.log \
	    && grep -Fq '[AIP_STRUCT] strict.int_q.size conflicts with generator length 3' cmdline_strict_queue_seq_size.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_STRING_GENERATOR > cmdline_strict_queue_string_generator.log 2>&1; rc=$$?; cat cmdline_strict_queue_string_generator.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_STRING_GENERATOR_UNEXPECTED_PASS cmdline_strict_queue_string_generator.log \
	    && grep -Fq '[AIP_STRUCT] strict.str_q seq/perm unsupported for string primitive queue' cmdline_strict_queue_string_generator.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_REAL_GENERATOR > cmdline_strict_queue_real_generator.log 2>&1; rc=$$?; cat cmdline_strict_queue_real_generator.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_REAL_GENERATOR_UNEXPECTED_PASS cmdline_strict_queue_real_generator.log \
	    && grep -Fq '[AIP_STRUCT] strict.real_q seq/perm unsupported for real primitive queue' cmdline_strict_queue_real_generator.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_ENUM_GENERATOR > cmdline_strict_queue_enum_generator.log 2>&1; rc=$$?; cat cmdline_strict_queue_enum_generator.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_ENUM_GENERATOR_UNEXPECTED_PASS cmdline_strict_queue_enum_generator.log \
	    && grep -Fq '[AIP_STRUCT] strict.enum_q seq/perm unsupported for enum primitive queue' cmdline_strict_queue_enum_generator.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_BOUND_MISMATCH > cmdline_strict_queue_bound_mismatch.log 2>&1; rc=$$?; cat cmdline_strict_queue_bound_mismatch.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_BOUND_MISMATCH_UNEXPECTED_PASS cmdline_strict_queue_bound_mismatch.log \
	    && grep -Fq '[AIP_STRUCT] strict.bounded_q queue size mismatch after copy (expected 3, got 2)' cmdline_strict_queue_bound_mismatch.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_SIZE_LIMIT > cmdline_strict_queue_size_limit.log 2>&1; rc=$$?; cat cmdline_strict_queue_size_limit.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_SIZE_LIMIT_UNEXPECTED_PASS cmdline_strict_queue_size_limit.log \
	    && grep -Fq '[AIP_STRUCT] strict.int_q.size invalid candidate 1000001 (expected 0..1000000)' cmdline_strict_queue_size_limit.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_ENUM_DEFAULT_INVALID > cmdline_strict_queue_enum_default.log 2>&1; rc=$$?; cat cmdline_strict_queue_enum_default.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_ENUM_DEFAULT_INVALID_UNEXPECTED_PASS cmdline_strict_queue_enum_default.log \
	    && grep -Fq '[AIP_STRUCT] strict.enum_q invalid enum DEFAULT_VAL' cmdline_strict_queue_enum_default.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_FIXED_COLLISION > cmdline_strict_queue_fixed_collision.log 2>&1; rc=$$?; cat cmdline_strict_queue_fixed_collision.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_FIXED_COLLISION_UNEXPECTED_PASS cmdline_strict_queue_fixed_collision.log \
	    && grep -Fq '[AIP_STRUCT] strict.fixed_collision_q.unique: duplicate fixed value at indices 0 and 1' cmdline_strict_queue_fixed_collision.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_CANDIDATE_SHORTAGE > cmdline_strict_queue_candidate_shortage.log 2>&1; rc=$$?; cat cmdline_strict_queue_candidate_shortage.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_CANDIDATE_SHORTAGE_UNEXPECTED_PASS cmdline_strict_queue_candidate_shortage.log \
	    && grep -Fq '[AIP_STRUCT] strict.shortage_q.unique: only 1 candidates for 2 elements' cmdline_strict_queue_candidate_shortage.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_INTEGRAL_XZ > cmdline_strict_queue_integral_xz.log 2>&1; rc=$$?; cat cmdline_strict_queue_integral_xz.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_INTEGRAL_XZ_UNEXPECTED_PASS cmdline_strict_queue_integral_xz.log \
	    && grep -Fq "[AIP_STRUCT] strict.narrow_q[0] invalid integral literal '8'hx'" cmdline_strict_queue_integral_xz.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_INTEGRAL_OVERFLOW > cmdline_strict_queue_integral_overflow.log 2>&1; rc=$$?; cat cmdline_strict_queue_integral_overflow.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_INTEGRAL_OVERFLOW_UNEXPECTED_PASS cmdline_strict_queue_integral_overflow.log \
	    && grep -Fq "[AIP_STRUCT] strict.narrow_q[0] integral token '256' exceeds 8-bit target" cmdline_strict_queue_integral_overflow.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_INTEGRAL_MALFORMED > cmdline_strict_queue_integral_malformed.log 2>&1; rc=$$?; cat cmdline_strict_queue_integral_malformed.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_INTEGRAL_MALFORMED_UNEXPECTED_PASS cmdline_strict_queue_integral_malformed.log \
	    && grep -Fq "[AIP_STRUCT] strict.narrow_q[0] invalid integral literal '12oops'" cmdline_strict_queue_integral_malformed.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_strict_queue -no_save -exitstatus +STRICT_QUEUE_LEGACY_DIAGNOSTIC > cmdline_strict_queue_legacy_diagnostic.log 2>&1; rc=$$?; cat cmdline_strict_queue_legacy_diagnostic.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRICT_QUEUE_LEGACY_DIAGNOSTIC_UNEXPECTED_PASS cmdline_strict_queue_legacy_diagnostic.log \
	    && grep -Fq 'AIP_CORE[cmdline] parser Error: Invalid integer format: 12oops' cmdline_strict_queue_legacy_diagnostic.log
	cd $(TEST_SV_DIR) && if vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca +define+AIP_STRICT_QUEUE_WIDTH_FAIL $(AIP_TEST_INCDIRS) -o simv_cmdline_strict_queue_width_fail -Mdir=csrc_cmdline_strict_queue_width_fail test_cmdline_strict_queue.sv > cmdline_strict_queue_width_fail.log 2>&1; then cat cmdline_strict_queue_width_fail.log; echo 'expected >1024-bit queue compilation to fail'; exit 1; else cat cmdline_strict_queue_width_fail.log; fi

test_cmdline_struct_schema_lifecycle:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_lifecycle -Mdir=csrc_cmdline_struct_schema_lifecycle test_cmdline_struct_schema_lifecycle.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_lifecycle -no_save +AIP_TEST_LIFECYCLE_REPEAT > cmdline_struct_schema_lifecycle_repeat.log 2>&1 || { cat cmdline_struct_schema_lifecycle_repeat.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_LIFECYCLE_REPEAT_PASS cmdline_struct_schema_lifecycle_repeat.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_lifecycle -no_save +AIP_TEST_LIFECYCLE_EVAL_ONCE > cmdline_struct_schema_lifecycle_eval.log 2>&1 || { cat cmdline_struct_schema_lifecycle_eval.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_LIFECYCLE_EVAL_PASS cmdline_struct_schema_lifecycle_eval.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_lifecycle -no_save +AIP_TEST_LIFECYCLE_EXPLICIT_ZERO > cmdline_struct_schema_lifecycle_zero.log 2>&1 || { cat cmdline_struct_schema_lifecycle_zero.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SCHEMA_LIFECYCLE_ZERO_PASS cmdline_struct_schema_lifecycle_zero.log

test_cmdline_struct_schema_size_budget:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_size_budget -Mdir=csrc_cmdline_struct_schema_size_budget test_cmdline_struct_schema_size_budget.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_size_budget -no_save +ntb_random_seed=41 \
	    '+wide.seq.value=seq:0x100000000:0x100000004:2' \
	    '+wide.perm.value=perm:0x200000000:0x200000001' \
	    > cmdline_struct_schema_size_budget.log 2>&1 || { cat cmdline_struct_schema_size_budget.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_SIZE_GRAMMAR_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_SIZE_DRAW_ONCE_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_PERM_DRAW_ORDER_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_NESTED_PERM_DRAW_ORDER_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_NESTED_PERM_VALUES_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_SIZE_REACHABLE_ENDPOINTS_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_WIDE_GENERATORS_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_WIDEST_GENERATORS_PASS cmdline_struct_schema_size_budget.log \
	    && grep -Fxq CMDLINE_STRUCT_SIZE_BUDGET_PASS cmdline_struct_schema_size_budget.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_size_budget -no_save +AIP_SIZE_DEFAULT_ONCE \
	    > cmdline_struct_schema_size_default_once.log 2>&1 || { cat cmdline_struct_schema_size_default_once.log; exit 1; }
	cd $(TEST_SV_DIR) && grep -Fxq CMDLINE_STRUCT_SIZE_DEFAULT_ONCE_PASS cmdline_struct_schema_size_default_once.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +ntb_random_seed=1 +AIP_SIZE_INVALID_DOMAIN \
	    '+bad.domain.values.size={2:=1000000,1000001:=1}' > cmdline_struct_schema_size_invalid.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_invalid.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_INVALID_UNEXPECTED_PASS cmdline_struct_schema_size_invalid.log \
	    && grep -Fq '[AIP_STRUCT] bad.domain.values.size invalid candidate 1000001' cmdline_struct_schema_size_invalid.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_BARE_RAND \
	    '+bad.rand.size=rand' > cmdline_struct_schema_size_rand.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_rand.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_RAND_UNEXPECTED_PASS cmdline_struct_schema_size_rand.log \
	    && grep -Fq "[AIP_STRUCT] bad.rand.size invalid .size expression 'rand'" cmdline_struct_schema_size_rand.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_OTHER_INVALID \
	    '+bad.other.size=' > cmdline_struct_schema_size_empty.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_empty.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_OTHER_UNEXPECTED_PASS cmdline_struct_schema_size_empty.log \
	    && grep -Fq "[AIP_STRUCT] bad.other.size invalid .size expression ''" cmdline_struct_schema_size_empty.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_OTHER_INVALID \
	    '+bad.other.size=each' > cmdline_struct_schema_size_each.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_each.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_OTHER_UNEXPECTED_PASS cmdline_struct_schema_size_each.log \
	    && grep -Fq "[AIP_STRUCT] bad.other.size invalid .size expression 'each'" cmdline_struct_schema_size_each.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_OTHER_INVALID \
	    '+bad.other.size=seq:1:2' > cmdline_struct_schema_size_seq.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_seq.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_OTHER_UNEXPECTED_PASS cmdline_struct_schema_size_seq.log \
	    && grep -Fq "[AIP_STRUCT] bad.other.size invalid .size expression 'seq:1:2'" cmdline_struct_schema_size_seq.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_OTHER_INVALID \
	    '+bad.other.size=perm:1:2' > cmdline_struct_schema_size_perm.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_perm.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_OTHER_UNEXPECTED_PASS cmdline_struct_schema_size_perm.log \
	    && grep -Fq "[AIP_STRUCT] bad.other.size invalid .size expression 'perm:1:2'" cmdline_struct_schema_size_perm.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_STATIC_REJECT \
	    '+bad.static.value=seq:0:1' > cmdline_struct_schema_size_static.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_static.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_STATIC_UNEXPECTED_PASS cmdline_struct_schema_size_static.log \
	    && grep -Fq '[AIP_STRUCT] bad.static generator length 2 does not match static size 3' cmdline_struct_schema_size_static.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_STATIC_SIZE_TOP \
	    '+bad.static_size.size=3' > cmdline_struct_schema_static_size_top.log 2>&1; rc=$$?; cat cmdline_struct_schema_static_size_top.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_STATIC_SIZE_TOP_UNEXPECTED_PASS cmdline_struct_schema_static_size_top.log \
	    && grep -Fq '[AIP_STRUCT] bad.static_size.size not allowed for static array' cmdline_struct_schema_static_size_top.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_STATIC_SIZE_NESTED \
	    '+nested.static.each.fixed_children.size=3' > cmdline_struct_schema_static_size_nested.log 2>&1; rc=$$?; cat cmdline_struct_schema_static_size_nested.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_STATIC_SIZE_NESTED_UNEXPECTED_PASS cmdline_struct_schema_static_size_nested.log \
	    && grep -Fq '[AIP_STRUCT] nested.static[0].fixed_children.size not allowed for static array' cmdline_struct_schema_static_size_nested.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_GENERATOR_CONFLICT \
	    '+bad.gen.size=2' '+bad.gen.value=seq:0:2' > cmdline_struct_schema_size_gen.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_gen.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_GEN_UNEXPECTED_PASS cmdline_struct_schema_size_gen.log \
	    && grep -Fq '[AIP_STRUCT] bad.gen.size conflicts with generator length 3' cmdline_struct_schema_size_gen.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_SIZE_BUDGET_OVERFLOW \
	    '+budget.outer.each.values.size=500001' > cmdline_struct_schema_size_budget_overflow.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_budget_overflow.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_BUDGET_UNEXPECTED_PASS cmdline_struct_schema_size_budget_overflow.log \
	    && grep -Fq '[AIP_STRUCT] allocation budget exceeded before budget.outer[1].values' cmdline_struct_schema_size_budget_overflow.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +ntb_random_seed=1 +AIP_SIZE_MAX_PREFLIGHT \
	    '+bad.max.size={2:=1000000,4:=1}' > cmdline_struct_schema_size_max.log 2>&1; rc=$$?; cat cmdline_struct_schema_size_max.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_SIZE_MAX_UNEXPECTED_PASS cmdline_struct_schema_size_max.log \
	    && grep -Fq '[AIP_STRUCT] bad.max.size invalid candidate 4 (expected 0..3)' cmdline_struct_schema_size_max.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_WIDEST_X_INVALID \
	    > cmdline_struct_schema_widest_x.log 2>&1; rc=$$?; cat cmdline_struct_schema_widest_x.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_WIDEST_X_UNEXPECTED_PASS cmdline_struct_schema_widest_x.log \
	    && grep -Fq "[AIP_STRUCT] invalid seq generator 'seq:1024'hx:1024'h1'" cmdline_struct_schema_widest_x.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_struct_schema_size_budget -no_save -exitstatus +AIP_WIDEST_Z_INVALID \
	    > cmdline_struct_schema_widest_z.log 2>&1; rc=$$?; cat cmdline_struct_schema_widest_z.log; test $$rc -ne 0; } \
	    && ! grep -Fq CMDLINE_STRUCT_WIDEST_Z_UNEXPECTED_PASS cmdline_struct_schema_widest_z.log \
	    && grep -Fq "[AIP_STRUCT] invalid perm generator 'perm:1024'h0:1024'hz'" cmdline_struct_schema_widest_z.log

test_cmdline_struct_schema_width_fail:
	cd $(TEST_SV_DIR) && { vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_width_fail -Mdir=csrc_cmdline_struct_schema_width_fail test_cmdline_struct_schema_width_fail.sv > cmdline_struct_schema_width_fail.log 2>&1; rc=$$?; cat cmdline_struct_schema_width_fail.log; if [ $$rc -eq 0 ]; then echo 'unexpected PASS: 1025-bit schema array compiled'; exit 1; fi; grep -Fq 'Error-[TCF-ICTC] Illegal compile-time constant' cmdline_struct_schema_width_fail.log; grep -Fq '($$bits(too_wide_t) <= 1024)' cmdline_struct_schema_width_fail.log; }

test_cmdline_struct_schema_integration:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_integration -Mdir=csrc_cmdline_struct_schema_integration test_cmdline_struct_schema_integration.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_integration -no_save +AIP_INTEGRATION_API \
	    '+scope.wildcard.value=21' '+scope.selective.value=22' \
	    '+scope.alias.value=23' '+scope.module.value=24' \
	    '+scope.class.value=25' '+scope.object.value=26' \
	    '+legacy.legacy_cfg={addr=31}' '+obj.cfg.addr=32' \
	    '+scope.post.value=10' '+dut.cfg2.value=99' \
	    > cmdline_struct_schema_integration_api.log 2>&1
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_integration_api.log \
	    && grep -Fxq CMDLINE_STRUCT_SCHEMA_INTEGRATION_API_PASS cmdline_struct_schema_integration_api.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_integration -no_save +AIP_INTEGRATION_INHERITED_GENERATOR \
	    '+risk.parents.each.children.value=seq:1:3' \
	    > cmdline_struct_schema_integration_inherited.log 2>&1
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_integration_inherited.log \
	    && grep -Fxq CMDLINE_STRUCT_SCHEMA_INHERITED_GENERATOR_PASS cmdline_struct_schema_integration_inherited.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_struct_schema_integration -no_save +AIP_INTEGRATION_SUMMARY \
	    > cmdline_struct_schema_integration_summary.log 2>&1
	cd $(TEST_SV_DIR) && cat cmdline_struct_schema_integration_summary.log \
	    && grep -Fxq CMDLINE_STRUCT_SCHEMA_SUMMARY_NORMALIZATION_PASS cmdline_struct_schema_integration_summary.log \
	    && grep -F "queue_summary root='summary.disabled'" cmdline_struct_schema_integration_summary.log | grep -Eq "flags=size,each([^[:alnum:],]|$$)" \
	    && grep -F "queue_summary root='summary.segment'" cmdline_struct_schema_integration_summary.log | grep -Eq "flags=none([^[:alnum:],]|$$)" \
	    && grep -F "queue_summary root='summary.summary_primitive_q'" cmdline_struct_schema_integration_summary.log | grep -Eq "flags=size([^[:alnum:],]|$$)"

# Runtime schema failures share one compiled fixture, but every matrix row is
# launched in its own process and must return nonzero with its own marker absent.
test_cmdline_struct_schema_negative:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_struct_schema_negative -Mdir=csrc_cmdline_struct_schema_negative test_cmdline_struct_schema_negative.sv
	cd $(TEST_SV_DIR) && set -e; \
	    run_neg() { \
	        case_name="$$1"; fragment="$$2"; log="cmdline_struct_schema_negative_$${case_name}.log"; \
	        set +e; ./simv_cmdline_struct_schema_negative -no_save -exitstatus +UVM_NO_RELNOTES +AIP_NEG_CASE=$${case_name} > "$$log" 2>&1; rc=$$?; set -e; \
	        cat "$$log"; test $$rc -ne 0; \
	        ! grep -Fq "AIP_STRUCT_NEG_$${case_name}_UNEXPECTED_PASS" "$$log"; \
	        grep -Fq "$$fragment" "$$log"; \
	    }; \
	    run_neg root_empty "[AIP_STRUCT] schema ROOT must not be empty"; \
	    run_neg root_space "[AIP_STRUCT] invalid ROOT 'neg root'"; \
	    run_neg root_digit "[AIP_STRUCT] invalid ROOT '1neg.root'"; \
	    run_neg root_repeat_dot "[AIP_STRUCT] invalid ROOT 'neg..root'"; \
	    run_neg root_trailing_dot "[AIP_STRUCT] invalid ROOT 'neg.root.'"; \
	    run_neg root_plus "[AIP_STRUCT] invalid ROOT '+neg.root'"; \
	    run_neg root_equal "[AIP_STRUCT] invalid ROOT 'neg=root'"; \
	    run_neg root_index "[AIP_STRUCT] invalid ROOT 'neg.root[0]'"; \
	    run_neg index_noncanonical "[AIP_STRUCT] noncanonical index in runtime key neg.many[01].value"; \
	    run_neg index_negative "[AIP_STRUCT] noncanonical index in runtime key neg.many[-1].value"; \
	    run_neg index_oob "[AIP_STRUCT] index 2 out of range for neg.fixed"; \
	    run_neg compact_unknown "[AIP_STRUCT] unknown compact field 'unknown'"; \
	    run_neg compact_duplicate "[AIP_STRUCT] duplicate compact field 'value'"; \
	    run_neg compact_missing_equal "[AIP_STRUCT] malformed compact member 'value'"; \
	    run_neg compact_empty_nonstring "[AIP_STRUCT] empty value for non-string field 'value'"; \
	    run_neg compact_unbalanced "[AIP_STRUCT] unbalanced delimiters or quote"; \
	    run_neg compact_bad_escape "[AIP_STRUCT] invalid escape"; \
	    run_neg default_size_negative "[AIP_STRUCT] invalid DEFAULT_SIZE -1.000000"; \
	    run_neg default_size_fractional "[AIP_STRUCT] invalid DEFAULT_SIZE 1.500000"; \
	    run_neg max_size_negative "[AIP_STRUCT] invalid MAX_SIZE -2.000000"; \
	    run_neg size_list_conflict "[AIP_STRUCT] neg.many overall list has 2 elements, .size is 1"; \
	    run_neg size_index_conflict "[AIP_STRUCT] index 1 out of range for neg.many"; \
	    run_neg size_generator_conflict "[AIP_STRUCT] neg.many.size conflicts with generator length 3"; \
	    run_neg default_x "[AIP_STRUCT] integral default for field 'bad' contains X/Z"; \
	    run_neg default_z "[AIP_STRUCT] integral default for field 'bad' contains X/Z"; \
	    run_neg command_x "[AIP_STRUCT] neg.unsigned_q[0] invalid integral literal '8'hx'"; \
	    run_neg command_z "[AIP_STRUCT] neg.unsigned_q[0] invalid integral literal '8'hz'"; \
	    run_neg signed_256 "[AIP_STRUCT] neg.signed_q[0] integral token '256' exceeds 8-bit target"; \
	    run_neg signed_neg256 "[AIP_STRUCT] neg.signed_q[0] integral token '-256' exceeds 8-bit target"; \
	    run_neg signed_wide_literal "[AIP_STRUCT] neg.signed_q[0] integral token '9'h0ff' exceeds 8-bit target"; \
	    run_neg unsigned_256 "[AIP_STRUCT] neg.unsigned_q[0] integral token '256' exceeds 8-bit target"; \
	    run_neg unsigned_neg256 "[AIP_STRUCT] neg.unsigned_q[0] integral token '-256' exceeds 8-bit target"; \
	    run_neg unsigned_wide_literal "[AIP_STRUCT] neg.unsigned_q[0] integral token '9'h0ff' exceeds 8-bit target"; \
	    run_neg schema_command_x "[AIP_STRUCT] neg.one.u8 invalid integral literal '8'hx'"; \
	    run_neg schema_command_z "[AIP_STRUCT] neg.one.u8 invalid integral literal '8'hz'"; \
	    run_neg schema_signed_256 "[AIP_STRUCT] neg.one.s8 integral token '256' exceeds 8-bit target"; \
	    run_neg schema_signed_neg256 "[AIP_STRUCT] neg.one.s8 integral token '-256' exceeds 8-bit target"; \
	    run_neg schema_signed_wide_literal "[AIP_STRUCT] neg.one.s8 integral token '9'h0ff' exceeds 8-bit target"; \
	    run_neg schema_unsigned_256 "[AIP_STRUCT] neg.one.u8 integral token '256' exceeds 8-bit target"; \
	    run_neg schema_unsigned_neg256 "[AIP_STRUCT] neg.one.u8 integral token '-256' exceeds 8-bit target"; \
	    run_neg schema_unsigned_wide_literal "[AIP_STRUCT] neg.one.u8 integral token '9'h0ff' exceeds 8-bit target"; \
	    run_neg real_nan "[AIP_STRUCT] neg.one.rate invalid real literal 'NaN'"; \
	    run_neg real_inf "[AIP_STRUCT] neg.one.rate invalid real literal 'Inf'"; \
	    run_neg real_garbage "[AIP_STRUCT] neg.one.rate invalid real literal '1.0junk'"; \
	    run_neg enum_invalid "[AIP_STRUCT] neg.one.mode invalid enum value 'NOT_A_MODE'"; \
	    run_neg seq_string "[AIP_STRUCT] neg.one.labels seq/perm unsupported for string primitive schema array"; \
	    run_neg perm_real "[AIP_STRUCT] neg.one.rates seq/perm unsupported for real primitive schema array"; \
	    run_neg seq_enum "[AIP_STRUCT] neg.one.modes seq/perm unsupported for enum primitive schema array"; \
	    run_neg sort_through_container "array-valued child"; \
	    run_neg unique_shortage "[AIP_STRUCT] neg.many.each.value.unique: only 2 candidates for 3 elements"; \
	    run_neg unique_fixed_collision "[AIP_STRUCT] neg.fixed.each.value.unique: duplicate fixed value"; \
	    run_neg sort_multiple "[AIP_STRUCT] neg.fixed has more than one active struct sort key"; \
	    run_neg sort_invalid "[AIP_STRUCT] neg.fixed.each.value.sort must be asc, desc, or none"; \
	    run_neg queue_overflow "[AIP_STRUCT] neg.bounded.size invalid candidate 3"; \
	    run_neg queue_declaration_mismatch "[AIP_STRUCT] neg.bounded queue size mismatch after copy (expected 3, got 2)"; \
	    run_neg null_object "Null object access"
	cd $(TEST_SV_DIR) && set -e; \
	    for fixture in struct_schema_negative/*.sv; do \
	        name=$$(basename "$$fixture" .sv); simv="simv_struct_schema_compile_negative_$${name}"; log="struct_schema_compile_negative_$${name}.log"; \
	        rm -f "$$simv"; \
	        set +e; vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o "$$simv" -Mdir="csrc_struct_schema_compile_negative_$${name}" "$$fixture" > "$$log" 2>&1; rc=$$?; set -e; \
	        cat "$$log"; test $$rc -ne 0; test ! -x "$$simv"; \
	        ! grep -Fq COMPILE_NEGATIVE_SIMV_LAUNCHED "$$log"; \
	    done

test_cmdline_struct_schema: test_cmdline_struct_schema_scalar test_cmdline_struct_schema_containers test_cmdline_struct_schema_typed_postprocess test_cmdline_struct_schema_nested test_cmdline_struct_schema_nested_canonical test_cmdline_struct_schema_final_review test_cmdline_struct_schema_queue test_cmdline_strict_queue test_cmdline_struct_schema_lifecycle test_cmdline_struct_schema_primitive_arrays test_cmdline_struct_schema_size_budget test_cmdline_struct_schema_width_fail test_cmdline_struct_schema_integration test_cmdline_struct_schema_negative

# Integer list/container syntax regression — requires VCS on PATH
test_cmdline_container_syntax:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_container -Mdir=csrc_cmdline_container test_cmdline_container_syntax.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_container \
	    "+compact_pick=1,2,3" \
	    "+bracket_pick=[1,2,3]" \
	    "+range_pick=[4:6]" \
	    "+range_list_pick=[1:3],4" \
	    "+brace_weight={0:=1,[1:3]:=1}" \
	    "+paren_weight=(0:=1,[1:3]:=1)" \
	    "+compact_arr=1,2,3" \
	    "+bracket_arr=[1,2,3]" \
	    "+signed_arr=[-3,-2,-1]" \
	    "+nested_brace_arr=[{0:=1,[1:3]:=1},4]" \
	    "+nested_paren_arr=[(0:=1,[1:3]:=1),4]" \
	    > cmdline_container.log 2>&1 \
	    || { cat cmdline_container.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_container.log && grep -q CMDLINE_CONTAINER_PASS cmdline_container.log && ! grep -q MALFORMED_ACCEPTED cmdline_container.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_container -no_save -exitstatus +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1,,2,3]" > cmdline_container_malformed_empty.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_container_malformed_empty.log && grep -Fq "Invalid outer list wrapper: [1,,2,3]" cmdline_container_malformed_empty.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_empty.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_container -no_save -exitstatus +AIP_CONTAINER_MALFORMED +ntb_random_seed=9 "+malformed_pick=[1,[2:3],]" > cmdline_container_malformed_trailing.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_container_malformed_trailing.log && grep -Fq "Invalid outer list wrapper: [1,[2:3],]" cmdline_container_malformed_trailing.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_trailing.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_container -no_save -exitstatus +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1,2,3" > cmdline_container_malformed_missing.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_container_malformed_missing.log && grep -Fq "Invalid outer list wrapper: [1,2,3" cmdline_container_malformed_missing.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_missing.log
	cd $(TEST_SV_DIR) && { ./simv_cmdline_container -no_save -exitstatus +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1:3],4]" > cmdline_container_malformed_extra.log 2>&1; rc=$$?; test $$rc -ne 0; }
	cd $(TEST_SV_DIR) && cat cmdline_container_malformed_extra.log && grep -Fq "Invalid outer list wrapper: [1:3],4]" cmdline_container_malformed_extra.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_extra.log

# Command-line registration print control — compile once, run startup modes fresh
test_cmdline_print_control:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_print_control -Mdir=csrc_cmdline_print_control test_cmdline_print_control.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=runtime > cmdline_print_runtime.log 2>&1 || { cat cmdline_print_runtime.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_print_runtime.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=runtime" cmdline_print_runtime.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-default > cmdline_print_startup_default.log 2>&1 || { cat cmdline_print_startup_default.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_print_startup_default.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-default" cmdline_print_startup_default.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-limit +aip_cmdline.max_prints=2 > cmdline_print_startup_limit.log 2>&1 || { cat cmdline_print_startup_limit.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_print_startup_limit.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-limit" cmdline_print_startup_limit.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-normalized +aip_cmdline.max_prints=-2 > cmdline_print_startup_normalized.log 2>&1 || { cat cmdline_print_startup_normalized.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_print_startup_normalized.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-normalized" cmdline_print_startup_normalized.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-disabled +aip_cmdline.print_enable=0 +startup.repeated=77 > cmdline_print_startup_disabled.log 2>&1 || { cat cmdline_print_startup_disabled.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_print_startup_disabled.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-disabled" cmdline_print_startup_disabled.log

# Runtime .so command-plugin test — requires VCS + gcc
test_soload:
	cd $(TEST_PLUGIN_DIR) && gcc -fPIC -shared hello_plugin.c -I../../include -o ../hello.so
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) +define+AIP_ENABLE_SOLOAD \
	    -o simv_soload \
	    -Mdir=csrc_soload \
    -CFLAGS -I$(AIP_INCLUDE_DIR) -LDFLAGS -ldl \
	    test_soload.sv ../../src/c/runtime/aip_soload.c
	cd $(TEST_SV_DIR) && ./simv_soload -ucli -do ../tcl/test_soload.tcl

# Command stall-watchdog test — requires VCS on PATH
test_tcl_watchdog:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_watchdog \
	    -Mdir=csrc_watchdog \
	    test_tcl_watchdog.sv
	cd $(TEST_SV_DIR) && ./simv_watchdog -ucli -do ../tcl/test_tcl_watchdog.tcl > tcl_watchdog.log 2>&1 \
	    || { cat tcl_watchdog.log; exit 1; }
	cd $(TEST_SV_DIR) && cat tcl_watchdog.log \
	    && grep -Fxq "TCL_WATCHDOG_PASS" tcl_watchdog.log \
	    && ! grep -Fq 'invalid command name "hang"' tcl_watchdog.log

# Unified SystemVerilog package + UCLI visibility regression
test_core_package:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_core_package \
	    -Mdir=csrc_core_package \
	    test_core_package.sv ../../src/c/runtime/sv_socket_dpi.c
	cd $(TEST_SV_DIR) && ./simv_core_package -ucli -do ../tcl/test_core_package.tcl > core_package.log 2>&1 \
	    || { cat core_package.log; exit 1; }
	cd $(TEST_SV_DIR) && cat core_package.log && grep -q CORE_PACKAGE_SV_PASS core_package.log && grep -q CORE_PACKAGE_UCLI_PASS core_package.log

# Stateful components must not be included before the canonical package entry
test_core_package_preinclude:
	cd $(TEST_SV_DIR) && if vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    -top test_core_package_preinclude \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_core_package_preinclude \
	    -Mdir=csrc_core_package_preinclude \
	    test_core_package_preinclude.sv ../../src/c/runtime/sv_socket_dpi.c \
	    > core_package_preinclude.log 2>&1; then \
	        cat core_package_preinclude.log; \
	        echo "expected preinclude-order compilation to fail"; \
	        exit 1; \
	    fi
	cd $(TEST_SV_DIR) && cat core_package_preinclude.log && grep -q AIP_CORE_PKG_PREINCLUDE_ERROR core_package_preinclude.log
	@echo CORE_PACKAGE_PREINCLUDE_REJECT_PASS

# CPU bridge regression through the unified include entry point
test_cpu_bridge:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    $(AIP_TEST_INCDIRS) \
	    -o simv_cpu_bridge \
	    -Mdir=csrc_cpu_bridge \
	    test_cpu_bridge.sv ../../src/c/runtime/sv_socket_dpi.c
	cd $(TEST_SV_DIR) && ./simv_cpu_bridge > cpu_bridge.log 2>&1 \
	    || { cat cpu_bridge.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cpu_bridge.log && grep -q CPU_BRIDGE_PASS cpu_bridge.log

# Strict cseq/creg arbitration regression using a fake UVM bus sequencer.
test_cseq_arbitration:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_cseq_arbitration -Mdir=csrc_cseq_arbitration \
	    test_cseq_arbitration.sv
	cd $(TEST_SV_DIR) && ./simv_cseq_arbitration -no_save > cseq_arbitration.log 2>&1 \
	    || { cat cseq_arbitration.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cseq_arbitration.log && grep -Fq CSEQ_ARBITRATION_PASS cseq_arbitration.log \
	    && ! grep -Fq 'SEQFINERR' cseq_arbitration.log

# TCP C bridge regression: valid -> unknown -> valid.  SRC_SOCKET must turn
# unknown commands into an ERROR reply without terminating the simulation.
# 默认未监听、显式 Tcl 启动及完整真实客户端协议。
test_c_bridge_socket:
	bash tests/socket/run_explicit.sh ordinary

# 同一 binary 创建未监听快照，再由新进程恢复后首次显式监听。
.PHONY: test_c_bridge_checkpoint
test_c_bridge_checkpoint:
	bash tests/socket/run_explicit.sh checkpoint

# Controlled DUT force/deposit/get/release/readmem commands through the aip_cmd registry.
test_dut_control:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_dut_control -Mdir=csrc_dut_control test_dut_control.sv
	cd $(TEST_SV_DIR) && ./simv_dut_control -no_save > dut_control.log 2>&1 \
	    || { cat dut_control.log; exit 1; }
	cd $(TEST_SV_DIR) && cat dut_control.log && grep -Fq DUT_CONTROL_PASS dut_control.log

# Delimiter byte-literal regression for aip_str::split / aip_cmd::get_arg.
test_str_delim:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_str_delim -Mdir=csrc_str_delim test_str_delim.sv
	cd $(TEST_SV_DIR) && ./simv_str_delim -no_save > str_delim.log 2>&1 \
	    || { cat str_delim.log; exit 1; }
	cd $(TEST_SV_DIR) && cat str_delim.log && grep -Fq STR_DELIM_PASS str_delim.log

# String-input command macros must forward the wrapped task's status/result.
test_cmd_str_result:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_cmd_str_result -Mdir=csrc_cmd_str_result test_cmd_str_result.sv
	cd $(TEST_SV_DIR) && ./simv_cmd_str_result -no_save > cmd_str_result.log 2>&1 \
	    || { cat cmd_str_result.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmd_str_result.log && grep -Fq CMD_STR_RESULT_PASS cmd_str_result.log

# 单次结果上下文定向验证：正常组与故意fatal的边界组分别运行。
# 负例必须报告精确上下文错误，不接受主机timeout、崩溃或测试自己的兜底fatal。
test_cmd_result_context:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_cmd_result_context -Mdir=csrc_cmd_result_context test_cmd_result_context.sv
	cd $(TEST_SV_DIR) && timeout --kill-after=10s 90s ./simv_cmd_result_context -no_save -exitstatus \
	    > cmd_result_context.log 2>&1 || { cat cmd_result_context.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmd_result_context.log \
	    && grep -Eq '^CMD_RESULT_CONTEXT_PASS checks=[0-9]+$$' cmd_result_context.log \
	    && ! grep -Eq '^CMD_RESULT_CONTEXT_CHECK_FAIL|^Error-|^Fatal:|^UVM_(ERROR|FATAL)' cmd_result_context.log
	cd $(TEST_SV_DIR) && set -e; \
	    for context_case in no_context stale_context killed_context direct_nested direct_reentrant; do \
	        context_log="cmd_result_context_$${context_case}.log"; \
	        context_rc=0; \
	        timeout --kill-after=10s 90s ./simv_cmd_result_context -no_save -exitstatus \
	            +context_negative=$$context_case > $$context_log 2>&1 || context_rc=$$?; \
	        cat $$context_log; \
	        case $$context_rc in 1|3) ;; *) echo "unexpected context-negative exit=$$context_rc"; exit 1;; esac; \
	        grep -Fxq "CMD_RESULT_CONTEXT_NEGATIVE case=$$context_case" $$context_log; \
	        case $$context_case in \
	            no_context) context_message='No current command context';; \
	            stale_context|killed_context) context_message='Cannot write an inactive command result context';; \
	            direct_nested) context_message='Nested direct cmd_exec';; \
	            direct_reentrant) context_message='is busy or reentrant';; \
	        esac; \
	        grep -Fq "$$context_message" $$context_log; \
	        test "$$(grep -Fc 'AIP_CMD[result]' $$context_log)" -eq 1; \
	        if grep -Eq 'EXPECTED_CONTEXT_FATAL_MISSING|UNKNOWN_CONTEXT_NEGATIVE|^Error-' $$context_log; then exit 1; fi; \
	        echo "CMD_RESULT_CONTEXT_NEGATIVE_PASS case=$$context_case"; \
	    done

# 旧SV入口兼容门禁；不以仿真退出码代替实际断言，任何失败必须阻止CI通过。
test_cmd_compat:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+r+w+f -full64 -lca $(AIP_TEST_INCDIRS) \
	    -o simv_cmd_compat -Mdir=csrc_cmd_compat test_cmd_compat.sv
	cd $(TEST_SV_DIR) && timeout --kill-after=10s 90s ./simv_cmd_compat -no_save -exitstatus \
	    > cmd_compat.log 2>&1 || { cat cmd_compat.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmd_compat.log \
	    && grep -Eq '^CMD_COMPAT_PASS checks=[0-9]+$$' cmd_compat.log \
	    && ! grep -Eq '^CMD_COMPAT_CHECK_FAIL|^CMD_COMPAT_FAILED|^Error-|^Fatal[-:]|^UVM_(ERROR|FATAL)' cmd_compat.log
	cd $(TEST_SV_DIR) && set -e; \
	    for compat_case in facade_busy compat_no_context; do \
	        compat_log="cmd_compat_$${compat_case}.log"; \
	        compat_rc=0; \
	        timeout --kill-after=10s 90s ./simv_cmd_compat -no_save -exitstatus +compat_negative=$$compat_case \
	            > $$compat_log 2>&1 || compat_rc=$$?; \
	        cat $$compat_log; \
	        case $$compat_rc in 1|3) ;; *) echo "unexpected compatibility-negative exit=$$compat_rc"; exit 1;; esac; \
	        grep -Fxq "CMD_COMPAT_NEGATIVE case=$$compat_case" $$compat_log; \
	        case $$compat_case in \
	            facade_busy) compat_message='Direct compatibility call cannot acquire the legacy result slot; use exec_result';; \
	            compat_no_context) compat_message='No current compatibility result context; enter begin_compat_result_scope before calling a legacy facade';; \
	        esac; \
	        grep -Fq "AIP_CMD[result] $$compat_message" $$compat_log; \
	        test "$$(grep -Fc 'AIP_CMD[result]' $$compat_log)" -eq 1; \
	        if grep -Eq 'EXPECTED_COMPAT_FATAL_MISSING|UNKNOWN_COMPAT_NEGATIVE|CMD_COMPAT_NEGATIVE_SETUP_FAILED|^Error-' $$compat_log; then exit 1; fi; \
	        echo "CMD_COMPAT_NEGATIVE_PASS case=$$compat_case"; \
	    done

# Wide-integer literal parsing and random draws (bit[127:0] / bit[255:0])
test_cmdline_wide:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_wide -Mdir=csrc_cmdline_wide test_cmdline_wide.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_wide \
	    "+l64=0x8000_0000_0000" "+u64=0xFFFF_FFFF_FFFF_FFFF" \
	    "+u128=340282366920938463463374607431768211455" \
	    "+u256=256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
	    "+u256_pat=0x0123456700000000000000000000000000000000000000000000000089abcdef" \
	    "+u8=8'hff" "+i32=-0x10" "+iu32=0xFFFF_FFFF" \
	    "+r128=[0x1_0000_0000_0000_0000:0x1_0000_0000_0000_00FF]" "+rl=[0x1_0000_0000:0x1_0000_00FF]" \
	    "+rr=rand" \
	    > cmdline_wide.log 2>&1 || { cat cmdline_wide.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_wide.log && grep -q CMDLINE_WIDE_PASS cmdline_wide.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_wide +AIP_WIDE_ERRCASE=overflow32 "+e_i32=0x1_0000_0000" > cmdline_wide_overflow32.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_wide_overflow32.log && grep -Fq "value 0x1_0000_0000 exceeds 32-bit int" cmdline_wide_overflow32.log && ! grep -q WIDE_ACCEPTED cmdline_wide_overflow32.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_wide +AIP_WIDE_ERRCASE=width "+e_i32=64'h1" > cmdline_wide_width.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_wide_width.log && grep -Fq "explicit width in 64'h1 exceeds 32-bit int" cmdline_wide_width.log && ! grep -q WIDE_ACCEPTED cmdline_wide_width.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_wide +AIP_WIDE_ERRCASE=vecoverflow "+e_u256=0x10000000000000000000000000000000000000000000000000000000000000000" > cmdline_wide_vecoverflow.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_wide_vecoverflow.log && grep -Fq "exceeds 256-bit" cmdline_wide_vecoverflow.log && ! grep -q WIDE_ACCEPTED cmdline_wide_vecoverflow.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_wide +AIP_WIDE_ERRCASE=randeach "+e_i32={rand:=5}" > cmdline_wide_randeach.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_wide_randeach.log && grep -Fq "rand:=w not allowed; use rand:/w" cmdline_wide_randeach.log && ! grep -q WIDE_ACCEPTED cmdline_wide_randeach.log

# Array random modes: .size/.each/.unique/.sort, seq:/perm:, dynamic + static
ARR_RANDOM_ARGS := "+d_list=1,2,3" "+d_one=[1:10]" "+d_idx[2]=7" "+s_list=[4,3,2,1]" "+s_part=5,6"
ARR_RANDOM_ARGS += "+d_each.size=8" "+d_each.each=[1:10]" "+d_rsize.size=[4:16]" "+d_rsize.each=[100:200]" \
    "+d_ovr.size=4" "+d_ovr.each=[1:10]" "+d_ovr[0]=99" "+d_part2.size=4" "+d_part2=5,6" "+d_part2.each=[100:200]" \
    "+s_each.each=[1:10]" "+s_ovr.each=[1:10]" "+s_ovr[3]=42"
ARR_RANDOM_ARGS += "+d_seq=seq:0x1000:0x1F00:0x100" "+d_perm=perm:0:7" "+s_seq=seq:0:3" "+s_perm=perm:0:3"
ARR_RANDOM_ARGS += "+d_uni.size=8" "+d_uni.each=[0:9]" "+d_uni.unique=1" \
    "+d_unifix.size=4" "+d_unifix=3" "+d_unifix.each=[0:4]" "+d_unifix.unique=1" \
    "+s_uni.each=[0:3]" "+s_uni.unique=1" "+d_suni.size=3" "+d_suni.each=a,b,c" "+d_suni.unique=1"
ARR_RANDOM_ARGS += "+d_sort.size=6" "+d_sort.each=[1:100]" "+d_sort.sort=asc" "+d_sort[0]=1000" \
    "+d_sortd=3,1,2" "+d_sortd.sort=desc" "+s_sort.each=[1:100]" "+s_sort.sort=desc"
ARR_RANDOM_ARGS += "+d_sseq=seq:one,two" "+d_ssort=c,a,b" "+d_ssort.sort=asc"
test_cmdline_array_random:
	cd $(TEST_SV_DIR) && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca $(AIP_TEST_INCDIRS) -o simv_cmdline_array_random -Mdir=csrc_cmdline_array_random test_cmdline_array_random.sv
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random $(ARR_RANDOM_ARGS) > cmdline_array_random.log 2>&1 || { cat cmdline_array_random.log; exit 1; }
	cd $(TEST_SV_DIR) && cat cmdline_array_random.log && grep -q CMDLINE_ARRAY_RANDOM_PASS cmdline_array_random.log
	cd $(TEST_SV_DIR) && grep -Fq "array 'd_uni' (scope='') [8] each=[0:9] unique =" cmdline_array_random.log
	cd $(TEST_SV_DIR) && grep -Fq "array 's_sort' (scope='') [4] each=[1:100] sort=desc =" cmdline_array_random.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=static_size "+e_st.size=4" "+e_st=1,2,3,4" > cmdline_array_random_static_size.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_static_size.log && grep -Fq "e_st.size not allowed for static array (declared size 4)" cmdline_array_random_static_size.log && ! grep -q ARR_ACCEPTED cmdline_array_random_static_size.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=static_long "+e_st=1,2,3,4,5" > cmdline_array_random_static_long.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_static_long.log && grep -Fq "e_st overall list has 5 elements, static array holds 4" cmdline_array_random_static_long.log && ! grep -q ARR_ACCEPTED cmdline_array_random_static_long.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=size_lt_list "+e_dyn.size=2" "+e_dyn=1,2,3" > cmdline_array_random_size_lt_list.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_size_lt_list.log && grep -Fq "e_dyn overall list has 3 elements, .size is 2" cmdline_array_random_size_lt_list.log && ! grep -q ARR_ACCEPTED cmdline_array_random_size_lt_list.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=each_nosize "+e_dyn.each=[1:10]" > cmdline_array_random_each_nosize.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_each_nosize.log && grep -Fq "e_dyn.each given but size unknown" cmdline_array_random_each_nosize.log && ! grep -q ARR_ACCEPTED cmdline_array_random_each_nosize.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=seq_static_len "+e_st=seq:0:9" > cmdline_array_random_seq_static_len.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_seq_static_len.log && grep -Fq "e_st seq: expands to 10 elements, static array holds 4" cmdline_array_random_seq_static_len.log && ! grep -q ARR_ACCEPTED cmdline_array_random_seq_static_len.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=perm_static_len "+e_st=perm:0:1" > cmdline_array_random_perm_static_len.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_perm_static_len.log && grep -Fq "e_st perm: expands to 2 elements, static array holds 4" cmdline_array_random_perm_static_len.log && ! grep -q ARR_ACCEPTED cmdline_array_random_perm_static_len.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=seq_scalar "+e_i=seq:0:3" > cmdline_array_random_seq_scalar.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_seq_scalar.log && grep -Fq "seq:/perm: are array-only" cmdline_array_random_seq_scalar.log && ! grep -q ARR_ACCEPTED cmdline_array_random_seq_scalar.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=unique_short "+e_dyn.size=4" "+e_dyn.each=[0:2]" "+e_dyn.unique=1" > cmdline_array_random_unique_short.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_unique_short.log && grep -Fq "e_dyn.unique: only 3 candidates for 4 elements" cmdline_array_random_unique_short.log && ! grep -q ARR_ACCEPTED cmdline_array_random_unique_short.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=unique_dup "+e_dyn.size=4" "+e_dyn=1,1" "+e_dyn.each=[0:9]" "+e_dyn.unique=1" > cmdline_array_random_unique_dup.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_unique_dup.log && grep -Fq "e_dyn.unique: duplicate fixed value" cmdline_array_random_unique_dup.log && ! grep -q ARR_ACCEPTED cmdline_array_random_unique_dup.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=bad_sort "+e_dyn=1,2" "+e_dyn.sort=up" > cmdline_array_random_bad_sort.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_bad_sort.log && grep -Fq "e_dyn.sort must be asc or desc" cmdline_array_random_bad_sort.log && ! grep -q ARR_ACCEPTED cmdline_array_random_bad_sort.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=size_negative "+e_dyn.size=-2" > cmdline_array_random_size_negative.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_size_negative.log && grep -Fq "e_dyn.size must be >= 0" cmdline_array_random_size_negative.log && ! grep -q ARR_ACCEPTED cmdline_array_random_size_negative.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random +AIP_ARR_ERRCASE=bad_unique "+e_dyn=1,2" "+e_dyn.unique=yes" > cmdline_array_random_bad_unique.log 2>&1; true
	cd $(TEST_SV_DIR) && cat cmdline_array_random_bad_unique.log && grep -Fq "e_dyn.unique must be 0 or 1" cmdline_array_random_bad_unique.log && ! grep -q ARR_ACCEPTED cmdline_array_random_bad_unique.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random $(ARR_RANDOM_ARGS) +ntb_random_seed=7 2>&1 | grep ARRAY_VALUES > cmdline_array_random_seed_a.log
	cd $(TEST_SV_DIR) && ./simv_cmdline_array_random $(ARR_RANDOM_ARGS) +ntb_random_seed=7 2>&1 | grep ARRAY_VALUES > cmdline_array_random_seed_b.log
	cd $(TEST_SV_DIR) && test -s cmdline_array_random_seed_a.log
	cd $(TEST_SV_DIR) && cmp cmdline_array_random_seed_a.log cmdline_array_random_seed_b.log

clean:
	rm -rf $(TEST_SV_DIR)/simv_set_param_benchmark $(TEST_SV_DIR)/simv_set_param_benchmark.daidir $(TEST_SV_DIR)/csrc_set_param_benchmark
	rm -rf $(TEST_SV_DIR)/simv_set_param_expressions $(TEST_SV_DIR)/simv_set_param_expressions.daidir $(TEST_SV_DIR)/csrc_set_param_expressions
	rm -rf $(TEST_SV_DIR)/simv_set_param_tcl $(TEST_SV_DIR)/simv_set_param_tcl.daidir $(TEST_SV_DIR)/csrc_set_param_tcl
	rm -f $(TEST_SV_DIR)/set_param_*.log
	rm -rf $(TEST_SV_DIR)/simv_reg_wide $(TEST_SV_DIR)/simv_reg_wide.daidir $(TEST_SV_DIR)/csrc_reg_wide $(TEST_SV_DIR)/reg_wide.log
	rm -rf $(TEST_SV_DIR)/simv_end_checker $(TEST_SV_DIR)/simv_end_checker.daidir $(TEST_SV_DIR)/csrc_end_checker
	rm -f $(TEST_SV_DIR)/end_checker_*.log $(TEST_SV_DIR)/ucli.key $(TEST_SV_DIR)/vc_hdrs.h
	rm -rf $(TEST_SV_DIR)/simv_reg_seq $(TEST_SV_DIR)/simv_reg_seq.daidir $(TEST_SV_DIR)/csrc_reg_seq
	rm -rf $(TEST_SV_DIR)/simv_user_seq $(TEST_SV_DIR)/simv_user_seq.daidir $(TEST_SV_DIR)/csrc_user_seq $(TEST_SV_DIR)/user_seq.log
	rm -rf $(TEST_SV_DIR)/simv_aip_bind_seq $(TEST_SV_DIR)/simv_aip_bind_seq.daidir $(TEST_SV_DIR)/csrc_aip_bind_seq
	rm -f $(TEST_SV_DIR)/aip_bind_seq_*.log
	rm -rf $(TEST_SV_DIR)/simv_cmd_wait $(TEST_SV_DIR)/simv_cmd_wait.daidir $(TEST_SV_DIR)/csrc_cmd_wait
	rm -f $(TEST_SV_DIR)/cmd_wait.log
	rm -rf $(TEST_SV_DIR)/simv_cmd_ack_progress $(TEST_SV_DIR)/simv_cmd_ack_progress.daidir $(TEST_SV_DIR)/csrc_cmd_ack_progress
	rm -f $(TEST_SV_DIR)/cmd_ack_progress.log
	rm -rf $(TEST_SV_DIR)/simv_cmd_result_context $(TEST_SV_DIR)/simv_cmd_result_context.daidir $(TEST_SV_DIR)/csrc_cmd_result_context
	rm -f $(TEST_SV_DIR)/cmd_result_context*.log
	rm -rf $(TEST_SV_DIR)/simv_cmd_compat $(TEST_SV_DIR)/simv_cmd_compat.daidir $(TEST_SV_DIR)/csrc_cmd_compat
	rm -f $(TEST_SV_DIR)/cmd_compat*.log $(TEST_SV_DIR)/cmd_compat_rom.hex
	rm -rf $(TEST_SV_DIR)/simv_soload $(TEST_SV_DIR)/simv_soload.daidir $(TEST_SV_DIR)/csrc_soload $(TEST_DIR)/hello.so
	rm -f $(TEST_SV_DIR)/tcl_watchdog.log $(TEST_TCL_DIR)/checkpoint_wait_tcl.log $(TEST_SV_DIR)/checkpoint_wait_vcs.log
	rm -rf $(TEST_SV_DIR)/simv_checkpoint_wait $(TEST_SV_DIR)/simv_checkpoint_wait.daidir $(TEST_SV_DIR)/csrc_checkpoint_wait $(TEST_SV_DIR)/checkpoint_wait_artifacts
	rm -rf $(TEST_SV_DIR)/simv_checkpoint_background $(TEST_SV_DIR)/simv_checkpoint_background.daidir $(TEST_SV_DIR)/csrc_checkpoint_background $(TEST_SV_DIR)/checkpoint_background_artifacts
	rm -f $(TEST_SV_DIR)/checkpoint_background_build.log $(TEST_SV_DIR)/checkpoint_background_generate.log $(TEST_SV_DIR)/checkpoint_background_restore.log $(TEST_SV_DIR)/checkpoint_background_generate.summary $(TEST_SV_DIR)/checkpoint_background_restore.summary
	rm -rf $(TEST_SV_DIR)/simv_ckpt_restore $(TEST_SV_DIR)/simv_ckpt_restore.daidir $(TEST_SV_DIR)/csrc_ckpt_restore $(TEST_SV_DIR)/ckpt_restore_artifacts $(TEST_SV_DIR)/ckpt_gen.log $(TEST_SV_DIR)/ckpt_restore.log $(TEST_SV_DIR)/ckpt_dut_get.base $(TEST_SV_DIR)/ckpt_dut_get.restored
	rm -rf $(TEST_SV_DIR)/simv_core_package $(TEST_SV_DIR)/simv_core_package.daidir $(TEST_SV_DIR)/csrc_core_package $(TEST_SV_DIR)/core_package.log
	rm -rf $(TEST_SV_DIR)/simv_core_package_preinclude $(TEST_SV_DIR)/simv_core_package_preinclude.daidir $(TEST_SV_DIR)/csrc_core_package_preinclude $(TEST_SV_DIR)/core_package_preinclude.log
	rm -rf $(TEST_SV_DIR)/simv_cpu_bridge $(TEST_SV_DIR)/simv_cpu_bridge.daidir $(TEST_SV_DIR)/csrc_cpu_bridge $(TEST_SV_DIR)/cpu_bridge.log
	rm -rf $(TEST_SV_DIR)/simv_cseq_arbitration $(TEST_SV_DIR)/simv_cseq_arbitration.daidir $(TEST_SV_DIR)/csrc_cseq_arbitration $(TEST_SV_DIR)/cseq_arbitration.log
	rm -rf $(TEST_SV_DIR)/simv_c_bridge_socket $(TEST_SV_DIR)/simv_c_bridge_socket.daidir $(TEST_SV_DIR)/csrc_c_bridge_socket $(TEST_SV_DIR)/c_bridge_socket.log $(TEST_SV_DIR)/c_bridge_socket.rc
	rm -rf $(TEST_SV_DIR)/simv_dut_control $(TEST_SV_DIR)/simv_dut_control.daidir $(TEST_SV_DIR)/csrc_dut_control $(TEST_SV_DIR)/dut_control.log
	rm -f $(TEST_SV_DIR)/dut_control.hex $(TEST_SV_DIR)/dut_control.bin $(TEST_SV_DIR)/dut_control_bad.hex $(TEST_SV_DIR)/dut_control_width.hex $(TEST_SV_DIR)/dut_control_width.bin $(TEST_SV_DIR)/dut_control_overflow.hex
	rm -rf $(TEST_SV_DIR)/simv_str_delim $(TEST_SV_DIR)/simv_str_delim.daidir $(TEST_SV_DIR)/csrc_str_delim $(TEST_SV_DIR)/str_delim.log
	rm -rf $(TEST_SV_DIR)/simv_cmd_str_result $(TEST_SV_DIR)/simv_cmd_str_result.daidir $(TEST_SV_DIR)/csrc_cmd_str_result $(TEST_SV_DIR)/cmd_str_result.log
	rm -rf $(TEST_SV_DIR)/simv_parse_uint_arg $(TEST_SV_DIR)/simv_parse_uint_arg.daidir $(TEST_SV_DIR)/csrc_parse_uint_arg $(TEST_SV_DIR)/parse_uint_arg.log
	rm -rf $(TEST_SV_DIR)/simv_aip_flags $(TEST_SV_DIR)/simv_aip_flags.daidir $(TEST_SV_DIR)/csrc_aip_flags $(TEST_SV_DIR)/aip_flags*.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_negative $(TEST_SV_DIR)/simv_cmdline_negative.daidir $(TEST_SV_DIR)/csrc_cmdline_negative $(TEST_SV_DIR)/cmdline_negative.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_zero_weight $(TEST_SV_DIR)/simv_cmdline_zero_weight.daidir $(TEST_SV_DIR)/csrc_cmdline_zero_weight $(TEST_SV_DIR)/cmdline_zero_weight*.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_diagnostics $(TEST_SV_DIR)/simv_cmdline_diagnostics.daidir $(TEST_SV_DIR)/csrc_cmdline_diagnostics $(TEST_SV_DIR)/cmdline_diagnostics*.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_split_standalone $(TEST_SV_DIR)/simv_cmdline_split_standalone.daidir $(TEST_SV_DIR)/csrc_cmdline_split_standalone
	rm -rf $(TEST_SV_DIR)/simv_cmdline_split_package $(TEST_SV_DIR)/simv_cmdline_split_package.daidir $(TEST_SV_DIR)/csrc_cmdline_split_package
	rm -rf $(TEST_SV_DIR)/simv_cmdline_split_internal_class $(TEST_SV_DIR)/simv_cmdline_split_internal_class.daidir $(TEST_SV_DIR)/csrc_cmdline_split_internal_class
	rm -rf $(TEST_SV_DIR)/simv_cmdline_split_internal_macro $(TEST_SV_DIR)/simv_cmdline_split_internal_macro.daidir $(TEST_SV_DIR)/csrc_cmdline_split_internal_macro
	rm -rf $(TEST_SV_DIR)/simv_cmdline_split_legacy_selftest $(TEST_SV_DIR)/simv_cmdline_split_legacy_selftest.daidir $(TEST_SV_DIR)/csrc_cmdline_split_legacy_selftest
	rm -f $(TEST_SV_DIR)/cmdline_split*.log $(TEST_SV_DIR)/cmdline_split*.trace
	rm -rf $(TEST_SV_DIR)/simv_cmdline_container $(TEST_SV_DIR)/simv_cmdline_container.daidir $(TEST_SV_DIR)/csrc_cmdline_container $(TEST_SV_DIR)/cmdline_container.log $(TEST_SV_DIR)/cmdline_container_malformed_empty.log $(TEST_SV_DIR)/cmdline_container_malformed_trailing.log $(TEST_SV_DIR)/cmdline_container_malformed_missing.log $(TEST_SV_DIR)/cmdline_container_malformed_extra.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_print_control $(TEST_SV_DIR)/simv_cmdline_print_control.daidir $(TEST_SV_DIR)/csrc_cmdline_print_control $(TEST_SV_DIR)/cmdline_print_runtime.log $(TEST_SV_DIR)/cmdline_print_startup_default.log $(TEST_SV_DIR)/cmdline_print_startup_limit.log $(TEST_SV_DIR)/cmdline_print_startup_normalized.log $(TEST_SV_DIR)/cmdline_print_startup_disabled.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_strict_queue $(TEST_SV_DIR)/simv_cmdline_strict_queue.daidir $(TEST_SV_DIR)/csrc_cmdline_strict_queue $(TEST_SV_DIR)/cmdline_strict_queue*.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_wide $(TEST_SV_DIR)/simv_cmdline_wide.daidir $(TEST_SV_DIR)/csrc_cmdline_wide $(TEST_SV_DIR)/cmdline_wide*.log
	rm -rf $(TEST_SV_DIR)/simv_cmdline_array_random $(TEST_SV_DIR)/simv_cmdline_array_random.daidir $(TEST_SV_DIR)/csrc_cmdline_array_random $(TEST_SV_DIR)/cmdline_array_random*.log
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name "*.egg-info" -exec rm -rf {} +

.PHONY: ci ci-host ci-sv ci-regress

ci: ci-host ci-sv ci-regress

ci-host:
	$(MAKE) -C firmware/tests

# aip_cpu_mem regression (legacy RAM/ROM + RAM72/packed40)
ci-sv:
	$(MAKE) -C $(TEST_SV_DIR)/cpu_mem clean && $(MAKE) -C $(TEST_SV_DIR)/cpu_mem run
	$(MAKE) -C $(TEST_SV_DIR)/cpu_mem run72

ci-regress:
	$(MAKE) test_end_checker_registry
	$(MAKE) ci-cmd
	$(MAKE) test_live_resume
	$(MAKE) test_paused_injection

# 命令调度变更必须同时经过旧入口、逐调用结果、桥接、sequence和在途快照。
# 保留各单项目标便于本地定向验证；make ci也会经ci-regress运行这组门禁。
ci-cmd:
	$(MAKE) test_inject_queue
	$(MAKE) test_cmd_str_result test_cmd_result_context test_cmd_compat test_cmd_wait test_cmd_ack_progress
	$(MAKE) test_dut_control test_c_bridge_socket test_user_seq test_tcl_watchdog test_cseq_arbitration test_seq_registry_active
	$(MAKE) test_aip_bind_seq
	$(MAKE) test_checkpoint_background
