// aip_reg_seq 运行时注册回归：两个 sequencer、两种声明类型（rs_path_seq 带 param_path），命令全部由 Tcl 注册；
// 只经公开命令/注册表接口观测，不读调度器私有状态。
`include "aip_core_pkg.sv"

class rs_item extends uvm_sequence_item;
    `uvm_object_utils(rs_item)
    string src;   // 发出该 item 的 seq 实例名，即命令名
    int    len;   // seq 按 param_path 读到的参数

    function new(string name = "rs_item");
        super.new(name);
    endfunction
endclass

// driver 侧记录，Tcl 经 rs_state 查询；按命令名与 agent 分别计数。
class rs_record;
    static int items[string];
    static int sqr_items[string];
    static int last_len[string];
    static string path_seen[string];

    static function void note(string agent, rs_item it);
        items[it.src] = items.exists(it.src) ? items[it.src] + 1 : 1;
        sqr_items[agent] = sqr_items.exists(agent) ? sqr_items[agent] + 1 : 1;
        last_len[it.src] = it.len;
    endfunction
endclass

// 只有 int count：发 count 个 item。
class rs_plain_seq extends uvm_sequence #(rs_item);
    `uvm_object_utils(rs_plain_seq)
    int count = 1;

    function new(string name = "rs_plain_seq");
        super.new(name);
    endfunction

    task body();
        repeat (count) begin
            rs_item it = rs_item::type_id::create("it");
            it.src = get_name();
            it.len = 0;
            start_item(it);
            finish_item(it);
        end
    endtask
endclass

// 另有 string param_path：body 内按 <param_path>.len 读参数；<param_path>.stall_ns 非零时先静默等待（不 tick），
// 供命令停滞 watchdog 用例使用，等待有界。
class rs_path_seq extends uvm_sequence #(rs_item);
    `uvm_object_utils(rs_path_seq)
    int count = 1;
    string param_path = "rs.def";

    function new(string name = "rs_path_seq");
        super.new(name);
    endfunction

    task body();
        int len;
        int stall_ns;
        `aip_int(param_path, int, len, 1)
        `aip_int(param_path, int, stall_ns, 0)
        rs_record::path_seen[get_name()] = param_path;
        if (stall_ns > 0) #(stall_ns * 1ns);
        repeat (count) begin
            rs_item it = rs_item::type_id::create("it");
            it.src = get_name();
            it.len = len;
            start_item(it);
            finish_item(it);
        end
    endtask
endclass

`aip_seq_type(rs_plain_seq)
`aip_seq_type_path(rs_path_seq)

// 每 item 10ns 并 tick，长 seq 不触发停滞 watchdog。
class rs_driver extends uvm_driver #(rs_item);
    `uvm_component_utils(rs_driver)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            rs_item it;
            seq_item_port.get_next_item(it);
            #10ns;
            rs_record::note(get_parent().get_name(), it);
            aip_activity::tick();
            seq_item_port.item_done();
        end
    endtask
endclass

class rs_agent extends uvm_agent;
    `uvm_component_utils(rs_agent)
    rs_driver drv;
    uvm_sequencer #(rs_item) sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = rs_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(rs_item)::type_id::create("sqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class rs_env extends uvm_env;
    `uvm_component_utils(rs_env)
    rs_agent a;
    rs_agent b;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        a = rs_agent::type_id::create("a", this);
        b = rs_agent::type_id::create("b", this);
    endfunction
endclass

// 编译期注册的对照命令：与运行时命令共用启动流程，并用于重名拒绝用例。
class rs_binding;
    static uvm_sequencer #(rs_item) sqr_a;
endclass

`aip_cmd_seq(rs_static, rs_plain_seq, rs_binding::sqr_a)

// 只读观测命令；未知 kind 明确失败，不把缺失当作正确结果。
class rs_state_cmd extends aip_cmd;
    task cmd_exec();
        string kind;
        string name;
        kind = get_arg(args_in, "kind");
        name = get_arg(args_in, "name");
        status = 0;
        case (kind)
            "items": result_out = $sformatf("%0d", rs_record::items.exists(name) ? rs_record::items[name] : 0);
            "sqr_items": result_out = $sformatf("%0d", rs_record::sqr_items.exists(name) ?
                                                         rs_record::sqr_items[name] : 0);
            "len": result_out = $sformatf("%0d", rs_record::last_len.exists(name) ? rs_record::last_len[name] : -1);
            "path": result_out = rs_record::path_seen.exists(name) ? rs_record::path_seen[name] : "";
            "exists": result_out = (aip_cmd::get_handle(name) != null) ? "1" : "0";
            "active": result_out = aip_cmd_seq_registry::active(name) ? "1" : "0";
            "now": result_out = $sformatf("%.0f", $realtime / 1ns);
            default: begin
                status = 1;
                result_out = {"bad observation kind: ", kind};
            end
        endcase
    endtask

    function new(string name);
        super.new(name);
    endfunction

    static rs_state_cmd __inst = new("rs_state");
endclass

class rs_test extends uvm_test;
    `uvm_component_utils(rs_test)
    rs_env env;

    function new(string name = "rs_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = rs_env::type_id::create("env", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        rs_binding::sqr_a = env.a.sqr;
    endfunction

    // 注入队列不得暗中改变注册表；声明宏按类型名登记并区分 path 支持。
    function void precheck();
        aip_cmd handle;
        string why;
        aip_seq_launcher plain;
        aip_seq_launcher with_path;
        if (aip_inject_bridge::validate("aip_reg_seq cmd=rs_q type=rs_plain_seq sqr=uvm_test_top.env.a.sqr",
                                        handle, why) || aip_str::str_find(why, "not allowed") < 0)
            `uvm_fatal("REG_SEQ_PRECHECK", {"injection accepted aip_reg_seq: ", why})
        if (aip_inject_bridge::validate("aip_unreg_seq cmd=rs_q", handle, why) ||
            aip_str::str_find(why, "not allowed") < 0)
            `uvm_fatal("REG_SEQ_PRECHECK", {"injection accepted aip_unreg_seq: ", why})
        plain = aip_seq_launcher::find("rs_plain_seq");
        with_path = aip_seq_launcher::find("rs_path_seq");
        if (plain == null || plain.path_supported || with_path == null || !with_path.path_supported)
            `uvm_fatal("REG_SEQ_PRECHECK", "declared sequence types missing or path support wrong")
        if (aip_seq_launcher::find("rs_item") != null)
            `uvm_fatal("REG_SEQ_PRECHECK", "undeclared type resolved")
        $display("REG_SEQ_SV_PRECHECK_PASS");
    endfunction

    // 5000ns 停滞 watchdog 供 hang 用例；总期限只防死锁，正常经 end_test 退出以执行 report 检查。
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        precheck();
        aip_tcl_bridge::set_cmd_watchdog(5000);
        fork
            aip_tcl_bridge::run_loop();
            begin
                #2ms;
                `uvm_fatal("REG_SEQ_DEADLINE", "aip_reg_seq test did not finish in time")
            end
        join_any
        disable fork;
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        super.report_phase(phase);
        server = uvm_report_server::get_server();
        if (server.get_severity_count(UVM_ERROR) != 0 || server.get_severity_count(UVM_FATAL) != 0)
            `uvm_fatal("REG_SEQ_REPORT", "unexpected UVM ERROR/FATAL")
        $display("REG_SEQ_SV_PASS a=%0d b=%0d",
                 rs_record::sqr_items.exists("a") ? rs_record::sqr_items["a"] : 0,
                 rs_record::sqr_items.exists("b") ? rs_record::sqr_items["b"] : 0);
    endfunction
endclass

module test_aip_reg_seq;
    initial run_test("rs_test");
endmodule
