`include "aip_core_pkg.sv"
`include "aip_ral_fixture.sv"
package ral_op_test_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import aip_ral_fixture_pkg::*;
    class ral_op_test extends uvm_test;
        `uvm_component_utils(ral_op_test)
        aip_ral_fixture_env env;
        int checks;
        class op_reset_hook extends aip_ral_reset_hook;
            virtual task reset(output bit ok, output string detail);
                ok=1; detail="";
            endtask
        endclass
        function new(string name,uvm_component parent); super.new(name,parent); endfunction
        function void demand(bit ok,string label);
            if(!ok) `uvm_fatal("RAL_OP_ASSERT",label)
            checks++;
        endfunction
        task invoke(string command, output int status, output string result);
            aip_cmd::exec_result(command,SRC_INTERNAL,status,result);
            $display("RAL_OP_CALL command=%s status=%0d result=%s",command,status,result);
        endtask
        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase); env=new("env",this);
        endfunction
        virtual task run_phase(uvm_phase phase);
            aip_ral_service svc=aip_ral_service::get();
            aip_ral_cfg_status_e cfg;
            string detail,reply;
            string expected_wide;
            int rc;
            op_reset_hook reset0=new();
            phase.raise_objection(this);
            cfg=svc.register_root("soc",env.model,env.model.default_map,detail);
            demand(cfg==AIP_RAL_CFG_OK && detail=="","root_registered");
            cfg=svc.set_reset_hook(reset0,detail);
            demand(cfg==AIP_RAL_CFG_OK && detail=="","reset_hook_registered");
            invoke("ral_op write soc.LEAF.WIDE 0x1234",rc,reply);
            demand(rc==0 && reply.len()>0 && aip_str::str_find(reply,"OK op=write")>=0,"register_write");
            invoke("ral_op read soc.LEAF.WIDE",rc,reply);
            expected_wide=aip_ral_command_util::value_text(uvm_reg_data_t'('h1234),`UVM_REG_DATA_WIDTH);
            demand(rc==0 && aip_str::str_find(reply,expected_wide)>=0,"register_read");
            invoke("ral_op write soc.LEAF.WIDE.DATA 0x55",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"kind=field")>=0,"field_write");
            invoke("ral_op write soc.LEAF.RAM 0 0x1122334455667788",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"kind=mem")>=0,"memory_write");
            invoke("ral_op read soc.LEAF.RAM 0",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"1122334455667788")>=0,"memory_read");
            invoke("ral_op write soc.LEAF.VIEW 0 0x1234",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"kind=vreg")>=0,"vreg_write");
            invoke("ral_op write soc.LEAF.VIEW.LODATA 0 0x1fff",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"kind=vfield")>=0,"vfield_write");
            invoke("ral_op read soc.LEAF.VIEW.LODATA 0",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"0x1fff")>=0,"vfield_read");
            invoke("ral_op read soc.LEAF.RAM",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"BAD_ARGS")>=0,"missing_index");
            invoke("ral_op write soc.LEAF.RAM 0 0x1 am=missing",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"NOT_IN_MAP")>=0,"map_miss");
            invoke("ral_op write soc.LEAF.WIDE 0x1xz",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"X_DATA")>=0,"unknown_data_rejected");
            invoke("ral_op write soc.LEAF.WIDE 0x1 am=ral am=ral",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"BAD_ARGS")>=0,"duplicate_map_rejected");
            invoke("ral_test run soc suite=random",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"BAD_ARGS")>=0,"unsupported_suite_rejected");
            invoke("ral_test run soc mem=bad",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"BAD_ARGS")>=0,"unsupported_memory_mode_rejected");
            invoke("ral_test run soc.LEAF.VIEW",rc,reply);
            demand(rc!=0 && aip_str::str_find(reply,"BAD_ARGS")>=0,"virtual_target_rejected");
            invoke("ral_test run soc.LEAF.WIDE.DATA",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"PASS")>=0 &&
                   aip_str::str_find(reply,"effective_target=soc.LEAF.WIDE")>=0 &&
                   aip_str::str_find(reply,"total=1")>=0,
                   "field_target_expands_to_parent_register");
            invoke("ral_test run soc",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"PASS")>=0 &&
                   aip_str::str_find(reply,"inventory_complete=1")>=0 &&
                   aip_str::str_find(reply,"passed=2")>=0,
                   "runner_executes_rw_inventory");
            invoke("ral_test run soc mem=all",rc,reply);
            demand(rc==0 && aip_str::str_find(reply,"PASS")>=0 &&
                   aip_str::str_find(reply,"memory_entries_tested=4")>=0,
                   "runner_mem_all_mode");
            $display("RAL_OP_COMPLETE width=%0d checks=%0d",`UVM_REG_DATA_WIDTH,checks);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
module test_ral_op;
    import uvm_pkg::*;
    import ral_op_test_pkg::*;
    initial run_test("ral_op_test");
endmodule
