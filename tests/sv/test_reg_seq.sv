`include "aip_core_pkg.sv"

// aip_cmd_reg 宏端到端测试：fake 寄存器堆（assoc array）+ reg_item/driver/seq/vsqr。

class reg_item extends uvm_sequence_item;
    `uvm_object_utils(reg_item)
    bit              is_write;
    longint unsigned addr;
    longint unsigned wdata;
    longint unsigned rdata;
    int  unsigned    len;
    int  unsigned    mask;
    function new(string name = "reg_item"); super.new(name); endfunction
    function string convert2string();
        return $sformatf("%s addr=0x%0h wdata=0x%0h len=%0d mask=0x%0h",
                         (is_write ? "WR" : "RD"), addr, wdata, len, mask);
    endfunction
endclass

// aip_cmd_reg 契约：sequence 使用固定命名字段。
class reg_seq extends uvm_sequence #(reg_item);
    `uvm_object_utils(reg_seq)
    bit              is_write;
    longint unsigned addr;
    longint unsigned wdata;
    longint unsigned rdata;
    int  unsigned    len;
    int  unsigned    mask;
    function new(string name = "reg_seq"); super.new(name); endfunction
    task body();
        reg_item tr = reg_item::type_id::create("tr");
        start_item(tr);
        tr.is_write = is_write;
        tr.addr = addr;
        tr.wdata = wdata;
        tr.len = len;
        tr.mask = mask;
        finish_item(tr);
        if (!is_write) rdata = tr.rdata;
    endtask
endclass

class reg_driver extends uvm_driver #(reg_item);
    `uvm_component_utils(reg_driver)
    longint unsigned regfile[longint unsigned];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        forever begin
            reg_item tr;
            seq_item_port.get_next_item(tr);
            if (tr.is_write) begin
                regfile[tr.addr] = tr.wdata;
                $display("[REG_DRV] WR 0x%0h <= 0x%0h at t=%0t", tr.addr, tr.wdata, $time);
            end else begin
                tr.rdata = regfile.exists(tr.addr) ? regfile[tr.addr] : 64'h0;
                $display("[REG_DRV] RD 0x%0h => 0x%0h at t=%0t", tr.addr, tr.rdata, $time);
            end
            #10;
            seq_item_port.item_done();
        end
    endtask
endclass

class reg_agent extends uvm_agent;
    `uvm_component_utils(reg_agent)
    reg_driver drv;
    uvm_sequencer #(reg_item) sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = reg_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(reg_item)::type_id::create("sqr", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class virtual_sqr extends uvm_sequencer;
    `uvm_component_utils(virtual_sqr)
    static uvm_sequencer #(reg_item) reg_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class my_env extends uvm_env;
    `uvm_component_utils(my_env)
    reg_agent   agt;
    virtual_sqr v_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt   = reg_agent::type_id::create("agt", this);
        v_sqr = virtual_sqr::type_id::create("v_sqr", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        virtual_sqr::reg_sqr = agt.sqr;
        $display("[ENV] virtual_sqr bound: reg=%s", agt.sqr.get_full_name());
    endfunction
endclass

`aip_cmd_reg(reg_acc, reg_seq, virtual_sqr::reg_sqr)
// 非法字符命令名（含 '.'）— 靠转义 class 标识符支持
`aip_cmd_reg(reg.rw, reg_seq, virtual_sqr::reg_sqr)
// 含 '::' 的命令名 — 回归转义 class 标识符 + TCL 派发
`aip_cmd_reg(xxx::reg_write, reg_seq, virtual_sqr::reg_sqr)

class my_test extends uvm_test;
    `uvm_component_utils(my_test)
    my_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = my_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        $display("[TEST] run_phase started, entering TCL bridge...");
        aip_tcl_bridge::run_loop();
        phase.drop_objection(this);
    endtask
endclass

module test_reg_seq;
    aip_clk_if clk0_if();
    aip_clk clk0;
    initial begin
        clk0 = new("clk0", clk0_if);
        clk0.set_freq(100e6);
        clk0.start();
    end
    initial begin
        `aip_cmd_info(reg_acc, "reg", "register read/write access",
                      "op:str addr:int len:int mask:int data:int")
    end
    initial run_test("my_test");
endmodule
