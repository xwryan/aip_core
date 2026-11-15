#===========================================================
# Makefile — aip_cpu_mem test
#===========================================================

SRC_DIR    := ../../../src/sv/cpu_mem
CORE_DIR   := ../../..
SV_DIR     := $(CORE_DIR)/src/sv
SV_INCDIRS := +incdir+$(CORE_DIR) +incdir+$(SV_DIR) +incdir+$(SV_DIR)/core \
	+incdir+$(SV_DIR)/bridge +incdir+$(SV_DIR)/util +incdir+$(SV_DIR)/plugin

VCS_OPTS   := -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+all -full64
INCDIRS    := $(SV_INCDIRS) +incdir+$(SRC_DIR)

TEST       ?= test_cpu_mem.sv

.PHONY: all run run72 run_overlap clean FORCE

all: simv

FORCE:

simv: FORCE $(TEST) fake_mem.sv $(SRC_DIR)/aip_cpu_mem.sv $(CORE_DIR)/aip_core_pkg.sv $(SV_DIR)/aip_core_pkg.sv
	vcs $(VCS_OPTS) $(INCDIRS) $(TEST) -o simv

run: simv
	./simv

run72:
	$(MAKE) clean
	$(MAKE) TEST=test_cpu_mem72.sv run

# Expected-fatal negative regression for the unified loader overlap guard.
run_overlap:
	$(MAKE) clean
	$(MAKE) TEST=test_cpu_loader_overlap.sv simv
	set +e; ./simv > loader_overlap.log 2>&1; rc=$$?; set -e; \
	cat loader_overlap.log; \
	grep -Fq 'address overlap' loader_overlap.log; \
	grep -Fq 'UVM_FATAL' loader_overlap.log; \
	! grep -Fq 'EXPECTED_LOAD_IMAGE_OVERLAP_FATAL_MISSING' loader_overlap.log

clean:
	rm -rf simv simv.daidir csrc *.log *.fsdb ucli.key tmp_*.hex
