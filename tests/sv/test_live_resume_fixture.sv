// 保栈暂停回归的最小信号夹具，与 test_cmd_wait.sv 共同编译：只提供断点信号、ACK 顶层别名及调试目标。
// manual 模式的忙时钟只用于制造可重复的 Ctrl+C 墙钟窗口。
module aip_live_resume_fixture;
    timeunit 1ns;
    timeprecision 1ps;

    bit first = 0;
    bit second = 0;
    bit pending = 0;
    bit debug_flag = 0;
    bit manual_clock = 0;

    // 当前 VCS stop 条件解析不支持 package:: 路径；仅做真实 ACK 的别名。
    wire first_ack = (aip_core_pkg::__tcl_result_id == 1);

    // 同一个有限 run 内有两个断点；第三个发生在真实 sequence 等待期间。
    initial begin
        #20ns first = 1;
        #40ns second = 1;
        #290ns pending = 1;
    end

    // 不修改测试总期限；两轮 500000ns 仍小于原夹具的 2000000ns 总 watchdog。
    initial begin
        if ($test$plusargs("AIP_LIVE_MANUAL")) begin
            forever #1ns manual_clock = !manual_clock;
        end
    end
endmodule
