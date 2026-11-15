//===========================================================
// aip_c_bridge - Socket/DPI-C command bridge
// Refactored from sv_server_multi.sv (module -> class)
// Usage: `aip_c_bridge_create(c_bridge, "127.0.0.1", 8888, "commands.txt")
// Depends: aip_cmd.sv, sv_socket_dpi.c
//===========================================================
`ifndef AIP_C_BRIDGE_SV
`define AIP_C_BRIDGE_SV

import "DPI-C" function int sv_socket_init(input string ip, input int port);
import "DPI-C" function int sv_socket_accept_nonblock(input int listen_fd);
import "DPI-C" function int sv_socket_recv_nonblock(input int fd, output byte buff[1024], input int maxlen);
import "DPI-C" function int sv_socket_send(input int fd, input string msg);
import "DPI-C" function void sv_socket_close(input int fd);
import "DPI-C" function int sv_socket_is_valid_fd(input int fd);

class aip_c_bridge;

    typedef struct {
        int client_fd;
        string cmd;
    } cmd_item_t;

    string listen_ip;
    int    listen_port;
    string current_file;

    int    listen_fd;
    bit    run_sim;
    mailbox #(cmd_item_t) high_pri_mbox;
    mailbox #(cmd_item_t) low_pri_mbox;

    bit    stop_reading;
    event  file_ctrl_ev;
    event  file_stopped_ev;
    bit    file_thread_active;

    // ---- Constructor: init only, no fork (VCS Q-2020) ----
    function new(string ip = "127.0.0.1", int port = 8888, string file = "");
        this.listen_ip          = ip;
        this.listen_port        = port;
        this.current_file       = file;
        this.run_sim            = 1;
        this.stop_reading       = 0;
        this.file_thread_active = 0;
        high_pri_mbox = new(32);
        low_pri_mbox  = new(32);
    endfunction

    // ---- Start: launch all threads ----
    task start();
        `aip_info(("[AIP_C_BRIDGE] Starting on %s:%0d", listen_ip, listen_port));
        fork
            listener_thread();
            exec_thread();
            if (current_file != "") file_read_thread();
        join_none
    endtask

    // ---- Stop: signal all threads to exit ----
    task stop();
        run_sim = 0;
        -> file_ctrl_ev;
    endtask

    // ---- Listener: accept connections, fork client handlers ----
    task automatic listener_thread();
        listen_fd = sv_socket_init(listen_ip, listen_port);
        if (listen_fd < 0) begin
            `aip_error(("[AIP_C_BRIDGE] Socket init failed on %s:%0d", listen_ip, listen_port));
            run_sim = 0;
            return;
        end
        `aip_info(("[AIP_C_BRIDGE] Listening on %s:%0d, fd=%0d", listen_ip, listen_port, listen_fd));

        while (run_sim) begin
            int conn_fd = sv_socket_accept_nonblock(listen_fd);
            if (conn_fd >= 0) begin
                `aip_info(("[AIP_C_BRIDGE] Client connected, fd=%0d", conn_fd));
                fork
                    automatic int cfd = conn_fd;
                    client_handler(cfd);
                join_none
            end else if (conn_fd == -1) begin
                `aip_error(("[AIP_C_BRIDGE] Accept error"));
                run_sim = 0;
                break;
            end
            #100;
        end
        `aip_info(("[AIP_C_BRIDGE] Listener thread ended"));
    endtask

    // ---- Client handler: recv commands, route to mailbox ----
    task automatic client_handler(int client_fd);
        byte cmd_buf[1024];
        string cmd_str;
        cmd_item_t item;
        int ret;
        string reply;

        `aip_debug(("[AIP_C_BRIDGE] Client handler started, fd=%0d", client_fd));
        while (run_sim) begin
            ret = sv_socket_recv_nonblock(client_fd, cmd_buf, 1024);

            if (ret > 0) begin
                // byte[] to string conversion (VCS Q-2020 compatible)
                cmd_str = "";
                for (int i = 0; i < ret; i++)
                    cmd_str = {cmd_str, $sformatf("%c", cmd_buf[i])};

                `aip_debug(("[AIP_C_BRIDGE] fd=%0d received: %s", client_fd, cmd_str));

                // File control commands handled locally
                if (cmd_str == "stop") begin
                    stop_reading = 1;
                    -> file_ctrl_ev;
                    reply = "OK: File reading stopped";
                    sv_socket_send(client_fd, reply);
                end
                else if (cmd_str.len() >= 7 && cmd_str.substr(0, 6) == "change ") begin
                    handle_change_file(client_fd, cmd_str.substr(7, cmd_str.len() - 1));
                end
                // All other commands go to high priority mailbox
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

    // ---- File change handler ----
    task handle_change_file(int client_fd, string new_file);
        string reply;
        int fd;
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
        current_file = new_file;
        stop_reading = 0;
        -> file_ctrl_ev;
        reply = {"OK: File changed to ", new_file};
        sv_socket_send(client_fd, reply);
    endtask

    // ---- Exec thread: dequeue from mailbox, dispatch via aip_cmd::exec ----
    task automatic exec_thread();
        cmd_item_t item;
        `aip_info(("[AIP_C_BRIDGE] Exec thread started"));
        while (run_sim) begin
            if (high_pri_mbox.try_get(item)) begin
                `aip_debug(("[AIP_C_BRIDGE] Exec high-pri: %s", item.cmd));
                aip_cmd::exec(item.cmd, SRC_DPI);
                begin
                    string result;
                    int st = aip_cmd::__aip_cmd_last_status;
                    string msg = aip_cmd::__aip_cmd_last_result;
                    result = (st == 0) ? {"OK: ", msg} : {"ERROR: ", msg};
                    if (item.client_fd >= 0 && sv_socket_is_valid_fd(item.client_fd)) begin
                        sv_socket_send(item.client_fd, result);
                    end
                end
            end
            else if (low_pri_mbox.try_get(item)) begin
                `aip_debug(("[AIP_C_BRIDGE] Exec low-pri: %s", item.cmd));
                aip_cmd::exec(item.cmd, SRC_DPI);
                // File-sourced commands: no result sent back to client
            end
            else begin
                #100;
            end
        end
        `aip_info(("[AIP_C_BRIDGE] Exec thread ended"));
    endtask

    // ---- File read thread: read commands from file into low_pri_mbox ----
    task automatic file_read_thread();
        int fd;
        string line;
        cmd_item_t item;
        `aip_info(("[AIP_C_BRIDGE] File thread started: %s", current_file));
        -> file_ctrl_ev;

        while (run_sim) begin
            @(file_ctrl_ev or posedge run_sim);
            if (!run_sim) break;

            // Wait while stop_reading is asserted
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

// ---- Macro: create and start C bridge ----
`define aip_c_bridge_create(name, ip, port, file="") \
    aip_c_bridge name; \
    initial begin \
        name = new(ip, port, file); \
        name.start(); \
    end

`endif // AIP_C_BRIDGE_SV
