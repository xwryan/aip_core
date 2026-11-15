import "DPI-C" function int sv_socket_init(input string ip, input int port);
import "DPI-C" function int sv_socket_accept_nonblock(input int listen_fd);
import "DPI-C" function int sv_socket_recv_nonblock(input int fd, output byte buff[256], input int maxlen);
import "DPI-C" function int sv_socket_send(input int fd, input string msg);
import "DPI-C" function void sv_socket_close(input int fd);
import "DPI-C" function int sv_socket_is_valid_fd(input int fd); // 新增：校验fd有效性

module sv_server_multi;

    string listen_ip;
    int listen_port;

    typedef struct {
        int client_fd;
        string cmd;
    } cmd_item_t;

    mailbox #(cmd_item_t) high_pri_mbox = new(32);
    mailbox #(cmd_item_t) low_pri_mbox  = new(32);

    string current_file = "commands.txt";
    bit stop_reading = 0;
    event file_ctrl_ev;
    event file_stopped_ev;
    bit file_thread_active = 0;

    int listen_fd;
    bit run_sim = 1;

    // ------------------ 文件读取线程 ------------------
    task automatic file_read_thread();
        int fd;
        string line;
        cmd_item_t item;
        $display("[FILE] 线程启动，初始文件: %s", current_file);

        // 初始主动触发一次事件，让线程跳出首次阻塞
        -> file_ctrl_ev;

        while (run_sim) begin
            @(file_ctrl_ev or posedge run_sim);
            if (!run_sim) break;

            // 若停止读取，等待恢复信号
            while (stop_reading && run_sim) begin
                file_thread_active = 0;
                -> file_stopped_ev;
                @(file_ctrl_ev or posedge run_sim);
                if (!run_sim) break;
            end
            if (!run_sim) break;

            fd = $fopen(current_file, "r");
            if (fd == 0) begin
                $error("[FILE] 无法打开文件: %s", current_file);
                stop_reading = 1;
                continue;
            end

            file_thread_active = 1;
            $display("[FILE] 开始读取文件: %s", current_file);

            while (!$feof(fd) && !stop_reading && run_sim) begin
                if ($fgets(line, fd) == 0) break;
                
                // 修复：正确去除行尾的换行符（兼容 \n 或 \r\n）
                //line = line.strip(); // SystemVerilog 2009+ 内置方法，去除首尾空白（含换行/回车）
                if (line.len() == 0) continue; // 跳过空行

                item.client_fd = -1;
                item.cmd = line;
                low_pri_mbox.put(item);
                $display("[FILE] 放入低优先级指令: %s", line);
                #100; // 模拟读取间隔，可根据需求调整
            end

            $fclose(fd);
            $display("[FILE] 文件读取结束或被中断");
            file_thread_active = 0;
            if (stop_reading) -> file_stopped_ev;
        end
        $display("[FILE] 线程结束");
    endtask


    //task automatic file_read_thread();
    //    int fd;
    //    string line;
    //    cmd_item_t item;
    //    $display("[FILE] 线程启动，初始文件: %s", current_file);
    //    while (run_sim) begin
    //        @(file_ctrl_ev or posedge run_sim);
    //        if (!run_sim) break;

    //        while (stop_reading && run_sim) begin
    //            file_thread_active = 0;
    //            -> file_stopped_ev;
    //            @(file_ctrl_ev or posedge run_sim);
    //            if (!run_sim) break;
    //        end
    //        if (!run_sim) break;

    //        fd = $fopen(current_file, "r");
    //        if (fd == 0) begin
    //            $error("[FILE] 无法打开文件: %s", current_file);
    //            stop_reading = 1;
    //            continue;
    //        end

    //        file_thread_active = 1;
    //        $display("[FILE] 开始读取文件: %s", current_file);

    //        while (!$feof(fd) && !stop_reading && run_sim) begin
    //            if ($fgets(line, fd) == 0) break;
    //            line = line.substr(0, line.len()-2);
    //            item.client_fd = -1;
    //            item.cmd = line;
    //            low_pri_mbox.put(item);
    //            $display("[FILE] 放入低优先级指令: %s", line);
    //            #100;
    //        end

    //        $fclose(fd);
    //        $display("[FILE] 文件读取结束或被中断");
    //        file_thread_active = 0;
    //        if (stop_reading) -> file_stopped_ev;
    //    end
    //    $display("[FILE] 线程结束");
    //endtask

    // ------------------ 监听线程 ------------------
    task automatic listener_thread();
        $display("[LISTEN] 线程启动，监听 IP %s, 端口 %0d", listen_ip, listen_port);
        listen_fd = sv_socket_init(listen_ip, listen_port);
        if (listen_fd < 0) begin
            $error("[LISTEN] 初始化失败，请检查 IP/端口是否可用");
            run_sim = 0;
            return;
        end

        while (run_sim) begin
            int conn_fd = sv_socket_accept_nonblock(listen_fd);
            if (conn_fd >= 0) begin
                $display("[LISTEN] 新客户端连接，fd=%0d", conn_fd);
                fork
                    automatic int client_fd = conn_fd;
                    client_handler(client_fd);
                join_none
            end
            else if (conn_fd == -1) begin
                $error("[LISTEN] accept 错误");
                run_sim = 0;
                break;
            end
            #100;
        end
        $display("[LISTEN] 线程结束");
    endtask

    // ------------------ 单个客户端处理任务（所有指令均有回复） ------------------
	
	 // ------------------ 单个客户端处理任务（核心修改：byte 数组替代 char） ------------------
    task automatic client_handler(int client_fd);
        // 关键修正：char cmd_buf[256] → byte cmd_buf[256]
        byte cmd_buf[256]; 
        string cmd_str;
        cmd_item_t item;
        int ret,pos;
        string reply;
        $display("[CLIENT %0d] 处理线程启动", client_fd);
        while (run_sim) begin
            // 传入 byte 数组，DPI 自动映射 C 的 char*
            ret = sv_socket_recv_nonblock(client_fd, cmd_buf, 256);

			if (ret > 0) begin
                // byte 转数组 
				for(int i=0;i<ret;i++) begin
					cmd_str = {cmd_str,$sformatf("%c", cmd_buf[i])};
				end
                $display("[CLIENT %0d] 收到指令: %s", client_fd, cmd_str);
                if (cmd_str.substr(0,4) == "exec ") begin
                    string exec_cmd = cmd_str.substr(5, cmd_str.len()-1);
                    item.client_fd = client_fd;
                    item.cmd = exec_cmd;
                    high_pri_mbox.put(item);
                    $display("[CLIENT %0d] 放入高优先级队列: %s", client_fd, exec_cmd);
                    reply = "Command received, executing...";
                    sv_socket_send(client_fd, reply);
                end
                else if (cmd_str == "stop") begin
                    $display("[CLIENT %0d] 收到停止文件读取指令", client_fd);
                    stop_reading = 1;
                    -> file_ctrl_ev;
                    reply = "File reading stopped";
                    if (sv_socket_send(client_fd, reply) < 0)
                        $error("[CLIENT %0d] 发送回复失败", client_fd);
                    else
                        $display("[CLIENT %0d] 已发送停止确认", client_fd);
                end
                else if (cmd_str.len() >= 6 && cmd_str.substr(0,5) == "change") begin
                    string new_file = "";
                    int file_fd;
                    // 提取文件名（假设格式为 "change filename" 或 "change filename"）
                    if (cmd_str.len() > 6) begin
                        new_file = cmd_str.substr(6, cmd_str.len()-1);  // 从第7个字符开始
                        // 去除前导空格
                        while (new_file.len() > 0 && new_file[0] == " ") begin
                            new_file = new_file.substr(1, new_file.len()-1);
                        end
                    end

                    if (new_file.len() == 0) begin
                        reply = "ERROR: Missing filename for change command";
                        $display("[CLIENT %0d] %s", client_fd, reply);
                        if (sv_socket_send(client_fd, reply) < 0)
                            $error("[CLIENT %0d] 发送回复失败", client_fd);
                    end else begin
                        // 尝试以只读方式打开文件，检查是否可读
                        file_fd = $fopen(new_file, "r");
                        if (file_fd == 0) begin
                            reply = {"ERROR: Cannot open file '", new_file, "'"};
                            $display("[CLIENT %0d] %s", client_fd, reply);
                            if (sv_socket_send(client_fd, reply) < 0)
                                $error("[CLIENT %0d] 发送回复失败", client_fd);
                        end else begin
                            $fclose(file_fd);
                            $display("[CLIENT %0d] 收到更换文件指令: %s", client_fd, new_file);
                            stop_reading = 1;
                            -> file_ctrl_ev;
                            if (file_thread_active) @(file_stopped_ev);
                            current_file = new_file;
                            stop_reading = 0;
                            -> file_ctrl_ev;
                            reply = {"File changed to ", new_file};
                            if (sv_socket_send(client_fd, reply) < 0)
                                $error("[CLIENT %0d] 发送回复失败", client_fd);
                            else
                                $display("[CLIENT %0d] 已发送更换确认", client_fd);
                        end
                    end
                end
                //else if (cmd_str.substr(0,5) == "change") begin
                //    string new_file = cmd_str.substr(6, cmd_str.len()-1);
                //    $display("[CLIENT %0d] 收到更换文件指令: %s", client_fd, new_file);
                //    stop_reading = 1;
                //    -> file_ctrl_ev;
                //    if (file_thread_active) @(file_stopped_ev);
                //    current_file = new_file;
                //    stop_reading = 0;
                //    -> file_ctrl_ev;
                //    reply = {"File changed to ", new_file};
                //    if (sv_socket_send(client_fd, reply) < 0)
                //        $error("[CLIENT %0d] 发送回复失败", client_fd);
                //    else
                //        $display("[CLIENT %0d] 已发送更换确认", client_fd);
                //end
                else begin
                    $display("[CLIENT %0d] 未知指令: %s", client_fd, cmd_str);
                    reply = {"ERROR: Unknown command '", cmd_str, "'"};
                    if (sv_socket_send(client_fd, reply) < 0)
                        $error("[CLIENT %0d] 发送回复失败", client_fd);
                    else
                        $display("[CLIENT %0d] 已发送错误回复", client_fd);
                end
                cmd_str = "";//clear
            end
			else if (ret < 0) begin
                $display("[CLIENT %0d] 连接断开或错误，关闭", client_fd);
                sv_socket_close(client_fd);
                break;
			end
			else begin
				#100;
			end
        end
        $display("[CLIENT %0d] 处理线程结束", client_fd);
    endtask

    // ------------------ 指令执行线程（含详细打印） ------------------
    task automatic exec_thread();
        cmd_item_t item;
        string result;
		int ret ;
        $display("[EXEC] 线程启动");  // 必须看到此日志
        while (run_sim) begin
			if (high_pri_mbox.try_get(item)) begin
                $display("[EXEC] 取到高优先级指令: fd=%0d, cmd=%s", item.client_fd, item.cmd);
                execute_command(item.cmd,result);
                $display("[EXEC] 执行结果: %s", result);
                
                // 关键修复：发送前校验fd是否有效
                if (item.client_fd >= 0 && sv_socket_is_valid_fd(item.client_fd)) begin
                    $display("[EXEC] 准备向 fd=%0d 发送结果", item.client_fd);
                    ret = sv_socket_send(item.client_fd, result);
                    if (ret < 0)
                        $error("[EXEC] 向客户端 %0d 发送结果失败", item.client_fd);
                    else
                        $display("[EXEC] 已向客户端 %0d 发送结果: %s", item.client_fd, result);
				end else begin
                    $display("[EXEC] 客户端 fd=%0d 已失效，跳过结果发送", item.client_fd);
				end
            end
            else if (low_pri_mbox.try_get(item)) begin
                $display("[EXEC] 取到低优先级指令: %s", item.cmd);
                execute_command(item.cmd,result);
                $display("[EXEC] 低优先级指令执行结果: %s", result); // 新增：打印文件指令执行结果
                // 文件指令不返回客户端
            end
            else begin
                #100;
            end
        end
        $display("[EXEC] 线程结束");
    endtask

    task execute_command(string cmd,output string result);
        $display("[EXEC] 开始执行: %s", cmd);
        #10;  // 模拟执行时间，仿真时间前进
        $display("[EXEC] 完成执行: %s", cmd);
        result =  {"OK: ", cmd};
    endtask

    // ------------------ 主流程 ------------------
    initial begin
        if (!$value$plusargs("IP=%s", listen_ip))
            listen_ip = "127.0.0.1";
        if (!$value$plusargs("PORT=%d", listen_port))
            listen_port = 8888;

        $display("多客户端 SV 服务器启动，监听 %s:%0d", listen_ip, listen_port);
        fork
            file_read_thread();
            listener_thread();
            exec_thread();
        join_any

        // 运行一段时间后自动退出（可调整或改为手动）
        #100ms;
        run_sim = 0;
        -> file_ctrl_ev;
        #100;
        $finish;
    end

    final begin
        $display("服务器关闭");
    end

endmodule
