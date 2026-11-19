// 可选参数（_opt）、路径别名、选根容器、枚举 rand/数值候选与键使用记录；+tco_neg=<case> 单独运行非法输入，预期 hard fatal。
`include "aip_core_pkg.sv"

package tco_pkg;
    typedef enum bit [3:0] {A = 1, B = 5, C = 9} abc_e;
    typedef enum {RAND, OTHER} rand_member_e;
    typedef enum int {NEG = -1, POS = 3} signed_e;
endpackage

module test_cmdline_opt;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import tco_pkg::*;

    int unsigned	failures = 0;

    function automatic void check(bit	cond, string	what);
        if (!cond) begin
            failures++;
            $display("TCO_FAIL: %s", what);
        end else begin
            $display("TCO_OK:   %s", what);
        end
    endfunction

    // 来源顺序：override(完整、别名、叶名) 再 plusarg(完整、别名、叶名)；空值保持原值并屏蔽其后来源。
    task automatic check_scalar_sources();
        int		v;
        int		pa;
        int		pl;
        int		pe;
        int		w;
        int		missing;
        bit		given;
        string	state;
        process	owner;
        owner = process::self();
        aip_cmdline_override::clear_all();
        aip_cmdline_alias::push("o.outer_x", "o.x");
        aip_cmdline_override::set_val("o.outer_x.v", "11");
        aip_cmdline_override::set_val("o.x.v", "12");
        aip_cmdline_override::set_val("v", "13");
        v = 0; `aip_int_opt("o.outer_x", int, v)
        check(v == 11, "override full path wins");
        aip_cmdline_override::clear("o.outer_x.v");
        v = 0; `aip_int_opt("o.outer_x", int, v)
        check(v == 12, "override alias beats override leaf");
        aip_cmdline_override::clear("o.x.v");
        v = 0; `aip_int_opt("o.outer_x", int, v)
        check(v == 13, "override leaf beats every plusarg");
        aip_cmdline_override::clear("v");
        v = 0; `aip_int_opt("o.outer_x", int, v)
        check(v == 21, "plusarg full path after overrides");
        pa = 0; `aip_int_opt("o.outer_x", int, pa)
        check(pa == 22, "plusarg alias beats plusarg leaf");
        pl = 0; `aip_int_opt("o.outer_x", int, pl)
        check(pl == 23, "plusarg leaf is the last source");
        pe = 99; given = 0; `aip_int_opt("o.outer_x", int, pe, given)
        check(pe == 99 && !given, "empty plusarg at full path keeps value and blocks the alias");
        aip_cmdline_override::set_val("o.outer_x.v", "");
        v = 98; given = 0; `aip_int_opt("o.outer_x", int, v, given)
        check(v == 98 && !given, "empty override keeps value (opt) and blocks lower sources");
        v = 5; `aip_int("o.outer_x", int, v, 7)
        check(v == 0, "aip_int keeps its rule: empty override gives the type initial value");
        aip_cmdline_override::clear("o.outer_x.v");
        v = 0; `aip_int("o.outer_x", int, v, 7)
        check(v == 21, "aip_int also sees the alias chain");
        aip_cmdline_override::set_val("o.x.sub.w", "7");
        w = 0; `aip_int_opt("o.outer_x.sub", int, w)
        check(w == 7, "alias maps sub paths");
        state = owner.get_randstate();
        missing = 44; given = 0; `aip_int_opt("o.outer_x", int, missing, given)
        check(missing == 44 && !given && owner.get_randstate() == state, "missing keeps value, flag and RNG");
        given = 0;
        `aip_int_opt("o.outer_x", int, missing, given)
        `aip_int_opt("o.outer_x", int, pa, given)
        check(given, "given accumulates over several reads");
        check(aip_cmdline_query::present("o.outer_x", "sub"), "present sees alias sub keys");
        aip_cmdline_alias::pop();
        pa = 0; `aip_int_opt("o.outer_x", int, pa)
        check(pa == 23, "after pop the alias no longer applies");
        aip_cmdline_alias::push("n", "m");
        aip_cmdline_alias::push("n.c", "n.d");
        check(aip_cmdline_alias::resolve("n.c.k") == "n.d.k" && aip_cmdline_alias::resolve("n.e") == "m.e",
              "nested aliases: innermost first, outer still maps other sub paths");
        aip_cmdline_alias::push("n.c", "");
        check(aip_cmdline_alias::resolve("n.c") == "", "empty alias disables the outer mapping for that path");
        aip_cmdline_alias::pop();
        aip_cmdline_alias::pop();
        aip_cmdline_alias::pop();
        check(aip_cmdline_alias::resolve("n.c") == "", "all aliases popped");
    endtask

    task automatic check_string_and_enum();
        string			color;
        abc_e			e;
        abc_e			seen[abc_e];
        abc_e			cands[$];
        rand_member_e	r;
        signed_e		s;
        bit				given;
        aip_cmdline_override::clear_all();
        aip_cmdline_override::set_val("s.color", "red");
        color = "none"; `aip_string_opt("s", color)
        check(color == "red", "string opt literal");
        aip_cmdline_override::set_val("s.color", "");
        color = "keep"; given = 0; `aip_string_opt("s", color, given)
        check(color == "keep" && !given, "empty string override keeps value");
        aip_cmdline_override::set_val("s.e", "rand");
        repeat (64) begin
            `aip_enum_opt("s", abc_e, e)
            seen[e] = 1;
        end
        check(seen.num() == 3, "rand draws every member");
        aip_cmdline_override::set_val("s.e", "0x5");
        e = A; `aip_enum_opt("s", abc_e, e)
        check(e == B, "numeric literal selects the member with that value");
        aip_cmdline_override::set_val("s.e", " c , 4'd1 ");
        repeat (16) begin
            `aip_enum_opt("s", abc_e, e)
            check(e inside {C, A}, "names (case-insensitive) mixed with sized literals");
        end
        `aip_enum_candidates("s", abc_e, e, cands)
        check(cands.size() == 2 && cands[0] == C && cands[1] == A, "candidates listed without sampling");
        aip_cmdline_override::clear("s.e");
        `aip_enum_candidates("s", abc_e, e, cands)
        check(cands.size() == 0, "no candidates when not given");
        e = C; given = 0; `aip_enum_opt("s", abc_e, e, given)
        check(e == C && !given, "missing enum keeps value");
        aip_cmdline_override::set_val("s.e", "9");
        `aip_enum("s", abc_e, e, A)
        check(e == C, "aip_enum also accepts member values");
        aip_cmdline_override::set_val("s.r", "rand");
        repeat (8) begin
            `aip_enum_opt("s", rand_member_e, r)
            check(r == RAND, "a member named RAND wins over the rand keyword");
        end
        aip_cmdline_override::set_val("s.s", "-1");
        `aip_enum_opt("s", signed_e, s)
        check(s == NEG, "negative literal matches a negative member value");
    endtask

    // 容器先选根：完整根下有任一键时不与别名根合并；override 根优先于 plusarg 根；无键保持原容器。
    task automatic check_array_roots();
        int				arr[];
        int				arr2[];
        int				arr3[];
        int				ar[];
        byte unsigned	q[$];
        bit [7:0]		f[3];
        bit				given;
        aip_cmdline_override::clear_all();
        aip_cmdline_alias::push("o.outer_x", "o.x");
        aip_cmdline_override::set_val("o.outer_x.arr.size", "2");
        aip_cmdline_override::set_val("o.x.arr", "9,9,9");
        `aip_int_list_opt("o.outer_x", int, arr)
        check(arr.size() == 2 && arr[0] == 0 && arr[1] == 0, "full root selected as a whole");
        aip_cmdline_override::set_val("o.x.arr2", "5");
        `aip_int_list_opt("o.outer_x", int, arr2)
        check(arr2.size() == 1 && arr2[0] == 5, "override alias root beats plusarg full root");
        arr3 = '{7, 8}; given = 0;
        `aip_int_list_opt("o.outer_x", int, arr3, 0, given)
        check(arr3.size() == 2 && arr3[1] == 8 && !given, "no key under any root keeps the container");
        aip_cmdline_override::set_val("o.outer_x.q", "seq:1:4");
        q = '{42};
        `aip_int_list_opt("o.outer_x", byte unsigned, q)
        check(q.size() == 4 && q[3] == 4, "queue target replaced");
        aip_cmdline_override::set_val("o.x.f[1]", "6");
        f = '{1, 2, 3};
        `aip_int_slist_opt("o.outer_x", bit [7:0], f)
        check(f[0] == 0 && f[1] == 6 && f[2] == 0, "fixed array replaced, other elements use the default");
        aip_cmdline_override::set_val("o.outer_x.arx", "1");
        ar = '{7};
        `aip_int_list_opt("o.outer_x", int, ar)
        check(ar.size() == 1 && ar[0] == 7, "similar prefix is not under the root");
        aip_cmdline_alias::pop();
    endtask

    // 记录期间被查询的键（含容器根下的键）不算未用；其余落在前缀下的 override/plusarg 键按字典序列出。
    task automatic check_usage();
        int		a;
        int		b;
        int		list[];
        string	unused[$];
        string	state;
        process	owner;
        owner = process::self();
        aip_cmdline_override::clear_all();
        aip_cmdline_override::set_val("u.outer_y.a", "1");
        aip_cmdline_override::set_val("u.y.b", "2");
        aip_cmdline_override::set_val("u.outer_y.list[2]", "4");
        aip_cmdline_override::set_val("u.outer_y.junk", "1");
        aip_cmdline_override::set_val("u.zzz.k", "1");
        aip_cmdline_override::set_val("uu.k", "1");
        state = owner.get_randstate();
        aip_cmdline_usage::record_begin();
        aip_cmdline_alias::push("u.outer_y", "u.y");
        `aip_int_opt("u.outer_y", int, a)
        `aip_int_opt("u.outer_y", int, b)
        `aip_int_list_opt("u.outer_y", int, list)
        void'(aip_cmdline_query::present("u", "flag"));
        aip_cmdline_alias::pop();
        aip_cmdline_usage::record_end("u", unused);
        check(a == 1 && b == 2 && list.size() == 3, "values read while recording");
        check(owner.get_randstate() == state, "fixed values and recording consume no RNG");
        $display("TCO_UNUSED %p", unused);
        check(unused.size() == 3 && unused[0] == "u.outer_y.junk" && unused[1] == "u.y.typo" &&
              unused[2] == "u.zzz.k", "unused keys under the prefix (override and plusarg), sorted");
        check(!aip_cmdline_usage::recording(), "recording ended");
        aip_cmdline_override::set_val("u.again", "1");
        `aip_int_opt("u", int, a)
        aip_cmdline_usage::record_begin();
        aip_cmdline_usage::record_end("u", unused);
        check(unused.size() == 7, "a new record starts empty");
    endtask

    task automatic run_negative(string	c);
        abc_e	e;
        int		v;
        case (c)
            "enum_number": begin
                aip_cmdline_override::set_val("bad.e", "A,7");
                `aip_enum_opt("bad", abc_e, e)
            end
            "enum_range": begin
                aip_cmdline_override::set_val("bad.e", "[1:5]");
                `aip_enum_opt("bad", abc_e, e)
            end
            "enum_rand_list": begin
                aip_cmdline_override::set_val("bad.e", "rand,A");
                `aip_enum_opt("bad", abc_e, e)
            end
            "opt_syntax": begin
                aip_cmdline_alias::push("bad.outer_x", "bad.x");
                aip_cmdline_override::set_val("bad.x.v", "[5:1]");
                `aip_int_opt("bad.outer_x", int, v)
            end
            default: $display("TCO_FAIL: unknown negative case %s", c);
        endcase
        $display("TCO_FAIL: negative case %s was accepted", c);
        $finish;
    endtask

    initial begin
        string	neg_case;
        if ($value$plusargs("tco_neg=%s", neg_case)) run_negative(neg_case);
        check_scalar_sources();
        check_string_and_enum();
        check_array_roots();
        check_usage();
        if (failures == 0) $display("TEST_CMDLINE_OPT_PASS");
        else               $display("TEST_CMDLINE_OPT_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
