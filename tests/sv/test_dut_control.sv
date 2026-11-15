// tests/sv：DUT命令的真实HDL访问和逐调用结果隔离测试。
// 依赖AIP/UVM HDL DPI；顶层拥有被测信号，调度器拥有每次调用上下文。
// force_time后台期间允许另一个字符串命令读取信号；不并行写同一DUT对象。
`include "aip_core_pkg.sv"

import uvm_pkg::*;
import aip_core_pkg::*;

// 单信号测试保持原同步覆盖，追加不同旧宏命令之间的后台并行读验证。
module test_dut_control;
    logic dut_signal;
    logic [15:0] dut_mem [0:15];

    // 同步兼容入口仍通过exec读取最近结果；后台用例单独使用逐次输出。
    task automatic exec_ok(string cmd);
        aip_cmd::exec(cmd, SRC_SOCKET);
        if (aip_cmd::__aip_cmd_last_status != 0)
            $fatal(1, "command failed: %s -> %s", cmd,
                   aip_cmd::__aip_cmd_last_result);
    endtask

    // 非法参数必须返回失败，不能把HDL写操作执行成功。
    task automatic exec_error(string cmd);
        aip_cmd::exec(cmd, SRC_SOCKET);
        if (aip_cmd::__aip_cmd_last_status == 0)
            $fatal(1, "invalid command unexpectedly succeeded: %s", cmd);
    endtask

    initial begin
        int fd;
        dut_signal = 1'b0;
        foreach (dut_mem[i]) dut_mem[i] = 16'hffff;
        if (aip_cmd::get_handle("dut_force") == null ||
            aip_cmd::get_handle("dut_force_time") == null ||
            aip_cmd::get_handle("dut_deposit") == null ||
            aip_cmd::get_handle("dut_get") == null ||
            aip_cmd::get_handle("dut_release") == null ||
            aip_cmd::get_handle("dut_readmemh") == null ||
            aip_cmd::get_handle("dut_readmemb") == null)
            $fatal(1, "DUT control commands were not registered");

        // 省略 width 时默认 8 bit：普通 token 从 offset 连续装载，@ADDR 也以
        // offset 为基址；空白、行注释、块注释和下划线均可出现在文件中。
        fd = $fopen("dut_control.hex", "w");
        if (fd == 0) $fatal(1, "cannot create hex fixture");
        $fdisplay(fd, "000a 001b // sequential words");
        $fdisplay(fd, "/* address jump");
        $fdisplay(fd, "   across lines */ @4 fe");
        $fclose(fd);
        exec_ok("dut_readmemh file=dut_control.hex path=test_dut_control.dut_mem offset=2");
        if (dut_mem[2] !== 16'h000a || dut_mem[3] !== 16'h001b ||
            dut_mem[6] !== 16'h00fe || dut_mem[4] !== 16'hffff)
            $fatal(1, "readmemh data/address mapping mismatch");

        // width 可为任意正 bit 数，不要求按 byte 或 hex nibble 对齐。
        fd = $fopen("dut_control_width.hex", "w");
        if (fd == 0) $fatal(1, "cannot create width fixture");
        $fdisplay(fd, "1abc");
        $fclose(fd);
        exec_ok("dut_readmemh file=dut_control_width.hex path=test_dut_control.dut_mem offset=7 width=13");
        if (dut_mem[7] !== 16'h1abc)
            $fatal(1, "13-bit readmemh value mismatch");

        fd = $fopen("dut_control.bin", "w");
        if (fd == 0) $fatal(1, "cannot create binary fixture");
        $fdisplay(fd, "0000_0011 1111_0000");
        $fdisplay(fd, "@4 1010_0101 # shell-style comment");
        $fclose(fd);
        exec_ok("dut_readmemb file=dut_control.bin path=test_dut_control.dut_mem offset=0x8");
        if (dut_mem[8] !== 16'h0003 || dut_mem[9] !== 16'h00f0 ||
            dut_mem[12] !== 16'h00a5)
            $fatal(1, "readmemb data/address mapping mismatch");

        fd = $fopen("dut_control_width.bin", "w");
        if (fd == 0) $fatal(1, "cannot create binary width fixture");
        $fdisplay(fd, "1_0000_0011");
        $fclose(fd);
        exec_ok("dut_readmemb file=dut_control_width.bin path=test_dut_control.dut_mem offset=13 width=9");
        if (dut_mem[13] !== 16'h0103)
            $fatal(1, "9-bit readmemb value mismatch");

        // 完整文件在首个 deposit 前预检；后部坏 token 不得留下前部写入。
        dut_mem[14] = 16'h55aa;
        fd = $fopen("dut_control_bad.hex", "w");
        if (fd == 0) $fatal(1, "cannot create malformed fixture");
        $fdisplay(fd, "34 not_hex");
        $fclose(fd);
        exec_error("dut_readmemh file=dut_control_bad.hex path=test_dut_control.dut_mem offset=14");
        if (dut_mem[14] !== 16'h55aa)
            $fatal(1, "malformed readmemh partially modified memory");
        fd = $fopen("dut_control_overflow.hex", "w");
        if (fd == 0) $fatal(1, "cannot create overflow fixture");
        $fdisplay(fd, "1ff");
        $fclose(fd);
        exec_error("dut_readmemh file=dut_control_overflow.hex path=test_dut_control.dut_mem offset=14");
        if (dut_mem[14] !== 16'h55aa)
            $fatal(1, "8-bit readmemh silently truncated an overflowing value");
        exec_error("dut_readmemh file=missing.hex path=test_dut_control.dut_mem offset=0");
        exec_error("dut_readmemb file=dut_control.bin path=test_dut_control.dut_mem offset=-1");
        exec_error("dut_readmemh file=dut_control.hex path=test_dut_control.dut_mem offset=0 width=0");
        exec_error("dut_readmemh file=dut_control.hex path=test_dut_control.dut_mem offset=0 width=1025");

        exec_ok("dut_deposit path=test_dut_control.dut_signal value=1");
        if (dut_signal !== 1'b1)
            $fatal(1, "deposit did not update signal");

        exec_error("dut_deposit path=test_dut_control.dut_signal value=not_a_number");
        if (dut_signal !== 1'b1)
            $fatal(1, "invalid deposit changed signal");

        exec_ok("dut_force path=test_dut_control.dut_signal value=0");
        if (dut_signal !== 1'b0)
            $fatal(1, "force did not update signal");
        dut_signal = 1'b1;
        #1;
        if (dut_signal !== 1'b0)
            $fatal(1, "force was not persistent");

        exec_ok("dut_get path=test_dut_control.dut_signal");
        if (aip_cmd::__aip_cmd_last_result.len() == 0 ||
            aip_cmd::__aip_cmd_last_result.substr(
                aip_cmd::__aip_cmd_last_result.len()-8,
                aip_cmd::__aip_cmd_last_result.len()-1) != "00000000")
            $fatal(1, "unexpected get result: %s", aip_cmd::__aip_cmd_last_result);

        exec_ok("dut_release path=test_dut_control.dut_signal");
        dut_signal = 1'b1;
        #1;
        if (dut_signal !== 1'b1)
            $fatal(1, "release did not restore HDL driver");

        exec_ok("dut_force_time path=test_dut_control.dut_signal value=0 time=2ns");
        dut_signal = 1'b1;
        #1;
        if (dut_signal !== 1'b1)
            $fatal(1, "force-time did not release after timeout");

        // 两个命令都保留原str_status宏，但内置实现使用局部结果上下文，
        // 因此dut_get不能因为另一个字符串task尚未返回而被全局legacy锁挡住。
        begin
            int returned_status;
            string returned_result;
            aip_cmd delayed_handle;
            realtime launch_time;
            launch_time = $realtime;
            aip_cmd::exec_result("dut_force_time path=test_dut_control.dut_signal value=0 time=20ns wait=0",
                                 SRC_SOCKET, returned_status, returned_result);
            if (returned_status != 0 || returned_result != "STARTED: dut_force_time" ||
                $realtime != launch_time || dut_signal !== 1'b0)
                $fatal(1, "background force-time did not start immediately");

            aip_cmd::exec_result("dut_get path=test_dut_control.dut_signal",
                                 SRC_SOCKET, returned_status, returned_result);
            if (returned_status != 0 || dut_signal !== 1'b0 || $realtime != launch_time)
                $fatal(1, "dut_get was blocked by unrelated string command");

            aip_cmd::exec_result("dut_force_time path=test_dut_control.dut_signal value=1 time=1ns wait=0",
                                 SRC_SOCKET, returned_status, returned_result);
            if (returned_status == 0 || returned_result.substr(0, 3) != "BUSY")
                $fatal(1, "same-name force-time did not preserve original invocation");
            #25ns;
            delayed_handle = aip_cmd::get_handle("dut_force_time");
            if (delayed_handle.status != 0 ||
                aip_str::str_find(delayed_handle.result_out, "for 20ns, released") < 0)
                $fatal(1, "background force-time lost its own result");
            dut_signal = 1'b1;
            #1ns;
            if (dut_signal !== 1'b1)
                $fatal(1, "background force-time did not release DUT signal");
            $display("DUT_CONTROL_CONTEXT_PASS");
        end

        $display("DUT_CONTROL_PASS");
        $finish;
    end
endmodule
