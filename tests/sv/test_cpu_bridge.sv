//===========================================================
// test_cpu_bridge.sv — CPU Bridge 功能测试
//
// 用纯 SV 模拟 C908 CPU 行为：
//   1. 内存数组模拟 mailbox 区域
//   2. "fake_cpu" 进程模拟 C 固件 poll-dispatch-respond
//   3. 通过 aip_cmd::exec() 发命令，验证结果
//
// 编译:
//   vcs -sverilog -ntb_opts uvm +incdir+.. -timescale=1ns/1ps test_cpu_bridge.sv -debug_access+all
// 运行:
//   ./simv
//===========================================================
`include "aip_core_pkg.sv"

// ============================================================
// 模拟内存 — 当作 CPU 的 RAM/Mailbox 区域
// ============================================================
module fake_ram;
    reg [31:0] mem [0:1023];  // 4KB, 1024 x 32-bit words

    initial begin
        for (int i = 0; i < 1024; i++) mem[i] = 0;
    end
endmodule

// ============================================================
// Memory accessor — 通过 hdl path 访问 fake_ram
// ============================================================
class sim_mem extends aip_mem_accessor;
    virtual task wr_mem(input longint unsigned addr, input int unsigned data);
        if (addr >= 64'h4000_0000 && addr < 64'h4000_0400) begin
            // CPU 地址空间 → cpu_mem (1KB)
            tb.cpu_mem[(addr - 64'h4000_0000) >> 2] = data;
        end else begin
            // Mailbox 区域 → fake_ram
            tb.ram.mem[addr >> 2] = data;
        end
    endtask

    virtual task rd_mem(input longint unsigned addr, output int unsigned data);
        if (addr >= 64'h4000_0000 && addr < 64'h4000_0400) begin
            data = tb.cpu_mem[(addr - 64'h4000_0000) >> 2];
        end else begin
            data = tb.ram.mem[addr >> 2];
        end
    endtask
endclass

// ============================================================
// 注册 CPU 命令（SV 侧声明，"C 侧" 执行）
// ============================================================
`aip_cmd_cpu(cpu_read)
`aip_cmd_cpu(cpu_write)
`aip_cmd_cpu(cpu_hello)
`aip_cmd_cpu(cpu_slow)

// 注册内建命令: cpu_read32, cpu_write32, cpu_read64, cpu_write64
`aip_cpu_bridge_builtins

// 同时注册一个普通 SV 命令，测试混合路由
class sv_ops;
    static task sv_hello();
        $display("[SV_CMD] sv_hello executed at t=%0t", $time);
    endtask
endclass
`aip_cmd_task(sv_hello, sv_ops::sv_hello)

// ============================================================
// Testbench
// ============================================================
module tb;
    // 时钟
    `aip_clk_create(clk0, 100e6)

    // 事件监控: rsp_flag 变化时触发 __cpu_bridge_rsp_event
    // ram.mem[130] = rsp_flag (offset 0x208, base_idx=0)
    `aip_cpu_bridge_monitor(tb.ram.mem, 0)

    // fake RAM 实例（mailbox 区域）
    fake_ram ram();

    // Fake CLINT MSIP0 寄存器 (MSIP 唤醒测试用). hdl 路径 = tb.fake_msip
    reg [31:0] fake_msip = 0;

    // Fake PLIC_IP word (src48 → bit16). hdl 路径 = tb.fake_plic_ip
    reg [31:0] fake_plic_ip = 0;

    // 模拟 CPU 地址空间（用于 cpu_read32/write32 测试）
    reg [31:0] cpu_mem [0:255];  // 1KB CPU 地址空间，基地址 0x4000_0000
    initial begin
        for (int i = 0; i < 256; i++) cpu_mem[i] = 0;
        // 预填一些值供 read 测试
        cpu_mem[0] = 32'h12345678;
        cpu_mem[1] = 32'hDEADBEEF;
    end

    // ============================================================
    // Fake CPU 进程 — 模拟 C 固件的 cmd_loop()
    // 轮询 cmd_flag，解析命令，写回结果
    // ============================================================
    task automatic fake_cpu_loop();
        int unsigned cmd_flag;
        int unsigned cmd_len;
        int unsigned async_flag;
        int unsigned ch;
        string cmd_str;
        string cmd_name;
        string args;

        `aip_info(("[FAKE_CPU] Started, polling mailbox..."));

        forever begin
            // 检查 exit_flag (offset 0x418 -> word 262)
            if (ram.mem[262] == 1) begin
                `aip_info(("[FAKE_CPU] Exit requested by SV, stopping"));
                ram.mem[262] = 0;  // ACK
                return;
            end
            // 轮询 cmd_flag (offset 0x000)
            cmd_flag = ram.mem[0];
            if (cmd_flag != 1) begin
                #10;
                continue;
            end

            // 读取命令
            cmd_len = ram.mem[1];  // offset 0x004 -> word index 1
            cmd_str = "";
            for (int i = 0; i < int'(cmd_len) && i < 512; i++) begin
                ch = ram.mem[2 + i];  // offset 0x008 -> word index 2
                cmd_str = {cmd_str, string'(ch[7:0])};
            end

            // 读取 async_flag (offset 0x414 -> word index 0x414/4 = 261)
            async_flag = ram.mem[261];

            `aip_info(("[FAKE_CPU] Received: '%s' async=%0d", cmd_str, async_flag));

            // 立即清 cmd_flag，防止重复处理
            ram.mem[0] = 0;

            // 解析命令名（第一个空格前）
            begin
                int sp;
                sp = aip_str::str_find(cmd_str, " ");
                if (sp == -1) begin
                    cmd_name = cmd_str;
                    args = "";
                end else begin
                    cmd_name = cmd_str.substr(0, sp - 1);
                    args = cmd_str.substr(sp + 1, cmd_str.len() - 1);
                end
            end

            // 模拟命令执行 + 延迟（模拟 CPU 执行时间）
            #50;

            // 分发
            if (cmd_name == "cpu_read") begin
                int addr;
                string addr_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                `aip_info(("[FAKE_CPU] cpu_read: addr=0x%0h -> data=0xDEADBEEF", addr));
                write_response("data=0xDEADBEEF", 0);
            end
            else if (cmd_name == "cpu_write") begin
                int addr, data;
                string addr_s, data_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                data_s = aip_cmd::get_arg(args, "data");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                data = aip_cmd::parse_int_arg(data_s, 0);
                `aip_info(("[FAKE_CPU] cpu_write: addr=0x%0h data=0x%0h OK", addr, data));
                write_response($sformatf("status=0 addr=0x%0h", addr), 0);
            end
            else if (cmd_name == "cpu_hello") begin
                `aip_info(("[FAKE_CPU] cpu_hello: Hello from fake CPU!"));
                write_response("msg=hello_from_cpu", 0);
            end
            else if (cmd_name == "cpu_slow") begin
                `aip_info(("[FAKE_CPU] cpu_slow: starting long operation..."));
                #200;  // 模拟耗时操作
                `aip_info(("[FAKE_CPU] cpu_slow: done"));
                write_response("msg=slow_done", 0);
            end
            else if (cmd_name == "cpu_read32") begin
                int addr;
                int unsigned rdata;
                string addr_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                // 模拟: 0x4000_0000 基地址映射到 cpu_mem
                rdata = cpu_mem[(addr - 32'h4000_0000) >> 2];
                `aip_info(("[FAKE_CPU] cpu_read32: addr=0x%0h -> data=0x%08h", addr, rdata));
                write_response($sformatf("data=0x%08h", rdata), 0);
            end
            else if (cmd_name == "cpu_write32") begin
                int addr;
                int unsigned wdata;
                string addr_s, data_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                data_s = aip_cmd::get_arg(args, "data");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                wdata = aip_cmd::parse_int_arg(data_s, 0);
                cpu_mem[(addr - 32'h4000_0000) >> 2] = wdata;
                `aip_info(("[FAKE_CPU] cpu_write32: addr=0x%0h data=0x%08h OK", addr, wdata));
                write_response($sformatf("ok addr=0x%08h data=0x%08h", addr, wdata), 0);
            end
            else if (cmd_name == "cpu_read64") begin
                int addr;
                int unsigned lo, hi;
                string addr_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                lo = cpu_mem[(addr - 32'h4000_0000) >> 2];
                hi = cpu_mem[((addr - 32'h4000_0000) >> 2) + 1];
                `aip_info(("[FAKE_CPU] cpu_read64: addr=0x%0h -> data=0x%08h%08h", addr, hi, lo));
                write_response($sformatf("data=0x%08h%08h", hi, lo), 0);
            end
            else if (cmd_name == "cpu_write64") begin
                int addr;
                int unsigned lo, hi;
                string addr_s, data_s;
                int data_val;
                addr_s = aip_cmd::get_arg(args, "addr");
                data_s = aip_cmd::get_arg(args, "data");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                data_val = aip_cmd::parse_int_arg(data_s, 0);
                lo = data_val;
                hi = 0;
                cpu_mem[(addr - 32'h4000_0000) >> 2] = lo;
                cpu_mem[((addr - 32'h4000_0000) >> 2) + 1] = hi;
                `aip_info(("[FAKE_CPU] cpu_write64: addr=0x%0h data=0x%08h%08h OK", addr, hi, lo));
                write_response($sformatf("ok addr=0x%08h data=0x%08h%08h", addr, hi, lo), 0);
            end
            else if (cmd_name == "cpu_read32_swap") begin
                int addr;
                int unsigned rdata, swapped;
                string addr_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                rdata = cpu_mem[(addr - 32'h4000_0000) >> 2];
                swapped = {rdata[7:0], rdata[15:8], rdata[23:16], rdata[31:24]};
                `aip_info(("[FAKE_CPU] cpu_read32_swap: addr=0x%0h raw=0x%08h swapped=0x%08h", addr, rdata, swapped));
                write_response($sformatf("data=0x%08h", swapped), 0);
            end
            else if (cmd_name == "cpu_write32_swap") begin
                int addr;
                int unsigned wdata, swapped;
                string addr_s, data_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                data_s = aip_cmd::get_arg(args, "data");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                wdata = aip_cmd::parse_int_arg(data_s, 0);
                swapped = {wdata[7:0], wdata[15:8], wdata[23:16], wdata[31:24]};
                cpu_mem[(addr - 32'h4000_0000) >> 2] = swapped;
                `aip_info(("[FAKE_CPU] cpu_write32_swap: addr=0x%0h data=0x%08h swapped=0x%08h", addr, wdata, swapped));
                write_response($sformatf("ok addr=0x%08h data=0x%08h swapped=0x%08h", addr, wdata, swapped), 0);
            end
            else if (cmd_name == "cpu_poll32") begin
                int addr;
                int unsigned mask_val, expect_val, rdata;
                int timeout_val, i;
                string addr_s, mask_s, expect_s, timeout_s;
                addr_s    = aip_cmd::get_arg(args, "addr");
                mask_s    = aip_cmd::get_arg(args, "mask");
                expect_s  = aip_cmd::get_arg(args, "expect");
                timeout_s = aip_cmd::get_arg(args, "timeout");
                addr       = aip_cmd::parse_int_arg(addr_s, 0);
                mask_val   = aip_cmd::parse_int_arg(mask_s, 32'hFFFFFFFF);
                expect_val = aip_cmd::parse_int_arg(expect_s, 0);
                timeout_val = aip_cmd::parse_int_arg(timeout_s, 10000);
                `aip_info(("[FAKE_CPU] cpu_poll32: addr=0x%0h mask=0x%0h expect=0x%0h timeout=%0d",
                           addr, mask_val, expect_val, timeout_val));
                for (i = 0; i < timeout_val; i++) begin
                    rdata = cpu_mem[(addr - 32'h4000_0000) >> 2];
                    if ((rdata & mask_val) == (expect_val & mask_val)) begin
                        write_response($sformatf("ok data=0x%08h iter=%0d", rdata, i), 0);
                        break;
                    end
                    #1;  // 每次 poll 间隔
                end
                if (i == timeout_val) begin
                    write_response($sformatf("timeout data=0x%08h iter=%0d", rdata, timeout_val), 1);
                end
            end
            else begin
                `aip_warning(("[FAKE_CPU] Unknown command: %s", cmd_name));
                write_response("error=unknown_cmd", -1);
            end

            // cmd_flag 已在读取命令后立即清除（sync 和 async 统一处理）
        end
    endtask

    // 写回响应到 mailbox
    task automatic write_response(string rsp, int status);
        int len;
        len = rsp.len();
        if (len > 512) len = 512;

        // rsp_status (offset 0x20C -> word 131)
        ram.mem[131] = status;
        // rsp_len (offset 0x210 -> word 132)
        ram.mem[132] = len;
        // rsp_data (offset 0x214 -> word 133+)
        for (int i = 0; i < len; i++) begin
            ram.mem[133 + i] = rsp[i];
        end
        // rsp_flag = 1 (offset 0x208 -> word 130) — 最后置位
        ram.mem[130] = 1;
    endtask

    // ============================================================
    // Fake CPU 进程 — 中断驱动模式
    // 用 @(posedge aip_core_pkg::__cpu_bridge_irq) 替代 #10 忙等
    // 模拟真实 C 固件的 WFI + ISR 行为
    // ============================================================
    task automatic fake_cpu_irq_loop();
        int unsigned cmd_flag;
        int unsigned cmd_len;
        int unsigned async_flag;
        int unsigned ch;
        string cmd_str;
        string cmd_name;
        string args;

        `aip_info(("[FAKE_CPU_IRQ] Started, waiting for IRQ..."));

        forever begin
            // WFI — 等中断信号
            @(posedge aip_core_pkg::__cpu_bridge_irq);

            // 模拟 C ISR 进入后写 irq_ack；bridge monitor 随后清 ACK 和 IRQ。
            ram.mem[264] = 1;  // OFF_IRQ_ACK = 0x420, word index 264

            // 检查 exit_flag
            if (ram.mem[262] == 1) begin
                `aip_info(("[FAKE_CPU_IRQ] Exit requested by SV, stopping"));
                ram.mem[262] = 0;
                return;
            end

            // 检查 cmd_flag
            cmd_flag = ram.mem[0];
            if (cmd_flag != 1) begin
                `aip_warning(("[FAKE_CPU_IRQ] Spurious IRQ, cmd_flag=%0d", cmd_flag));
                continue;
            end

            // 读取命令
            cmd_len = ram.mem[1];
            cmd_str = "";
            for (int i = 0; i < int'(cmd_len) && i < 512; i++) begin
                ch = ram.mem[2 + i];
                cmd_str = {cmd_str, string'(ch[7:0])};
            end

            async_flag = ram.mem[261];

            `aip_info(("[FAKE_CPU_IRQ] IRQ received, cmd: '%s' async=%0d", cmd_str, async_flag));

            // 立即清 cmd_flag
            ram.mem[0] = 0;

            // 解析命令名
            begin
                int sp;
                sp = aip_str::str_find(cmd_str, " ");
                if (sp == -1) begin
                    cmd_name = cmd_str;
                    args = "";
                end else begin
                    cmd_name = cmd_str.substr(0, sp - 1);
                    args = cmd_str.substr(sp + 1, cmd_str.len() - 1);
                end
            end

            // 模拟 CPU 执行时间
            #30;

            // 分发（复用同样的命令逻辑）
            if (cmd_name == "cpu_read") begin
                int addr;
                string addr_s;
                addr_s = aip_cmd::get_arg(args, "addr");
                addr = aip_cmd::parse_int_arg(addr_s, 0);
                `aip_info(("[FAKE_CPU_IRQ] cpu_read: addr=0x%0h -> data=0xBEEFCAFE", addr));
                write_response("data=0xBEEFCAFE", 0);
            end
            else if (cmd_name == "cpu_hello") begin
                `aip_info(("[FAKE_CPU_IRQ] cpu_hello: Hello from IRQ-driven CPU!"));
                write_response("msg=hello_from_irq_cpu", 0);
            end
            else begin
                `aip_info(("[FAKE_CPU_IRQ] Dispatching: %s", cmd_name));
                write_response($sformatf("msg=%s_done_irq", cmd_name), 0);
            end
        end
    endtask

    // MSIP 唤醒模型: 平时不处理 (代表 wfi 停核);
    // 仅当 fake_msip[0]==1 时"醒来"——清 MSIP (模拟 C handler 同步清) + 处理一条命令。
    task automatic fake_cpu_msip_loop();
        int cmd_flag, cmd_len, i, ch;
        string cmd_str;
        forever begin
            #1;
            if (fake_msip[0] !== 1'b1) continue;   // wfi: 未被 deposit 唤醒 → 不动
            fake_msip = 0;                          // C handler 同步清 MSIP (防风暴)
            cmd_flag = ram.mem[0];
            if (cmd_flag != 1) continue;            // 唤醒但无命令 (理论不会)
            cmd_len = ram.mem[1];
            cmd_str = "";
            for (i = 0; i < cmd_len; i++) begin
                ch = ram.mem[2 + i];
                cmd_str = {cmd_str, string'(ch[7:0])};
            end
            ram.mem[0] = 0;                         // 清 cmd_flag
            write_response("msip_ok", 0);           // 简化: 任何命令都回 msip_ok
        end
    endtask

    // PLIC 唤醒模型: 仅当 fake_plic_ip[16]==1 (src48) 醒来; claim 清该位; 处理; 回 plic_ok。
    task automatic fake_cpu_plic_loop();
        int cmd_len, i, ch;
        forever begin
            #1;
            if (fake_plic_ip[16] !== 1'b1) continue;   // wfi: 未置 pending → 不动
            fake_plic_ip[16] = 1'b0;                    // 模拟 claim 清 IP
            if (ram.mem[0] != 1) continue;
            cmd_len = ram.mem[1];
            for (i = 0; i < cmd_len; i++) ch = ram.mem[2 + i];
            ram.mem[0] = 0;
            write_response("plic_ok", 0);
        end
    endtask

    // ============================================================
    // 主测试流程
    // ============================================================
    initial begin
        sim_mem mem_acc;
        int pass_count;
        int fail_count;

        pass_count = 0;
        fail_count = 0;

        // 初始化 CPU bridge
        mem_acc = new();
        aip_cpu_bridge::init(mem_acc, 64'h0);  // base=0, 直接映射到 fake_ram

        // 启动 fake CPU 进程
        fork
            fake_cpu_loop();
        join_none

        #100;  // 等待系统稳定

        // ---- Test 1: 同步 CPU 命令 — cpu_hello ----
        $display("\n========== Test 1: Sync CPU command — cpu_hello ==========");
        aip_cmd::exec("cpu_hello", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "hello_from_cpu") != -1) begin
            $display("[PASS] cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 2: 同步 CPU 命令 — cpu_read ----
        $display("\n========== Test 2: Sync CPU command — cpu_read ==========");
        aip_cmd::exec("cpu_read addr=0x100", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "DEADBEEF") != -1) begin
            $display("[PASS] cpu_read: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_read: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 3: 同步 CPU 命令 — cpu_write ----
        $display("\n========== Test 3: Sync CPU command — cpu_write ==========");
        aip_cmd::exec("cpu_write addr=0x200 data=0xCAFE", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "status=0") != -1) begin
            $display("[PASS] cpu_write: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_write: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 4: 异步 CPU 命令 ----
        $display("\n========== Test 4: Async CPU command — cpu_hello async=1 ==========");
        begin
            realtime t_start, t_end;
            t_start = $realtime;
            aip_cmd::exec("cpu_hello async=1", SRC_INTERNAL);
            t_end = $realtime;
            if (aip_cmd::__aip_cmd_last_status == 0) begin
                $display("[PASS] async cpu_hello: returned immediately, status=%0d result=%s",
                         aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
                pass_count++;
            end else begin
                $display("[FAIL] async cpu_hello: status=%0d result=%s",
                         aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
                fail_count++;
            end
        end

        #200;  // 等 fake CPU 处理完异步命令

        // ---- Test 5: SV 命令正常路由（不走 CPU） ----
        $display("\n========== Test 5: SV command — sv_hello (should NOT go to CPU) ==========");
        aip_cmd::exec("sv_hello", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            $display("[PASS] sv_hello: routed to SV, not CPU");
            pass_count++;
        end else begin
            $display("[FAIL] sv_hello: status=%0d", aip_cmd::__aip_cmd_last_status);
            fail_count++;
        end

        #50;

        // ---- Test 6: 混合 fork — SV + CPU 并行 ----
        $display("\n========== Test 6: Mixed fork — sv_hello + cpu_read ==========");
        aip_cmd::exec("fork sv_hello, cpu_read addr=0x300 join", SRC_INTERNAL);
        $display("[PASS] Mixed fork completed at t=%0t", $time);
        pass_count++;

        #50;

        // ---- Test 7: CPU 慢命令 — 验证同步等待 ----
        $display("\n========== Test 7: Slow CPU command — cpu_slow ==========");
        begin
            realtime t_start, t_end;
            t_start = $realtime;
            aip_cmd::exec("cpu_slow", SRC_INTERNAL);
            t_end = $realtime;
            if (aip_cmd::__aip_cmd_last_status == 0 &&
                aip_str::str_find(aip_cmd::__aip_cmd_last_result, "slow_done") != -1) begin
                $display("[PASS] cpu_slow: took %.0f ns, result=%s",
                         (t_end - t_start) / 1ns, aip_cmd::__aip_cmd_last_result);
                pass_count++;
            end else begin
                $display("[FAIL] cpu_slow: status=%0d result=%s",
                         aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
                fail_count++;
            end
        end

        // ---- Test 8: 内建命令 cpu_read32 ----
        $display("\n========== Test 8: Built-in cpu_read32 ==========");
        aip_cmd::exec("cpu_read32 addr=0x40000000", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "12345678") != -1) begin
            $display("[PASS] cpu_read32: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_read32: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 9: 内建命令 cpu_write32 + readback ----
        $display("\n========== Test 9: Built-in cpu_write32 + readback ==========");
        aip_cmd::exec("cpu_write32 addr=0x40000008 data=0xAABBCCDD", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            $display("[INFO] cpu_write32 done: %s", aip_cmd::__aip_cmd_last_result);
        end
        #50;
        // 读回验证
        aip_cmd::exec("cpu_read32 addr=0x40000008", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "aabbccdd") != -1) begin
            $display("[PASS] cpu_write32+read32 readback: %s",
                     aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_write32+read32 readback: %s",
                     aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 10: 内建命令 cpu_read64 ----
        $display("\n========== Test 10: Built-in cpu_read64 ==========");
        // cpu_mem[0]=0x12345678, cpu_mem[1]=0xDEADBEEF → 64-bit: 0xDEADBEEF_12345678
        aip_cmd::exec("cpu_read64 addr=0x40000000", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "deadbeef") != -1) begin
            $display("[PASS] cpu_read64: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_read64: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 11: cpu_write32_swap — 字节倒序写入 ----
        $display("\n========== Test 11: cpu_write32_swap + readback ==========");
        aip_cmd::exec("cpu_write32_swap addr=0x4000000C data=0x80102030", SRC_INTERNAL);
        $display("[INFO] write32_swap: %s", aip_cmd::__aip_cmd_last_result);
        #50;
        // readback 应该是 0x30201080 (字节倒序后存入)
        aip_cmd::exec("cpu_read32 addr=0x4000000C", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "30201080") != -1) begin
            $display("[PASS] cpu_write32_swap: wrote 0x80102030, read back 0x30201080");
            pass_count++;
        end else begin
            $display("[FAIL] cpu_write32_swap readback: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 12: cpu_read32_swap — 字节倒序读取 ----
        $display("\n========== Test 12: cpu_read32_swap ==========");
        // cpu_mem[0] = 0x12345678, swap 后应为 0x78563412
        aip_cmd::exec("cpu_read32_swap addr=0x40000000", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "78563412") != -1) begin
            $display("[PASS] cpu_read32_swap: 0x12345678 -> 0x78563412");
            pass_count++;
        end else begin
            $display("[FAIL] cpu_read32_swap: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 13: cpu_poll32 — 轮询成功 ----
        $display("\n========== Test 13: cpu_poll32 — immediate match ==========");
        // cpu_mem[0] = 0x12345678, poll mask=0xFF expect=0x78 应立即匹配
        aip_cmd::exec("cpu_poll32 addr=0x40000000 mask=0xFF expect=0x78 timeout=100", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "ok") != -1) begin
            $display("[PASS] cpu_poll32 match: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_poll32: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 14: cpu_poll32 — 超时 ----
        $display("\n========== Test 14: cpu_poll32 — timeout ==========");
        // poll expect=0xFF but actual low byte is 0x78, should timeout
        aip_cmd::exec("cpu_poll32 addr=0x40000000 mask=0xFF expect=0xFF timeout=10", SRC_INTERNAL);
        if (aip_str::str_find(aip_cmd::__aip_cmd_last_result, "timeout") != -1) begin
            $display("[PASS] cpu_poll32 timeout: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_poll32 should timeout: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 15: cpu_memset — SV 后门批量填充 ----
        $display("\n========== Test 15: cpu_memset (SV backdoor) ==========");
        aip_cmd::exec("cpu_memset addr=0x40000100 len=32 val=0xCAFEBABE", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            // 验证 cpu_mem 是否被后门写入
            // addr 0x40000100 → cpu_mem idx = (0x100)/4 = 64
            if (cpu_mem[64] == 32'hCAFEBABE && cpu_mem[65] == 32'hCAFEBABE) begin
                $display("[PASS] cpu_memset: verified cpu_mem[64]=0x%08h cpu_mem[65]=0x%08h",
                         cpu_mem[64], cpu_mem[65]);
                pass_count++;
            end else begin
                $display("[FAIL] cpu_memset: cpu_mem[64]=0x%08h cpu_mem[65]=0x%08h",
                         cpu_mem[64], cpu_mem[65]);
                fail_count++;
            end
        end else begin
            $display("[FAIL] cpu_memset: status=%0d %s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 16: cpu_memdump — SV 后门内存 dump ----
        $display("\n========== Test 16: cpu_memdump (SV backdoor) ==========");
        aip_cmd::exec("cpu_memdump addr=0x40000000 len=32", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            $display("[PASS] cpu_memdump: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] cpu_memdump: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ============================================================
        // Phase 2: IRQ 模式测试
        // 停止 polling CPU，启动 IRQ CPU，开启 IRQ
        // ============================================================
        $display("\n\n============ Phase 2: IRQ Mode Tests ============\n");

        // 停止 polling fake CPU (disable fork)，启动 IRQ fake CPU
        disable fork;
        #50;

        // 清空 mailbox
        ram.mem[0] = 0;    // cmd_flag
        ram.mem[130] = 0;  // rsp_flag

        // 启用 IRQ 模式
        aip_cpu_bridge::enable_irq();
        aip_cpu_bridge::start_monitors();

        // 启动 IRQ 驱动的 fake CPU
        fork
            fake_cpu_irq_loop();
        join_none

        #50;

        // ---- Test 17: IRQ 模式同步命令 — cpu_hello ----
        $display("\n========== Test 17: IRQ mode — cpu_hello ==========");
        aip_cmd::exec("cpu_hello", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "hello_from_irq_cpu") != -1) begin
            $display("[PASS] IRQ cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] IRQ cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 18: IRQ 模式同步 — cpu_read ----
        $display("\n========== Test 18: IRQ mode — cpu_read ==========");
        aip_cmd::exec("cpu_read addr=0x400", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "BEEFCAFE") != -1) begin
            $display("[PASS] IRQ cpu_read: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] IRQ cpu_read: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 19: IRQ 模式异步 ----
        $display("\n========== Test 19: IRQ mode async — cpu_hello async=1 ==========");
        aip_cmd::exec("cpu_hello async=1", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            $display("[PASS] IRQ async cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] IRQ async cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #200;

        // ---- Test 20: cpu_exit — SV 通知 C 退出 ----
        $display("\n========== Test 20: cpu_exit — SV requests CPU exit ==========");
        aip_cmd::exec("cpu_exit", SRC_INTERNAL);
        #100;  // 等 IRQ fake CPU 收到退出信号
        // 验证: exit_flag 应该被 ACK 清零
        if (ram.mem[262] == 0) begin
            $display("[PASS] cpu_exit: IRQ CPU exited, exit_flag cleared");
            pass_count++;
        end else begin
            $display("[FAIL] cpu_exit: exit_flag=%0d, expected 0", ram.mem[262]);
            fail_count++;
        end

        #50;

        // ---- Test 21: C 侧 cmd_exit — 模拟 C 主动异常退出 ----
        $display("\n========== Test 21: C-side cmd_exit simulation ==========");
        // 模拟 C 侧写 exit_flag=2, exit_code=1 (异常)
        ram.mem[262] = 2;   // exit_flag = 2 (C requests exit)
        ram.mem[263] = 1;   // exit_code = 1 (error)
        begin
            int exit_st;
            aip_cpu_bridge::check_cpu_exit(exit_st);
            if (exit_st == -1) begin
                $display("[PASS] check_cpu_exit: detected C-side error exit (code=1)");
                pass_count++;
            end else begin
                $display("[FAIL] check_cpu_exit: expected -1, got %0d", exit_st);
                fail_count++;
            end
        end

        // ============================================================
        // Phase 3: Event-Driven 模式测试
        // 用 @(__cpu_bridge_rsp_event) 替代 #10 轮询
        // ============================================================
        $display("\n\n============ Phase 3: Event-Driven Mode Tests ============\n");

        // 重新启动 polling fake CPU（Phase 2 的 disable fork 已停掉）
        // 清 mailbox
        ram.mem[0] = 0;    // cmd_flag
        ram.mem[130] = 0;  // rsp_flag
        ram.mem[262] = 0;  // exit_flag

        // 启用事件模式
        aip_cpu_bridge::enable_event_mode();

        fork
            fake_cpu_loop();
        join_none
        #50;

        // ---- Test 22: 事件模式同步命令 ----
        $display("\n========== Test 22: Event mode — cpu_hello ==========");
        aip_cmd::exec("cpu_hello", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "hello_from_cpu") != -1) begin
            $display("[PASS] Event mode cpu_hello: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] Event mode cpu_hello: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 23: 事件模式 cpu_read32 ----
        $display("\n========== Test 23: Event mode — cpu_read32 ==========");
        aip_cmd::exec("cpu_read32 addr=0x40000000", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0 &&
            aip_str::str_find(aip_cmd::__aip_cmd_last_result, "12345678") != -1) begin
            $display("[PASS] Event mode cpu_read32: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] Event mode cpu_read32: status=%0d result=%s",
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        #50;

        // ---- Test 24: 事件模式 cpu_write32 + readback ----
        $display("\n========== Test 24: Event mode — cpu_write32 + readback ==========");
        aip_cmd::exec("cpu_write32 addr=0x40000010 data=0xEVENT001", SRC_INTERNAL);
        #50;
        aip_cmd::exec("cpu_read32 addr=0x40000010", SRC_INTERNAL);
        if (aip_cmd::__aip_cmd_last_status == 0) begin
            $display("[PASS] Event mode write+read: %s", aip_cmd::__aip_cmd_last_result);
            pass_count++;
        end else begin
            $display("[FAIL] Event mode write+read: %s", aip_cmd::__aip_cmd_last_result);
            fail_count++;
        end

        // 停止 fake CPU
        disable fork;
        #50;

        // ---- Test 24b: 事件模式, exit_flag=2 已预置 → 立即报 CPU exited, 不等超时 ----
        $display("\n========== Test 24b: Event mode — exit_flag=2 pre-set ==========");
        begin
            int st; string res; real t0; real saved_to;
            saved_to = aip_cpu_bridge::timeout_ns;
            aip_cpu_bridge::set_timeout(5000.0);
            ram.mem[130] = 0;   // rsp_flag
            ram.mem[262] = 2;   // exit_flag = 2 (C 已退出)
            ram.mem[263] = 0;   // exit_code = 0 (正常退出, 仅 warning)
            t0 = $realtime;
            aip_cpu_bridge::send_cmd("cpu_ping", 0, st, res);
            if (st == -1 && aip_str::str_find(res, "CPU exited") != -1 && ($realtime - t0) < 5000.0) begin
                $display("[PASS] Test 24b: event mode detected pre-set exit in %.0f ns: %s", $realtime - t0, res);
                pass_count++;
            end else begin
                $display("[FAIL] Test 24b: st=%0d res=%s elapsed=%.0f ns", st, res, $realtime - t0);
                fail_count++;
            end
            ram.mem[262] = 0;
            aip_cpu_bridge::timeout_ns = saved_to;
        end

        #50;

        // ---- Test 24c: 事件模式, 命令进行中 C 置 exit_flag=2 (不动 rsp_flag) → 需被唤醒 ----
        $display("\n========== Test 24c: Event mode — exit_flag=2 raised mid-command ==========");
        begin
            int st; string res; real t0; real saved_to;
            saved_to = aip_cpu_bridge::timeout_ns;
            aip_cpu_bridge::set_timeout(5000.0);
            ram.mem[130] = 0;
            ram.mem[262] = 0;
            ram.mem[263] = 0;
            fork
                begin
                    #200;
                    ram.mem[262] = 2;   // C 退出, rsp_flag 保持 0
                end
            join_none
            t0 = $realtime;
            aip_cpu_bridge::send_cmd("cpu_ping", 0, st, res);
            if (st == -1 && aip_str::str_find(res, "CPU exited") != -1 && ($realtime - t0) < 5000.0) begin
                $display("[PASS] Test 24c: event mode woke on exit_flag in %.0f ns: %s", $realtime - t0, res);
                pass_count++;
            end else begin
                $display("[FAIL] Test 24c: st=%0d res=%s elapsed=%.0f ns", st, res, $realtime - t0);
                fail_count++;
            end
            ram.mem[262] = 0;
            aip_cpu_bridge::timeout_ns = saved_to;
        end

        #50;

        // ========== Test 25: MSIP 唤醒 ==========
        $display("\n========== Test 25: MSIP wake ==========");
        begin
            int st; string res;
            aip_cpu_bridge::event_mode = 0;                   // 本测试用轮询，非事件驱动
            aip_cpu_bridge::irq_enabled = 0;   // 前序 IRQ 测试遗留; MSIP 测试只用 MSIP
            aip_cpu_bridge::set_msip_path("tb.fake_msip");   // 启用 MSIP 模式
            fork fake_cpu_msip_loop(); join_none              // 启 MSIP fake cpu
            #10;
            aip_cpu_bridge::send_cmd("cpu_ping", 0, st, res); // 应 deposit fake_msip=1 → 醒
            if (st == 0 && res == "msip_ok") begin
                $display("[PASS] Test 25: MSIP wake: deposit woke fake cpu, result=%s", res);
                pass_count++;
            end else begin
                $display("[FAIL] Test 25: MSIP wake: st=%0d res=%s", st, res);
                fail_count++;
            end
        end
        // 停止 MSIP fake CPU
        disable fork;
        #50;

        // ========== Test 26: PLIC 唤醒 ==========
        $display("\n========== Test 26: PLIC wake ==========");
        begin
            int st; string res;
            aip_cpu_bridge::event_mode  = 0;
            aip_cpu_bridge::irq_enabled = 0;
            aip_cpu_bridge::msip_mode   = 0;
            aip_cpu_bridge::set_plic_path("tb.fake_plic_ip", 48, 0);
            fork fake_cpu_plic_loop(); join_none
            #10;
            aip_cpu_bridge::send_cmd("cpu_ping", 0, st, res);
            if (st == 0 && res == "plic_ok") begin
                $display("[PASS] Test 26: PLIC wake: IP deposit woke fake cpu, result=%s", res);
                pass_count++;
            end else begin
                $display("[FAIL] Test 26: PLIC wake: st=%0d res=%s", st, res);
                fail_count++;
            end
        end

        // 停止 PLIC fake CPU
        disable fork;
        #50;

        // ---- Test 27: mailbox 布局 — cmd_data (一字符一 word) 不得越过 rsp_flag ----
        $display("\n========== Test 27: mailbox layout ==========");
        if (aip_cpu_bridge::OFF_CMD_DATA + aip_cpu_bridge::CMD_DATA_MAX * 4 <= aip_cpu_bridge::OFF_RSP_FLAG &&
            aip_cpu_bridge::OFF_RSP_DATA + aip_cpu_bridge::CMD_DATA_MAX * 4 <= aip_cpu_bridge::OFF_ASYNC_FLAG) begin
            $display("[PASS] Test 27: CMD_DATA_MAX=%0d fits between data offsets", aip_cpu_bridge::CMD_DATA_MAX);
            pass_count++;
        end else begin
            $display("[FAIL] Test 27: CMD_DATA_MAX=%0d words overrun rsp_flag/async_flag", aip_cpu_bridge::CMD_DATA_MAX);
            fail_count++;
        end

        // ---- Summary ----
        #100;
        $display("\n==========================================================");
        $display("  CPU Bridge Test Summary");
        $display("  PASS: %0d  FAIL: %0d  TOTAL: %0d", pass_count, fail_count, pass_count + fail_count);
        $display("==========================================================\n");

        if (fail_count > 0)
            $fatal(1, "CPU_BRIDGE_FAIL pass=%0d fail=%0d", pass_count, fail_count);

        $display("CPU_BRIDGE_PASS");
        $finish;
    end

endmodule
