`ifndef AIP_CPU_BRIDGE_SV
`define AIP_CPU_BRIDGE_SV

// Package IRQ signal — user connects to CPU IRQ pin
// Usage: assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;
reg __cpu_bridge_irq = 0;

// Package response event — triggered when CPU writes rsp_flag=1
// User must set up a monitor in testbench (see aip_cpu_bridge_monitor macro)
event __cpu_bridge_rsp_event;

// ============================================================
// aip_mem_accessor — abstract base class for backdoor memory access
// User implements wr_mem/rd_mem with project-specific hdl paths.
// ============================================================
virtual class aip_mem_accessor;
    pure virtual task wr_mem(input longint unsigned addr, input int unsigned data);
    pure virtual task rd_mem(input longint unsigned addr, output int unsigned data);
endclass

// ============================================================
// aip_cpu_bridge — send commands to CPU firmware via shared memory mailbox
//
// Mailbox layout (base + offset):
//   +0x000  cmd_flag    (4B)  1=pending 0=idle
//   +0x004  cmd_len     (4B)  command string length
//   +0x008  cmd_data    (512B) command string bytes
//   +0x208  rsp_flag    (4B)  1=ready 0=idle
//   +0x20C  rsp_status  (4B)  0=ok -1=error
//   +0x210  rsp_len     (4B)  response string length
//   +0x214  rsp_data    (512B) response string bytes
//   +0x414  async_flag  (4B)  1=async 0=sync
//
// Usage:
//   aip_cpu_bridge::init(mem_accessor, 64'h800E_0000);
//   aip_cpu_bridge::enable_irq();  // optional: pulse aip_core_pkg::__cpu_bridge_irq on send
//   assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;  // user connects in testbench
// ============================================================
class aip_cpu_bridge;

    // Mailbox offsets
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
    localparam int CMD_DATA_MAX = 512;

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

    // Initialize bridge with user-provided mem accessor and mailbox base address
    static function void init(aip_mem_accessor m, longint unsigned mbox_base);
        mem = m;
        mailbox_base = mbox_base;
        irq_enabled = 0;
        initialized = 1;
        `aip_info(("[AIP_CPU_BRIDGE] Initialized, mailbox_base=0x%0h", mbox_base));
    endfunction

    // Enable IRQ mode — send_cmd raises aip_core_pkg::__cpu_bridge_irq until ISR ACK
    // User must connect: assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;
    static function void enable_irq();
        irq_enabled = 1;
        `aip_info(("[AIP_CPU_BRIDGE] IRQ mode enabled (signal: __cpu_bridge_irq)"));
    endfunction

    // Enable event-driven mode — send_cmd uses @(__cpu_bridge_rsp_event)
    // instead of #10 polling. Requires user to set up monitor macro.
    // Usage:
    //   aip_cpu_bridge::enable_event_mode();
    //   `aip_cpu_bridge_monitor(tb.ram.mem, 0)  // in module scope
    static function void enable_event_mode();
        event_mode = 1;
        `aip_info(("[AIP_CPU_BRIDGE] Event-driven mode enabled (signal: __cpu_bridge_rsp_event)"));
    endfunction

    // Enable MSIP wake mode — send_cmd deposits MSIP0=1 to wake CPU from wfi.
    // path = HDL path to the CLINT MSIP0 register (testbench/SoC provides).
    // MSIP wake and event_mode are independent; caller controls event_mode separately.
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

    // Set response timeout (ns). Default 100us. Set 0 to disable.
    static function void set_timeout(real ns);
        timeout_ns = ns;
        `aip_info(("[AIP_CPU_BRIDGE] Timeout set to %.0f ns", ns));
    endfunction

    // Write a string to mailbox cmd_data area (one word per char)
    static task write_cmd_string(string s);
        int len;
        len = s.len();
        if (len > CMD_DATA_MAX) len = CMD_DATA_MAX;
        // Write length
        mem.wr_mem(mailbox_base + OFF_CMD_LEN, len);
        // Write chars as 32-bit words
        for (int i = 0; i < len; i++) begin
            begin
                int unsigned _ch = s[i];
                mem.wr_mem(mailbox_base + OFF_CMD_DATA + i * 4, _ch);
            end
        end
    endtask

    // Read response string from mailbox rsp_data area
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

    // Raise package IRQ signal (held until irq_ack_monitor drops it)
    // User connects: assign cpu.irq_ext[0] = aip_core_pkg::__cpu_bridge_irq;
    static task trigger_irq();
        if (irq_enabled) __cpu_bridge_irq = 1;
    endtask

    // ============================================================
    // IRQ ACK monitor — drops __cpu_bridge_irq when C ISR signals ack.
    // Started by start_monitors() (call once after init() if IRQ used).
    // ============================================================
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

    // Send command to CPU via mailbox
    // If async=0: waits for response, returns status and result string
    // If async=1: returns immediately after writing command
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

        // Write async flag
        begin
            int unsigned _async_val = is_async;
            mem.wr_mem(mailbox_base + OFF_ASYNC_FLAG, _async_val);
        end

        // Write command string
        write_cmd_string(cmd);

        // Set cmd_flag = 1 (must be last — C polls this)
        mem.wr_mem(mailbox_base + OFF_CMD_FLAG, 1);

        // Trigger IRQ if configured
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

        // Synchronous: fork — wait response vs timeout
        // 外层 fork-begin-join 隔离 disable fork 作用域
        begin
            bit timed_out;
            bit cpu_exited;
            timed_out = 0;
            cpu_exited = 0;
            rsp_flag = 0;

            fork
                begin
                    fork
                        // Branch 1: 等待响应（事件驱动 or 轮询）
                        begin
                            if (event_mode) begin
                                // 事件模式: 等 __cpu_bridge_rsp_event
                                // memory 变化 → monitor 触发事件 → 立即唤醒
                                @(__cpu_bridge_rsp_event);
                                // 事件触发后检查是否是 exit
                                mem.rd_mem(mailbox_base + OFF_EXIT_FLAG, rsp_flag);
                                if (rsp_flag == 2) begin
                                    cpu_exited = 1;
                                end else begin
                                    rsp_flag = 1;  // 标记响应到达
                                end
                            end else begin
                                // 轮询模式: #10 循环
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

                        // Branch 2: timeout 保护
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

            // 处理结果
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
                // 正常响应
                mem.rd_mem(mailbox_base + OFF_RSP_STATUS, rsp_status);
                read_rsp_string(result);
                status = int'(rsp_status);
                mem.wr_mem(mailbox_base + OFF_RSP_FLAG, 0);
                `aip_debug(("[AIP_CPU_BRIDGE] Response: status=%0d result=%s", status, result));
            end
        end
    endtask

    // Request CPU to exit cmd_loop (SV → C)
    // C 侧 cmd_loop 检测 exit_flag==1 后退出循环
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

    // Check if CPU requested exit (C → SV)
    // C 侧调 cmd_exit() 后 exit_flag==2, SV 侧检测到后处理
    // 返回: 0=未退出, 1=正常退出, -1=异常退出
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

// ============================================================
// Built-in CPU commands macro
// C 侧调 cmd_register_builtins()，SV 侧调此宏，两侧匹配
// Usage: `aip_cpu_bridge_builtins
// ============================================================
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

// ============================================================
// SV 后门命令宏: cpu_memset / cpu_memdump
// 不走 CPU，直接通过 aip_mem_accessor backdoor 访问
// 必须在 aip_cmd.sv 之后展开（依赖 aip_cmd 类）
// 通过 `aip_cpu_bridge_builtins 宏自动注册
// ============================================================
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
\
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

// ============================================================
// Exit commands:
//   cpu_exit         — TCL/SV 通知 C 退出 cmd_loop
//   (C 侧 cmd_exit) — C 通知 SV 异常退出（通过 exit_flag=2）
// ============================================================
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

// ============================================================
// Monitor macro — 监控 memory model 的 rsp_flag 变化，触发事件
// 放在 module 作用域（initial/always 块所在的地方）
//
// 参数:
//   mem_path  — memory 数组的 hdl path (如 tb.ram.mem)
//   base_idx  — mailbox 基地址对应的 word index (如 0x800E0000>>2)
//
// rsp_flag offset = 0x208, word index = base_idx + 0x208/4 = base_idx + 130
//
// Usage:
//   `aip_cpu_bridge_monitor(tb.ram.mem, 0)       // base_idx=0
//   `aip_cpu_bridge_monitor(soc.ram.mem, 960)     // 0xF00>>2 = 960
// ============================================================
`define aip_cpu_bridge_monitor(mem_path, base_idx) \
    always @(mem_path[(base_idx) + 130]) begin \
        if (mem_path[(base_idx) + 130] == 1) \
            -> aip_core_pkg::__cpu_bridge_rsp_event; \
    end

// ============================================================
// aip_cpu_bridge_ops — TCL-friendly wrapper exposing aip_cpu_bridge static
// methods as plain SV tasks (注册宏 aip_cmd_task / aip_cmd_1i 需 task 签名)
//
// 注册命令在 aip_cpu_bridge_cmds.sv (必须 include 在 aip_cmd.sv 之后)
//
// mem_accessor 仍需 testbench 调 aip_cpu_bridge_ops::set_mem(mem) 提供
// (SV class 实例无法从 TCL 构造)
// ============================================================
class aip_cpu_bridge_ops;
    static aip_mem_accessor stored_mem = null;

    // testbench 调用一次, 提供 mem accessor
    static function void set_mem(aip_mem_accessor m);
        stored_mem = m;
    endfunction

    // 重新 init mailbox base (TCL 可调, mem 用之前注册的)
    // VCS Q-2020 不支持 int unsigned'(...) cast, 用 int + {32'h0, x} 显式 zero-extend
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

// TCL 注册宏调用在 aip_core_pkg.sv 末尾 (须在 aip_cmd.sv include 之后,
// 但 aip_cmd.sv 又必须在本文件之后, 形成循环依赖, 只能放 pkg 末尾)
// 注册的 TCL 命令:
//   sv_cpu_bridge_status / _set_timeout / _enable_irq / _enable_event_mode / _reinit / _set_msip_path

`endif // AIP_CPU_BRIDGE_SV
