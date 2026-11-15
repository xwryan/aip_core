// aip_uint 与 aip_cmdline_query::present 单元测试；+tcq_neg 运行负数路径，预期 hard fatal。
`include "aip_core_pkg.sv"

module test_cmdline_query;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    int unsigned failures = 0;

    function automatic void check(bit cond, string what);
        if (!cond) begin
            failures++;
            $display("TCQ_FAIL: %s", what);
        end else begin
            $display("TCQ_OK:   %s", what);
        end
    endfunction

    initial begin
        int unsigned     cnt;
        longint unsigned neg;

        if ($test$plusargs("tcq_neg")) begin
            neg = 0;
            `aip_uint("q", longint unsigned, neg, neg)
            $display("TCQ_FAIL: negative unsigned value was accepted");
            $finish;
        end

        cnt = 1;
        `aip_uint("q", int unsigned, cnt, cnt)
        check(cnt == 5, "aip_uint reads q.cnt=5");
        check(aip_cmdline_query::present("q", "cnt"), "present: exact key");
        check(aip_cmdline_query::present("q", "list"), "present: indexed key q.list[1]");
        check(aip_cmdline_query::present("q", "sub"), "present: sub-field key q.sub.x");
        check(aip_cmdline_query::present("other", "leaf"), "present: bare leaf-name fallback");
        check(!aip_cmdline_query::present("q", "absent"), "absent key is not present");
        check(!aip_cmdline_query::present("q", "cn"), "key prefix is not a match");
        check(aip_cmdline_query::present("q", "list", 1), "unsigned check passes for non-negative entries");

        if (failures == 0) $display("TEST_CMDLINE_QUERY_PASS");
        else               $display("TEST_CMDLINE_QUERY_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
