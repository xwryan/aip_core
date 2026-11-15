`ifndef AIP_CPU_BRIDGE_SV
`define AIP_CPU_BRIDGE_SV

// Package IRQ signal — user connects to CPU IRQ pin
// Usage: assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;
reg __cpu_bridge_irq = 0;

// Package response event — triggered when CPU writes rsp_flag=1
// User must set up a monitor in testbench (see aip_cpu_bridge_monitor macro)
event __cpu_bridge_rsp_event;

// Backdoor memory access base: users implement wr_mem/rd_mem with project-specific hdl paths.
virtual class aip_mem_accessor;
    pure virtual task wr_mem(input longint unsigned addr, input int unsigned data);
    pure virtual task rd_mem(input longint unsigned addr, output int unsigned data);
endclass

// Sends commands to CPU firmware through a shared-memory mailbox (base + offset):
//   +0x000 cmd_flag 1=pending, +0x004 cmd_len, +0x008 cmd_data (one word per char),
//   +0x208 rsp_flag 1=ready, +0x20C rsp_status 0=ok/-1=error, +0x210 rsp_len, +0x214 rsp_data, +0x414 async_flag.
// Usage: init(mem_accessor, base); optionally enable_irq() and `assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;`
class aip_cpu_bridge;

    localparam longint unsigned OFF_CMD_FLAG   = 'h000;
    localparam longint unsigned OFF_CMD_LEN    = 'h004;
    localparam longint unsigned OFF_CMD_DATA   = 'h008;
    localparam longint unsigned OFF_RSP_FLAG   = 'h208;
    localparam longint unsigned OFF_RSP_STATUS = 'h20C;
    localparam longint unsigned OFF_RSP_LEN    = 'h210;
    localparam longint unsigned OFF_RSP_DATA   = 'h214;
    localparam longint unsigned OFF_ASYNC_FLAG = 'h414;
    localparam longint unsigned OFF_EXIT_FLAG  = 'h418;  // 1=SV请求C退出, 2=C请求SV退出
    localparam longint unsigned OFF_EXIT_CODE  = 'h41C;  // 退出码: 0=正常, 非0=异常
    localparam longint unsigned OFF_IRQ_ACK    = 'h420;  // +0x420  C 写 1 表示进 ISR; SV monitor 读后清 0
    // One word per char: 128 words = 0x200 bytes, matching OFF_CMD_DATA..OFF_RSP_FLAG
    // and firmware/core/aip_cmd.h AIP_CMD_DATA_MAX.
    localparam int CMD_DATA_MAX = 128;

    static aip_mem_accessor mem;
    static longint unsigned mailbox_base;
    static bit              irq_enabled  = 0;
    static bit              event_mode   = 0;  // 1=事件驱动 0=轮询
    static bit              initialized  = 0;
    static real             timeout_ns   = 100000.0;  // 默认 100us 超时
    static string           msip_path    = "";   // CLINT MSIP0 寄存器后门路径
    static bit              msip_mode    = 0;    // 1 = MSIP 唤醒模式
    static string           plic_ip_path    = "";   // PLIC_IP 寄存器后门路径
    static int              plic_src        = 0;    // PLIC 中断源号
    static bit              plic_single_bit = 0;    // 0=RMW IP word; 1=deposit 单个 bit
    static bit              plic_mode       = 0;    // 1 = PLIC 唤醒模式

    static function void init(aip_mem_accessor m, longint unsigned mbox_base);
        mem = m;
        mailbox_base = mbox_base;
        irq_enabled = 0;
        initialized = 1;
        `aip_info(("[AIP_CPU_BRIDGE] Initialized, mailbox_base=0x%0h", mbox_base));
    endfunction

    // send_cmd raises __cpu_bridge_irq until the ISR acks; connect it to the CPU IRQ pin.
    static function void enable_irq();
        irq_enabled = 1;
        `aip_info(("[AIP_CPU_BRIDGE] IRQ mode enabled (signal: __cpu_bridge_irq)"));
    endfunction

    // send_cmd waits on __cpu_bridge_rsp_event instead of #10 polling; needs `aip_cpu_bridge_monitor in module scope.
    static function void enable_event_mode();
        event_mode = 1;
        `aip_info(("[AIP_CPU_BRIDGE] Event-driven mode enabled (signal: __cpu_bridge_rsp_event)"));
    endfunction

    // MSIP wake: send_cmd deposits MSIP0=1 at path (CLINT MSIP0 register) to wake the CPU from wfi;
    // independent of event_mode.
    static function void set_msip_path(string path);
        msip_path = path;
        msip_mode = 1;
        `aip_info(("[AIP_CPU_BRIDGE] MSIP wake mode enabled, path=%s", path));
    endfunction

    // Enable PLIC wake mode. path=PLIC_IP register HDL path, src=PLIC source num.
    // single_bit=0: path is the 32-bit IP word (RMW set bit src%32);
    // single_bit=1: path is that source's single pending-bit flop (deposit 1).
    static function void set_plic_path(string path, int src, bit single_bit = 0);
        plic_ip_path    = path;
        plic_src        = src;
        plic_single_bit = single_bit;
        plic_mode       = 1;
        `aip_info(("[AIP_CPU_BRIDGE] PLIC wake mode enabled, path=%s src=%0d single_bit=%0b", path, src, single_bit));
    endfunction

    // Raise PLIC pending (A-mode backdoor) to wake CPU from wfi.
    static task plic_raise();
        uvm_hdl_data_t cur;
        if (!plic_mode) return;
        if (plic_single_bit) begin
            cur = 1;
            if (!uvm_hdl_deposit(plic_ip_path, cur))
                `aip_warning(("[AIP_CPU_BRIDGE] PLIC IP deposit fail, path=%s", plic_ip_path));
        end else begin
            void'(uvm_hdl_read(plic_ip_path, cur));
            cur = cur | (longint'(1) << (plic_src % 32));
            if (!uvm_hdl_deposit(plic_ip_path, cur))
                `aip_warning(("[AIP_CPU_BRIDGE] PLIC IP deposit fail, path=%s", plic_ip_path));
        end
    endtask

    // Response timeout in ns (0 disables).
    static function void set_timeout(real ns);
        timeout_ns = ns;
        `aip_info(("[AIP_CPU_BRIDGE] Timeout set to %.0f ns", ns));
    endfunction

    static task write_cmd_string(string s);
        int len;
        len = s.len();
        if (len > CMD_DATA_MAX) len = CMD_DATA_MAX;
        mem.wr_mem(mailbox_base + OFF_CMD_LEN, len);
        for (int i = 0; i < len; i++) begin
            begin
                int unsigned _ch = s[i];
                mem.wr_mem(mailbox_base + OFF_CMD_DATA + i * 4, _ch);
            end
        end
    endtask

    static task read_rsp_string(output string s);
        int unsigned len;
        int unsigned ch;
        mem.rd_mem(mailbox_base + OFF_RSP_LEN, len);
        if (len > CMD_DATA_MAX) len = CMD_DATA_MAX;
        s = "";
        for (int i = 0; i < int'(len); i++) begin
            mem.rd_mem(mailbox_base + OFF_RSP_DATA + i * 4, ch);
            s = {s, string'(ch[7:0])};
        end
    endtask

    // Held until irq_ack_monitor drops it.
    static task trigger_irq();
        if (irq_enabled) __cpu_bridge_irq = 1;
    endtask

    // Drops __cpu_bridge_irq when the C ISR acks; started by start_monitors() (once after init() if IRQ is used).
    static task irq_ack_monitor();
        int unsigned ack;
        forever begin
            #10;
            if (!initialized) continue;
            if (!irq_enabled) continue;
            if (__cpu_bridge_irq == 1'b0) continue;
            mem.rd_mem(mailbox_base + OFF_IRQ_ACK, ack);
            if (ack == 32'd1) begin
                mem.wr_mem(mailbox_base + OFF_IRQ_ACK, 32'd0);
                __cpu_bridge_irq = 1'b0;
            end
        end
    endtask

    static task start_monitors();
        fork irq_ack_monitor(); join_none
        `aip_info(("[AIP_CPU_BRIDGE] Monitors started (irq_ack)"));
    endtask

    // async=1 returns right after writing the command; async=0 waits for the response or timeout.
    static task send_cmd(string cmd, bit is_async, output int status, output string result);
        int unsigned rsp_flag;
        int unsigned rsp_status;

        if (!initialized) begin
            `aip_error(("[AIP_CPU_BRIDGE] Not initialized! Call aip_cpu_bridge::init() first"));
            status = -1;
            result = "ERROR: cpu_bridge not initialized";
            return;
        end

        `aip_debug(("[AIP_CPU_BRIDGE] Sending cmd: %s (async=%0b)", cmd, is_async));

        // Clear rsp_flag before sending (prevent stale response)
        mem.wr_mem(mailbox_base + OFF_RSP_FLAG, 0);

        begin
            int unsigned _async_val = is_async;
            mem.wr_mem(mailbox_base + OFF_ASYNC_FLAG, _async_val);
        end

        write_cmd_string(cmd);

        // Set cmd_flag = 1 (must be last — C polls this)
        mem.wr_mem(mailbox_base + OFF_CMD_FLAG, 1);

        trigger_irq();

        // MSIP wake: 后门 deposit MSIP0=1 唤醒 wfi 中的 CPU
        if (msip_mode) begin
            uvm_hdl_data_t _msip_val;
            _msip_val = 1;
            if (!uvm_hdl_deposit(msip_path, _msip_val))
                `aip_warning(("[AIP_CPU_BRIDGE] MSIP deposit fail, path=%s", msip_path));
        end

        // PLIC wake: 后门 deposit PLIC_IP 位唤醒 wfi 中的 CPU
        plic_raise();

        if (is_async) begin
            status = 0;
            result = "OK: async command sent";
            `aip_debug(("[AIP_CPU_BRIDGE] Async cmd sent, returning immediately"));
            return;
        end

        // 同步：等待响应与超时竞速；外层 fork-begin-join 隔离 disable fork 的作用域。
        begin
            bit timed_out;
            bit cpu_exited;
            timed_out = 0;
            cpu_exited = 0;
            rsp_flag = 0;

            fork
                begin
                    fork
                        begin
                            if (event_mode) begin
                                // 事件模式：monitor 同时监视 rsp_flag 与 exit_flag；CPU 若在发送前已退出（exit_flag=2）
                                // 不会再有跳变，故先读一次再等事件。
                                mem.rd_mem(mailbox_base + OFF_EXIT_FLAG, rsp_flag);
                                if (rsp_flag != 2) begin
                                    @(__cpu_bridge_rsp_event);
                                    mem.rd_mem(mailbox_base + OFF_EXIT_FLAG, rsp_flag);
                                end
                                if (rsp_flag == 2) begin
                                    cpu_exited = 1;
                                end else begin
                                    rsp_flag = 1;
                                end
                            end else begin
                                while (rsp_flag != 1 && !cpu_exited) begin
                                    int unsigned exit_flag;
                                    #10;
                                    mem.rd_mem(mailbox_base + OFF_EXIT_FLAG, exit_flag);
                                    if (exit_flag == 2) begin
                                        cpu_exited = 1;
                                    end else begin
                                        mem.rd_mem(mailbox_base + OFF_RSP_FLAG, rsp_flag);
                                    end
                                end
                            end
                        end

                        begin
                            if (timeout_ns > 0) begin
                                aip_time::delay_ns(timeout_ns);
                                timed_out = 1;
                            end else begin
                                forever #1000000;  // timeout=0 禁用
                            end
                        end
                    join_any
                    disable fork;
                end
            join;

            if (timed_out) begin
                `aip_error(("[AIP_CPU_BRIDGE] TIMEOUT (%.0f ns) waiting for CPU response, cmd='%s'", timeout_ns, cmd));
                status = -1;
                result = $sformatf("ERROR: timeout %.0fns, cmd=%s", timeout_ns, cmd);
                mem.wr_mem(mailbox_base + OFF_CMD_FLAG, 0);
            end else if (cpu_exited) begin
                int unsigned exit_code;
                mem.rd_mem(mailbox_base + OFF_EXIT_CODE, exit_code);
                if (exit_code != 0) begin
                    `aip_error(("[AIP_CPU_BRIDGE] CPU FATAL EXIT during command '%s', exit_code=%0d", cmd, exit_code));
                    `aip_fatal(("[AIP_CPU_BRIDGE] CPU firmware abnormal exit (code=%0d). Check C-side error handling.", exit_code));
                end else begin
                    `aip_warning(("[AIP_CPU_BRIDGE] CPU exited normally during command '%s'", cmd));
                end
                status = -1;
                result = $sformatf("ERROR: CPU exited (code=%0d) during command", exit_code);
            end else begin
                mem.rd_mem(mailbox_base + OFF_RSP_STATUS, rsp_status);
                read_rsp_string(result);
                status = int'(rsp_status);
                mem.wr_mem(mailbox_base + OFF_RSP_FLAG, 0);
                `aip_debug(("[AIP_CPU_BRIDGE] Response: status=%0d result=%s", status, result));
            end
        end
    endtask

    // SV -> C: set exit_flag=1 so the firmware cmd_loop returns.
    static task request_cpu_exit();
        if (!initialized) return;
        mem.wr_mem(mailbox_base + OFF_EXIT_FLAG, 1);
        mem.wr_mem(mailbox_base + OFF_EXIT_CODE, 0);
        // 触发 IRQ 唤醒 WFI 中的 CPU
        trigger_irq();
        if (msip_mode) begin
            uvm_hdl_data_t _msip_val;
            _msip_val = 1;
            if (!uvm_hdl_deposit(msip_path, _msip_val))
                `aip_warning(("[AIP_CPU_BRIDGE] MSIP deposit fail, path=%s", msip_path));
        end
        // PLIC wake: 后门 deposit PLIC_IP 位唤醒 wfi 中的 CPU
        plic_raise();
        `aip_info(("[AIP_CPU_BRIDGE] Requested CPU exit"));
    endtask

    // C -> SV: firmware cmd_exit() sets exit_flag=2. exit_status: 0 = running, 1 = normal exit, -1 = error exit.
    static task check_cpu_exit(output int exit_status);
        int unsigned flag;
        int unsigned code;
        if (!initialized) begin
            exit_status = 0;
            return;
        end
        mem.rd_mem(mailbox_base + OFF_EXIT_FLAG, flag);
        if (flag == 2) begin
            mem.rd_mem(mailbox_base + OFF_EXIT_CODE, code);
            exit_status = (code == 0) ? 1 : -1;
            if (code != 0) begin
                `aip_error(("[AIP_CPU_BRIDGE] CPU requested exit with error code=%0d", code));
            end else begin
                `aip_info(("[AIP_CPU_BRIDGE] CPU requested normal exit"));
            end
        end else begin
            exit_status = 0;
        end
    endtask

endclass

// 内建 CPU 命令：SV 侧展开此宏，须与 C 侧 cmd_register_builtins() 一一匹配。
`define aip_cpu_bridge_builtins \
    `aip_cmd_cpu(cpu_read32) \
    `aip_cmd_cpu(cpu_write32) \
    `aip_cmd_cpu(cpu_read64) \
    `aip_cmd_cpu(cpu_write64) \
    `aip_cmd_cpu(cpu_read32_swap) \
    `aip_cmd_cpu(cpu_write32_swap) \
    `aip_cmd_cpu(cpu_read64_swap) \
    `aip_cmd_cpu(cpu_write64_swap) \
    `aip_cmd_cpu(cpu_poll32) \
    `__aip_cpu_bridge_sv_builtins \
    `__aip_cpu_bridge_exit_cmds

// SV 后门命令 cpu_memset/cpu_memdump：不经 CPU，直接走 aip_mem_accessor；须在 aip_cmd.sv 之后展开（由 `aip_cpu_bridge_builtins 自动注册）。
`define __aip_cpu_bridge_sv_builtins \
class \__aip_cmd_cpu_memset extends aip_cmd; \
    task cmd_exec(); \
        longint unsigned addr; \
        int unsigned val; \
        int len; \
        int i; \
        string addr_s, val_s, len_s; \
        addr_s = aip_cmd::get_arg(this.args_in, "addr"); \
        val_s  = aip_cmd::get_arg(this.args_in, "val"); \
        len_s  = aip_cmd::get_arg(this.args_in, "len"); \
        begin \
            int w; \
            longint unsigned tmp; \
            tmp = aip_str::str_to_num(addr_s, w); \
            addr = tmp; \
        end \
        val = aip_cmd::parse_int_arg(val_s, 0); \
        len = aip_cmd::parse_int_arg(len_s, 0); \
        if (!aip_cpu_bridge::initialized) begin \
            this.result_out = "ERROR: cpu_bridge not initialized"; \
            this.status = 1; \
            return; \
        end \
        for (i = 0; i < len; i = i + 4) begin \
            aip_cpu_bridge::mem.wr_mem(addr + i, val); \
        end \
        this.result_out = $sformatf("ok addr=0x%0h len=%0d val=0x%0h", addr, len, val); \
        this.status = 0; \
        `aip_info(("[CPU_MEMSET] addr=0x%0h len=%0d val=0x%0h done", addr, len, val)); \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_cpu_memset __inst = new("cpu_memset"); \
endclass \
class \__aip_cmd_cpu_memdump extends aip_cmd; \
    task cmd_exec(); \
        longint unsigned addr; \
        int len; \
        int i; \
        string addr_s, len_s; \
        int unsigned data; \
        addr_s = aip_cmd::get_arg(this.args_in, "addr"); \
        len_s  = aip_cmd::get_arg(this.args_in, "len"); \
        begin \
            int w; \
            longint unsigned tmp; \
            tmp = aip_str::str_to_num(addr_s, w); \
            addr = tmp; \
        end \
        len = aip_cmd::parse_int_arg(len_s, 64); \
        if (!aip_cpu_bridge::initialized) begin \
            this.result_out = "ERROR: cpu_bridge not initialized"; \
            this.status = 1; \
            return; \
        end \
        `aip_info(("[CPU_MEMDUMP] addr=0x%0h len=%0d", addr, len)); \
        $display(""); \
        $display("  Address     +0       +4       +8       +C"); \
        $display("  ---------   -------- -------- -------- --------"); \
        for (i = 0; i < len; i = i + 16) begin \
            string line; \
            line = $sformatf("  %08h: ", addr + i); \
            begin \
                int j; \
                for (j = 0; j < 16 && (i + j) < len; j = j + 4) begin \
                    aip_cpu_bridge::mem.rd_mem(addr + i + j, data); \
                    line = {line, $sformatf(" %08h", data)}; \
                end \
            end \
            $display("%s", line); \
        end \
        $display(""); \
        this.result_out = $sformatf("ok addr=0x%0h len=%0d", addr, len); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_cpu_memdump __inst = new("cpu_memdump"); \
endclass

// 退出命令：cpu_exit 由 Tcl/SV 通知 C 退出 cmd_loop；C 侧 cmd_exit 经 exit_flag=2 通知 SV 异常退出。
`define __aip_cpu_bridge_exit_cmds \
class \__aip_cmd_cpu_exit extends aip_cmd; \
    task cmd_exec(); \
        aip_cpu_bridge::request_cpu_exit(); \
        this.result_out = "ok: cpu exit requested"; \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_cpu_exit __inst = new("cpu_exit"); \
endclass

// 监控 memory model 的 rsp_flag/exit_flag 变化并触发 __cpu_bridge_rsp_event，放在 module 作用域。
// mem_path = memory 数组 hdl path；base_idx = mailbox 基址的 word index（rsp_flag = base_idx+130，exit_flag = base_idx+262）。
// C 退出时只写 exit_flag=2，事件模式也必须被它唤醒。用法：`aip_cpu_bridge_monitor(tb.ram.mem, 0)
`define aip_cpu_bridge_monitor(mem_path, base_idx) \
    always @(mem_path[(base_idx) + 130]) begin \
        if (mem_path[(base_idx) + 130] == 1) \
            -> aip_core_pkg::__cpu_bridge_rsp_event; \
    end \
    always @(mem_path[(base_idx) + 262]) begin \
        if (mem_path[(base_idx) + 262] == 2) \
            -> aip_core_pkg::__cpu_bridge_rsp_event; \
    end

// Tcl 友好的封装：把 aip_cpu_bridge 静态方法暴露为普通 task（注册宏 aip_cmd_task/aip_cmd_1i 需要 task 签名）。
// SV 类实例无法从 Tcl 构造，testbench 仍需调用 set_mem(mem) 提供 accessor。
class aip_cpu_bridge_ops;
    static aip_mem_accessor stored_mem = null;

    static function void set_mem(aip_mem_accessor m);
        stored_mem = m;
    endfunction

    // Tcl 可调；VCS Q-2020 不支持 int unsigned'(...) cast，故用 int + {32'h0, x} 显式零扩展。
    static task reinit(input int mbox_base);
        longint unsigned base_lu;
        if (stored_mem == null) begin
            `aip_error(("sv_cpu_bridge_reinit: mem_accessor 未注册, testbench 需先调 aip_cpu_bridge_ops::set_mem"));
            return;
        end
        base_lu = {32'h0, mbox_base};
        aip_cpu_bridge::init(stored_mem, base_lu);
    endtask

    static task set_timeout(input int ns);
        aip_cpu_bridge::set_timeout(real'(ns));
    endtask

    static task enable_irq();
        aip_cpu_bridge::enable_irq();
    endtask

    static task enable_event_mode();
        aip_cpu_bridge::enable_event_mode();
    endtask

    static task set_msip_path(input string path);
        aip_cpu_bridge::set_msip_path(path);
    endtask

    static task set_plic_path(input string path, input int src);
        aip_cpu_bridge::set_plic_path(path, src, 0);   // TCL 默认 word-RMW (single_bit=0)
    endtask

    static task show_status();
        `aip_info(("cpu_bridge: initialized=%0d mbox_base=0x%0h irq=%0d event=%0d timeout=%.0fns",
            aip_cpu_bridge::initialized, aip_cpu_bridge::mailbox_base,
            aip_cpu_bridge::irq_enabled, aip_cpu_bridge::event_mode,
            aip_cpu_bridge::timeout_ns));
    endtask
endclass

// Tcl 命令（sv_cpu_bridge_status/_set_timeout/_enable_irq/_enable_event_mode/_reinit/_set_msip_path）在 aip_core_pkg.sv
// 末尾注册：注册须在 aip_cmd.sv 之后，而 aip_cmd.sv 又须在本文件之后。

`endif // AIP_CPU_BRIDGE_SV
