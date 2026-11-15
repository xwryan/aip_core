// 真实 TCP/C bridge 测试：命令回复、后台派发与 legacy 结果隔离。
// 后台任务由客户端后续命令显式释放，不依赖网络请求赶在短仿真延迟内到达；最后一个 ping 是完整流程门禁。
// 默认不监听，由 Tcl 显式 listen；未监听的快照用于跨进程恢复测试。
`include "aip_core_pkg.sv"

import uvm_pkg::*;
import aip_core_pkg::*;

int	socket_ping_count;
int	socket_file_count;

// 文件命令不依赖客户端：默认不监听时也必须执行，且恢复后不能重跑。
class socket_file_ops;
    static task mark();
        socket_file_count++;
    endtask
endclass
`aip_cmd_task(socket_file_mark, socket_file_ops::mark)

// 业务观测与握手门控：不读调度器私有字段，也不靠墙钟推断完成。
class socket_wait_record;
    static bit	background_started;
    static bit	background_release;
    static bit	background_finished;
    static bit	background_checked;
    static bit	legacy_started;
    static bit	legacy_release;
    static bit	legacy_finished;
    static bit	legacy_checked;
endclass

// 普通 task 经自身 handle 反馈；legacy task 刻意保留旧全局写法。
class socket_test_ops;
    // 仅最终客户端请求调用；计数后允许 UVM 收尾。
    static task ping();
        #1;
        socket_ping_count++;
    endtask

    // 后台 task 必须一直等待客户端释放；非零业务状态不能污染前台同步回复。
    static task background();
        aip_cmd	handle = aip_cmd::get_handle("socket_wait_task");
        socket_wait_record::background_started = 1;
        wait (socket_wait_record::background_release);
        handle.status = 23;
        handle.result_out = "BACKGROUND_DONE";
        socket_wait_record::background_finished = 1;
    endtask

    // 释放后台并等其完成后返回自身结果；参数仍为启动值，证明 wait 已剥离且 handle 未被覆盖。
    static task foreground();
        aip_cmd	handle = aip_cmd::get_handle("socket_wait_front");
        aip_cmd	background_handle = aip_cmd::get_handle("socket_wait_task");
        socket_wait_record::background_release = 1;
        wait (socket_wait_record::background_finished);
        if (background_handle.status != 23 || background_handle.result_out != "BACKGROUND_DONE" ||
            background_handle.args_in != "token=original") begin
            handle.status = 1;
            handle.result_out = "background state or arguments changed";
            return;
        end
        socket_wait_record::background_checked = 1;
        handle.status = 0;
        handle.result_out = "FOREGROUND_DONE";
    endtask

    // wait=0 启动并沿用旧全局结果写法：先写返回槽再阻塞，期间任何 ACK 覆盖该槽都会被最终检查发现。
    static task legacy(string	text);
        aip_cmd::__aip_cmd_last_status = 17;
        aip_cmd::__aip_cmd_last_result = {"LEGACY:", text};
        socket_wait_record::legacy_started = 1;
        wait (socket_wait_record::legacy_release);
        socket_wait_record::legacy_finished = 1;
    endtask
endclass

`aip_cmd_task(socket_ping, socket_test_ops::ping)
`aip_cmd_task(socket_wait_task, socket_test_ops::background)
`aip_cmd_task(socket_wait_front, socket_test_ops::foreground)
`aip_cmd_str_1i(socket_legacy, socket_test_ops::legacy, text, "")

// 无延迟、固定业务结果的普通同步命令，用来识别回复误读旧全局槽的缺陷。
class socket_value_cmd extends aip_cmd;
    task cmd_exec();
        this.result_out = "value=0x1234";
        this.status = 0;
    endtask
    function new(string	name); super.new(name); endfunction
    static socket_value_cmd	inst = new("socket_value");
endclass

// TCP 两端确定性握手用的同步观测/释放命令；不开放后台，避免观测自身产生额外 worker。
class socket_wait_control_cmd extends aip_cmd;
    // 末尾 #1 只等当前仿真进程尾声，不是等待客户端网络请求。
    task cmd_exec();
        string	op = get_arg(args_in, "op");
        aip_cmd	legacy_handle;
        case (op)
            "background_state": begin
                wait (socket_wait_record::background_started);
                result_out = $sformatf("started=1 finished=%0d", socket_wait_record::background_finished);
            end
            "legacy_started": begin
                wait (socket_wait_record::legacy_started);
                result_out = "LEGACY_STARTED";
            end
            "legacy_finish": begin
                wait (socket_wait_record::legacy_started);
                socket_wait_record::legacy_release = 1;
                wait (socket_wait_record::legacy_finished);
                #1;
                legacy_handle = aip_cmd::get_handle("socket_legacy");
                result_out = $sformatf("legacy_status=%0d legacy_result=%s",
                                      legacy_handle.status, legacy_handle.result_out);
                if (legacy_handle.status != 17 || legacy_handle.result_out != "LEGACY:preserve") begin
                    status = 1;
                    return;
                end
                socket_wait_record::legacy_checked = 1;
            end
            default: begin
                status = 1;
                result_out = {"unknown socket wait control: ", op};
            end
        endcase
    endtask

    function new(string	name); super.new(name); endfunction
    static socket_wait_control_cmd	inst = new("socket_wait_control");
endclass

class socket_cseq_item extends uvm_sequence_item;
    `uvm_object_utils(socket_cseq_item)
    string	tag;
    function new(string	name = "socket_cseq_item"); super.new(name); endfunction
endclass

// cseq 回归：加入逐命令等待控制后 count 与握手行为不变。
class socket_cseq_seq extends uvm_sequence #(socket_cseq_item);
    `uvm_object_utils(socket_cseq_seq)
    int	count;
    function new(string	name = "socket_cseq_seq"); super.new(name); endfunction
    task body();
        for (int	i = 1; i <= count; i++) begin
            socket_cseq_item	req = socket_cseq_item::type_id::create($sformatf("socket_c_%0d", i));
            start_item(req);
            req.tag = $sformatf("socket_c_%0d", i);
            finish_item(req);
        end
    endtask
endclass

// 记录真实 sequencer/driver 握手顺序，作为独立于 TCP 回复的业务证据。
class socket_cseq_driver extends uvm_driver #(socket_cseq_item);
    `uvm_component_utils(socket_cseq_driver)
    static string	order[$];
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase	phase);
        forever begin
            socket_cseq_item	req;
            seq_item_port.get_next_item(req);
            order.push_back(req.tag);
            seq_item_port.item_done();
        end
    endtask
endclass

class socket_cseq_env extends uvm_env;
    `uvm_component_utils(socket_cseq_env)
    uvm_sequencer #(socket_cseq_item)	sqr;
    socket_cseq_driver					drv;
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        sqr = uvm_sequencer#(socket_cseq_item)::type_id::create("sqr", this);
        drv = socket_cseq_driver::type_id::create("drv", this);
    endfunction
    function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// 注册宏使用的静态绑定点；目标真实 sequencer 由 test.connect_phase 提供。
class socket_cseq_sqr_holder extends uvm_sequencer;
    `uvm_component_utils(socket_cseq_sqr_holder)
    static uvm_sequencer #(socket_cseq_item)	target;
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
endclass

`aip_cmd_cseq(socket_cseq, socket_cseq_seq, socket_cseq_sqr_holder::target)

// 持有 objection 直到所有网络验证完成，避免墙钟较慢的客户端被提前结束。
class socket_test extends uvm_test;
    `uvm_component_utils(socket_test)
    socket_cseq_env	env;
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        env = socket_cseq_env::type_id::create("env", this);
    endfunction
    function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        socket_cseq_sqr_holder::target = env.sqr;
    endfunction
    // 任何一项缺失都不打印完整 PASS。
    task run_phase(uvm_phase	phase);
        phase.raise_objection(this);
        wait (socket_cseq_driver::order.size() == 3);
        if (socket_cseq_driver::order[0] != "socket_c_1" ||
            socket_cseq_driver::order[1] != "socket_c_2" ||
            socket_cseq_driver::order[2] != "socket_c_3") begin
            `uvm_fatal("SOCKET_CSEQ_ORDER", $sformatf("unexpected order: %p", socket_cseq_driver::order))
        end
        $display("C_BRIDGE_CSEQ_PASS order=%s,%s,%s",
                 socket_cseq_driver::order[0], socket_cseq_driver::order[1],
                 socket_cseq_driver::order[2]);
        wait (socket_wait_record::background_checked && socket_wait_record::legacy_checked);
        $display("C_BRIDGE_SOCKET_WAIT_PASS background=checked legacy=preserved");
        // 保持 bridge 存活直到错误之后的最后一个合法网络请求到达。
        wait (socket_ping_count == 1);
        $display("C_BRIDGE_SOCKET_SIM_CONTINUED");
        phase.drop_objection(this);
    endtask
endclass

module test_c_bridge_socket;
    // 使用文档中的原宏并放在 C bridge 前，验证首次 Tcl 握手无需用户额外 run/#0。
    `aip_tcl_bridge_create(tcl)

    // 端口 0 让内核选择空闲端口；显式监听命令返回实际 endpoint，宿主据此连接。
    `aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "socket_commands.txt")

    task check_default();
        if (c_bridge.listen_fd != -1 || socket_file_count != 1)
            $fatal(1, "C_BRIDGE_LIFECYCLE_FAIL fd=%0d file_count=%0d", c_bridge.listen_fd, socket_file_count);
        $display("C_BRIDGE_DEFAULT_CLOSED file_count=%0d", socket_file_count);
    endtask
    `aip_cmd_task(socket_check_default, check_default)

    // 故意用非法地址触发真实 socket 初始化失败；须保留原配置并允许重试。
    task check_failed_start();
        int		status;
        string	result;
        c_bridge.listen_ip = "invalid-address";
        c_bridge.start_listener(status, result);
        c_bridge.listen_ip = "127.0.0.1";
        if (status == 0 || c_bridge.listen_fd != -1 || !c_bridge.run_sim)
            $fatal(1, "C_BRIDGE_LIFECYCLE_FAIL failed start damaged bridge");
        $display("C_BRIDGE_FAILED_START_CLEAN");
    endtask
    `aip_cmd_task(socket_check_failed_start, check_failed_start)

    initial run_test("socket_test");
endmodule
