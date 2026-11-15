`include "aip_core_pkg.sv"

// 命令停滞看门狗端到端测试：driver 永不 item_done 使 finish_item 永久阻塞；
// 期望 hang 命令因无活动进展被判死锁强杀，run_loop 恢复接命令，后续 ping 仍返回 pong。

class wd_item extends uvm_sequence_item;
    `uvm_object_utils(wd_item)
    int dummy;
    function new(string name = "wd_item"); super.new(name); endfunction
endclass

class hang_seq extends uvm_sequence #(wd_item);
    `uvm_object_utils(hang_seq)
    int count;   // aip_cmd_seq 契约字段
    function new(string name = "hang_seq"); super.new(name); endfunction
    task body();
        wd_item tr = wd_item::type_id::create("tr");
        start_item(tr);
        finish_item(tr);   // ← 阻塞: driver 永不 item_done
    endtask
endclass

// 故意从不取 item，使 seq 的 finish_item 永久挂起。
class hang_driver extends uvm_driver #(wd_item);
    `uvm_component_utils(hang_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        forever #1000;
    endtask
endclass

class wd_agent extends uvm_agent;
    `uvm_component_utils(wd_agent)
    hang_driver drv;
    uvm_sequencer #(wd_item) sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = hang_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(wd_item)::type_id::create("sqr", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class wd_vsqr extends uvm_sequencer;
    `uvm_component_utils(wd_vsqr)
    static uvm_sequencer #(wd_item) hang_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class wd_env extends uvm_env;
    `uvm_component_utils(wd_env)
    wd_agent agt;
    wd_vsqr  v_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt   = wd_agent::type_id::create("agt", this);
        v_sqr = wd_vsqr::type_id::create("v_sqr", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        wd_vsqr::hang_sqr = agt.sqr;
    endfunction
endclass

// 有活动（tick）并返回 pong，证明 bridge 仍存活。
class ping_cmd extends aip_cmd;
    task cmd_exec();
        aip_activity::tick();
        this.result_out = "pong";
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static ping_cmd __inst = new("ping");
endclass

class wd_hook extends aip_cmd_watchdog_hook;
    static string last_killed = "";
    static int    call_count  = 0;
    function void on_timeout(string cmd_str);
        last_killed = cmd_str;
        call_count  = call_count + 1;
        $display("[WDOG_HOOK] cleanup for killed cmd '%s' at t=%0t", cmd_str, $time);
    endfunction
endclass

// 供 Tcl 验证 hook 已被调用。
class wdog_last_cmd extends aip_cmd;
    task cmd_exec();
        this.result_out = $sformatf("killed=%s calls=%0d", wd_hook::last_killed, wd_hook::call_count);
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static wdog_last_cmd __inst = new("wdog_last");
endclass

`aip_cmd_seq(hang, hang_seq, wd_vsqr::hang_sqr)

class my_test extends uvm_test;
    `uvm_component_utils(my_test)
    wd_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = wd_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
        wd_hook h = new();
        phase.raise_objection(this);
        // stall watchdog = 10us (< TCL 侧 ack_timeout 50us), 让被杀命令干净返回
        aip_tcl_bridge::set_cmd_watchdog(10000);
        aip_tcl_bridge::set_watchdog_hook(h);
        $display("[TEST] entering TCL bridge with watchdog...");
        aip_tcl_bridge::run_loop();
        phase.drop_objection(this);
    endtask
endclass

module test_tcl_watchdog;
    initial run_test("my_test");
endmodule
