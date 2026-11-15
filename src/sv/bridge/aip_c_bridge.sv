// src/sv/bridge：Socket/DPI-C 命令接入，将网络及文件输入转交公共命令调度器。
// 依赖 aip_cmd.sv、aip_str 和 sv_socket_dpi.c；本对象拥有邮箱与监听/客户端
// 句柄，客户端断开由 handler 关闭，stop 仅通知工作循环退出，不取消用户命令。
// 执行线程持有每次 exec_result 的独立返回值；旧全局镜像只供兼容读取，不能
// 用于组装 Socket 回复，否则后台 legacy task 可能造成串台或读到旧结果。
// 用法：`aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "commands.txt")`
// 宏只建持久工作线程；Tcl 显式调用 <name>_listen 才打开监听。端口 0 由内核分配。
// 只支持从未监听的快照恢复后启动，不恢复保存过的 OS socket/客户端状态。
`ifndef AIP_C_BRIDGE_SV
`define AIP_C_BRIDGE_SV

// 建立监听 socket，失败返回负数；句柄由 bridge 持有。
import "DPI-C" function int sv_socket_init(input string	ip, input int	port);
// 获取 bind() 后的实际端口；port=0 时由内核动态分配，失败返回负数。
import "DPI-C" function int sv_socket_get_bound_port(input int	listen_fd);
// 只回收本次启动失败的监听 fd，不触碰客户端；不提供 live socket 恢复或重启语义。
import "DPI-C" function void sv_socket_abort_listener(input int	listen_fd);
// 非阻塞接受连接：非负为客户端 fd，-1 错误、-2 暂无连接、-3 客户端已满。
import "DPI-C" function int sv_socket_accept_nonblock(input int	listen_fd);
// 非阻塞接收：正数为有效字节数，0 表示暂无数据，负数表示断连/错误。
import "DPI-C" function int sv_socket_recv_nonblock(input int	fd, output byte	buff[1024], input int	maxlen);
// 向客户端发送回复；保留 C 层返回码，当前协议不重试发送失败。
import "DPI-C" function int sv_socket_send(input int	fd, input string	msg);
// 释放已断开的客户端 socket；调用方不应继续使用其 fd。
import "DPI-C" function void sv_socket_close(input int	fd);
// 检查等待命令期间客户端 fd 是否仍有效，避免对已关闭连接回包。
import "DPI-C" function int sv_socket_is_valid_fd(input int	fd);
// 每个仿真实例在 C 层生成一个 32 位认证 key；只有完成 auth 握手的
// socket 才能进入命令队列。
import "DPI-C" function int sv_socket_is_authenticated(input int	fd);
import "DPI-C" function int sv_socket_authenticate(input int	fd, input string	key_text);
import "DPI-C" function string sv_socket_get_auth_key_text();
// 在 VCS UCLI 提供的 MHPI 上下文中执行认证后的原始 Tcl 命令；实现位于
// sv_socket_dpi.c，TCP 线程只串行调用，不直接链接 Tcl 运行库。
import "DPI-C" function string sv_socket_eval_tcl(input string	script);

// 输入线程只排队，单个执行线程按网络优先级调度；wait=0 由 aip_cmd 管理，
// 不在传输层另建业务线程，以保持 Tcl/Socket/文件三种入口的一致语义。
class aip_c_bridge;

    // 按本次状态形成协议回复；已有 OK:/ERROR: 前缀保持原样，不重复包装。
    static function string format_response(int	st, string	msg);
        string	trimmed;
        trimmed = aip_str::strip(msg);
        if ((trimmed.len() >= 3 && trimmed.substr(0, 2) == "OK:") ||
            (trimmed.len() >= 6 && trimmed.substr(0, 5) == "ERROR:"))
            return trimmed;
        return (st == 0) ? {"OK: ", msg} : {"ERROR: ", msg};
    endfunction

    typedef struct {
        int		client_fd;
        string	cmd;
    } cmd_item_t;

    string	listen_ip;
    int		listen_port;
    string	current_file;

    int	listen_fd;
    bit	run_sim;
    bit	workers_started;
    bit	file_read_requested;

    mailbox #(cmd_item_t)	high_pri_mbox;
    mailbox #(cmd_item_t)	low_pri_mbox;

    bit		stop_reading;
    event	file_ctrl_ev;
    event	file_stopped_ev;
    bit		file_thread_active;

    // MHPI 的 no-print API 不返回 Tcl 状态码，先识别常见错误文本再包装协议结果。
    // 认证后的非 AIP 命令都交给同一 UCLI Tcl 解释器，不在此维护命令白名单。
    static function bit tcl_result_is_error(string	raw);
        string	text;
        text = aip_str::strip(raw);
        return ((text.len() >= 6 && text.substr(0, 5) == "ERROR:") ||
                (text.len() >= 6 && text.substr(0, 5) == "usage:") ||
                (text.len() >= 10 && text.substr(0, 9) == "aip_watch:") ||
                (text.len() >= 5 && text.substr(0, 4) == "AIP_") ||
                (text.len() >= 20 && text.substr(0, 19) == "invalid command name") ||
                (text.len() >= 12 && text.substr(0, 11) == "wrong # args") ||
                (text.len() >= 6 && text.substr(0, 5) == "can't"));
    endfunction

    // VCS 禁止在 MHPI 回调中推进仿真；调用前识别此类命令，向客户端返回明确错误，
    // 避免把 mhpi_ucliTclExecNoPrint 的空结果误当成成功。
    static function bit tcl_is_time_control(string	request, output string	name);
        string	text;
        int		space_pos;
        text = aip_str::strip(request);
        name = text;
        space_pos = -1;
        for (int	i = 0; i < text.len(); i++) begin
            if (text[i] == 8'd32 || text[i] == 8'd9) begin
                space_pos = i;
                break;
            end
        end
        if (space_pos > 0) name = text.substr(0, space_pos - 1);
        return (name == "run" || name == "next" || name == "step" ||
                name == "quit" || name == "finish" || name == "restart" ||
                name == "resume");
    endfunction

    // 先执行 AIP 注册命令；未知命令才转给同一 UCLI Tcl，禁止从 MHPI 推进仿真时间。
    task automatic exec_remote_command(string	request,
                                       output int	status,
                                       output string	result);
        string	raw;
        string	tcl_name;
        status = 0;
        result = "";
        // 已注册 AIP 命令保留原调度与 wait=0 语义；未知名称转交 Tcl，允许通过
        // 同一 TCP 通道使用 get/force 等 UCLI 命令及 aip_watch 等辅助函数。
        aip_cmd::exec_result(request, SRC_SOCKET, status, result);
        if (status == -1 && result.len() >= 17 &&
            result.substr(0, 16) == "Unknown command: ") begin
            if (tcl_is_time_control(request, tcl_name)) begin
                status = 1;
                result = {"ERROR: VCS MHPI Tcl evaluation does not support simulation-time command '",
                          tcl_name, "'; use the local UCLI prompt"};
                return;
            end
            raw = sv_socket_eval_tcl(request);
            result = raw;
            status = tcl_result_is_error(raw) ? 1 : 0;
        end
    endtask

    // 初始化连接配置和有界邮箱，不在构造函数派生线程，以兼容 VCS Q-2020。
    function new(string	ip = "127.0.0.1", int	port = 8888, string	file = "");
        this.listen_ip           = ip;
        this.listen_port         = port;
        this.current_file        = file;
        this.run_sim             = 1;
        this.listen_fd           = -1;
        this.workers_started     = 0;
        this.file_read_requested = (file != "");
        this.stop_reading        = 0;
        this.file_thread_active  = 0;
        high_pri_mbox = new(32);
        low_pri_mbox  = new(32);
    endfunction

    // 仅启动持久等待/执行/文件线程，完全不创建 OS socket；重复调用不派生第二组线程。
    // 由宏的 initial 持有这些线程，恢复后继续等待，避免 Tcl 命令作用域退出时杀掉 listener。
    task start();
        if (workers_started) return;
        workers_started = 1;
        fork
            listener_thread();
            exec_thread();
            file_read_thread();
        join_none
    endtask

    // 显式打开监听并返回实际 endpoint/auth；已有监听重复调用返回同一结果，无使能参数。
    // 同步完成初始化后才发布 fd 唤醒持久线程；失败保持 fd=-1，保留文件执行并允许重试。
    // 已 stop 的 bridge 不重启；保存过 live socket 的快照不属于本接口支持范围。
    task start_listener(output int	status, output string	result);
        int	new_fd;
        int	actual_port;

        status = 1;
        result = "ERROR: bridge workers are not running";
        if (!workers_started || !run_sim) return;
        if (listen_fd < 0) begin
            new_fd = sv_socket_init(listen_ip, listen_port);
            if (new_fd < 0) begin
                result = $sformatf("ERROR: socket init failed on %s:%0d", listen_ip, listen_port);
                return;
            end
            actual_port = sv_socket_get_bound_port(new_fd);
            if (actual_port <= 0) begin
                sv_socket_abort_listener(new_fd);
                result = "ERROR: cannot query bound socket port";
                return;
            end
            listen_port = actual_port;
            listen_fd   = new_fd;
            `aip_info(("[AIP_C_BRIDGE] Listening on %s:%0d, fd=%0d, auth_key=%s",
                       listen_ip, listen_port, listen_fd, sv_socket_get_auth_key_text()));
        end
        status = 0;
        result = $sformatf("OK: Listening on %s:%0d, fd=%0d, auth_key=%s",
                          listen_ip, listen_port, listen_fd, sv_socket_get_auth_key_text());
    endtask

    // 通知循环退出并唤醒文件线程；不强制中断正在执行或已 ACK 的后台命令。
    task stop();
        run_sim = 0;
        -> file_ctrl_ev;
    endtask

    // initial 派生的持久监听线程先等待显式启动；初始无 socket、restore 后也不自动 bind。
    // 接受连接产生的 handler 属于本线程。accept 错误只结束网络接收，不停止独立文件执行。
    task automatic listener_thread();
        wait (listen_fd >= 0 || !run_sim);
        while (run_sim) begin
            int	conn_fd;
            conn_fd = sv_socket_accept_nonblock(listen_fd);
            if (conn_fd >= 0) begin
                `aip_info(("[AIP_C_BRIDGE] Client connected, fd=%0d", conn_fd));
                fork
                    automatic int	cfd = conn_fd;
                    client_handler(cfd);
                join_none
            end else if (conn_fd == -1) begin
                `aip_error(("[AIP_C_BRIDGE] Accept error"));
                break;
            end
            #100;
        end
        `aip_info(("[AIP_C_BRIDGE] Listener thread ended"));
    endtask

    // 接收客户端命令：文件控制在本地处理，其余写高优先级邮箱；断连时关闭 fd。
    task automatic client_handler(int	client_fd);
        byte		cmd_buf[1024];
        string		cmd_str;
        string		key_text;
        cmd_item_t	item;
        int			ret;
        string		reply;

        `aip_debug(("[AIP_C_BRIDGE] Client handler started, fd=%0d", client_fd));
        while (run_sim) begin
            ret = sv_socket_recv_nonblock(client_fd, cmd_buf, 1024);

            if (ret > 0) begin
                // 按字节组装字符串，兼容 VCS Q-2020 的动态转换限制。
                cmd_str = "";
                for (int	i = 0; i < ret; i++)
                    cmd_str = {cmd_str, $sformatf("%c", cmd_buf[i])};

                `aip_debug(("[AIP_C_BRIDGE] fd=%0d received: %s", client_fd, cmd_str));

                // 每个连接独立认证；成功前任何命令（包括文件控制）都不能进入调度器。
                if (sv_socket_is_authenticated(client_fd) != 1) begin
                    if (cmd_str.len() >= 5 && cmd_str.substr(0, 4) == "auth ") begin
                        key_text = aip_str::strip(cmd_str.substr(5, cmd_str.len() - 1));
                        if (sv_socket_authenticate(client_fd, key_text) == 1)
                            reply = "OK: AUTHENTICATED";
                        else
                            reply = "ERROR: AUTH_FAILED";
                    end else begin
                        reply = "ERROR: AUTH_REQUIRED (send: auth <auth_key>)";
                    end
                    sv_socket_send(client_fd, reply);
                end
                // 文件控制由当前 handler 处理，不作为普通业务入队。
                else if (cmd_str == "stop") begin
                    stop_reading = 1;
                    -> file_ctrl_ev;
                    reply = "OK: File reading stopped";
                    sv_socket_send(client_fd, reply);
                end
                else if (cmd_str.len() >= 7 && cmd_str.substr(0, 6) == "change ") begin
                    handle_change_file(client_fd, cmd_str.substr(7, cmd_str.len() - 1));
                end
                // 其余命令进入高优先级邮箱，由唯一执行线程串行分派。
                else begin
                    item.client_fd = client_fd;
                    item.cmd = cmd_str;
                    high_pri_mbox.put(item);
                end
            end
            else if (ret < 0) begin
                `aip_info(("[AIP_C_BRIDGE] fd=%0d disconnected", client_fd));
                sv_socket_close(client_fd);
                break;
            end
            else begin
                #100;
            end
        end
        `aip_info(("[AIP_C_BRIDGE] Client handler ended, fd=%0d", client_fd));
    endtask

    // 验证并切换输入文件；先让旧读取线程停止，失败时向请求客户端返回原因。
    task handle_change_file(int	client_fd, string	new_file);
        string	reply;
        int		fd;
        new_file = aip_str::strip(new_file);
        if (new_file == "") begin
            reply = "ERROR: Missing filename";
            sv_socket_send(client_fd, reply);
            return;
        end
        fd = $fopen(new_file, "r");
        if (fd == 0) begin
            reply = {"ERROR: Cannot open file '", new_file, "'"};
            sv_socket_send(client_fd, reply);
            return;
        end
        $fclose(fd);
        stop_reading = 1;
        -> file_ctrl_ev;
        if (file_thread_active) @(file_stopped_ev);
        current_file        = new_file;
        stop_reading        = 0;
        file_read_requested = 1;
        -> file_ctrl_ev;
        reply = {"OK: File changed to ", new_file};
        sv_socket_send(client_fd, reply);
    endtask

    // 网络命令优先、文件命令次之；每次调用用局部状态/结果构造回复。
    // wait=0 的 STARTED 立即返回，后续后台完成不会再次向 socket 发送结果。
    // 兼容镜像经保护接口发布，legacy 全局返回槽被占用时允许跳过镜像写入。
    task automatic exec_thread();
        cmd_item_t	item;
        int			cmd_status;
        string		cmd_result;

        `aip_info(("[AIP_C_BRIDGE] Exec thread started"));
        while (run_sim) begin
            if (high_pri_mbox.try_get(item)) begin
                `aip_debug(("[AIP_C_BRIDGE] Exec high-pri: %s", item.cmd));
                exec_remote_command(item.cmd, cmd_status, cmd_result);
                aip_cmd::publish_compat_result(cmd_status, cmd_result);
                begin
                    string	result;
                    result = format_response(cmd_status, cmd_result);
                    if (item.client_fd >= 0 && sv_socket_is_valid_fd(item.client_fd)) begin
                        sv_socket_send(item.client_fd, result);
                    end
                end
            end
            else if (low_pri_mbox.try_get(item)) begin
                `aip_debug(("[AIP_C_BRIDGE] Exec low-pri: %s", item.cmd));
                aip_cmd::exec_result(item.cmd, SRC_DPI, cmd_status, cmd_result);
                aip_cmd::publish_compat_result(cmd_status, cmd_result);
                // 文件输入没有客户端回复；未知命令仍按 SRC_DPI 的硬失败规则处理。
            end
            else begin
                #100;
            end
        end
        `aip_info(("[AIP_C_BRIDGE] Exec thread ended"));
    endtask

    // 按控制事件打开文件并逐行入低优先级邮箱；暂停/切换时关闭当前文件。
    // 文件打开失败进入停止读取状态，不向执行线程提交无效内容。
    task automatic file_read_thread();
        int			fd;
        string		line;
        cmd_item_t	item;
        `aip_info(("[AIP_C_BRIDGE] File thread started: %s", current_file));
        // 请求位在构造/切换时置位，线程调度较晚也不会像瞬时 event 一样丢掉首次文件读取。
        while (run_sim) begin
            wait (file_read_requested || !run_sim);
            file_read_requested = 0;
            if (!run_sim) break;

            // 暂停时等待新的文件控制事件，通知切换请求旧文件已停止读取。
            while (stop_reading && run_sim) begin
                file_thread_active = 0;
                -> file_stopped_ev;
                @(file_ctrl_ev or posedge run_sim);
                if (!run_sim) break;
            end
            if (!run_sim) break;

            fd = $fopen(current_file, "r");
            if (fd == 0) begin
                `aip_error(("[AIP_C_BRIDGE] Cannot open file: %s", current_file));
                stop_reading = 1;
                continue;
            end

            file_thread_active = 1;
            `aip_info(("[AIP_C_BRIDGE] Reading file: %s", current_file));

            while (!$feof(fd) && !stop_reading && run_sim) begin
                if ($fgets(line, fd) == 0) break;
                if (line.len() == 0) continue;
                item.client_fd = -1;
                item.cmd = line;
                low_pri_mbox.put(item);
                #100;
            end

            $fclose(fd);
            file_thread_active = 0;
            if (stop_reading) -> file_stopped_ev;
        end
        `aip_info(("[AIP_C_BRIDGE] File thread ended"));
    endtask

endclass

// 宏在 module 层创建对象及常驻注册命令；命令对象只引用同一 bridge，不拥有其线程。
// initial 仅建立后台等待能力，<name>_listen 必须由用户在希望监听的时点显式调用。
`define aip_c_bridge_create(name, ip, port, file="") \
    aip_c_bridge	name; \
    class \__aip_c_listen_``name extends aip_cmd; \
        /* 显式无参启动，结果直接写本次命令实例；拒绝额外参数避免静默误用。 */ \
        task cmd_exec(); \
            if (aip_str::strip(this.args_in) != "") begin \
                this.status = 1; \
                this.result_out = "ERROR: socket listen takes no arguments"; \
            end else if (name == null) begin \
                this.status = 1; \
                this.result_out = "ERROR: C bridge is not initialized"; \
            end else name.start_listener(this.status, this.result_out); \
        endtask \
        /* 注册对象常驻仿真及快照；实际 listener 的所有权仍归 module initial。 */ \
        function new(string	command_name); super.new(command_name); endfunction \
        static \__aip_c_listen_``name	__instance = new({`"name`", "_listen"}); \
    endclass \
    initial begin \
        name = new(ip, port, file); \
        name.start(); \
    end

`endif // AIP_C_BRIDGE_SV
