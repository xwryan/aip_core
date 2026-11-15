#===========================================================
# Makefile — aip_cpu_mem test
#===========================================================

SRC_DIR    := ../src
CORE_DIR   := ../..

VCS_OPTS   := -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+all -full64
INCDIRS    := +incdir+$(CORE_DIR) +incdir+$(SRC_DIR)

TEST       ?= test_cpu_mem.sv

.PHONY: all run run72 clean FORCE

all: simv

FORCE:

simv: FORCE $(TEST) fake_mem.sv $(SRC_DIR)/aip_cpu_mem.sv $(CORE_DIR)/aip_core_pkg.sv
	vcs $(VCS_OPTS) $(INCDIRS) $(TEST) -o simv

run: simv
	./simv

run72:
	$(MAKE) clean
	$(MAKE) TEST=test_cpu_mem72.sv run

clean:
	rm -rf simv simv.daidir csrc *.log *.fsdb ucli.key tmp_firmware.hex tmp_combined.hex tmp_ram72.hex
