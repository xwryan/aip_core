// 命令行零权重语义及用户调用位置诊断测试；错误用例分别启动进程，Makefile 校验 FATAL、非零退出码和用户来源。
`include "aip_log.sv"
`include "aip_cmdline.sv"

// 将标量、容器和 schema 放在同一入口，检查它们使用一致的零权重语义。
module test_cmdline_zero_weight;
    typedef struct { int value; real rate; } record_t;

    `aip_struct_type_begin(record_t)
        `aip_field_int(int, value, 0)
        `aip_field_real(rate, 0.0)
    `aip_struct_type_end(record_t)

    int eq, slash, mixed, rand_off, bad, good;
    real rate, bad_real, real_dyn[], bad_real_dyn[];
    int dyn[], unique_dyn[], bad_dyn[];
    int int_q[$], bad_int_q[$];
    real real_q[$], bad_real_q[$];
    record_t record, records[], legacy, bad_legacy, bad_record, bad_records[];
    string case_name;

    task automatic check(bit condition, string message);
        if (!condition) $fatal(1, "ZERO_WEIGHT_CHECK_FAIL: %s", message);
    endtask

    // 驱动器剔除这些期望行后再搜索真实错误文本。
    task automatic expect_error(string key, string value);
        $display("WEIGHT_EXPECT_KEY %s", key);
        $display("WEIGHT_EXPECT_VALUE %s", value);
    endtask

    // 多次抽样确保零权重的首/中/末项及 rand 分支从不被选中；运行期 override 的同语法回归见 test_set_param_expressions。
    task automatic run_positive();
        aip_cmdline_print_control::configure(0, 0);
        repeat (128) begin
            `aip_int("weighted", int, eq, 0)
            `aip_int("weighted", int, slash, 0)
            `aip_int("weighted", int, mixed, 0)
            `aip_int("weighted", int, rand_off, 0)
            `aip_real("weighted", rate, 0.0)
            check(eq == 7, ":= zero scalar arms excluded");
            check(slash == 8, ":/ zero range excluded");
            check(mixed == 12, "mixed := / :/ zero ranges excluded");
            check(rand_off == 13, "rand:/0 excluded");
            check(rate == 3.5, "real zero literal/range arms excluded");
        end

        aip_cmdline_override::set_val("weighted.dyn.size", "{0:=0,3:=1}");
        aip_cmdline_override::set_val("weighted.dyn.each", "{99:=0,4:=1}");
        aip_cmdline_override::set_val("weighted.dyn[1]", "{5:/1,99:/0}");
        `aip_int_list("weighted", int, dyn, 0)
        check(dyn.size() == 3 && dyn[0] == 4 && dyn[1] == 5 && dyn[2] == 4,
              "dynamic .size/.each/index zero weights");

        aip_cmdline_override::set_val("weighted.unique_dyn.size", "2");
        aip_cmdline_override::set_val("weighted.unique_dyn.each", "{99:=0,[1:2]:=1}");
        aip_cmdline_override::set_val("weighted.unique_dyn.unique", "1");
        `aip_int_list("weighted", int, unique_dyn, 0)
        check(unique_dyn.size() == 2 && unique_dyn[0] inside {1,2} &&
              unique_dyn[1] inside {1,2} && unique_dyn[0] != unique_dyn[1],
              "unique candidate enumeration excludes zero arms");

        aip_cmdline_override::set_val("weighted.int_q.size", "{0:=0,3:/1}");
        aip_cmdline_override::set_val("weighted.int_q.each", "{rand:/0,[6:6]:=1}");
        aip_cmdline_override::set_val("weighted.int_q[1]", "{99:=0,7:=1}");
        `aip_int_queue("weighted", int, int_q, 0, 3)
        check(int_q.size() == 3 && int_q[0] == 6 && int_q[1] == 7 && int_q[2] == 6,
              "strict integral queue validators accept zero arms");

        aip_cmdline_override::set_val("weighted.real_q.size", "{0:=0,2:=1}");
        aip_cmdline_override::set_val("weighted.real_q.each", "{[1.0:2.0]:/0,2.5:=1}");
        aip_cmdline_override::set_val("weighted.real_q[1]", "{3.5:/1,99.0:/0}");
        `aip_real_queue("weighted", real_q, 0.0, 2)
        check(real_q.size() == 2 && real_q[0] == 2.5 && real_q[1] == 3.5,
              "strict real queue validators accept zero arms");

        aip_cmdline_override::set_val("weighted.real_dyn", "{1.0:=0,2.5:=1},{3.5:/1,99.0:/0}");
        `aip_real_list("weighted", real_dyn, 0.0)
        check(real_dyn.size() == 2 && real_dyn[0] == 2.5 && real_dyn[1] == 3.5,
              "legacy real array zero arms");

        aip_cmdline_override::set_val("weighted.legacy.value", "{1:=0,16:=1}");
        aip_cmdline_override::set_val("weighted.legacy.rate", "{1.0:/0,5.5:/1}");
        `aip_struct_begin("weighted", legacy)
            `aip_struct_int(legacy, value, 0)
            `aip_struct_real(legacy, rate, 0.0)
        `aip_struct_end(legacy)
        check(legacy.value == 16 && legacy.rate == 5.5, "legacy struct zero arms");

        aip_cmdline_override::set_val("weighted.record.value", "{1:=0,14:=1}");
        aip_cmdline_override::set_val("weighted.record.rate", "{1.0:/0,4.5:/1}");
        `aip_struct_apply("weighted.record", record_t, record)
        check(record.value == 14 && record.rate == 4.5, "schema scalar zero arms");

        aip_cmdline_override::set_val("weighted.records.size", "{0:=0,2:=1}");
        aip_cmdline_override::set_val("weighted.records.each.value", "{1:=0,15:=1}");
        `aip_struct_darray_apply("weighted.records", record_t, records, 0)
        check(records.size() == 2 && records[0].value == 15 && records[1].value == 15,
              "schema .size and inherited each zero arms");
        $display("CMDLINE_ZERO_WEIGHT_PASS");
    endtask

    // 源行号在调用宏前动态记录（改动行数不破坏断言）；普通参数打印全关，验证诊断不受 print_enable/max_prints 限制。
    task automatic run_negative();
        aip_cmdline_print_control::configure(0, 0);
        case (case_name)
            "scalar_zero", "scalar_negative": begin
                expect_error("weighted.bad", case_name == "scalar_zero" ? "{1:=0,2:/0}" : "{1:=-1,2:=3}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int("weighted", int, bad, 0)
            end
            "real_zero", "real_negative": begin
                expect_error("weighted.bad_real", case_name == "real_zero" ? "{1.0:=0,2.0:/0}" : "{1.0:=-1,2.0:=3}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_real("weighted", bad_real, 0.0)
            end
            "single_zero": begin
                expect_error("weighted.bad", "7:=0");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int("weighted", int, bad, 0)
            end
            "fallback_zero": begin
                // leaf plusarg 回退仍须报告请求的完整作用域和实际消费的原始值。
                expect_error("weighted.bad", "{1:=0,2:/0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int("weighted", int, bad, 0)
            end
            "disabled_malformed": begin
                expect_error("weighted.bad", "{broken:=0,2:=1}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int("weighted", int, bad, 0)
            end
            "real_disabled_malformed": begin
                expect_error("weighted.bad_real", "{broken:=0,2.0:=1}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_real("weighted", bad_real, 0.0)
            end
            "scalar_malformed": begin
                expect_error("weighted.bad", "not_an_int");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int("weighted", int, bad, 0)
            end
            "each_zero": begin
                aip_cmdline_override::set_val("weighted.bad_dyn.size", "2");
                aip_cmdline_override::set_val("weighted.bad_dyn.each", "{1:=0,2:=0}");
                expect_error("weighted.bad_dyn.each", "{1:=0,2:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int_list("weighted", int, bad_dyn, 0)
            end
            "index_negative": begin
                aip_cmdline_override::set_val("weighted.bad_dyn.size", "2");
                aip_cmdline_override::set_val("weighted.bad_dyn[1]", "{1:=-1,2:=3}");
                expect_error("weighted.bad_dyn[1]", "{1:=-1,2:=3}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int_list("weighted", int, bad_dyn, 0)
            end
            "size_zero": begin
                aip_cmdline_override::set_val("weighted.bad_dyn.size", "{1:=0,2:=0}");
                expect_error("weighted.bad_dyn.size", "{1:=0,2:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int_list("weighted", int, bad_dyn, 0)
            end
            "queue_zero", "queue_negative": begin
                aip_cmdline_override::set_val("weighted.bad_int_q.size", "2");
                aip_cmdline_override::set_val("weighted.bad_int_q.each", case_name == "queue_zero" ? "{1:=0,2:=0}" : "{1:=-1,2:=3}");
                expect_error("weighted.bad_int_q.each", case_name == "queue_zero" ? "{1:=0,2:=0}" : "{1:=-1,2:=3}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int_queue("weighted", int, bad_int_q, 0, 2)
            end
            "real_queue_zero", "real_queue_negative": begin
                aip_cmdline_override::set_val("weighted.bad_real_q.size", "2");
                aip_cmdline_override::set_val("weighted.bad_real_q.each", case_name == "real_queue_zero" ? "{1.0:=0,2.0:=0}" : "{1.0:=-1,2.0:=3}");
                expect_error("weighted.bad_real_q.each", case_name == "real_queue_zero" ? "{1.0:=0,2.0:=0}" : "{1.0:=-1,2.0:=3}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_real_queue("weighted", bad_real_q, 0.0, 2)
            end
            "queue_size_zero": begin
                aip_cmdline_override::set_val("weighted.bad_int_q.size", "{1:=0,2:=0}");
                expect_error("weighted.bad_int_q.size", "{1:=0,2:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_int_queue("weighted", int, bad_int_q, 0, 2)
            end
            "struct_zero": begin
                aip_cmdline_override::set_val("weighted.bad_record.value", "{1:=0,2:=0}");
                expect_error("weighted.bad_record.value", "{1:=0,2:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_struct_apply("weighted.bad_record", record_t, bad_record)
            end
            "struct_size_zero": begin
                aip_cmdline_override::set_val("weighted.bad_records.size", "{1:=0,2:=0}");
                expect_error("weighted.bad_records.size", "{1:=0,2:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_struct_darray_apply("weighted.bad_records", record_t, bad_records, 0)
            end
            "real_array_zero": begin
                aip_cmdline_override::set_val("weighted.bad_real_dyn", "{1.0:=0,2.0:=0}");
                expect_error("weighted.bad_real_dyn[0]", "{1.0:=0,2.0:=0}");
                $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                `aip_real_list("weighted", bad_real_dyn, 0.0)
            end
            "legacy_int_zero": begin
                aip_cmdline_override::set_val("weighted.bad_legacy.value", "{1:=0,2:=0}");
                expect_error("weighted.bad_legacy.value", "{1:=0,2:=0}");
                `aip_struct_begin("weighted", bad_legacy)
                    $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                    `aip_struct_int(bad_legacy, value, 0)
                `aip_struct_end(bad_legacy)
            end
            "legacy_real_zero": begin
                aip_cmdline_override::set_val("weighted.bad_legacy.rate", "{1.0:=0,2.0:=0}");
                expect_error("weighted.bad_legacy.rate", "{1.0:=0,2.0:=0}");
                `aip_struct_begin("weighted", bad_legacy)
                    $display("WEIGHT_EXPECT_LINE %0d", `__LINE__ + 1);
                    `aip_struct_real(bad_legacy, rate, 0.0)
                `aip_struct_end(bad_legacy)
            end
            "context_cleared": begin
                aip_cmdline_override::set_val("weighted.good", "17");
                `aip_int("weighted", int, good, 0)
                check(good == 17, "successful prior call");
                // 直接解析没有用户宏调用点，不能继承上一条参数名或其源码位置。
                bad = aip_cmdline#(int)::parse_value("{1:=0,2:=0}");
            end
            default: $fatal(1, "unknown AIP_WEIGHT_CASE %s", case_name);
        endcase
        $fatal(1, "CMDLINE_ZERO_WEIGHT_UNEXPECTED_PASS case=%s", case_name);
    endtask

    initial begin
        if ($value$plusargs("AIP_WEIGHT_CASE=%s", case_name)) run_negative();
        else run_positive();
        $finish;
    end
endmodule
