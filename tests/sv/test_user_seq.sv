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
    static bit seq_of_self;

    function new(string name = "user_seq");
        super.new(name);
    endfunction

    // status=N 只写非零 status 不写文本；text=T 自写结果文本；api=1 经 aip_cmd_seq_registry::set_result 报失败。
    task body();
        aip_cmd h;
        user_item item;
        string args;
        string enable_s;
        string status_s;
        string text_s;

        // 参数键白名单：aip_cmd_user_seq 除 wait 外不消费任何键，count/time 也须由 seq 自己列出。
        if (!aip_cmd_seq_registry::check_args(this, '{"enable", "tag", "status", "text", "api"})) return;
        seq_of_self = (aip_cmd_seq_registry::seq_of("user_seq_run") == this);
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

        status_s = aip_cmd::get_arg(args, "status");
        text_s = aip_cmd::get_arg(args, "text");
        if (h != null && status_s != "") h.status = aip_cmd::parse_int_arg(status_s, 0);
        if (h != null && text_s != "") h.result_out = text_s;
        if (aip_cmd::get_arg(args, "api") == "1")
            void'(aip_cmd_seq_registry::set_result(this, 4, "ERROR: user_seq_run rejected via set_result"));
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

`aip_cmd_user_seq(user_seq_run, user_seq, user_vsqr::seqr)

// 自己解析参数的 task 命令：先用 aip_cmd::check_arg_keys 拒绝未知键，再读 addr/len。
class user_ops;
    static task strict();
        aip_cmd h = aip_cmd::get_handle("user_task_strict");
        if (!aip_cmd::check_arg_keys(h, '{"addr", "len"})) return;
        h.result_out = $sformatf("OK: addr=%s len=%s", aip_cmd::get_arg(h.args_in, "addr"),
                                 aip_cmd::get_arg(h.args_in, "len"));
        h.status = 0;
    endtask
endclass

`aip_cmd_task(user_task_strict, user_ops::strict)

class user_probe_cmd extends aip_cmd;
    task cmd_exec();
        this.result_out = $sformatf("seq_of_self=%0d", user_seq::seq_of_self);
        this.status = 0;
    endtask

    function new(string name);
        super.new(name);
    endfunction

    static user_probe_cmd __inst = new("user_seq_probe");
endclass

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

    // aip_cmd::unknown_arg_keys / unknown_args_text 的直接检查：顺序去重、区分大小写、brace/引号整体、
    // 非 key=value 的 token 报错文本与 aip_bind_seq 一致。
    function void check_key_helpers();
        string unknown[$];
        string why;
        if (!aip_cmd::unknown_arg_keys("a=1 b=2 c=3", '{"a", "c"}, unknown, why) || unknown.size() != 1 ||
            unknown[0] != "b" || why != "")
            `uvm_fatal("USER_KEYS", "single unknown key")
        if (!aip_cmd::unknown_arg_keys("a=1,b=2 b=3 d=4", '{"a"}, unknown, why) || unknown.size() != 2 ||
            unknown[0] != "b" || unknown[1] != "d")
            `uvm_fatal("USER_KEYS", "unknown keys must keep first-seen order without duplicates")
        if (!aip_cmd::unknown_arg_keys("A=1", '{"a"}, unknown, why) || unknown.size() != 1 || unknown[0] != "A")
            `uvm_fatal("USER_KEYS", "key match must be case-sensitive")
        if (!aip_cmd::unknown_arg_keys("x={1 y=2} z=\"q r=3\"", '{"x", "z"}, unknown, why) || unknown.size() != 0)
            `uvm_fatal("USER_KEYS", "brace/quote values must stay one token")
        if (aip_cmd::unknown_arg_keys("a=1 junk", '{"a"}, unknown, why) ||
            why != "malformed argument 'junk'; expected key=value")
            `uvm_fatal("USER_KEYS", {"malformed token: ", why})
        if (aip_cmd::unknown_arg_keys("=5", '{"a"}, unknown, why) || why != "malformed argument '=5'; expected key=value")
            `uvm_fatal("USER_KEYS", {"empty key: ", why})
        if (aip_cmd::unknown_args_text('{"qp", "foo"}, '{"wait", "qps", "count", "qps"}) !=
            "unknown argument(s) qp, foo; allowed: count, qps, wait")
            `uvm_fatal("USER_KEYS", "standard text must list allowed keys sorted and deduplicated")
        $display("USER_KEYS_SV_PASS");
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_key_helpers();
        aip_tcl_bridge::run_loop();
        phase.drop_objection(this);
    endtask
endclass

module test_user_seq;
    initial run_test("user_test");
endmodule
