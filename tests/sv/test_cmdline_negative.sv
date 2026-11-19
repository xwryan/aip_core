`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_negative;
    int failures;
    int neg_dec, neg_hex, neg_sv, plus_dec, neg_range, cross_range;
    int neg_list, neg_inc, neg_dec_seq, neg_weight, positive;
    bit signed [7:0] neg_bits;  // 有符号位向量接受负数；无符号目标拒绝负数见 test_cmdline_unsigned
    int width;
    longint unsigned raw;

    task automatic check_equal(string label, longint signed actual,
                               longint signed expected);
        if (actual != expected) begin
            failures++;
            $error("%s: got %0d, expected %0d", label, actual, expected);
        end
    endtask

    task automatic check_true(string label, bit condition);
        if (!condition) begin
            failures++;
            $error("%s", label);
        end
    endtask

    initial begin
        failures = 0;

        `aip_int("", int, neg_dec, 0);
        `aip_int("", int, neg_hex, 0);
        `aip_int("", int, neg_sv, 0);
        `aip_int("", int, plus_dec, 0);
        `aip_int("", int, neg_range, 0);
        `aip_int("", int, cross_range, 0);
        `aip_int("", int, neg_list, 0);
        `aip_int("", int, neg_inc, 0);
        `aip_int("", int, neg_dec_seq, 0);
        `aip_int("", int, neg_weight, 0);
        `aip_int("", bit signed [7:0], neg_bits, 0);
        `aip_int("", int, positive, 0);

        check_equal("neg_dec", neg_dec, -10);
        check_equal("neg_hex", neg_hex, -16);
        check_equal("neg_sv", neg_sv, -10);
        check_equal("plus_dec", plus_dec, 10);
        check_true("neg_range", neg_range >= -10 && neg_range <= -1);
        check_true("cross_range", cross_range >= -2 && cross_range <= 2);
        check_true("neg_list", neg_list inside {-3, -2, -1});
        check_true("neg_inc", neg_inc >= -10 && neg_inc <= 10 &&
                   ((neg_inc + 10) % 2 == 0));
        check_true("neg_dec_seq", neg_dec_seq >= -10 && neg_dec_seq <= 10 &&
                   ((neg_dec_seq + 10) % 2 == 0));
        check_true("neg_weight", neg_weight >= -3 && neg_weight <= -1);
        check_equal("neg_bits", neg_bits, -1);
        check_equal("positive", positive, 42);

        raw = aip_str::str_to_num("-", width);
        check_true("invalid '-'", raw == {64{1'b1}} && width == 0);
        raw = aip_str::str_to_num("--1", width);
        check_true("invalid '--1'", raw == {64{1'b1}} && width == 0);
        raw = aip_str::str_to_num("0x-1", width);
        check_true("invalid '0x-1'", raw == {64{1'b1}} && width == 0);

        if (failures != 0)
            $fatal(1, "CMDLINE_NEGATIVE_FAIL failures=%0d", failures);
        $display("CMDLINE_NEGATIVE_PASS");
        $finish;
    end
endmodule
