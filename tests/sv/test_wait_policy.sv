// aip_wait_policy 单元测试（纯 SV/UVM）。预期的 WAIT_POLICY 超时 uvm_error 由 catcher 计数并降级为 INFO，
// 故通过时 UVM_ERROR 仍为 0，意外错误照常失败。
`include "aip_core_pkg.sv"

module test_wait_policy;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    `include "uvm_macros.svh"

    class twp_catcher extends uvm_report_catcher;
        int unsigned caught;
        function new(string name = "twp_catcher");
            super.new(name);
            caught = 0;
        endfunction
        virtual function action_e catch();
            if (get_severity() == UVM_ERROR && get_id() == "WAIT_POLICY") begin
                caught++;
                set_severity(UVM_INFO);
            end
            return THROW;
        endfunction
    endclass

    int unsigned failures = 0;
    twp_catcher catcher;

    function automatic void check(bit cond, string what);
        if (!cond) begin
            failures++;
            $display("TWP_FAIL: %s", what);
        end else begin
            $display("TWP_OK:   %s", what);
        end
    endfunction

    // 以 ns 为单位的当前时间（本模块 timescale 1ns/1ps）。
    function automatic realtime now_ns();
        return $realtime;
    endfunction

    initial begin
        aip_wait_policy pol;
        aip_wait_policy cp;
        uvm_event       evt;
        bit             flag;
        bit             timed_out;
        bit             hit;
        realtime        t0;
        realtime        start;
        int unsigned    attempts;
        int unsigned    prev_caught;
        bit             cond;

        catcher = new();
        uvm_report_cb::add(null, catcher);
        pol = aip_wait_policy::type_id::create("pol");

        // 1. 倍率、饱和与 0 倍率。
        pol.timeout_multiplier = 3;
        check(pol.effective_timeout(100) == 300, "effective_timeout 100x3 = 300");
        pol.timeout_multiplier = 2;
        check(pol.effective_timeout(32'hFFFF_FFFF) == 32'hFFFF_FFFF, "effective_timeout saturates");
        pol.timeout_multiplier = 0;
        check(pol.effective_timeout(55) == 55, "multiplier 0 treated as 1");
        pol.timeout_multiplier = 1;

        // 2. poll_until_flag 成功：50ns 时置位。
        flag = 0; t0 = now_ns();
        fork begin #50ns; flag = 1; end join_none
        pol.poll_until_flag("flag set at 50ns", 1000, 10, flag, timed_out);
        check(!timed_out && flag, "poll_until_flag success");
        check(now_ns() - t0 >= 50 && now_ns() - t0 <= 60, $sformatf("poll_until_flag woke at +%0.1fns", now_ns() - t0));

        // 3. poll_until_flag 超时：100ns 基准，倍率 2 → 约 200ns。
        prev_caught = catcher.caught; flag = 0; t0 = now_ns();
        pol.timeout_multiplier = 2;
        pol.poll_until_flag("never set", 100, 10, flag, timed_out);
        pol.timeout_multiplier = 1;
        check(timed_out && catcher.caught == prev_caught + 1, "poll_until_flag timeout reports one error");
        check(now_ns() - t0 >= 200 && now_ns() - t0 <= 210, $sformatf("multiplier applied: timed out at +%0.1fns", now_ns() - t0));

        // 4. 次数上限先于时间上限触发。
        prev_caught = catcher.caught; flag = 0; t0 = now_ns();
        pol.max_poll_attempts = 3;
        pol.poll_until_flag("attempt cap", 100000, 10, flag, timed_out);
        pol.max_poll_attempts = 10000;
        check(timed_out && catcher.caught == prev_caught + 1, "max_poll_attempts guard");
        check(now_ns() - t0 == 30, $sformatf("attempt cap after 3 polls (+%0.1fns)", now_ns() - t0));

        // 5. wait_event_or_timeout：20ns 触发 / 不触发。
        evt = new("evt");
        fork begin #20ns; evt.trigger(); end join_none
        pol.wait_event_or_timeout("evt at 20ns", evt, 1000, hit);
        check(hit, "wait_event_or_timeout triggered");
        evt.reset();
        prev_caught = catcher.caught;
        pol.wait_event_or_timeout("evt never", evt, 50, hit);
        check(!hit && catcher.caught == prev_caught + 1, "wait_event_or_timeout timeout");

        // 6. wait_event_or_poll：事件已为 on 时立即返回。
        evt.trigger(); t0 = now_ns();
        pol.wait_event_or_poll("already on", evt, 100, 10, hit);
        check(hit && now_ns() == t0, "wait_event_or_poll returns immediately when on");
        evt.reset();

        // 7. 调用方自行轮询（CMQ 用法）：35ns 时条件成立。
        cond = 0; pol.default_poll_interval_ns = 10;
        fork begin #35ns; cond = 1; end join_none
        start = pol.wait_start(); attempts = 0; t0 = now_ns();
        while (!cond && !pol.deadline_reached(start, 1000, attempts)) begin
            pol.wait_poll_interval(pol.time_left_ns(start, 1000));
            attempts++;
        end
        check(cond && now_ns() - t0 == 40, $sformatf("self-poll loop sees condition at +%0.1fns", now_ns() - t0));
        //    条件永不成立：在有效超时处停止，且最后一次等待被剩余预算截断。
        cond = 0; pol.default_poll_interval_ns = 30;
        start = pol.wait_start(); attempts = 0; t0 = now_ns();
        while (!cond && !pol.deadline_reached(start, 100, attempts)) begin
            pol.wait_poll_interval(pol.time_left_ns(start, 100));
            attempts++;
        end
        check(!cond && now_ns() - t0 == 100, $sformatf("self-poll loop stops at deadline (+%0.1fns)", now_ns() - t0));
        check(pol.time_left_ns(start, 100) <= 0, "time_left_ns <= 0 after deadline");

        // 8. load_params：命令行 +twp.wait.*。
        pol.load_params("twp.wait");
        check(pol.default_poll_interval_ns == 7, "load_params poll_ns=7");
        check(pol.default_timeout_ns == 500, "load_params timeout_ns=500");
        check(pol.timeout_multiplier == 4, "load_params multiplier=4");
        check(pol.max_poll_attempts == 99, "load_params max_polls=99");
        //    未提供的路径保留当前值。
        pol.load_params("twp.absent");
        check(pol.default_timeout_ns == 500 && pol.timeout_multiplier == 4, "absent params keep current values");

        // 9. do_copy 复制全部策略字段。
        cp = aip_wait_policy::type_id::create("cp");
        cp.copy(pol);
        check(cp.default_poll_interval_ns == 7 && cp.default_timeout_ns == 500 &&
              cp.timeout_multiplier == 4 && cp.max_poll_attempts == 99, "do_copy copies all fields");

        // 预期错误：3 poll 超时 + 4 次数上限 + 5 事件超时 = 3 条（自行轮询只判断、不报错）。
        if (failures == 0 && catcher.caught == 3)
            $display("TEST_WAIT_POLICY_PASS");
        else
            $display("TEST_WAIT_POLICY_FAIL failures=%0d caught=%0d (expected 3)", failures, catcher.caught);
        $finish;
    end
endmodule
