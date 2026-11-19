// 用真实 VCS checkpoint 与 AIP loader 验证恢复后 CLI 的来源；期望 profile 由 Tcl 显式传入，不从待测 CLI 获取。
`include "aip_core_pkg.sv"

// 嵌套动态成员使测试同时覆盖 schema 的索引扫描及完整键查找，而非仅标量读取。
typedef struct { int value; string text; } ckpr_child_t;
`aip_struct_type_begin(ckpr_child_t)
    `aip_field_int(int, value, -1)
    `aip_field_string(text, "DEFAULT")
`aip_struct_type_end(ckpr_child_t)
typedef struct { ckpr_child_t children[]; } ckpr_tree_t;
`aip_struct_type_begin(ckpr_tree_t)
    `aip_field_struct_darray(ckpr_child_t, children, 0)
`aip_struct_type_end(ckpr_tree_t)

// 保存对象与每次重新解析的局部值分离，确认刷新不重跑 initial、不自动重赋业务配置。
class ckpr_state;
    static int saved_count;
    static int init_calls;

    // 仅时间零调用；此时来源须仍是 UVM singleton，不能提前分配刷新对象。
    static function void initialize();
        int count;
        if (aip_cmdline_source::get() != uvm_cmdline_processor::get_inst())
            $fatal(1, "CKPR_FAIL ordinary startup source changed");
        `aip_int("probe", int, count, 7)
        saved_count = count;
        init_calls++;
        $display("CKPR_INIT count=%0d calls=%0d", count, init_calls);
    endfunction

    // 失败即 fatal，生成阶段不能带错继续保存快照。
    static function void require(bit condition, string message);
        if (!condition) $fatal(1, "CKPR_FAIL %s", message);
    endfunction

    // profile A/B/C/N = 基准/变更/链式恢复/缺参；saved = 保存对象应来自的 profile；
    // source=private 检查恢复后的独占句柄，held 检查快照内已有 override 的优先级；首次 getter 不得消耗 RNG；
    // prints=<print_enable>:<max_prints> 为注册日志的当前设置（刷新后应按新进程完整键重读）。
    static task sample(string profile, string saved, string source_kind, int expected_held, string expected_prints);
        int count, dupe, newonly, oldonly, choice, held;
        string label, empty;
        int items[], q[$];
        ckpr_tree_t tree;
        int expected_count, expected_dupe, expected_new, expected_old, expected_choice, array_base;
        string expected_label, expected_empty, expected_text;
        uvm_cmdline_processor clp;
        process owner;
        string rng;
        string values[$];
        bit print_enable;
        int max_prints;
        string prints;

        case (profile)
            "A": begin
                expected_count=11; expected_label="BASE"; expected_dupe=2;
                expected_new=9; expected_old=71; expected_choice=5; array_base=10;
                expected_empty="OLD"; expected_text="old = text";
            end
            "B": begin
                expected_count=22; expected_label="NEW"; expected_dupe=9;
                expected_new=33; expected_old=-7; expected_choice=15; array_base=20;
                expected_empty="DEFAULT"; expected_text="new = text";
            end
            "C": begin
                expected_count=31; expected_label="CHAIN"; expected_dupe=19;
                expected_new=44; expected_old=-7; expected_choice=25; array_base=30;
                expected_empty="CHAINEMPTY"; expected_text="chain = text";
            end
            "N": begin
                expected_count=7; expected_label="DEFAULT"; expected_dupe=-1;
                expected_new=9; expected_old=-7; expected_choice=-1; array_base=0;
                expected_empty="DEFAULT"; expected_text="DEFAULT";
            end
            default: $fatal(1, "CKPR_FAIL invalid profile %s", profile);
        endcase
        owner = process::self();
        rng = owner.get_randstate();
        clp = aip_cmdline_source::get();
        require(owner.get_randstate() == rng, "refresh changed caller RNG");
        require(clp == aip_cmdline_source::get(), "repeated getter changed source");
        require((clp != uvm_cmdline_processor::get_inst()) == (source_kind == "private"), "singleton ownership");
        require(__aip_cmdline_refresh_ack == __aip_cmdline_refresh_request, "refresh did not acknowledge");
        require(init_calls == 1, "restore restarted initialization");
        require(saved_count == ((saved == "A") ? 11 : (saved == "B") ? 22 : (saved == "C") ? 31 : 7),
                "persisted business variable changed");

        `aip_int("probe", int, count, 7)
        `aip_string("probe", label, "DEFAULT")
        `aip_int("probe", int, dupe, -1)
        `aip_int("probe", int, newonly, 9)
        `aip_int("probe", int, oldonly, -7)
        `aip_int("probe", int, choice, -1)
        `aip_int("probe", int, held, -4)
        `aip_string("probe", empty, "DEFAULT")
        require(count == expected_count && label == expected_label, "current scalar CLI");
        require(dupe == expected_dupe, "last duplicate wins");
        require(newonly == expected_new && oldonly == expected_old, "new/deleted keys");
        require(choice == expected_choice, "full key before later leaf");
        require(held == expected_held, "snapshot override precedence");
        require(empty == expected_empty, "legacy empty suffix behavior");
        void'(clp.get_arg_values("+probe.empty=", values));
        if (profile == "B") require(values.size() == 1 && values[0] == "", "empty suffix lost");
        if (profile == "N") require(values.size() == 0, "absent CLI merged with old snapshot");

        `aip_int_list("probe", int, items, 0)
        `aip_int_queue("probe", int, q, 0, -1)
        `aip_struct_apply("probe.tree", ckpr_tree_t, tree)
        if (profile == "N") begin
            require(items.size() == 0 && q.size() == 0 && tree.children.size() == 0, "old arrays survived source refresh");
        end else begin
            require(items.size() == 2 && items[0] == array_base && items[1] == array_base+1, "indexed legacy array");
            require(q.size() == 2 && q[0] == array_base && q[1] == array_base+1, "strict primitive queue");
            require(tree.children.size() == 1 && tree.children[0].value == expected_count &&
                    tree.children[0].text == expected_text, "nested schema indexed/space/equal value");
        end
        aip_cmdline_print_control::get_config(print_enable, max_prints);
        prints = $sformatf("%0d:%0d", print_enable, max_prints);
        require(prints == expected_prints, {"print control ", prints, " expected ", expected_prints});
        $display("CKPR_SAMPLE profile=%s saved=%s source=%s count=%0d held=%0d prints=%s",
                 profile, saved, source_kind, count, held, prints);
    endtask
endclass

// 手工注册只为传递五个期望字段，业务检查仍走公开 AIP 宏。
class ckpr_command extends aip_cmd;
    task cmd_exec();
        string profile, saved, source_kind, held, prints;
        profile = aip_cmd::get_arg(args_in, "profile");
        saved = aip_cmd::get_arg(args_in, "saved");
        source_kind = aip_cmd::get_arg(args_in, "source");
        held = aip_cmd::get_arg(args_in, "held");
        prints = aip_cmd::get_arg(args_in, "prints");
        ckpr_state::sample(profile, saved, source_kind, held.atoi(), prints);
        result_out = "CKPR_OK";
        status = 0;
    endtask

    function new(string name); super.new(name); endfunction
    static ckpr_command instance = new("ckpr_sample");
endclass

// 顺序初始化后启动 bridge，消除时间零两个 initial 的先后竞争。
module test_checkpoint_cmdline;
    initial begin
        ckpr_state::initialize();
        aip_tcl_bridge::run_loop();
    end
endmodule
