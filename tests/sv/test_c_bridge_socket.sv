// tests/sv：真实 TCP/C bridge 的命令回复、后台派发和 legacy 结果隔离测试。
// 依赖 AIP package、UVM 及 socket DPI；测试拥有观测 flag 与真实 sequencer/driver，
// AIP 拥有命令调度进程。后台任务由客户端后续命令显式释放，不依赖网络请求
// 必须赶在短仿真延迟内到达；最后一个 ping 保持仿真存活并作为完整流程门禁。
// 默认只建立等待线程；Tcl 显式 listen，未监听快照用于跨进程恢复测试，文件命令独立执行。
`include "aip_core_pkg.sv"

import uvm_pkg::*;
import aip_core_pkg::*;

int	socket_ping_count;
int	socket_file_count;

// 文件路径的业务计数不依赖任何客户端，默认不监听时也必须执行。
class socket_file_ops;
    // 每条文件命令仅累加一次；恢复不能重启文件读取。
    static task mark();
        socket_file_count++;
    endtask
endclass
`aip_cmd_task(socket_file_mark, socket_file_ops::mark)

// 独立业务观测与握手门控，不读取调度器私有字段，也不靠墙钟推断任务完成。
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

// 命令业务入口：普通 task 通过自身 handle 反馈，legacy task 刻意保留旧全局写法。
class socket_test_ops;
    // 原有存活检测；仅最终客户端请求调用，增加计数后允许 UVM 正常收尾。
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

    // 下一条默认同步 task 释放后台，等待其业务完成，再返回自身真实结果。
    // 检查业务参数仍是启动值，证明框架 wait 已剥离且后续命令没有覆盖 handle。
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

    // 先写旧全局返回槽再阻塞；期间任意普通命令 ACK 覆盖该槽都会被最终检查发现。
    // 该命令沿用旧宏/全局结果写法，通过wait=0启动并持有legacy兼容槽。
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
    // 只返回自身结果，不读写兼容全局镜像。
    task cmd_exec();
        this.result_out = "value=0x1234";
        this.status = 0;
    endtask
    // 注册常驻测试命令，执行能力保持父类的同步默认值。
    function new(string	name); super.new(name); endfunction
    static socket_value_cmd	inst = new("socket_value");
endclass

// 用于 TCP 两端确定性握手的同步观测/释放命令；其结果同样必须来自本次调用。
class socket_wait_control_cmd extends aip_cmd;
    // 等待实际启动 flag 后报告状态，或释放 legacy 并校验宏已提取的业务结果。
    // 最后一个 #1 仅等待当前仿真进程尾声，不用于等待客户端网络请求。
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

    // 仅本测试注册控制命令，不开放后台，避免观测自身产生额外 worker。
    function new(string	name); super.new(name); endfunction
    static socket_wait_control_cmd	inst = new("socket_wait_control");
endclass

// 真实 cseq 通道的数据对象；driver 只观察 tag，不持有已完成请求的句柄。
class socket_cseq_item extends uvm_sequence_item;
    `uvm_object_utils(socket_cseq_item)
    string	tag;
    // 标准 factory 构造，不获取额外共享资源。
    function new(string	name = "socket_cseq_item"); super.new(name); endfunction
endclass

// 保留原有 cseq 回归，验证增加逐命令等待控制后 count 和握手行为不变。
class socket_cseq_seq extends uvm_sequence #(socket_cseq_item);
    `uvm_object_utils(socket_cseq_seq)
    int	count;
    // count 由现有 cseq 注册器填入，sequence 本身不解释框架 wait。
    function new(string	name = "socket_cseq_seq"); super.new(name); endfunction
    // 按 count 顺序提交带 tag 的真实 item，等待 driver 完成每次请求。
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
    // driver 隶属测试 env，组件生命周期由 UVM 管理。
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    // 收到请求后记录 tag 并应答，不在 item_done 后保留请求句柄。
    task run_phase(uvm_phase	phase);
        forever begin
            socket_cseq_item	req;
            seq_item_port.get_next_item(req);
            order.push_back(req.tag);
            seq_item_port.item_done();
        end
    endtask
endclass

// 测试拥有的最小真实事务通道，与 TCP listener 生命周期独立。
class socket_cseq_env extends uvm_env;
    `uvm_component_utils(socket_cseq_env)
    uvm_sequencer #(socket_cseq_item)	sqr;
    socket_cseq_driver					drv;
    // 仅设置 UVM 父子关系，组件创建推迟到 build_phase。
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    // 创建真实 sequencer/driver，不在构建阶段启动命令。
    function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        sqr = uvm_sequencer#(socket_cseq_item)::type_id::create("sqr", this);
        drv = socket_cseq_driver::type_id::create("drv", this);
    endfunction
    // 连接 item 端口，确保 TCP 命令启动前驱动通道已可用。
    function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// 注册宏使用的静态绑定点；目标真实 sequencer 由 test.connect_phase 提供。
class socket_cseq_sqr_holder extends uvm_sequencer;
    `uvm_component_utils(socket_cseq_sqr_holder)
    static uvm_sequencer #(socket_cseq_item)	target;
    // 标准组件构造，无需自行创建目标 sequencer。
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
endclass

`aip_cmd_cseq(socket_cseq, socket_cseq_seq, socket_cseq_sqr_holder::target)

// 持有 objection 直到所有网络验证完成，避免墙钟较慢的客户端被提前结束。
class socket_test extends uvm_test;
    `uvm_component_utils(socket_test)
    socket_cseq_env	env;
    // 标准 factory 构造，资源由 env 持有。
    function new(string	name, uvm_component	parent); super.new(name, parent); endfunction
    // 创建测试通道，不修改 AIP 默认调度或 Socket 实现。
    function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        env = socket_cseq_env::type_id::create("env", this);
    endfunction
    // 公布实际 sequencer，注册命令仅引用它而不另建环境。
    function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        socket_cseq_sqr_holder::target = env.sqr;
    endfunction
    // 检查真实业务序列、后台隔离标记及最终存活请求；任何缺失都不发完整 PASS。
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

// 顶层启动真实 TCP bridge；监听 fd 与客户端线程由 AIP bridge 拥有。
module test_c_bridge_socket;
    // 使用文档中的原宏并放在 C bridge 前，验证首次 Tcl 握手无需用户额外 run/#0。
    `aip_tcl_bridge_create(tcl)

    // 端口 0 让内核选择空闲端口；显式监听命令返回实际 endpoint，宿主据此连接。
    `aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "socket_commands.txt")

    // 生命周期断言通过 Tcl 注册入口执行；无监听时 fd 必须为 -1，文件已执行恰好一次。
    task check_default();
        if (c_bridge.listen_fd != -1 || socket_file_count != 1)
            $fatal(1, "C_BRIDGE_LIFECYCLE_FAIL fd=%0d file_count=%0d", c_bridge.listen_fd, socket_file_count);
        $display("C_BRIDGE_DEFAULT_CLOSED file_count=%0d", socket_file_count);
    endtask
    `aip_cmd_task(socket_check_default, check_default)

    // 故意使用非法地址触发真实 C socket 初始化失败；保留文件执行/原配置并允许后续重试。
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
