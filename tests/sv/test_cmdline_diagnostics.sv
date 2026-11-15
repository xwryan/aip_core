// 非权重解析失败的诊断测试：用户来源、原始输入与立即终止；每个负例独立运行，驱动器校验真实 FATAL 与非零退出码。
`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_diagnostics;
    typedef enum { MODE_OFF, MODE_ON } mode_t;
    typedef struct { int value; real rate; mode_t mode; string label; } record_t;

    `aip_struct_type_begin(record_t)
        `aip_field_int(int, value, 0)
        `aip_field_real(rate, 0.0)
        `aip_field_enum(mode_t, mode, MODE_OFF)
        `aip_field_string(label, "")
    `aip_struct_type_end(record_t)

    int scalar, values[], direct, good, integers[$];
    real rate, rates[], reals[$];
    mode_t mode, modes[$];
    string words[$], text_value;
    record_t legacy, record, records[];
    uvm_root root;
    string case_name, raw;

    // 缺失参数用显式 <missing>，不伪装成空串输入。
    task automatic expect_error(string key, string value, int line,
                                string source_file = "test_cmdline_diagnostics.sv");
        $display("DIAG_EXPECT_KEY %s", key);
        $display("DIAG_EXPECT_VALUE %s", value);
        $display("DIAG_EXPECT_FILE %s", source_file);
        $display("DIAG_EXPECT_LINE %0d", line);
    endtask

    // 合法 real 语法和空 override 保持原语义；普通 aip_error 仍只计数/打印并返回。
    task automatic run_positive();
        int error_count;
        `aip_real("diag", rate, 0.0)
        if (rate != 1250.0) $fatal(1, "DIAG_POSITIVE_SCIENTIFIC");
        if (aip_cmdline_real::parse_value("-2.5") != -2.5)
            $fatal(1, "DIAG_POSITIVE_LITERAL");
        repeat (32) begin
            rate = aip_cmdline_real::parse_value("[1.5:2.5]");
            if (rate < 1.5 || rate > 2.5) $fatal(1, "DIAG_POSITIVE_RANGE");
            rate = aip_cmdline_real::parse_value("inc:0.5:2.5:1.0");
            if (rate != 0.5 && rate != 1.5 && rate != 2.5)
                $fatal(1, "DIAG_POSITIVE_INC");
            rate = aip_cmdline_real::parse_value("dec:2.5:0.5:1.0");
            if (rate != 0.5 && rate != 1.5 && rate != 2.5)
                $fatal(1, "DIAG_POSITIVE_DEC");
        end
        aip_cmdline_override::set_val("diag.rates.size", "2");
        aip_cmdline_override::set_val("diag.rates", "1.25e2,-2.5");
        `aip_real_list("diag", rates, 0.0)
        if (rates.size() != 2 || rates[0] != 125.0 || rates[1] != -2.5)
            $fatal(1, "DIAG_POSITIVE_REAL_ARRAY");
        aip_cmdline_override::set_val("diag.rate", "");
        `aip_real("diag", rate, 9.0)
        if (rate != 0.0) $fatal(1, "DIAG_POSITIVE_EMPTY_OVERRIDE");
        error_count = aip_log::get_count(aip_log::ERROR);
        `aip_error(("DIAG_EXPECTED_LOG_ONLY_ERROR"));
        if (aip_log::get_count(aip_log::ERROR) != error_count + 1)
            $fatal(1, "DIAG_POSITIVE_ERROR_COUNT");
        $display("CMDLINE_DIAGNOSTICS_POSITIVE_PASS");
    endtask

    // 各种成功入口先恢复上下文，再验证后续独立 API 的来源不被覆盖。
    task automatic prepare_successful_calls();
        aip_cmdline_override::set_val("diag.good", "17");
        `aip_int("diag", int, good, 0)
        `aip_enum("diag", mode_t, mode, MODE_ON)
        `aip_str_queue("diag", words, "ok", 4)
        `aip_enum_queue("diag", mode_t, modes, MODE_ON, 4)
        `aip_struct_begin("diag", legacy)
            `aip_struct_int(legacy, value, 1)
            `aip_struct_string(legacy, label, "ok")
            `aip_struct_enum(mode_t, legacy, mode, MODE_ON)
        `aip_struct_end(legacy)
        if (good != 17 || legacy.value != 1 || legacy.mode != MODE_ON)
            $fatal(1, "DIAG_SETUP_FAILED");
    endtask

    // 随机表达式通过 plusarg 输入；另用非法 override 验证同一解析路径的来源诊断。
    initial begin
        aip_cmdline_print_control::configure(0, 0);
        if (!$value$plusargs("AIP_DIAG_CASE=%s", case_name))
            $fatal(1, "missing AIP_DIAG_CASE");
        case (case_name)
            "positive": begin
                run_positive();
                $finish;
            end
            "real_literal", "real_range", "real_inc", "real_list", "real_overflow": begin
                if (!$value$plusargs("diag.rate=%s", raw)) $fatal(1, "missing diag.rate");
                expect_error("diag.rate", raw, `__LINE__ + 1);
                `aip_real("diag", rate, 0.0)
            end
            "real_override": begin
                aip_cmdline_override::set_val("diag.rate", "1.0junk");
                expect_error("diag.rate", "1.0junk", `__LINE__ + 1);
                `aip_real("diag", rate, 0.0)
            end
            "real_array": begin
                aip_cmdline_override::set_val("diag.rates", "1.0,broken");
                expect_error("diag.rates[1]", "1.0,broken", `__LINE__ + 1);
                `aip_real_list("diag", rates, 0.0)
            end
            "real_array_size_malformed", "real_array_size_negative": begin
                raw = case_name == "real_array_size_malformed" ? "broken" : "-1";
                aip_cmdline_override::set_val("diag.rates.size", raw);
                expect_error("diag.rates.size", raw, `__LINE__ + 1);
                `aip_real_list("diag", rates, 0.0)
            end
            "enum_literal", "enum_list", "enum_range": begin
                raw = case_name == "enum_literal" ? "NO_SUCH_MODE" :
                      case_name == "enum_list" ? "NO_SUCH_MODE,ALSO_BAD" : "[MODE_OFF:NO_SUCH_MODE]";
                aip_cmdline_override::set_val("diag.mode", raw);
                expect_error("diag.mode", raw, `__LINE__ + 1);
                `aip_enum("diag", mode_t, mode, MODE_OFF)
            end
            "legacy_compact": begin
                aip_cmdline_override::set_val("diag.legacy", "{value}");
                expect_error("diag.legacy", "{value}", `__LINE__ + 1);
                `aip_struct_begin("diag", legacy)
                    `aip_struct_int(legacy, value, 0)
                `aip_struct_end(legacy)
            end
            "legacy_enum": begin
                aip_cmdline_override::set_val("diag.legacy.mode", "NO_SUCH_MODE");
                `aip_struct_begin("diag", legacy)
                    expect_error("diag.legacy.mode", "NO_SUCH_MODE", `__LINE__ + 1);
                    `aip_struct_enum(mode_t, legacy, mode, MODE_OFF)
                `aip_struct_end(legacy)
            end
            "legacy_real": begin
                aip_cmdline_override::set_val("diag.legacy.rate", "1.0junk");
                `aip_struct_begin("diag", legacy)
                    expect_error("diag.legacy.rate", "1.0junk", `__LINE__ + 1);
                    `aip_struct_real(legacy, rate, 0.0)
                `aip_struct_end(legacy)
            end
            "required_int": begin
                aip_cmdline#(int)::global_required = 1;
                expect_error("diag.scalar", "<missing>", `__LINE__ + 1);
                `aip_int("diag", int, scalar, 0)
            end
            "required_real": begin
                aip_cmdline#(int)::global_required = 1;
                expect_error("diag.rate", "<missing>", `__LINE__ + 1);
                `aip_real("diag", rate, 0.0)
            end
            "required_string": begin
                aip_cmdline#(string)::global_required = 1;
                expect_error("diag.text_value", "<missing>", `__LINE__ + 1);
                `aip_string("diag", text_value, "")
            end
            "required_enum": begin
                aip_cmdline#(int)::global_required = 1;
                expect_error("diag.mode", "<missing>", `__LINE__ + 1);
                `aip_enum("diag", mode_t, mode, MODE_OFF)
            end
            "required_array_size": begin
                aip_cmdline#(int)::global_required = 1;
                expect_error("diag.values.size", "<missing>", `__LINE__ + 1);
                `aip_int_list("diag", int, values, 0)
            end
            "array_sort": begin
                aip_cmdline_override::set_val("diag.values.sort", "sideways");
                expect_error("diag.values.sort", "sideways", `__LINE__ + 1);
                `aip_int_list("diag", int, values, 0)
            end
            "int_queue_sort", "int_queue_unique": begin
                raw = case_name == "int_queue_sort" ? "sort" : "unique";
                aip_cmdline_override::set_val({"diag.integers.", raw}, "bad_control");
                expect_error({"diag.integers.", raw}, "bad_control", `__LINE__ + 1);
                `aip_int_queue("diag", int, integers, 0, 4)
            end
            "real_queue_sort", "real_queue_unique": begin
                raw = case_name == "real_queue_sort" ? "sort" : "unique";
                aip_cmdline_override::set_val({"diag.reals.", raw}, "bad_control");
                expect_error({"diag.reals.", raw}, "bad_control", `__LINE__ + 1);
                `aip_real_queue("diag", reals, 0.0, 4)
            end
            "int_queue_fixed_invalid": begin
                aip_cmdline_override::set_val("diag.integers.size", "1");
                aip_cmdline_override::set_val("diag.integers.unique", "1");
                aip_cmdline_override::set_val("diag.integers[0]", "broken");
                expect_error("diag.integers[0]", "broken", `__LINE__ + 1);
                `aip_int_queue("diag", int, integers, 0, 4)
            end
            "real_queue_fixed_invalid": begin
                aip_cmdline_override::set_val("diag.reals.size", "1");
                aip_cmdline_override::set_val("diag.reals.unique", "1");
                aip_cmdline_override::set_val("diag.reals[0]", "broken");
                expect_error("diag.reals[0]", "broken", `__LINE__ + 1);
                `aip_real_queue("diag", reals, 0.0, 4)
            end
            "string_queue_sort", "string_queue_unique", "string_queue_size": begin
                raw = case_name == "string_queue_sort" ? "sort" :
                      case_name == "string_queue_unique" ? "unique" : "size";
                aip_cmdline_override::set_val({"diag.words.", raw}, "bad_control");
                expect_error({"diag.words.", raw}, "bad_control", `__LINE__ + 1);
                `aip_str_queue("diag", words, "", 4)
            end
            "string_queue_literal": begin
                aip_cmdline_override::set_val("diag.words", "\"bad\\q\"");
                expect_error("diag.words", "\"bad\\q\"", `__LINE__ + 1);
                `aip_str_queue("diag", words, "", 4)
            end
            "enum_queue_sort", "enum_queue_unique", "enum_queue_size": begin
                raw = case_name == "enum_queue_sort" ? "sort" :
                      case_name == "enum_queue_unique" ? "unique" : "size";
                aip_cmdline_override::set_val({"diag.modes.", raw}, "bad_control");
                expect_error({"diag.modes.", raw}, "bad_control", `__LINE__ + 1);
                `aip_enum_queue("diag", mode_t, modes, MODE_OFF, 4)
            end
            "enum_queue_literal": begin
                aip_cmdline_override::set_val("diag.modes.size", "1");
                aip_cmdline_override::set_val("diag.modes[0]", "NO_SUCH_MODE");
                expect_error("diag.modes[0]", "NO_SUCH_MODE", `__LINE__ + 1);
                `aip_enum_queue("diag", mode_t, modes, MODE_OFF, 4)
            end
            "schema_compact": begin
                aip_cmdline_override::set_val("diag.record", "{value}");
                expect_error("diag.record", "{value}", `__LINE__ + 1);
                `aip_struct_apply("diag.record", record_t, record)
            end
            "schema_real": begin
                aip_cmdline_override::set_val("diag.record.rate", "1.0junk");
                expect_error("diag.record.rate", "1.0junk", `__LINE__ + 1);
                `aip_struct_apply("diag.record", record_t, record)
            end
            "schema_enum": begin
                aip_cmdline_override::set_val("diag.record.mode", "NO_SUCH_MODE");
                expect_error("diag.record.mode", "NO_SUCH_MODE", `__LINE__ + 1);
                `aip_struct_apply("diag.record", record_t, record)
            end
            "schema_sort": begin
                aip_cmdline_override::set_val("diag.records.size", "1");
                aip_cmdline_override::set_val("diag.records.each.value.sort", "sideways");
                expect_error("diag.records.each.value.sort", "sideways", `__LINE__ + 1);
                `aip_struct_darray_apply("diag.records", record_t, records, 0)
            end
            "direct_int", "context_after_success": begin
                if (case_name == "context_after_success") prepare_successful_calls();
                aip_cmdline_override::set_val("diag.direct", "broken");
                expect_error("diag.direct", "broken", 137, "user_cfg_direct.sv");
                aip_cmdline#(int)::get_single_value("direct", "diag", 0, direct, "user_cfg_direct.sv", 137);
            end
            "direct_real": begin
                aip_cmdline_override::set_val("diag.rate", "broken");
                expect_error("diag.rate", "broken", 241, "user_cfg_direct.sv");
                aip_cmdline_real::get_single_value("rate", "diag", 0.0, rate, "user_cfg_direct.sv", 241);
            end
            "fatal_cannot_be_suppressed": begin
                // 配置错误必须独立于普通日志过滤和 UVM fatal action，避免继续使用错误值。
                aip_log::set_verbosity(aip_log::level_t'(-1));
                root = uvm_root::get();
                root.set_report_severity_action(UVM_FATAL, UVM_NO_ACTION);
                aip_cmdline_override::set_val("diag.scalar", "broken");
                expect_error("diag.scalar", "broken", `__LINE__ + 1);
                `aip_int("diag", int, scalar, 0)
            end
            default: $fatal(1, "unknown AIP_DIAG_CASE %s", case_name);
        endcase
        // FATAL 必须终止当前调用；驱动器检查此标记绝不能出现。
        $display("CMDLINE_DIAGNOSTICS_UNEXPECTED_CONTINUE case=%s", case_name);
        $finish;
    end
endmodule
