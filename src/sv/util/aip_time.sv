// 仿真时间获取与精确延迟工具，与调用方 timescale 无关。
`ifndef AIP_TIME_SV
`define AIP_TIME_SV

`timescale 1ns/1fs  // 精度 1fs：亚 ps 半周期（如 10.3125GHz 串行钟）不被截断

class aip_time;

    static bit   measured = 0;
    static real  unit_fs;                // 当前 timescale 的每个时间单位对应的飞秒数

    // unit: fs/ps/ns/us/ms/s/m/h；非法单位返回 -1000.0，解析失败返回 -2000.0。
    static function real get_sim_time(string unit = "ns");
        real time_fs = real'($realtime / 1fs);
        real divisor;
        case (unit)
            "fs": divisor = 1.0;
            "ps": divisor = 1e3;
            "ns": divisor = 1e6;
            "us": divisor = 1e9;
            "ms": divisor = 1e12;
            "s":  divisor = 1e15;
            "m":  divisor = 60.0 * 1e15;
            "h":  divisor = 3600.0 * 1e15;
            default: return -1000.0;
        endcase
        return time_fs / divisor;
    endfunction

    // 会消耗 #1 仿真时间；delay_ns 不依赖它。
    protected static task ensure_measured();
        longint unsigned start_fs, end_fs, delta_fs;

        if (measured) return;

        start_fs = longint'(get_sim_time("fs"));
        #1;
        end_fs   = longint'(get_sim_time("fs"));
        delta_fs = end_fs - start_fs;

        if (delta_fs <= 0 || delta_fs >= 1000000000) begin
            `aip_error(("timescale measurement failed (delta = %0d fs). Ensure unit is 1ns/100ps/10ps/1ps/100fs/10fs/1fs", delta_fs));
            $finish;
        end

        unit_fs = real'(delta_fs);
        measured = 1;
    endtask

    // 用 1ns 时间字面量换算，与 timescale 无关，无额外仿真时间开销。
    static task delay_ns(real ns);
        realtime delay_time;

        if (ns <= 0) return;

        delay_time = ns * 1ns;
        #(delay_time);
    endtask

    // 整数版本，保留向后兼容。
    static task delay_ns_int(longint ns);
        delay_ns(real'(ns));
    endtask

endclass
`endif // AIP_TIME_SV
