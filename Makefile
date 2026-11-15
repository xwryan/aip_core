# Spec-driven RAL gen + simulation
RDL        := example/demo_chip.rdl
GEN_DIR    := gen
RAL_PKG    := demo_chip_ral_pkg::demo_chip
VIEW       ?= RTL
PLUGIN_DIR := tools/peakrdl-aip-attach
# Per-case wall-clock guard for the checker matrix; override on slower hosts.
CHECKER_CASE_TIMEOUT ?= 60s

.PHONY: all install gen test_spec_driven test_reg_seq test_soload test_tcl_watchdog test_checkpoint_wait_tcl test_checkpoint_wait_vcs test_end_checker_registry test_cmdline_negative test_cmdline_container_syntax test_cmdline_print_control test_core_package test_core_package_preinclude test_cpu_bridge test_unit clean clean-gen

all: gen

install:
	pip install -e $(PLUGIN_DIR)/

gen: $(GEN_DIR)/.stamp

$(GEN_DIR)/.stamp: $(RDL) example/aip_udp.rdl
	mkdir -p $(GEN_DIR)
	peakrdl uvm        $(RDL) -o $(GEN_DIR)/demo_chip_ral_pkg.sv -I example
	peakrdl aip-attach $(RDL) -o $(GEN_DIR)/demo_chip_attach.sv  -I example \
	        --view $(VIEW) --ral-pkg $(RAL_PKG)
	touch $@

test_unit:
	cd $(PLUGIN_DIR) && pytest -v

test_checkpoint_wait_tcl:
	@tclsh test/test_checkpoint_wait.tcl > test/checkpoint_wait_tcl.log 2>&1 \
	    || { cat test/checkpoint_wait_tcl.log; exit 1; }
	@cat test/checkpoint_wait_tcl.log
	@grep -Fxq CHECKPOINT_WAIT_TCL_PASS test/checkpoint_wait_tcl.log

test_checkpoint_wait_vcs: test/test_checkpoint_wait.sv test/test_checkpoint_wait_vcs.tcl
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca +incdir+.. \
	    -o simv_checkpoint_wait -Mdir=csrc_checkpoint_wait \
	    test_checkpoint_wait.sv
	cd test && ./simv_checkpoint_wait -ucli -do test_checkpoint_wait_vcs.tcl \
	    > checkpoint_wait_vcs.log 2>&1 \
	    || { cat checkpoint_wait_vcs.log; exit 1; }
	cd test && cat checkpoint_wait_vcs.log \
	    && test "$$(grep -Fxc CHECKPOINT_WAIT_VCS_PASS checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Ec '^\[AIP_STATE_CKPT\] STATE_(ONE|TWO|THREE|FOUR) ' checkpoint_wait_vcs.log)" -eq 4 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_ONE ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_TWO ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_THREE ' checkpoint_wait_vcs.log)" -eq 1 \
	    && test "$$(grep -Fc '[AIP_STATE_CKPT] STATE_FOUR ' checkpoint_wait_vcs.log)" -eq 1 \
	    && ! grep -Eq '^FAIL ' checkpoint_wait_vcs.log

test_end_checker_registry:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
		-debug_access+all -full64 -lca +incdir+.. \
		-o simv_end_checker -Mdir=csrc_end_checker \
		test_end_checker_registry.sv
	cd test && set -e; \
		for case_name in legacy direct_legacy idle_compat multi legacy_named same_handle \
			failure failure_nonstrict \
			nonstrict_timeout strict_timeout multi_timeout strict_missing \
			watchdog_end_test watchdog_fork_end_test watchdog_end_test_drain \
			watchdog_fork_end_test_drain watchdog_fork_end_test_idle \
			invalid remove frozen; do \
			log="end_checker_$${case_name}.log"; \
			if ! timeout $(CHECKER_CASE_TIMEOUT) ./simv_end_checker \
				-ucli -do test_end_checker_registry.tcl \
				+CHECKER_CASE=$${case_name} +UVM_NO_RELNOTES > $$log 2>&1; then \
				cat $$log; \
				exit 1; \
			fi; \
			cat $$log; \
			grep -Fq "CHECKER_REGISTRY_PASS case=$${case_name}" $$log; \
			grep -Fq "CHECKER_REGISTRY_REPORT_PASS case=$${case_name}" $$log; \
		done

# Full simv run — requires VCS on PATH
test_spec_driven: gen
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. +incdir+../$(GEN_DIR) \
	    -o simv_spec_driven \
	    -Mdir=csrc_spec_driven \
	    test_spec_driven.sv dut_demo.sv
	cd test && ./simv_spec_driven

# Register R/W seq macro test — requires VCS on PATH
test_reg_seq:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. \
	    -o simv_reg_seq \
	    -Mdir=csrc_reg_seq \
	    test_reg_seq.sv
	cd test && ./simv_reg_seq -ucli -do test_reg_seq.tcl

# Signed integer command-line parsing regression — requires VCS on PATH
test_cmdline_negative:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca +incdir+.. -o simv_cmdline_negative -Mdir=csrc_cmdline_negative test_cmdline_negative.sv
	cd test && ./simv_cmdline_negative "+neg_dec=-10" "+neg_hex=-0x10" "+neg_sv=-8'd10" "+plus_dec=+10" "+neg_range=[-10:-1]" "+cross_range=[-2:2]" "+neg_list=-3,-2,-1" "+neg_inc=inc:-10:10:2" "+neg_dec_seq=dec:10:-10:2" "+neg_weight={-3:=10,[-2:-1]:=20}" "+neg_bits=-1" "+positive=0x2a" > cmdline_negative.log 2>&1 || { cat cmdline_negative.log; exit 1; }
	cd test && cat cmdline_negative.log && grep -q CMDLINE_NEGATIVE_PASS cmdline_negative.log

# Integer list/container syntax regression — requires VCS on PATH
test_cmdline_container_syntax:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca +incdir+.. -o simv_cmdline_container -Mdir=csrc_cmdline_container test_cmdline_container_syntax.sv
	cd test && ./simv_cmdline_container \
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
	cd test && cat cmdline_container.log && grep -q CMDLINE_CONTAINER_PASS cmdline_container.log && ! grep -q MALFORMED_ACCEPTED cmdline_container.log
	cd test && ./simv_cmdline_container +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1,,2,3]" > cmdline_container_malformed_empty.log 2>&1
	cd test && cat cmdline_container_malformed_empty.log && grep -Fq "Invalid outer list wrapper: [1,,2,3]" cmdline_container_malformed_empty.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_empty.log
	cd test && ./simv_cmdline_container +AIP_CONTAINER_MALFORMED +ntb_random_seed=9 "+malformed_pick=[1,[2:3],]" > cmdline_container_malformed_trailing.log 2>&1
	cd test && cat cmdline_container_malformed_trailing.log && grep -Fq "Invalid outer list wrapper: [1,[2:3],]" cmdline_container_malformed_trailing.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_trailing.log
	cd test && ./simv_cmdline_container +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1,2,3" > cmdline_container_malformed_missing.log 2>&1
	cd test && cat cmdline_container_malformed_missing.log && grep -Fq "Invalid outer list wrapper: [1,2,3" cmdline_container_malformed_missing.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_missing.log
	cd test && ./simv_cmdline_container +AIP_CONTAINER_MALFORMED +ntb_random_seed=1 "+malformed_pick=[1:3],4]" > cmdline_container_malformed_extra.log 2>&1
	cd test && cat cmdline_container_malformed_extra.log && grep -Fq "Invalid outer list wrapper: [1:3],4]" cmdline_container_malformed_extra.log && ! grep -q MALFORMED_ACCEPTED cmdline_container_malformed_extra.log

# Command-line registration print control — compile once, run startup modes fresh
test_cmdline_print_control:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 -lca +incdir+.. -o simv_cmdline_print_control -Mdir=csrc_cmdline_print_control test_cmdline_print_control.sv
	cd test && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=runtime > cmdline_print_runtime.log 2>&1 || { cat cmdline_print_runtime.log; exit 1; }
	cd test && cat cmdline_print_runtime.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=runtime" cmdline_print_runtime.log
	cd test && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-default > cmdline_print_startup_default.log 2>&1 || { cat cmdline_print_startup_default.log; exit 1; }
	cd test && cat cmdline_print_startup_default.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-default" cmdline_print_startup_default.log
	cd test && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-limit +aip_cmdline.max_prints=2 > cmdline_print_startup_limit.log 2>&1 || { cat cmdline_print_startup_limit.log; exit 1; }
	cd test && cat cmdline_print_startup_limit.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-limit" cmdline_print_startup_limit.log
	cd test && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-normalized +aip_cmdline.max_prints=-2 > cmdline_print_startup_normalized.log 2>&1 || { cat cmdline_print_startup_normalized.log; exit 1; }
	cd test && cat cmdline_print_startup_normalized.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-normalized" cmdline_print_startup_normalized.log
	cd test && ./simv_cmdline_print_control +AIP_CMDLINE_PRINT_MODE=startup-disabled +aip_cmdline.print_enable=0 +startup.repeated=77 > cmdline_print_startup_disabled.log 2>&1 || { cat cmdline_print_startup_disabled.log; exit 1; }
	cd test && cat cmdline_print_startup_disabled.log && grep -Fq "CMDLINE_PRINT_CONTROL_PASS mode=startup-disabled" cmdline_print_startup_disabled.log

# Runtime .so command-plugin test — requires VCS + gcc
test_soload:
	cd test/plugins && gcc -fPIC -shared hello_plugin.c -I../.. -o ../hello.so
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. +define+AIP_ENABLE_SOLOAD \
	    -o simv_soload \
	    -Mdir=csrc_soload \
	    -CFLAGS -I.. -LDFLAGS -ldl \
	    test_soload.sv ../aip_soload.c
	cd test && ./simv_soload -ucli -do test_soload.tcl

# Command stall-watchdog test — requires VCS on PATH
test_tcl_watchdog:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. \
	    -o simv_watchdog \
	    -Mdir=csrc_watchdog \
	    test_tcl_watchdog.sv
	cd test && ./simv_watchdog -ucli -do test_tcl_watchdog.tcl > tcl_watchdog.log 2>&1 \
	    || { cat tcl_watchdog.log; exit 1; }
	cd test && cat tcl_watchdog.log \
	    && grep -Fxq "TCL_WATCHDOG_PASS" tcl_watchdog.log \
	    && ! grep -Fq 'invalid command name "hang"' tcl_watchdog.log

# Unified SystemVerilog package + UCLI visibility regression
test_core_package:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. \
	    -o simv_core_package \
	    -Mdir=csrc_core_package \
	    test_core_package.sv ../sv_socket_dpi.c
	cd test && ./simv_core_package -ucli -do test_core_package.tcl > core_package.log 2>&1 \
	    || { cat core_package.log; exit 1; }
	cd test && cat core_package.log && grep -q CORE_PACKAGE_SV_PASS core_package.log && grep -q CORE_PACKAGE_UCLI_PASS core_package.log

# Stateful components must not be included before the canonical package entry
test_core_package_preinclude:
	cd test && if vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    -top test_core_package_preinclude \
	    +incdir+.. \
	    -o simv_core_package_preinclude \
	    -Mdir=csrc_core_package_preinclude \
	    test_core_package_preinclude.sv ../sv_socket_dpi.c \
	    > core_package_preinclude.log 2>&1; then \
	        cat core_package_preinclude.log; \
	        echo "expected preinclude-order compilation to fail"; \
	        exit 1; \
	    fi
	cd test && cat core_package_preinclude.log && grep -q AIP_CORE_PKG_PREINCLUDE_ERROR core_package_preinclude.log
	@echo CORE_PACKAGE_PREINCLUDE_REJECT_PASS

# CPU bridge regression through the unified include entry point
test_cpu_bridge:
	cd test && vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps \
	    -debug_access+all -full64 -lca \
	    +incdir+.. \
	    -o simv_cpu_bridge \
	    -Mdir=csrc_cpu_bridge \
	    test_cpu_bridge.sv ../sv_socket_dpi.c
	cd test && ./simv_cpu_bridge > cpu_bridge.log 2>&1 \
	    || { cat cpu_bridge.log; exit 1; }
	cd test && cat cpu_bridge.log && grep -q CPU_BRIDGE_PASS cpu_bridge.log

clean-gen:
	rm -rf $(GEN_DIR)

clean: clean-gen
	rm -rf test/simv_end_checker test/simv_end_checker.daidir test/csrc_end_checker
	rm -f test/end_checker_*.log test/ucli.key test/vc_hdrs.h
	rm -rf test/simv_spec_driven test/simv_spec_driven.daidir test/csrc_spec_driven
	rm -rf test/simv_reg_seq test/simv_reg_seq.daidir test/csrc_reg_seq
	rm -rf test/simv_soload test/simv_soload.daidir test/csrc_soload test/hello.so
	rm -f test/tcl_watchdog.log test/checkpoint_wait_tcl.log test/checkpoint_wait_vcs.log
	rm -rf test/simv_checkpoint_wait test/simv_checkpoint_wait.daidir test/csrc_checkpoint_wait test/checkpoint_wait_artifacts
	rm -rf test/simv_core_package test/simv_core_package.daidir test/csrc_core_package test/core_package.log
	rm -rf test/simv_core_package_preinclude test/simv_core_package_preinclude.daidir test/csrc_core_package_preinclude test/core_package_preinclude.log
	rm -rf test/simv_cpu_bridge test/simv_cpu_bridge.daidir test/csrc_cpu_bridge test/cpu_bridge.log
	rm -rf test/simv_cmdline_negative test/simv_cmdline_negative.daidir test/csrc_cmdline_negative test/cmdline_negative.log
	rm -rf test/simv_cmdline_container test/simv_cmdline_container.daidir test/csrc_cmdline_container test/cmdline_container.log test/cmdline_container_malformed_empty.log test/cmdline_container_malformed_trailing.log test/cmdline_container_malformed_missing.log test/cmdline_container_malformed_extra.log
	rm -rf test/simv_cmdline_print_control test/simv_cmdline_print_control.daidir test/csrc_cmdline_print_control test/cmdline_print_runtime.log test/cmdline_print_startup_default.log test/cmdline_print_startup_limit.log test/cmdline_print_startup_normalized.log test/cmdline_print_startup_disabled.log
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name "*.egg-info" -exec rm -rf {} +

# ============================================================
# CI — exercise all test levels.
# ============================================================

.PHONY: ci ci-host ci-sv ci-e2e ci-regress

ci: ci-host ci-sv ci-e2e ci-regress

ci-host:
	$(MAKE) -C firmware/tests

ci-sv:
	$(MAKE) -C aip_cpu_mem/test clean && $(MAKE) -C aip_cpu_mem/test && cd aip_cpu_mem/test && ./simv
	$(MAKE) -C cpu_demo/sim test_loader

ci-e2e:
	$(MAKE) -C cpu_demo/sim test_e2e

ci-regress:
	$(MAKE) -C cpu_demo/sim regress
	$(MAKE) test_end_checker_registry
