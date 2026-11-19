`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_print_control;
    typedef enum { MODE_ZERO, MODE_ONE } mode_t;
    typedef struct {
        int     count;
        string  label;
        real    ratio;
        mode_t  mode;
    } config_t;

    int failures;
    string test_mode;

    int repeated;
    int shared;
    int int_value;
    string string_value;
    int int_values[];
    string string_values[];
    int int_static[2];
    string string_static[2];
    real real_value;
    real real_values[];
    mode_t mode_value;
    config_t cfg;

    task automatic check_true(string label, bit condition);
        if (!condition) begin
            failures++;
            $error("%s", label);
        end
    endtask

    task automatic check_int(string label, int actual, int expected);
        if (actual != expected) begin
            failures++;
            $error("%s: got %0d expected %0d", label, actual, expected);
        end
    endtask

    task automatic check_string(string label, string actual, string expected);
        if (actual != expected) begin
            failures++;
            $error("%s: got '%s' expected '%s'", label, actual, expected);
        end
    endtask

    task automatic check_info_delta(string label, int before_count, int expected);
        int actual;
        actual = aip_log::get_count(aip_log::INFO) - before_count;
        check_int(label, actual, expected);
    endtask

    task automatic finish_mode(string mode_name);
        if (failures != 0)
            $fatal(1, "CMDLINE_PRINT_CONTROL_FAIL mode=%s failures=%0d",
                   mode_name, failures);
        $display("CMDLINE_PRINT_CONTROL_PASS mode=%s", mode_name);
        $finish;
    endtask

    task automatic run_startup_default();
        int before_count;
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("startup.default", int, repeated, 0);
        end
        check_info_delta("default lazy limit", before_count, 10);
        finish_mode("startup-default");
    endtask

    task automatic run_startup_limit();
        int before_count;
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("startup.limit", int, repeated, 0);
        end
        check_info_delta("startup max_prints=2", before_count, 2);
        finish_mode("startup-limit");
    endtask

    task automatic run_startup_normalized();
        int before_info_count;
        int before_warning_count;

        before_info_count = aip_log::get_count(aip_log::INFO);
        before_warning_count = aip_log::get_count(aip_log::WARNING);
        repeat (12) begin
            `aip_int("startup.normalized", int, repeated, 0);
        end
        check_int("startup max_prints below -1 normalizes",
                  aip_cmdline_print_control::max_prints, -1);
        check_int("startup normalization warning count",
                  aip_log::get_count(aip_log::WARNING) - before_warning_count,
                  1);
        check_info_delta("startup normalized max_prints is unlimited",
                         before_info_count, 12);
        finish_mode("startup-normalized");
    endtask

    task automatic run_startup_disabled();
        int before_count;
        before_count = aip_log::get_count(aip_log::INFO);
        `aip_int("startup", int, repeated, 0);
        check_info_delta("startup print_enable=0", before_count, 0);
        check_int("startup parsing remains enabled", repeated, 77);
        finish_mode("startup-disabled");
    endtask

    task automatic check_config(string label, bit expected_enable, int expected_max);
        bit enable;
        int limit;
        aip_cmdline_print_control::get_config(enable, limit);
        check_int({label, ": print_enable"}, enable, expected_enable);
        check_int({label, ": max_prints"}, limit, expected_max);
    endtask

    // 命令行同时给叶名 +print_enable=0 +max_prints=1 和别名 +alt.*；叶名 override 与别名都不得改变默认 1/10。
    task automatic run_startup_full_only();
        int before_count;
        aip_cmdline_override::set_val("max_prints", "0");
        aip_cmdline_alias::push("aip_cmdline", "alt");
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("startup.full_only", int, repeated, 0);
        end
        aip_cmdline_alias::pop();
        check_info_delta("leaf and alias forms are ignored", before_count, 10);
        check_config("leaf and alias forms are ignored", 1, 10);
        finish_mode("startup-full-only");
    endtask

    // 模拟恢复后的来源刷新（置 request 为 ack 的反值）；命令行给 +aip_cmdline.max_prints=4 与叶名 +max_prints=0。
    task automatic refresh_source();
        __aip_cmdline_refresh_request = ~__aip_cmdline_refresh_ack;
    endtask

    task automatic run_refresh();
        int before_count;

        before_count = aip_log::get_count(aip_log::INFO);
        repeat (6) begin
            `aip_int("refresh.start", int, repeated, 0);
        end
        check_info_delta("full plusarg max_prints=4", before_count, 4);
        check_config("startup", 1, 4);

        // configure 有效到下一次刷新；刷新后按命令行重读并清零计数。
        aip_cmdline_print_control::configure(1, 2);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (3) begin
            `aip_int("refresh.a", int, repeated, 0);
        end
        check_info_delta("configure(1,2) before refresh", before_count, 2);
        refresh_source();
        check_config("refresh discards configure", 1, 4);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (6) begin
            `aip_int("refresh.a", int, repeated, 0);
        end
        check_info_delta("refresh clears counters", before_count, 4);

        aip_cmdline_print_control::configure(1, 1);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (3) begin
            `aip_int("refresh.b", int, repeated, 0);
        end
        check_info_delta("configure after refresh", before_count, 1);

        // 完整键 override 到下一次刷新才生效，并优先于 plusarg；叶名 override 始终无效。
        aip_cmdline_override::set_val("aip_cmdline.max_prints", "3");
        aip_cmdline_override::set_val("max_prints", "0");
        aip_cmdline_override::set_val("print_enable", "0");
        check_config("override waits for refresh", 1, 1);
        refresh_source();
        check_config("full override after refresh", 1, 3);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (5) begin
            `aip_int("refresh.c", int, repeated, 0);
        end
        check_info_delta("full override limit", before_count, 3);

        // 空值按未给出处理：空 max_prints 取默认 10，且屏蔽 plusarg 的 4。
        aip_cmdline_override::set_val("aip_cmdline.max_prints", "");
        aip_cmdline_override::set_val("aip_cmdline.print_enable", "0");
        refresh_source();
        check_config("empty override means default", 0, 10);
        before_count = aip_log::get_count(aip_log::INFO);
        `aip_int("refresh.d", int, repeated, 0);
        check_info_delta("print_enable=0 after refresh", before_count, 0);

        finish_mode("refresh");
    endtask

    task automatic check_all_disabled_values();
        check_int("disabled int assignment", int_value, 42);
        check_string("disabled string assignment", string_value, "alpha");

        check_int("disabled int dynamic size", int_values.size(), 2);
        if (int_values.size() == 2) begin
            check_int("disabled int dynamic[0]", int_values[0], 3);
            check_int("disabled int dynamic[1]", int_values[1], 4);
        end

        check_int("disabled string dynamic size", string_values.size(), 2);
        if (string_values.size() == 2) begin
            check_string("disabled string dynamic[0]", string_values[0], "left");
            check_string("disabled string dynamic[1]", string_values[1], "right");
        end

        check_int("disabled int static[0]", int_static[0], 5);
        check_int("disabled int static[1]", int_static[1], 6);
        check_string("disabled string static[0]", string_static[0], "up");
        check_string("disabled string static[1]", string_static[1], "down");
        check_true("disabled real assignment", real_value > 1.49 && real_value < 1.51);

        check_int("disabled real dynamic size", real_values.size(), 2);
        if (real_values.size() == 2) begin
            check_true("disabled real dynamic[0]",
                       real_values[0] > 2.49 && real_values[0] < 2.51);
            check_true("disabled real dynamic[1]",
                       real_values[1] > 3.49 && real_values[1] < 3.51);
        end

        check_true("disabled enum assignment", mode_value == MODE_ONE);
        check_int("disabled struct int assignment", cfg.count, 8);
        check_string("disabled struct string assignment", cfg.label, "boxed");
        check_true("disabled struct real assignment", cfg.ratio > 4.49 && cfg.ratio < 4.51);
        check_true("disabled struct enum assignment", cfg.mode == MODE_ONE);
    endtask

    task automatic run_runtime();
        int before_count;

        aip_cmdline_print_control::configure(1, 2);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("runtime.limit", int, repeated, 0);
        end
        check_info_delta("configure(1,2) limit", before_count, 2);

        aip_cmdline_print_control::configure(1, 2);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (3) begin
            `aip_int("runtime.path_a", int, shared, 0);
        end
        repeat (3) begin
            `aip_int("runtime.path_b", int, shared, 0);
        end
        check_info_delta("independent complete-path counters", before_count, 4);

        aip_cmdline_print_control::configure(1, 0);
        before_count = aip_log::get_count(aip_log::INFO);
        `aip_int("runtime.zero", int, repeated, 0);
        check_info_delta("max_prints=0", before_count, 0);

        aip_cmdline_override::set_val("disabled.int_value", "42");
        aip_cmdline_override::set_val("disabled.string_value", "alpha");
        aip_cmdline_override::set_val("disabled.int_values", "3,4");
        aip_cmdline_override::set_val("disabled.string_values", "left,right");
        aip_cmdline_override::set_val("disabled.int_static", "5,6");
        aip_cmdline_override::set_val("disabled.string_static", "up,down");
        aip_cmdline_override::set_val("disabled.real_value", "1.5");
        aip_cmdline_override::set_val("disabled.real_values", "2.5,3.5");
        aip_cmdline_override::set_val("disabled.mode_value", "MODE_ONE");
        aip_cmdline_override::set_val(
            "disabled.cfg", "{count=8,label=boxed,ratio=4.5,mode=MODE_ONE}");

        aip_cmdline_print_control::configure(0, 10);
        before_count = aip_log::get_count(aip_log::INFO);
        `aip_int("disabled", int, int_value, 0);
        `aip_string("disabled", string_value, "");
        `aip_int_list("disabled", int, int_values, 0);
        `aip_str_list("disabled", string_values, "");
        `aip_int_slist("disabled", int, int_static, 0);
        `aip_str_slist("disabled", string_static, "");
        `aip_real("disabled", real_value, 0.0);
        `aip_real_list("disabled", real_values, 0.0);
        `aip_enum("disabled", mode_t, mode_value, MODE_ZERO);
        `aip_struct_begin("disabled", cfg)
            `aip_struct_int(cfg, count, 0)
            `aip_struct_string(cfg, label, "")
            `aip_struct_real(cfg, ratio, 0.0)
            `aip_struct_enum(mode_t, cfg, mode, MODE_ZERO)
        `aip_struct_end(cfg)
        check_info_delta("print_enable=0 suppresses all public macros",
                         before_count, 0);
        check_all_disabled_values();

        aip_cmdline_print_control::configure(1, -1);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("runtime.unlimited", int, repeated, 0);
        end
        check_info_delta("max_prints=-1 is unlimited", before_count, 12);

        aip_cmdline_print_control::configure(1, 2);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (2) begin
            `aip_int("runtime.cleared", int, repeated, 0);
        end
        check_info_delta("counter before configure clear", before_count, 2);
        aip_cmdline_print_control::configure(1, 2);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (2) begin
            `aip_int("runtime.cleared", int, repeated, 0);
        end
        check_info_delta("configure clears counters", before_count, 2);

        aip_cmdline_print_control::configure(1, -2);
        check_int("max_prints below -1 normalizes",
                  aip_cmdline_print_control::max_prints, -1);
        before_count = aip_log::get_count(aip_log::INFO);
        repeat (12) begin
            `aip_int("runtime.normalized", int, repeated, 0);
        end
        check_info_delta("normalized max_prints is unlimited", before_count, 12);

        finish_mode("runtime");
    endtask

    initial begin
        failures = 0;
        aip_log::enable_color = 0;
        if (!$value$plusargs("AIP_CMDLINE_PRINT_MODE=%s", test_mode))
            $fatal(1, "missing +AIP_CMDLINE_PRINT_MODE=<mode>");

        case (test_mode)
            "runtime":          run_runtime();
            "startup-default":  run_startup_default();
            "startup-limit":    run_startup_limit();
            "startup-normalized": run_startup_normalized();
            "startup-disabled": run_startup_disabled();
            "startup-full-only": run_startup_full_only();
            "refresh":          run_refresh();
            default: $fatal(1, "unknown print-control test mode '%s'", test_mode);
        endcase
    end
endmodule
