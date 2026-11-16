// Tcl ACK 按活动进展计时的端到端夹具：命令按周期 tick 后可静默或永久阻塞，状态命令供 Tcl 读回 SV 时刻。
`include "aip_core_pkg.sv"

class ap_record;
    static realtime last_tick = 0;
    static realtime done_at = 0;
    static event never;
endclass

class ap_ops;
    // ns 内每 period 纳秒 tick 一次（0 不 tick），再静默 quiet 纳秒；hang=1 时停在 tick 之后，只能由 watchdog 结束。
    static task run_ticks();
        aip_cmd handle;
        int remaining;
        int period;
        int quiet;
        bit hang;
        string tag;

        handle = aip_cmd::get_handle("ap_tick");
        remaining = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "ns"), 0);
        period = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "period"), 0);
        quiet = aip_cmd::parse_int_arg(aip_cmd::get_arg(handle.args_in, "quiet"), 0);
        hang = aip_cmd::get_arg(handle.args_in, "hang") == "1";
        tag = aip_cmd::get_arg(handle.args_in, "tag");

        while (remaining > 0) begin
            int step;
            step = (period > 0 && period < remaining) ? period : remaining;
            #(step * 1ns);
            remaining -= step;
            if (period > 0) begin
                aip_activity::tick();
                ap_record::last_tick = $realtime;
            end
        end
        if (hang) @(ap_record::never);
        #(quiet * 1ns);
        ap_record::done_at = $realtime;
        handle.status = 0;
        handle.result_out = $sformatf("DONE:ap_tick:%s", tag);
    endtask
endclass

`aip_cmd_task(ap_tick, ap_ops::run_ticks)

// 零耗时读回，不改变活动计数，供 Tcl 用 SV 时刻核对放弃/ACK 时间。
class ap_state_command extends aip_cmd;
    task cmd_exec();
        string field;
        field = get_arg(args_in, "field");
        status = 0;
        case (field)
            "last_tick": result_out = $sformatf("%.0f", ap_record::last_tick / 1ns);
            "done_at": result_out = $sformatf("%.0f", ap_record::done_at / 1ns);
            default: begin
                status = 1;
                result_out = {"bad field: ", field};
            end
        endcase
    endtask

    function new(string name);
        super.new(name);
    endfunction

    static ap_state_command instance = new("ap_state");
endclass

module test_cmd_ack_progress;
    initial aip_tcl_bridge::run_loop();
endmodule
