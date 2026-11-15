// tests/sv：验证后台任务/真实 UVM sequence 在途时的 VCS save/restore。
// 依赖 AIP package、官方 Tcl bridge 与 UVM；测试拥有计数、driver 和 sequencer，
// AIP 拥有每次执行的 process/result context。快照必须保留这些对象及等待位置，
// 不能因恢复或重新 source Tcl 而重启、丢失任务或解除仍有效的 BUSY 所有权。
`include "aip_core_pkg.sv"

// 用业务副作用而非私有 process 字段判断是否重复执行；所有记录参与快照。
class ckb_record;
    static int started[string];
    static int finished[string];
    static string enter_args[string];
    static string leave_args[string];
    static int driver_started;
    static int driver_count;

    // 只在用户业务实际进入时计数；重复恢复/启动会使最终断言失败。
    static function void enter(string name);
        aip_cmd handle = aip_cmd::get_handle(name);
        started[name] = started.exists(name) ? started[name] + 1 : 1;
        enter_args[name] = handle.args_in;
    endfunction

    // 正常完成才计数，并重新读取参数以捕获 BUSY 拒绝造成的意外覆盖。
    static function void leave(string name);
        aip_cmd handle = aip_cmd::get_handle(name);
        finished[name] = finished.exists(name) ? finished[name] + 1 : 1;
        leave_args[name] = handle.args_in;
    endfunction
endclass

// 两类字符串 task 保留相同用户签名，分别覆盖独立上下文及旧全局返回槽。
class ckb_ops;
    // 先捕获本次 context，快照恢复后同时验证捕获句柄和快捷查找仍有效。
    static task local_task(string text);
        aip_cmd_result_context ctx;
        ctx = aip_cmd::get_current_context();
        ckb_record::enter("ckb_local");
        ctx.set_result(3, {"LOCAL_PENDING:", text});
        #800ns;
        if (ctx != aip_cmd::get_current_context() || !ctx.is_active())
            $fatal(1, "CKB_CONTEXT_LOST: resumed local task lost its result owner");
        ctx.set_result(7, {"LOCAL_DONE:", text});
        ckb_record::leave("ckb_local");
    endtask

    // 在等待前写旧返回槽；并发 ACK、save 和恢复后的命令不得覆盖该值。
    static task legacy_task(string text);
        ckb_record::enter("ckb_legacy");
        aip_cmd::__aip_cmd_last_status = 17;
        aip_cmd::__aip_cmd_last_result = {"LEGACY_DONE:", text};
        #1200ns;
        ckb_record::leave("ckb_legacy");
    endtask

    // 另一个旧宏别名只能在旧槽空闲后进入，测试在途时要求返回 BUSY。
    static task legacy_peer(string text);
        ckb_record::enter("ckb_peer");
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result = {"PEER:", text};
        ckb_record::leave("ckb_peer");
    endtask

    // 无延迟前台命令用于确认 bridge 已恢复，并检查其结果未读到旧全局槽。
    static task front(string text);
        aip_cmd::set_result(0, {"FRONT:", text});
    endtask
endclass

`aip_cmd_str_1i(ckb_local, ckb_ops::local_task, text, "", 1'b1)
`aip_cmd_str_1i(ckb_legacy, ckb_ops::legacy_task, text, "")
`aip_cmd_str_1i(ckb_peer, ckb_ops::legacy_peer, text, "")
`aip_cmd_str_1i(ckb_front, ckb_ops::front, text, "", 1'b1)

// 真实 item 通道使恢复后的 sequence 不能仅靠改变计数伪装完成。
class ckb_item extends uvm_sequence_item;
    `uvm_object_utils(ckb_item)
    // 标准 factory 构造，无外部资源所有权。
    function new(string name = "ckb_item");
        super.new(name);
    endfunction
endclass

class ckb_sequence extends uvm_sequence #(ckb_item);
    `uvm_object_utils(ckb_sequence)
    // 由命令注册宏创建；对象生命周期覆盖本次 start 和快照恢复。
    function new(string name = "ckb_sequence");
        super.new(name);
    endfunction

    // 快照位于真实 item_done 等待中；恢复后不能重复发送或丢失 pending item。
    task body();
        aip_cmd handle;
        ckb_item item;
        string text;
        handle = aip_cmd::get_handle(get_name());
        text = aip_cmd::get_arg(handle.args_in, "text");
        ckb_record::enter(get_name());
        #50ns;
        item = ckb_item::type_id::create("item");
        start_item(item);
        finish_item(item);
        handle.status = 9;
        handle.result_out = {"SEQ_DONE:", text};
        ckb_record::leave(get_name());
    endtask
endclass

// 静态绑定指向 test 拥有的真实 sequencer；恢复后不能重新 new 或替换。
class ckb_binding;
    static uvm_sequencer #(ckb_item) sqr;
endclass
`aip_cmd_user_seq(ckb_seq, ckb_sequence, ckb_binding::sqr)

class ckb_driver extends uvm_driver #(ckb_item);
    `uvm_component_utils(ckb_driver)
    // 组件由 UVM test 持有，收到的 item 仅借用到 item_done。
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 应答延迟形成真实阻塞握手；每次完整传输增加一次独立业务计数。
    task run_phase(uvm_phase phase);
        forever begin
            ckb_item item;
            seq_item_port.get_next_item(item);
            ckb_record::driver_started++;
            #950ns;
            ckb_record::driver_count++;
            seq_item_port.item_done();
        end
    endtask
endclass

// 只读观察接口不使用 UCLI class 路径，也不依赖调度器私有字段。
class ckb_state extends aip_cmd;
    // 返回字段的标量文本；未知目标/字段明确失败，不能被 Tcl 当作空值通过。
    task cmd_exec();
        string name;
        string field;
        aip_cmd target;
        name = get_arg(args_in, "name");
        field = get_arg(args_in, "field");
        target = get_handle(name);
        status = 0;
        case (field)
            "now": result_out = $sformatf("%.0f", $realtime / 1ns);
            "driver_started": result_out = $sformatf("%0d", ckb_record::driver_started);
            "driver": result_out = $sformatf("%0d", ckb_record::driver_count);
            "active_seq": result_out = $sformatf("%0d", aip_cmd_seq_registry::count());
            "started": result_out = $sformatf("%0d", ckb_record::started.exists(name) ? ckb_record::started[name] : 0);
            "finished": result_out = $sformatf("%0d", ckb_record::finished.exists(name) ? ckb_record::finished[name] : 0);
            "enter": result_out = ckb_record::enter_args[name];
            "leave": result_out = ckb_record::leave_args[name];
            "busy", "args", "status", "result": begin
                if (target == null) begin
                    status = 1;
                    result_out = {"unknown target: ", name};
                end else begin
                    case (field)
                        "busy": result_out = $sformatf("%0d", target.is_busy());
                        "args": result_out = target.args_in;
                        "status": result_out = $sformatf("%0d", target.status);
                        "result": result_out = target.result_out;
                    endcase
                end
            end
            default: begin status = 1; result_out = {"unknown field: ", field}; end
        endcase
    endtask

    // 常驻观察命令不启动后台进程；注册对象由 package 生命周期管理。
    function new(string name);
        super.new(name);
    endfunction
    static ckb_state instance = new("ckb_state");
endclass

class ckb_test extends uvm_test;
    `uvm_component_utils(ckb_test)
    ckb_driver driver;
    uvm_sequencer #(ckb_item) sqr;

    // 构造只建立 UVM 所有权，不启动测试业务。
    function new(string name = "ckb_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 组件在第一次 elaboration/run_test 时创建，restore 必须复用快照对象。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        driver = ckb_driver::type_id::create("driver", this);
        sqr = uvm_sequencer#(ckb_item)::type_id::create("sqr", this);
    endfunction

    // Tcl 接入前公布绑定；恢复脚本只重新加载 Tcl，不重跑环境连接。
    function void connect_phase(uvm_phase phase);
        driver.seq_item_port.connect(sqr.seq_item_export);
        ckb_binding::sqr = sqr;
    endfunction

    // 保持 objection 到 end_test，业务全部短于 watchdog；总期限防回归永久挂起。
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork
            aip_tcl_bridge::run_loop();
            begin #100000ns; `uvm_fatal("CKB_DEADLINE", "后台快照测试未正常结束") end
        join_any
        disable fork;
        phase.drop_objection(this);
    endtask

    // 独立 SV 门禁防止 Tcl 仅打印 PASS；要求原调用及复用调用各执行一次。
    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        string names[3] = '{"ckb_local", "ckb_legacy", "ckb_seq"};
        super.report_phase(phase);
        foreach (names[i]) begin
            if (ckb_record::started[names[i]] != 2 || ckb_record::finished[names[i]] != 2)
                `uvm_fatal("CKB_COUNT", "恢复后任务被重复启动或未完整完成")
        end
        if (ckb_record::driver_started != 2 || ckb_record::driver_count != 2 ||
            aip_cmd_seq_registry::count() != 0)
            `uvm_fatal("CKB_DRIVER", "真实 sequence/driver 计数或登记释放不正确")
        server = uvm_report_server::get_server();
        if (server.get_severity_count(UVM_ERROR) || server.get_severity_count(UVM_FATAL))
            `uvm_fatal("CKB_REPORT", "存在非预期 UVM ERROR/FATAL")
        $display("CKB_SV_PASS driver_count=%0d", ckb_record::driver_count);
    endfunction
endclass

// 顶层仅启动 UVM；所有业务启动必须来自 Tcl，以覆盖真实 bridge 生命周期。
module test_checkpoint_background;
    initial run_test("ckb_test");
endmodule
