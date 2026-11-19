// Wide-integer parsing and random regression.
`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_wide;
    int failures = 0;

    string errcase;
    longint       l64;
    bit [63:0]    u64;
    bit [127:0]   u128;
    bit [255:0]   u256;
    bit [255:0]   u256_pat;
    bit [7:0]     u8;
    int           i32;
    int unsigned  iu32;
    int           e_i32;
    bit [255:0]   e_u256;
    bit [127:0]   r128;
    longint       rl;
    bit [255:0]   rr;

    task automatic check_true(string label, bit condition);
        if (!condition) begin
            failures++;
            $error("%s", label);
        end
    endtask

    task automatic check_str_to_vec();
        aip_vec_t v;
        int width;
        bit neg;
        string s;
        longint unsigned raw;

        check_true("vec 48-bit hex ok", aip_str::str_to_vec("0x8000_0000_0000", v, width, neg));
        check_true("vec 48-bit hex value", v == 48'h8000_0000_0000 && width == 0 && !neg);

        s = "256'h";
        repeat (64) s = {s, "f"};
        check_true("vec 256'h all-ones ok", aip_str::str_to_vec(s, v, width, neg));
        check_true("vec 256'h all-ones value", v == {256{1'b1}} && width == 256);

        check_true("vec 2^128-1 decimal ok",
                   aip_str::str_to_vec("340282366920938463463374607431768211455", v, width, neg));
        check_true("vec 2^128-1 decimal value", v == {128{1'b1}} && width == 0);

        check_true("vec negative ok", aip_str::str_to_vec("-0x10", v, width, neg));
        check_true("vec negative magnitude", v == 16 && neg);

        check_true("vec explicit width overflow fails", !aip_str::str_to_vec("8'h1FF", v, width, neg));
        check_true("vec explicit width > 1024 fails", !aip_str::str_to_vec("2000'h1", v, width, neg));
        check_true("vec explicit width 1024 ok", aip_str::str_to_vec("1024'h1", v, width, neg) && v == 1 && width == 1024);
        check_true("vec empty fails", !aip_str::str_to_vec("", v, width, neg));
        check_true("vec bad digit fails", !aip_str::str_to_vec("0x12G", v, width, neg));

        s = "0b1";
        repeat (1024) s = {s, "0"};
        check_true("vec 1025-bit overflow fails", !aip_str::str_to_vec(s, v, width, neg));

        raw = aip_str::str_to_num("0x1_0000_0000_0000_0000", width);
        check_true("str_to_num 65-bit -> sentinel", raw == {64{1'b1}} && width == 0);
        raw = aip_str::str_to_num("-8'd10", width);
        check_true("str_to_num -8'd10 unchanged", longint'(raw) == -10 && width == 8);
        raw = aip_str::str_to_num("0x1A3F", width);
        check_true("str_to_num legacy width = digit count", raw == 64'h1A3F && width == 4);
        raw = aip_str::str_to_num("8'h1FF", width);
        check_true("str_to_num explicit overflow -> sentinel", raw == {64{1'b1}} && width == 0);
    endtask

    task automatic check_wide_literals();
        `aip_int("", longint,     l64,      0);   // +l64=0x8000_0000_0000
        `aip_int("", bit [63:0],  u64,      0);   // +u64=0xFFFF_FFFF_FFFF_FFFF
        `aip_int("", bit [127:0], u128,     0);   // +u128=340282366920938463463374607431768211455
        `aip_int("", bit [255:0], u256,     0);   // +u256=256'hff..ff
        `aip_int("", bit [255:0], u256_pat, 0);   // +u256_pat=0x0123...
        `aip_int("", bit [7:0],   u8,       0);   // +u8=8'hff（无符号目标不接受负数）
        `aip_int("", int,         i32,      0);   // +i32=-0x10
        `aip_int("", int unsigned, iu32,    0);   // +iu32=0xFFFF_FFFF

        check_true("longint 48-bit literal not truncated", l64 == 64'h8000_0000_0000);
        check_true("bit[63:0] all ones", u64 == {64{1'b1}});
        check_true("bit[127:0] decimal 2^128-1", u128 == {128{1'b1}});
        check_true("bit[255:0] 256'h all ones", u256 == {256{1'b1}});
        check_true("bit[255:0] pattern high word", u256_pat[255:224] == 32'h0123_4567);
        check_true("bit[255:0] pattern low word",  u256_pat[31:0]    == 32'h89ab_cdef);
        check_true("8'hff into bit[7:0] at the max", u8 == 8'hff);
        check_true("-0x10 into int", i32 == -16);
        check_true("0xFFFF_FFFF into int unsigned", iu32 == 32'hFFFF_FFFF);
    endtask

    task automatic check_wide_random();
        bit [127:0] lo128 = 128'h1_0000_0000_0000_0000;
        bit [127:0] hi128 = 128'h1_0000_0000_0000_00FF;
        bit [127:0] x;
        bit [7:0]   w8;
        bit seen_min = 0, seen_max = 0, seen_lo = 0, seen_hi = 0;
        int cnt_zero = 0, cnt_ff = 0;

        `aip_int("", bit [127:0], r128, 0);   // +r128=[0x1_0000_0000_0000_0000:0x1_0000_0000_0000_00FF]
        `aip_int("", longint,     rl,   0);   // +rl=[0x1_0000_0000:0x1_0000_00FF]
        check_true("registered bit[127:0] range in bounds", r128 >= lo128 && r128 <= hi128);
        check_true("registered longint range in bounds", rl >= 64'h1_0000_0000 && rl <= 64'h1_0000_00FF);

        repeat (1000) begin
            x = aip_cmdline#(bit [127:0])::parse_value("[0x1_0000_0000_0000_0000:0x1_0000_0000_0000_00FF]");
            check_true("bit[127:0] draw in bounds", x >= lo128 && x <= hi128);
            if (x == lo128) seen_min = 1;
            if (x == hi128) seen_max = 1;
        end
        check_true("bit[127:0] range reaches both ends", seen_min && seen_max);

        // weight arithmetic must not be limited by T's width: 200+200 > 255
        repeat (400) begin
            w8 = aip_cmdline#(bit [7:0])::parse_value("{0:=200,255:=200}");
            if (w8 == 0) cnt_zero++;
            else if (w8 == 8'hff) cnt_ff++;
            else check_true("weighted bit[7:0] only 0 or 255", 0);
        end
        check_true("weighted bit[7:0] both outcomes seen", cnt_zero > 50 && cnt_ff > 50);

        // wide weighted range block: [2^64 : 2^64+255]:/1 vs 0:/1
        repeat (400) begin
            x = aip_cmdline#(bit [127:0])::parse_value("{0:/1,[0x1_0000_0000_0000_0000:0x1_0000_0000_0000_00FF]:/1}");
            if (x == 0) seen_lo = 1;
            else begin
                check_true("wide weighted block in bounds", x >= lo128 && x <= hi128);
                seen_hi = 1;
            end
        end
        check_true("wide weighted group both blocks seen", seen_lo && seen_hi);

        // inc: with a 64-bit stride keeps the stride
        repeat (100) begin
            longint unsigned v = aip_cmdline#(longint unsigned)::parse_value("inc:0x1_0000_0000:0x5_0000_0000:0x1_0000_0000");
            check_true("inc 64-bit stride", v[31:0] == 0 && v[63:32] >= 1 && v[63:32] <= 5);
        end
    endtask

    task automatic check_rand_keyword();
        bit [255:0] acc = '0;
        bit [255:0] x;
        bit seen_zero = 0, seen_wide = 0;

        `aip_int("", bit [255:0], rr, 0);   // +rr=rand
        repeat (100) begin
            x = aip_cmdline#(bit [255:0])::parse_value("rand");
            acc |= x;
        end
        check_true("rand fills bits above 64",  |acc[255:64]);
        check_true("rand fills low bits",       |acc[63:0]);
        check_true("registered rand nonzero",   rr != 0);

        repeat (200) begin
            x = aip_cmdline#(bit [255:0])::parse_value("{0:/1,rand:/1}");
            if (x == 0) seen_zero = 1;
            else if (|x[255:64]) seen_wide = 1;
        end
        check_true("rand inside weight group", seen_zero && seen_wide);
    endtask

    initial begin
        if ($value$plusargs("AIP_WIDE_ERRCASE=%s", errcase)) begin
            case (errcase)
                "overflow32", "width", "randeach": `aip_int("", int, e_i32, 0)
                "vecoverflow":         `aip_int("", bit [255:0], e_u256, 0)
                default: $fatal(1, "unknown AIP_WIDE_ERRCASE %s", errcase);
            endcase
            $display("WIDE_ACCEPTED");
            $finish;
        end

        check_str_to_vec();
        check_wide_literals();
        check_wide_random();
        check_rand_keyword();
        if (failures == 0) $display("CMDLINE_WIDE_PASS");
        else $display("CMDLINE_WIDE_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
