// aip_cmd::parse_uint_arg 单元测试：空串取默认值；负数、非整数字面量、超过上限都返回 0 并给出原因，
// value 保持默认值。另核对 parse_int64_arg 仍按旧行为静默回落默认值。
`include "aip_core_pkg.sv"

module test_parse_uint_arg;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    int unsigned failures = 0;

    function automatic void check(bit cond, string what);
        if (!cond) begin
            failures++;
            $display("TPU_FAIL: %s", what);
        end else begin
            $display("TPU_OK:   %s", what);
        end
    endfunction

    function automatic void accept(string s, longint unsigned max, longint unsigned dv,
                                   longint unsigned expected);
        longint unsigned value;
        string why;
        bit ok;
        ok = aip_cmd::parse_uint_arg(s, max, dv, value, why);
        check(ok && value == expected && why == "",
              $sformatf("accept '%s' max=0x%0h -> 0x%0h (ok=%0b value=0x%0h why='%s')",
                        s, max, expected, ok, value, why));
    endfunction

    // 拒绝时原因须以 "arg=<s>: " 开头并含 reason，value 保持默认值 0x55。
    function automatic void reject(string s, longint unsigned max, string reason);
        longint unsigned value;
        string why;
        bit ok;
        ok = aip_cmd::parse_uint_arg(s, max, 64'h55, value, why, "arg");
        check(!ok && value == 64'h55 && aip_str::str_find(why, {"arg=", s, ": "}) == 0 &&
              aip_str::str_find(why, reason) > 0,
              $sformatf("reject '%s' max=0x%0h: %s (ok=%0b value=0x%0h why='%s')",
                        s, max, reason, ok, value, why));
    endfunction

    initial begin
        longint unsigned value;
        string why;

        accept("", 10, 7, 7);
        accept("5", 10, 0, 5);
        accept("10", 10, 0, 10);
        accept("0x1f", 255, 0, 31);
        accept("8'hff", 255, 0, 255);
        accept("1_000", 1000, 0, 1000);
        accept("+3", 9, 0, 3);
        accept("0xffff_ffff_ffff_ffff", '1, 0, '1);

        reject("abc", '1, "not an unsigned integer literal");
        reject("12x", '1, "not an unsigned integer literal");
        reject("4'hff", '1, "not an unsigned integer literal");
        reject("-1", '1, "negative value");
        reject("-18446744073709551615", '1, "negative value");
        reject("11", 10, "exceeds the maximum 0xa");
        reject("0x1_0000_0000_0000_0000", '1, "exceeds the maximum 0xffffffffffffffff");

        check(!aip_cmd::parse_uint_arg("zz", 9, 1, value, why) && why == "'zz': not an unsigned integer literal",
              $sformatf("without a name the reason quotes the value (why='%s')", why));
        check(aip_cmd::parse_int64_arg("abc", 7) == 7 && aip_cmd::parse_int64_arg("-1") == '1 &&
              aip_cmd::parse_int64_arg("0x10") == 16, "parse_int64_arg keeps its lenient behaviour");

        if (failures == 0) $display("TEST_PARSE_UINT_ARG_PASS");
        else               $display("TEST_PARSE_UINT_ARG_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
