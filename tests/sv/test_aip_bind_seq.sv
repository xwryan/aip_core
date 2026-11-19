// aip_bind_seq 运行时绑定回归：两个 sequencer、两种声明类型（rs_path_seq 带 param_path），命令多由 Tcl 注册；
// 另含 seq 报告结果、严格 count、time= 上限与 aip_sqr_registry。只经公开命令/注册表接口观测，不读调度器私有状态。
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
    static int kills[string];
    static string cmd_seen[string];
    static string args_seen[string];
    static string child_cmd_seen[string];

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

// 子 seq 不直接登记：经父 seq 链找到启动命令。
class rs_child_seq extends uvm_sequence #(rs_item);
    `uvm_object_utils(rs_child_seq)

    function new(string name = "rs_child_seq");
        super.new(name);
    endfunction

    task body();
        aip_cmd cmd = aip_cmd_seq_registry::command_of(this);
        rs_record::child_cmd_seen[get_parent_sequence().get_name()] = (cmd == null) ? "<none>" : cmd.cmd_name;
    endtask
endclass

// 另有 string param_path：body 内按 <param_path>.* 读参数（len/stall_ns/reject/status_only/custom/finish_ns/child）。
// stall_ns 非零时先静默等待（不 tick）供 watchdog 用例；finish_ns 非零时到点自行结束（time= 早结束用例）；等待均有界。
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
        int reject;
        int status_only;
        int custom;
        int finish_ns;
        int child;
        int sent;
        aip_cmd cmd;
        realtime t0;
        `aip_int(param_path, int, len, 1)
        `aip_int(param_path, int, stall_ns, 0)
        `aip_int(param_path, int, reject, 0)
        `aip_int(param_path, int, status_only, 0)
        `aip_int(param_path, int, custom, 0)
        `aip_int(param_path, int, finish_ns, 0)
        `aip_int(param_path, int, child, 0)
        rs_record::path_seen[get_name()] = param_path;
        cmd = aip_cmd_seq_registry::command_of(this);
        rs_record::cmd_seen[get_name()] = (cmd == null) ? "<none>" : cmd.cmd_name;
        rs_record::args_seen[get_name()] = aip_cmd_seq_registry::args_of(this);
        // 拒绝非法参数：结果回到 Tcl aip_check_status，不发 item。
        if (reject != 0) begin
            if (!aip_cmd_seq_registry::set_result(this, 1, $sformatf("ERROR: %s rejected len=%0d", get_name(), len)))
                `uvm_error("RS_SEQ", "rejection outside a command")
            return;
        end
        if (child != 0) begin
            rs_child_seq sub = rs_child_seq::type_id::create("sub");
            sub.start(m_sequencer, this);
        end
        if (stall_ns > 0) #(stall_ns * 1ns);
        t0 = $realtime;
        sent = 0;
        repeat (count) begin
            rs_item it;
            if (finish_ns > 0 && $realtime - t0 >= finish_ns * 1ns) break;
            it = rs_item::type_id::create("it");
            it.src = get_name();
            it.len = len;
            start_item(it);
            finish_item(it);
            sent++;
        end
        if (status_only != 0 && cmd != null) cmd.status = status_only;
        if (custom != 0) void'(aip_cmd_seq_registry::set_result(this, 0, $sformatf("DONE: %s items=%0d", get_name(), sent)));
    endtask

    virtual function void do_kill();
        rs_record::kills[get_name()] = rs_record::kills.exists(get_name()) ? rs_record::kills[get_name()] + 1 : 1;
    endfunction
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

// sequencer 参数按名字在启动时取；rs_none 从未登记，启动时报错并让命令失败。
`aip_cmd_seq(rs_reg_static, rs_plain_seq, aip_sqr_registry::get("rs_b"))
`aip_cmd_cseq(rs_cseq, rs_plain_seq, aip_sqr_registry::get("rs_a"))
`aip_cmd_seq(rs_reg_bad, rs_plain_seq, aip_sqr_registry::get("rs_none"))

// 预期的 AIP_SQR_REGISTRY 错误降级为 INFO 并计数；只在 armed>0 时生效，未预期的错误照常计入 UVM_ERROR。
class rs_expect_catcher extends uvm_report_catcher;
    static int armed;
    static int caught;
    static string last_msg;

    function new(string name = "rs_expect_catcher");
        super.new(name);
    endfunction

    function action_e catch();
        if (armed > 0 && get_severity() == UVM_ERROR && get_id() == "AIP_SQR_REGISTRY") begin
            armed--;
            caught++;
            last_msg = get_message();
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

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
            "kills": result_out = $sformatf("%0d", rs_record::kills.exists(name) ? rs_record::kills[name] : 0);
            "cmd": result_out = rs_record::cmd_seen.exists(name) ? rs_record::cmd_seen[name] : "";
            "args": result_out = rs_record::args_seen.exists(name) ? rs_record::args_seen[name] : "";
            "child_cmd": result_out = rs_record::child_cmd_seen.exists(name) ? rs_record::child_cmd_seen[name] : "";
            "arm": begin
                rs_expect_catcher::armed = aip_cmd::parse_int_arg(name, 0);
                result_out = name;
            end
            "armed": result_out = $sformatf("%0d", rs_expect_catcher::armed);
            "caught_msg": result_out = rs_expect_catcher::last_msg;
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
        rs_expect_catcher catcher;
        super.connect_phase(phase);
        rs_binding::sqr_a = env.a.sqr;
        catcher = new();
        uvm_report_cb::add(null, catcher);
        aip_sqr_registry::set("rs_a", env.a.sqr);
        aip_sqr_registry::set("rs_b", env.b.sqr);
    endfunction

    // 单个预期错误：catcher 只接 1 次，接到后核对消息片段。
    function void expect_registry_error(string what, string fragment);
        if (rs_expect_catcher::armed != 0 || aip_str::str_find(rs_expect_catcher::last_msg, fragment) < 0)
            `uvm_fatal("BIND_SEQ_PRECHECK", {what, ": expected AIP_SQR_REGISTRY error containing '", fragment,
                                             "', got '", rs_expect_catcher::last_msg, "'"})
    endfunction

    // aip_sqr_registry：同名同对象幂等；同名异对象、非法名、null、未知名报错且不改表。
    // 不在命令中运行的 seq：command_of/args_of/set_result 返回 null/空串/0。
    function void precheck_registry();
        rs_plain_seq loose;
        int caught_before;
        if (!aip_sqr_registry::exists("rs_a") || aip_sqr_registry::get("rs_a") != env.a.sqr ||
            aip_sqr_registry::get("rs_b") != env.b.sqr || aip_sqr_registry::exists("rs_none"))
            `uvm_fatal("BIND_SEQ_PRECHECK", "registry names from connect_phase missing")
        caught_before = rs_expect_catcher::caught;
        aip_sqr_registry::set("rs_a", env.a.sqr);
        if (rs_expect_catcher::caught != caught_before)
            `uvm_fatal("BIND_SEQ_PRECHECK", "re-registering the same sequencer reported an error")
        rs_expect_catcher::armed = 1;
        aip_sqr_registry::set("rs_a", env.b.sqr);
        expect_registry_error("duplicate name", "already registered for uvm_test_top.env.a.sqr; rejected uvm_test_top.env.b.sqr");
        if (aip_sqr_registry::get("rs_a") != env.a.sqr)
            `uvm_fatal("BIND_SEQ_PRECHECK", "duplicate name replaced the first sequencer")
        rs_expect_catcher::armed = 1;
        aip_sqr_registry::set("bad name", env.a.sqr);
        expect_registry_error("invalid name", "invalid sequencer name 'bad name'");
        rs_expect_catcher::armed = 1;
        aip_sqr_registry::set("", env.a.sqr);
        expect_registry_error("empty name", "invalid sequencer name ''");
        rs_expect_catcher::armed = 1;
        aip_sqr_registry::set("rs_null", null);
        expect_registry_error("null sequencer", "sequencer 'rs_null' must not be null");
        rs_expect_catcher::armed = 1;
        if (aip_sqr_registry::get("rs_none") != null)
            `uvm_fatal("BIND_SEQ_PRECHECK", "unknown name resolved")
        expect_registry_error("unknown name", "unknown sequencer name 'rs_none'; registered: rs_a, rs_b");
        if (aip_sqr_registry::exists("bad name") || aip_sqr_registry::exists("rs_null") ||
            aip_sqr_registry::names() != "rs_a, rs_b")
            `uvm_fatal("BIND_SEQ_PRECHECK", "rejected registrations changed the registry")
        loose = new("loose");
        if (aip_cmd_seq_registry::command_of(loose) != null || aip_cmd_seq_registry::args_of(loose) != "" ||
            aip_cmd_seq_registry::set_result(loose, 1, "x"))
            `uvm_fatal("BIND_SEQ_PRECHECK", "seq outside a command resolved a launching command")
    endfunction

    // 注入队列不得暗中改变注册表；声明宏按类型名登记并区分 path 支持。
    function void precheck();
        aip_cmd handle;
        string why;
        aip_seq_launcher plain;
        aip_seq_launcher with_path;
        if (aip_inject_bridge::validate("aip_bind_seq cmd=rs_q type=rs_plain_seq sqr=uvm_test_top.env.a.sqr",
                                        handle, why) || aip_str::str_find(why, "not allowed") < 0)
            `uvm_fatal("BIND_SEQ_PRECHECK", {"injection accepted aip_bind_seq: ", why})
        if (aip_inject_bridge::validate("aip_unbind_seq cmd=rs_q", handle, why) ||
            aip_str::str_find(why, "not allowed") < 0)
            `uvm_fatal("BIND_SEQ_PRECHECK", {"injection accepted aip_unbind_seq: ", why})
        plain = aip_seq_launcher::find("rs_plain_seq");
        with_path = aip_seq_launcher::find("rs_path_seq");
        if (plain == null || plain.path_supported || with_path == null || !with_path.path_supported)
            `uvm_fatal("BIND_SEQ_PRECHECK", "declared sequence types missing or path support wrong")
        if (aip_seq_launcher::find("rs_item") != null)
            `uvm_fatal("BIND_SEQ_PRECHECK", "undeclared type resolved")
        precheck_registry();
        $display("BIND_SEQ_SV_PRECHECK_PASS");
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
                `uvm_fatal("BIND_SEQ_DEADLINE", "aip_bind_seq test did not finish in time")
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
            `uvm_fatal("BIND_SEQ_REPORT", "unexpected UVM ERROR/FATAL")
        $display("BIND_SEQ_SV_PASS a=%0d b=%0d",
                 rs_record::sqr_items.exists("a") ? rs_record::sqr_items["a"] : 0,
                 rs_record::sqr_items.exists("b") ? rs_record::sqr_items["b"] : 0);
    endfunction
endclass

module test_aip_bind_seq;
    initial run_test("rs_test");
endmodule
