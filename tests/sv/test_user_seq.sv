`include "aip_core_pkg.sv"

// Zero-adaptation user sequence regression.  The sequence deliberately has
// no count/time field; it owns all command-argument interpretation.
class user_item extends uvm_sequence_item;
    `uvm_object_utils(user_item)
    bit enable;
    string tag;

    function new(string name = "user_item");
        super.new(name);
    endfunction
endclass

class user_seq extends uvm_sequence #(user_item);
    `uvm_object_utils(user_seq)
    static int runs;
    static bit last_enable;
    static string last_tag;

    function new(string name = "user_seq");
        super.new(name);
    endfunction

    task body();
        aip_cmd h;
        user_item item;
        string args;
        string enable_s;

        h = aip_cmd::get_handle("user_seq_run");
        args = (h == null) ? "" : h.args_in;
        enable_s = aip_cmd::get_arg(args, "enable");
        // A real SVT link-up wrapper would set its official sequence's
        // enable field here.  The command framework must not guess it.
        last_enable = (enable_s == "") ? 1'b1 : (enable_s == "1");
        last_tag = aip_cmd::get_arg(args, "tag");
        runs++;

        item = user_item::type_id::create("item");
        item.enable = last_enable;
        item.tag = last_tag;
        start_item(item);
        finish_item(item);
    endtask
endclass

class user_driver extends uvm_driver #(user_item);
    `uvm_component_utils(user_driver)
    static bit last_enable;
    static string last_tag;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            user_item item;
            seq_item_port.get_next_item(item);
            last_enable = item.enable;
            last_tag = item.tag;
            #1ns;
            seq_item_port.item_done();
        end
    endtask
endclass

class user_agent extends uvm_agent;
    `uvm_component_utils(user_agent)
    user_driver drv;
    uvm_sequencer #(user_item) sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = user_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(user_item)::type_id::create("sqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class user_vsqr extends uvm_sequencer;
    `uvm_component_utils(user_vsqr)
    static uvm_sequencer #(user_item) seqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass

class user_env extends uvm_env;
    `uvm_component_utils(user_env)
    user_agent agent;
    user_vsqr vsqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = user_agent::type_id::create("agent", this);
        vsqr = user_vsqr::type_id::create("vsqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        user_vsqr::seqr = agent.sqr;
    endfunction
endclass

// The RED phase intentionally references the new macro before it exists.
`aip_cmd_user_seq(user_seq_run, user_seq, user_vsqr::seqr)

class user_state_cmd extends aip_cmd;
    task cmd_exec();
        this.result_out = $sformatf("runs=%0d enable=%0d tag=%s driver_enable=%0d driver_tag=%s",
                                    user_seq::runs, user_seq::last_enable,
                                    user_seq::last_tag, user_driver::last_enable,
                                    user_driver::last_tag);
        this.status = 0;
    endtask

    function new(string name);
        super.new(name);
    endfunction

    static user_state_cmd __inst = new("user_seq_state");
endclass

class user_test extends uvm_test;
    `uvm_component_utils(user_test)
    user_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = user_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        aip_tcl_bridge::run_loop();
        phase.drop_objection(this);
    endtask
endclass

module test_user_seq;
    initial run_test("user_test");
endmodule
