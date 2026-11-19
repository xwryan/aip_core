// 有符号目标取值规则：纯十进制须在 [-2^(N-1), 2^(N-1)-1] 内；带基数/位宽的写法是位模式，放进 N 位后按补码解释；
// 带负号的基数写法取无符号值的相反数。+tcs_neg=<case> 单独运行非法输入，预期 hard fatal 并报出参数名、原文与允许范围。
`include "aip_core_pkg.sv"

module test_cmdline_signed;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    typedef struct { bit signed [7:0] s8f; int unsigned u32f; } tcs_cfg_t;
    `aip_struct_type_begin(tcs_cfg_t)
        `aip_field_int(bit signed [7:0], s8f, 0)
        `aip_field_int(int unsigned, u32f, 0)
    `aip_struct_type_end(tcs_cfg_t)
    typedef struct { byte s8; } tcs_legacy_t;

    int unsigned	failures = 0;

    function automatic void check(bit	cond, string	what);
        if (!cond) begin
            failures++;
            $display("TCS_FAIL: %s", what);
        end else begin
            $display("TCS_OK:   %s", what);
        end
    endfunction

    task automatic check_values();
        int					imax;
        int					imin;
        int					ipat;
        int					ihex;
        int					imsb;
        int					itick;
        int					ineg;
        byte				bmax;
        byte				bmin;
        byte				bpat;
        byte				bmsb;
        byte				bneg;
        byte				bnegmsb;
        byte				bbin;
        bit signed [7:0]	sv8;
        longint				lmax;
        longint				lmin;
        longint				lpat;
        bit signed [127:0]	w128;
        bit signed [127:0]	wmax;
        byte				brange;
        byte				bov;
        int					ilist[];
        byte				bq[$];
        tcs_cfg_t			cfg;
        tcs_legacy_t		leg;
        `aip_int("ts", int, imax, 0)
        check(imax == 2147483647, "int decimal max 2147483647");
        `aip_int("ts", int, imin, 0)
        check(imin == -2147483648, "int decimal min -2147483648");
        `aip_int("ts", int, ipat, 0)
        check(ipat == -1, "int 32'hFFFF_FFFF is the bit pattern -1");
        `aip_int("ts", int, ihex, 0)
        check(ihex == -1, "int 0xFFFFFFFF is the bit pattern -1");
        `aip_int("ts", int, imsb, 0)
        check(imsb == -2147483648, "int 0x80000000 is -2^31");
        `aip_int("ts", int, itick, 0)
        check(itick == 2147483647, "int 'h7fffffff is the max");
        `aip_int("ts", int, ineg, 0)
        check(ineg == -16, "int -0x10 negates the based value");
        `aip_int("ts", byte, bmax, 0)
        check(bmax == 127, "byte decimal max 127");
        `aip_int("ts", byte, bmin, 0)
        check(bmin == -128, "byte decimal min -128");
        `aip_int("ts", byte, bpat, 0)
        check(bpat == -1, "byte 8'hff is -1");
        `aip_int("ts", byte, bmsb, 0)
        check(bmsb == -128, "byte 8'h80 is -128");
        `aip_int("ts", byte, bneg, 0)
        check(bneg == -1, "byte -8'h1 is -1");
        `aip_int("ts", byte, bnegmsb, 0)
        check(bnegmsb == -128, "byte -8'h80 is -128");
        `aip_int("ts", byte, bbin, 0)
        check(bbin == -1, "byte 'b1111_1111 is -1");
        `aip_int("ts", bit signed [7:0], sv8, 0)
        check(sv8 == -128, "bit signed [7:0] decimal -128");
        `aip_int("ts", longint, lmax, 0)
        check(lmax == 64'sh7fff_ffff_ffff_ffff, "longint decimal max");
        `aip_int("ts", longint, lmin, 0)
        check(lmin == -64'sh8000_0000_0000_0000, "longint decimal min");
        `aip_int("ts", longint, lpat, 0)
        check(lpat == -1, "longint 64'hFFFF_FFFF_FFFF_FFFF is -1");
        `aip_int("ts", bit signed [127:0], w128, 0)
        check(w128 == -1, "bit signed [127:0] 128'hFF..FF is -1");
        `aip_int("ts", bit signed [127:0], wmax, 0)
        check(wmax == {1'b0, {127{1'b1}}}, "bit signed [127:0] decimal 2^127-1");
        repeat (16) begin
            `aip_int("ts", byte, brange, 0)
            check(brange >= -128 && brange <= -127, "range of based bit patterns [8'h80:8'h81]");
        end
        aip_cmdline_override::set_val("ts.bov", "8'hff");
        `aip_int("ts", byte, bov, 0)
        check(bov == -1, "set_param literal 8'hff is -1");
        `aip_int_list("ts", int, ilist, 0)
        check(ilist.size() == 2 && ilist[0] == 2147483647 && ilist[1] == -2147483648, "list elements at both ends");
        `aip_int_queue("ts", byte, bq, 0, -1)
        check(bq.size() == 3 && bq[0] == 127 && bq[1] == -128 && bq[2] == -1, "strict queue: 127, -128, 8'hff");
        `aip_struct_apply("ts.cfg", tcs_cfg_t, cfg)
        check(cfg.s8f == -128 && cfg.u32f == 32'hffff_ffff, "schema signed 8'h80 and unsigned max");
        `aip_struct_begin("ts", leg)
            `aip_struct_int(leg, s8, 0)
        `aip_struct_end(leg)
        check(leg.s8 == -128, "legacy struct field -128");
    endtask

    task automatic run_negative(string	c);
        int		bad32;
        byte	bad8;
        longint	bad64;
        int		arr[];
        byte	q8[$];
        byte	opt8;
        tcs_cfg_t		cfg;
        tcs_legacy_t	leg;
        case (c)
            "dec_over32", "dec_under32", "dec_u32": begin `aip_int("ts", int, bad32, 0) end
            "dec_over8", "dec_under8", "based_over8", "neg_based_under8", "range", "weight_value": begin
                `aip_int("ts", byte, bad8, 0)
            end
            "dec_over64": begin `aip_int("ts", longint, bad64, 0) end
            "override": begin
                aip_cmdline_override::set_val("ts.bad8", "200");
                `aip_int("ts", byte, bad8, 0)
            end
            "list": begin `aip_int_list("ts", int, arr, 0) end
            "queue": begin `aip_int_queue("ts", byte, q8, 0, -1) end
            "schema": begin `aip_struct_apply("ts.ncfg", tcs_cfg_t, cfg) end
            "legacy": begin
                `aip_struct_begin("ts", leg)
                    `aip_struct_int(leg, s8, 0)
                `aip_struct_end(leg)
            end
            "opt": begin `aip_int_opt("ts", byte, opt8) end
            default: $display("TCS_FAIL: unknown negative case %s", c);
        endcase
        $display("TCS_FAIL: negative case %s was accepted", c);
        $finish;
    endtask

    initial begin
        string	neg_case;
        if ($value$plusargs("tcs_neg=%s", neg_case)) run_negative(neg_case);
        check_values();
        if (failures == 0) $display("TEST_CMDLINE_SIGNED_PASS");
        else               $display("TEST_CMDLINE_SIGNED_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
