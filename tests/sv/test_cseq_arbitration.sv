`include "aip_core_pkg.sv"

// Strict C-sequence arbitration regression.
// The normal sequence's first item is held in the driver while the C command
// requests the same sequencer.  The expected order is:
//   normal_1, c_reg, normal_2

class cseq_item extends uvm_sequence_item;
    `uvm_object_utils(cseq_item)
    string tag;
    function new(string name = "cseq_item"); super.new(name); endfunction
endclass

string cseq_order[$];
event cseq_first_active;

class cseq_normal extends uvm_sequence #(cseq_item);
    `uvm_object_utils(cseq_normal)
    function new(string name = "cseq_normal"); super.new(name); endfunction
    task body();
        cseq_item req;
        req = cseq_item::type_id::create("normal_1");
        start_item(req); req.tag = "normal_1"; finish_item(req);
        req = cseq_item::type_id::create("normal_2");
        start_item(req); req.tag = "normal_2"; finish_item(req);
    endtask
endclass

class cseq_multi extends uvm_sequence #(cseq_item);
    `uvm_object_utils(cseq_multi)
    int count;
    function new(string name = "cseq_multi"); super.new(name); endfunction
    task body();
        for (int i = 1; i <= count; i++) begin
            cseq_item req = cseq_item::type_id::create($sformatf("c_%0d", i));
            start_item(req);
            req.tag = $sformatf("c_%0d", i);
            finish_item(req);
        end
    endtask
endclass

class cseq_reg extends uvm_sequence #(cseq_item);
    `uvm_object_utils(cseq_reg)
    bit is_write;
    longint unsigned addr;
    longint unsigned wdata;
    longint unsigned rdata;
    int unsigned len;
    int unsigned mask;
    function new(string name = "cseq_reg"); super.new(name); endfunction
    task body();
        cseq_item req = cseq_item::type_id::create("c_request");
        start_item(req); req.tag = "c_reg"; finish_item(req);
        rdata = 64'hcafe;
    endtask
endclass

class cseq_driver extends uvm_driver #(cseq_item);
    `uvm_component_utils(cseq_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        forever begin
            cseq_item req;
            seq_item_port.get_next_item(req);
            cseq_order.push_back(req.tag);
            if (req.tag == "normal_1") -> cseq_first_active;
            #10;
            seq_item_port.item_done();
        end
    endtask
endclass

class cseq_env extends uvm_env;
    `uvm_component_utils(cseq_env)
    uvm_sequencer #(cseq_item) sqr;
    cseq_driver drv;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sqr = uvm_sequencer#(cseq_item)::type_id::create("sqr", this);
        drv = cseq_driver::type_id::create("drv", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class cseq_virtual_sqr extends uvm_sequencer;
    `uvm_component_utils(cseq_virtual_sqr)
    static uvm_sequencer #(cseq_item) bus_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

`aip_cmd_creg(c_reg, cseq_reg, cseq_virtual_sqr::bus_sqr)
`aip_cmd_cseq(c_multi, cseq_multi, cseq_virtual_sqr::bus_sqr)

class cseq_test extends uvm_test;
    `uvm_component_utils(cseq_test)
    cseq_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = cseq_env::type_id::create("env", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        cseq_virtual_sqr::bus_sqr = env.sqr;
    endfunction
    task run_phase(uvm_phase phase);
        cseq_normal normal;
        phase.raise_objection(this);
        normal = cseq_normal::type_id::create("normal");
        fork normal.start(env.sqr); join_none
        @cseq_first_active;
        fork
            aip_cmd::exec("c_reg op=read addr=0x100", SRC_DPI);
        join
        if (aip_cmd::__aip_cmd_last_result != "rdata=0xcafe") begin
            `uvm_fatal("CREG_RESULT", $sformatf("unexpected result: %s", aip_cmd::__aip_cmd_last_result))
        end
        fork
            aip_cmd::exec("c_multi count=3", SRC_DPI);
        join
        wait (cseq_order.size() == 6);
        if (cseq_order[0] != "normal_1" ||
            cseq_order[1] != "c_reg" ||
            cseq_order[2] != "c_1" ||
            cseq_order[3] != "c_2" ||
            cseq_order[4] != "c_3" ||
            cseq_order[5] != "normal_2") begin
            `uvm_fatal("CSEQ_ORDER", $sformatf("unexpected order: %p", cseq_order))
        end
        $display("CSEQ_ARBITRATION_PASS order=%s,%s,%s,%s,%s,%s",
                 cseq_order[0], cseq_order[1], cseq_order[2],
                 cseq_order[3], cseq_order[4], cseq_order[5]);
        phase.drop_objection(this);
    endtask
endclass

module test_cseq_arbitration;
    initial run_test("cseq_test");
endmodule
