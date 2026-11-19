// aip_flags 单元测试：成员名、整数掩码、set_param override、层级路径、格式化以及不消耗随机数；
// +taf_neg=<case> 单独运行非法输入，预期 hard fatal 并报出参数名与非法项。
`include "aip_core_pkg.sv"

// 成员值即位号；D0 形似十进制字面量 d0，用来确认名称优先于数字。
package taf_pkg;
    typedef enum int unsigned { A = 0, B = 1, D0 = 4, HIGH = 63 } taf_flag_e;
endpackage

module test_aip_flags;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    typedef aip_cmdline_flags#(taf_pkg::taf_flag_e) taf_flags;

    int unsigned failures = 0;

    function automatic void check(bit cond, string what);
        if (!cond) begin
            failures++;
            $display("TAF_FAIL: %s", what);
        end else begin
            $display("TAF_OK:   %s", what);
        end
    endfunction

    // 变量名即参数名，各 reader 用不同叶名区分命令行键。
    function automatic bit [63:0] read_names();
        bit [63:0] names;
        `aip_flags("taf", taf_pkg::taf_flag_e, names, 0)
        return names;
    endfunction

    function automatic bit [63:0] read_spaced();
        bit [63:0] spaced;
        `aip_flags("taf", taf_pkg::taf_flag_e, spaced, 0)
        return spaced;
    endfunction

    function automatic bit [63:0] read_num();
        bit [63:0] num;
        `aip_flags("taf", taf_pkg::taf_flag_e, num, 0)
        return num;
    endfunction

    function automatic bit [63:0] read_sized();
        bit [63:0] sized;
        `aip_flags("taf", taf_pkg::taf_flag_e, sized, 0)
        return sized;
    endfunction

    function automatic bit [63:0] read_neg();
        bit [63:0] neg;
        `aip_flags("taf", taf_pkg::taf_flag_e, neg, 0)
        return neg;
    endfunction

    function automatic bit [63:0] read_dname();
        bit [63:0] dname;
        `aip_flags("taf", taf_pkg::taf_flag_e, dname, 0)
        return dname;
    endfunction

    function automatic bit [63:0] read_dflt();
        bit [63:0] dflt;
        `aip_flags("taf", taf_pkg::taf_flag_e, dflt, 64'h8000_0000_0000_0002)
        return dflt;
    endfunction

    function automatic bit [63:0] read_mask(string path);
        bit [63:0] mask;
        `aip_flags(path, taf_pkg::taf_flag_e, mask, 0)
        return mask;
    endfunction

    function automatic bit [7:0] read_narrow();
        bit [7:0] narrow;
        `aip_flags("taf", taf_pkg::taf_flag_e, narrow, 0)
        return narrow;
    endfunction

    function automatic void read_bad(string path);
        bit [63:0] bad;
        `aip_flags(path, taf_pkg::taf_flag_e, bad, 0)
    endfunction

    function automatic void read_bad8(string path);
        bit [7:0] bad;
        `aip_flags(path, taf_pkg::taf_flag_e, bad, 0)
    endfunction

    // 走真实 set_param/clear_param 命令（与 Tcl 写同一张 override 表），失败即 fatal。
    task automatic command(string text);
        int    status;
        string result;
        aip_cmd::exec_result(text, SRC_INTERNAL, status, result);
        if (status != 0) $fatal(1, "TAF_FAIL: command '%s': %s", text, result);
    endtask

    task automatic run_negative(string c);
        case (c)
            "unknown":     read_bad("taf");                       // +taf.bad=A,BOGUS
            "hier":        begin command("set_param path=taf.h0.pf1.vf2.i0.bad value=nope"); read_bad("taf.h0.pf1.vf2.i0"); end
            "empty":       begin command("set_param path=taf.bad value=A,,B"); read_bad("taf"); end
            "mixed":       begin command("set_param path=taf.bad value=A,0x2"); read_bad("taf"); end
            "bit_range":   begin command("set_param path=taf.bad value=B,HIGH"); read_bad8("taf"); end
            "value_range": begin command("set_param path=taf.bad value=0x100"); read_bad8("taf"); end
            "negative":    begin command("set_param path=taf.bad value=-1"); read_bad8("taf"); end
            default:       $display("TAF_FAIL: unknown negative case %s", c);
        endcase
        $display("TAF_FAIL: negative case %s was accepted", c);
        $finish;
    endtask

    initial begin
        process owner;
        string  state;
        string  neg_case;
        bit [63:0] v;

        if ($value$plusargs("taf_neg=%s", neg_case)) run_negative(neg_case);

        owner = process::self();
        state = owner.get_randstate();
        check(read_names() == 64'h3, "names: b,A,b -> A|B (case-insensitive, duplicates allowed)");
        check(read_spaced() == 64'h8000_0000_0000_0001, "names: spaces around items are ignored");
        check(read_num() == 64'h8000_0000_0000_0011, "number: 0x8000_0000_0000_0011 is the mask itself");
        check(read_sized() == 64'ha5, "number: sized literal 8'b1010_0101");
        check(read_neg() == '1, "number: 64-bit all-ones mask");
        check(read_dname() == 64'h10, "names win over literals: d0 is flag D0, not decimal 0");
        check(owner.get_randstate() == state, "parsing names and numbers consumes no random numbers");
        check(read_dflt() == 64'h8000_0000_0000_0002, "absent parameter keeps the macro default");
        check(read_narrow() == 8'h12, "8-bit target: B,D0 -> 0x12");

        check(read_mask("taf.h0.pf1.vf2.i0") == 64'h8000_0000_0000_0010, "hierarchical exact key +taf.h0.pf1.vf2.i0.mask");
        check(read_mask("taf.h9") == 64'h2, "hierarchical path falls back to leaf +mask");

        command("set_param path=taf.names value=HIGH,D0");
        check(read_names() == 64'h8000_0000_0000_0010, "set_param names override wins over the plusarg");
        command("set_param path=taf.names value=0x3");
        check(read_names() == 64'h3, "set_param numeric override");
        command("set_param path=taf.names value=");
        check(read_names() == 64'h0, "empty override is 0, not the default or plusarg");
        command("clear_param path=taf.names");
        check(read_names() == 64'h3, "clear_param restores the plusarg value");
        command("set_param path=taf.h0.pf1.vf2.i0.mask value=a,b");
        command("set_param path=mask value=HIGH");
        check(read_mask("taf.h0.pf1.vf2.i0") == 64'h3, "hierarchical set_param override on the exact key");
        check(read_mask("taf.h9") == 64'h8000_0000_0000_0000, "leaf set_param override for other paths");
        command("clear_param path=mask");
        command("clear_param path=taf.h0.pf1.vf2.i0.mask");
        command("set_param path=taf.narrow value=0xff");
        check(read_narrow() == 8'hff, "8-bit target: 0xff is the full mask");

        check(taf_flags::describe(64'h8000_0000_0000_0013) == "0x8000000000000013 (A|B|D0|HIGH)",
              $sformatf("describe lists names by bit: %s", taf_flags::describe(64'h8000_0000_0000_0013)));
        check(taf_flags::describe(64'h111) == "0x111 (A|D0|0x100)",
              $sformatf("describe appends unnamed bits: %s", taf_flags::describe(64'h111)));
        check(taf_flags::describe(0) == "0x0", "describe(0) is 0x0");
        check(taf_flags::names(64'h12) == "B|D0", "names(0x12) is B|D0");
        v = taf_flags::parse("HIGH, a", 64);
        check(v == 64'h8000_0000_0000_0001, "parse() is usable directly");

        if (failures == 0) $display("TEST_AIP_FLAGS_PASS");
        else               $display("TEST_AIP_FLAGS_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
