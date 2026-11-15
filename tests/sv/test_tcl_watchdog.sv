`include "aip_core_pkg.sv"

// ============================================================
// test_tcl_watchdog — 命令停滞看门狗端到端测试
//
// 复现 bug: 一个 seq 发了 item 但 driver 永不 item_done ("seq 没回数据"),
// finish_item 永久阻塞 → run_loop 死锁 → 后续命令全废.
//
// 期望 (方向2 停滞检测 watchdog): hang 命令连续无活动进展被判死锁强杀,
// run_loop 回到接命令态, 后续 ping 命令仍能正常执行返回 pong.
// ============================================================

// ---- transaction ----
class wd_item extends uvm_sequence_item;
    `uvm_object_utils(wd_item)
    int dummy;
    function new(string name = "wd_item"); super.new(name); endfunction
endclass

// ---- 挂起 seq: 发 1 个 item, 等 driver item_done (永不来) ----
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

// ---- driver: 故意不 get_next_item / 不 item_done ("没回数据") ----
class hang_driver extends uvm_driver #(wd_item);
    `uvm_component_utils(hang_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        // 空转: 从不拉 item, seq 的 finish_item 永久挂起
        forever #1000;
    endtask
endclass

// ---- agent ----
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

// ---- virtual sequencer ----
class wd_vsqr extends uvm_sequencer;
    `uvm_component_utils(wd_vsqr)
    static uvm_sequencer #(wd_item) hang_sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

// ---- env ----
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

// ---- ping 命令: 有活动 (tick) + 返回 pong, 证明 bridge 存活 ----
class ping_cmd extends aip_cmd;
    task cmd_exec();
        aip_activity::tick();
        this.result_out = "pong";
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static ping_cmd __inst = new("ping");
endclass

// ---- watchdog 清理钩子: 记录被杀命令 ----
class wd_hook extends aip_cmd_watchdog_hook;
    static string last_killed = "";
    static int    call_count  = 0;
    function void on_timeout(string cmd_str);
        last_killed = cmd_str;
        call_count  = call_count + 1;
        $display("[WDOG_HOOK] cleanup for killed cmd '%s' at t=%0t", cmd_str, $time);
    endfunction
endclass

// ---- 读钩子记录的命令: 供 TCL 验证 hook 被调 ----
class wdog_last_cmd extends aip_cmd;
    task cmd_exec();
        this.result_out = $sformatf("killed=%s calls=%0d", wd_hook::last_killed, wd_hook::call_count);
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static wdog_last_cmd __inst = new("wdog_last");
endclass

// ---- 注册 hang 命令 (count mode seq) ----
`aip_cmd_seq(hang, hang_seq, wd_vsqr::hang_sqr)

// ---- test ----
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

// ---- top ----
module test_tcl_watchdog;
    initial run_test("my_test");
endmodule
