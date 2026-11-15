// 逐命令 wait=0/1 的真实 UVM/Tcl 集成测试；只经公开命令句柄读参数/写结果，不读调度器私有状态。
`include "aip_core_pkg.sv"

// 记录执行副作用，使 Tcl 能区分“已接受”与“真正完成”，并验证 BUSY 拒绝后原命令 args_in 不变。
class cw_record;
    static int started[string];
    static int finished[string];
    static string args_enter[string];
    static string args_leave[string];
    static int driver_count = 0;
    static string driver_tag = "";

    // 此时调用参数必须已剥离框架 wait 字段。
    static function void enter(string name, string args);
        started[name] = started.exists(name) ? started[name] + 1 : 1;
        args_enter[name] = args;
    endfunction

    // 仅正常返回时调用；重读句柄参数以检测同名拒绝是否破坏在途状态。
    static function void leave(string name, aip_cmd handle);
        finished[name] = finished.exists(name) ? finished[name] + 1 : 1;
        args_leave[name] = handle.args_in;
    endfunction
endclass

// 延迟模拟用户工作，不属于框架 timeout；tick=1 时定期报告活动，允许同步任务合法超过 watchdog 阈值。
class cw_ops;
    // 非零 code 模拟业务失败；结果写本命令句柄而非全局 last-result，后台失败不能污染另一条 ACK。
    static task execute(string name, int forced_delay = -1);
        aip_cmd handle;
        int delay_ns;
        int code;
        bit ticking;
        string tag;

        handle = aip_cmd::get_handle(name);
        delay_ns = (forced_delay < 0) ?
            aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "ns"), 0) :
            forced_delay;
        code = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "code"), 0);
        ticking = aip_cmd::get_arg(handle.args_in, "tick") == "1";
        tag = aip_cmd::get_arg(handle.args_in, "tag");
        cw_record::enter(name, handle.args_in);

        while (delay_ns > 0) begin
            int step_ns;
            step_ns = ticking && delay_ns > 250 ? 250 : delay_ns;
            #(step_ns * 1ns);
            delay_ns -= step_ns;
            if (ticking) aip_activity::tick();
        end

        cw_record::leave(name, handle);
        handle.status = code;
        handle.result_out = $sformatf("DONE:%s:%s", name, tag);
    endtask

    static task background();
        execute("cw_task");
    endtask

    // 独立注册名，可与后台 task 并行，验证下一条默认仍为同步。
    static task foreground();
        execute("cw_front");
    endtask

    // typed 宏必须照常转换 ns，剥离 wait 不能影响原业务参数。
    static task typed(int ns);
        execute("cw_typed", ns);
    endtask

    // legacy 命令共享全局返回槽，wait=0 时框架须保证它们互斥；普通命令仍可在其后台期间运行。
    static task legacy(string text);
        cw_record::enter("cw_legacy", text);
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result = {"LEGACY:", text};
    endtask

    // 先写返回槽再等待完成：在途期间任何前台 ACK 都不能覆盖这对全局返回值。
    static task legacy_delayed(string text);
        aip_cmd handle;
        handle = aip_cmd::get_handle("cw_legacy_late");
        cw_record::enter("cw_legacy_late", handle.args_in);
        aip_cmd::__aip_cmd_last_status = 23;
        aip_cmd::__aip_cmd_last_result = {"LEGACY_SAVED:", text};
        #6000ns;
        cw_record::leave("cw_legacy_late", handle);
    endtask

    // 用户常见的竞速超时写法：disable fork 只能杀本 task 的分支，框架须提供独立同步进程以免误杀其他后台调用。
    static task cancel_children();
        aip_cmd handle;
        handle = aip_cmd::get_handle("cw_cancel");
        cw_record::enter("cw_cancel", handle.args_in);
        fork
            begin #100ns; end
            begin #4000ns; end
        join_any
        disable fork;
        cw_record::leave("cw_cancel", handle);
        handle.status = 0;
        handle.result_out = "DONE:cw_cancel";
    endtask

    // wait fork 只能等待本 task 的子进程：完成时间应约 200ns，而非此前后台 task 的 10000ns。
    static task wait_children();
        aip_cmd handle;
        handle = aip_cmd::get_handle("cw_wait_children");
        cw_record::enter("cw_wait_children", handle.args_in);
        fork
            begin #200ns; end
        join_none
        wait fork;
        cw_record::leave("cw_wait_children", handle);
        handle.status = 0;
        handle.result_out = "DONE:cw_wait_children";
    endtask
endclass

`aip_cmd_task(cw_task, cw_ops::background)
`aip_cmd_task(cw_front, cw_ops::foreground)
`aip_cmd_1i(cw_typed, cw_ops::typed, int, ns, 0)
`aip_cmd_str_1i(cw_legacy, cw_ops::legacy, text, "")
`aip_cmd_str_1i(cw_legacy_late, cw_ops::legacy_delayed, text, "")
`aip_cmd_task(cw_cancel, cw_ops::cancel_children)
`aip_cmd_task(cw_wait_children, cw_ops::wait_children)

class cw_item extends uvm_sequence_item;
    `uvm_object_utils(cw_item)
    string tag;

    function new(string name = "cw_item");
        super.new(name);
    endfunction
endclass

// 两个命令别名共用此 sequence，按 get_name 取自身参数。可取消的等待刻意放在 start_item 之前，
// 避免把 driver 未完成事务的清理混入调度测试。
class cw_sequence extends uvm_sequence #(cw_item);
    `uvm_object_utils(cw_sequence)

    function new(string name = "cw_sequence");
        super.new(name);
    endfunction

    // 被 kill/watchdog 中止时不增加 finished，便于验证取消后重新运行。
    task body();
        aip_cmd handle;
        cw_item item;
        int delay_ns;
        int code;
        string name;
        string tag;

        name = get_name();
        handle = aip_cmd::get_handle(name);
        delay_ns = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "ns"), 0);
        code = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "code"), 0);
        tag = aip_cmd::get_arg(handle.args_in, "tag");
        cw_record::enter(name, handle.args_in);
        #(delay_ns * 1ns);

        item = cw_item::type_id::create("item");
        item.tag = tag;
        start_item(item);
        finish_item(item);
        cw_record::leave(name, handle);
        handle.status = code;
        handle.result_out = $sformatf("DONE:%s:%s", name, tag);
    endtask
endclass

// 静态 sqr 由 connect_phase 赋值，命令注册无需创建环境。
class cw_binding;
    static uvm_sequencer #(cw_item) sqr;
endclass

`aip_cmd_user_seq(cw_seq, cw_sequence, cw_binding::sqr)
`aip_cmd_user_seq(cw_seq_other, cw_sequence, cw_binding::sqr)

class cw_driver extends uvm_driver #(cw_item);
    `uvm_component_utils(cw_driver)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 延迟 300ns 应答，确保 sequence 真正等待 driver 返回。
    task run_phase(uvm_phase phase);
        forever begin
            cw_item item;
            seq_item_port.get_next_item(item);
            #300ns;
            cw_record::driver_count++;
            cw_record::driver_tag = item.tag;
            seq_item_port.item_done();
        end
    endtask
endclass

// 只读观测命令避免依赖 UCLI 对 class 的路径展开，不允许自身后台运行。
class cw_state_command extends aip_cmd;
    // 未知字段明确失败，不把缺失字段当正确结果。
    task cmd_exec();
        string name;
        string field;
        aip_cmd observed;

        name = get_arg(args_in, "name");
        field = get_arg(args_in, "field");
        observed = get_handle(name);
        status = 0;
        case (field)
            "started": result_out = $sformatf("%0d", cw_record::started.exists(name) ?
                                               cw_record::started[name] : 0);
            "finished": result_out = $sformatf("%0d", cw_record::finished.exists(name) ?
                                                cw_record::finished[name] : 0);
            "enter": result_out = cw_record::args_enter[name];
            "leave": result_out = cw_record::args_leave[name];
            "driver_count": result_out = $sformatf("%0d", cw_record::driver_count);
            "driver_tag": result_out = cw_record::driver_tag;
            "now": result_out = $sformatf("%.0f", $realtime / 1ns);
            // 仅在目标完成后查询句柄返回值。
            "command_status", "command_result": begin
                if (observed == null) begin
                    status = 1;
                    result_out = {"unknown observation command: ", name};
                end else if (field == "command_status") begin
                    result_out = $sformatf("%0d", observed.status);
                end else begin
                    result_out = observed.result_out;
                end
            end
            default: begin
                status = 1;
                result_out = {"bad observation field: ", field};
            end
        endcase
    endtask

    function new(string name);
        super.new(name);
    endfunction

    static cw_state_command instance = new("cw_state");
endclass

class cw_test extends uvm_test;
    `uvm_component_utils(cw_test)
    cw_driver driver;
    uvm_sequencer #(cw_item) sqr;

    function new(string name = "cw_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        driver = cw_driver::type_id::create("driver", this);
        sqr = uvm_sequencer#(cw_item)::type_id::create("sqr", this);
    endfunction

    // 静态绑定须先于 Tcl 的第一条命令公布。
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sqr.seq_item_export);
        cw_binding::sqr = sqr;
    endfunction

    // 2000ns watchdog 小于 Tcl 默认 ACK 窗口；总期限只防测试死锁，正常经 end_test 退出以执行 report 阶段检查。
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        aip_tcl_bridge::set_cmd_watchdog(2000);
        fork
            begin
                aip_tcl_bridge::run_loop();
            end
            begin
                #2000000ns;
                `uvm_fatal("CMD_WAIT_DEADLINE", "逐命令等待测试未在总期限内结束")
            end
        join_any
        disable fork;
        phase.drop_objection(this);
    endtask

    // 独立 SV 门禁：Tcl 正常退出之外，还必须走到 UVM 收尾且没有报告错误。
    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        super.report_phase(phase);
        server = uvm_report_server::get_server();
        if (server.get_severity_count(UVM_ERROR) != 0 ||
            server.get_severity_count(UVM_FATAL) != 0)
            `uvm_fatal("CMD_WAIT_REPORT", "测试出现非预期 UVM ERROR/FATAL")
        $display("CMD_WAIT_SV_PASS driver_count=%0d", cw_record::driver_count);
    endfunction
endclass

module test_cmd_wait;
    initial run_test("cw_test");
endmodule
