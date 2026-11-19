// 无符号目标拒绝负数与越界：边界值、带位宽/基数字面量、有符号目标不受影响；+tcu_neg=<case> 单独运行非法输入，
// 预期 hard fatal，并报出参数名、原文与允许范围（Makefile 逐项核对）。
`include "aip_core_pkg.sv"

module test_cmdline_unsigned;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    typedef enum {F0 = 0, F1 = 1, F7 = 7} tcu_flag_e;
    typedef struct { bit [7:0] u8f; int s32f; } tcu_cfg_t;
    `aip_struct_type_begin(tcu_cfg_t)
        `aip_field_int(bit [7:0], u8f, 0)
        `aip_field_int(int, s32f, 0)
    `aip_struct_type_end(tcu_cfg_t)
    typedef struct { bit [7:0] f8; } tcu_legacy_t;

    int unsigned	failures = 0;

    function automatic void check(bit	cond, string	what);
        if (!cond) begin
            failures++;
            $display("TCU_FAIL: %s", what);
        end else begin
            $display("TCU_OK:   %s", what);
        end
    endfunction

    task automatic check_boundaries();
        bit [7:0]			u8;
        bit [7:0]			u8h;
        bit [7:0]			u8x;
        bit [7:0]			r8;
        bit [7:0]			w8;
        bit [7:0]			ov8;
        int unsigned		u32;
        longint unsigned	u64;
        bit [127:0]			u128;
        int					i32;
        bit signed [7:0]	s8;
        bit [7:0]			arr8[];
        tcu_cfg_t			cfg;
        bit [63:0]			flags;
        `aip_int("tu", bit [7:0], u8, 0)
        check(u8 == 8'hff, "bit[7:0] decimal max 255");
        `aip_int("tu", bit [7:0], u8h, 0)
        check(u8h == 8'hff, "bit[7:0] sized literal 8'hFF");
        `aip_int("tu", bit [7:0], u8x, 0)
        check(u8x == 8'hff, "bit[7:0] 0xff");
        `aip_int("tu", int unsigned, u32, 0)
        check(u32 == 32'hffff_ffff, "int unsigned max 4294967295");
        `aip_int("tu", longint unsigned, u64, 0)
        check(u64 == 64'hffff_ffff_ffff_ffff, "longint unsigned max 18446744073709551615");
        `aip_int("tu", bit [127:0], u128, 0)
        check(u128 == {128{1'b1}}, "bit[127:0] max 128'hFF..FF");
        `aip_int("tu", int, i32, 0)
        check(i32 == -2147483648, "int still takes its minimum");
        `aip_int("tu", bit signed [7:0], s8, 0)
        check(s8 == -128, "bit signed[7:0] still takes -128");
        repeat (16) begin
            `aip_int("tu", bit [7:0], r8, 0)
            check(r8 inside {[250:255]}, "unsigned range up to the max");
        end
        `aip_int("tu", bit [7:0], w8, 0)
        check(w8 inside {0, 255}, "weighted values at both ends");
        aip_cmdline_override::set_val("tu.ov8", "8'd255");
        `aip_int("tu", bit [7:0], ov8, 0)
        check(ov8 == 255, "set_param literal at the max");
        `aip_int_list("tu", bit [7:0], arr8, 0)
        check(arr8.size() == 2 && arr8[0] == 0 && arr8[1] == 255, "list elements at both ends");
        `aip_struct_apply("tu.cfg", tcu_cfg_t, cfg)
        check(cfg.u8f == 255 && cfg.s32f == -7, "schema unsigned max and signed negative");
        `aip_flags("tu", tcu_flag_e, flags, 0)
        check(flags == 64'h82, "flags names still OR together");
    endtask

    task automatic run_negative(string	c);
        bit [7:0]			bad8;
        longint unsigned	bad64;
        bit [7:0]			arr8[];
        bit [7:0]			q8[$];
        bit [7:0]			opt8;
        bit [7:0]			flags8;
        tcu_cfg_t			cfg;
        tcu_legacy_t		leg;
        case (c)
            "plusarg", "zero", "sized", "wrap64", "over", "over_sized", "over_hex", "range", "weight_value",
            "weight_negative", "inc":
                if (c == "wrap64") begin `aip_int("tu", longint unsigned, bad64, 0) end
                else begin `aip_int("tu", bit [7:0], bad8, 0) end
            "over64": begin `aip_int("tu", longint unsigned, bad64, 0) end
            "override": begin
                aip_cmdline_override::set_val("tu.bad8", "-1");
                `aip_int("tu", bit [7:0], bad8, 0)
            end
            "override_expr": begin
                aip_cmdline_override::set_val("tu.bad8", "[-3:3]");
                `aip_int("tu", bit [7:0], bad8, 0)
            end
            "list", "each", "index": begin `aip_int_list("tu", bit [7:0], arr8, 0) end
            "queue": begin `aip_int_queue("tu", bit [7:0], q8, 0, -1) end
            "schema": begin `aip_struct_apply("tu.ncfg", tcu_cfg_t, cfg) end
            "legacy": begin
                `aip_struct_begin("tu", leg)
                    `aip_struct_int(leg, f8, 0)
                `aip_struct_end(leg)
            end
            "flags": begin `aip_flags("tu", tcu_flag_e, flags8, 0) end
            "opt": begin `aip_int_opt("tu", bit [7:0], opt8) end
            default: $display("TCU_FAIL: unknown negative case %s", c);
        endcase
        $display("TCU_FAIL: negative case %s was accepted", c);
        $finish;
    endtask

    initial begin
        string	neg_case;
        if ($value$plusargs("tcu_neg=%s", neg_case)) run_negative(neg_case);
        check_boundaries();
        if (failures == 0) $display("TEST_CMDLINE_UNSIGNED_PASS");
        else               $display("TEST_CMDLINE_UNSIGNED_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
