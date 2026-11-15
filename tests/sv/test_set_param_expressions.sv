// tests/sv：比较真实 plusarg 与 set_param 命令的类型化求值结果。
// 依赖公开 aip_core_pkg；测试进程持有目标值和随机状态，框架持有 override。
// 外部 runner 提供相同表达式，override 模式经命令安装，再逐 case 重置 RNG。
// 不同来源必须输出相同抽样轨迹；固定 override 的历史 RNG 消耗另外验证。
`include "aip_core_pkg.sv"

// 使用公开宏而非内部 parser，覆盖来源选择、用户诊断位置与容器转发。
module test_set_param_expressions;
    typedef enum { MODE0, MODE1, MODE2 } mode_t;
    typedef bit [255:0]	wide_t;
    typedef struct {
        int				length;
        real				rate;
        string				label;
        mode_t				mode;
    } record_t;

    `aip_struct_type_begin(record_t)
        `aip_field_int(int, length, 64)
        `aip_field_real(rate, 1.0)
        `aip_field_string(label, "default")
        `aip_field_enum(mode_t, mode, MODE0)
    `aip_struct_type_end(record_t)

    // 每次调用都通过宏重新读取；path 用来让所有样例共享实际字段名 value。
    function automatic int read_int(string	path);
        int				value;
        `aip_int(path, int, value, 7)
        return value;
    endfunction

    // 实数路径不经过整数转换，保留完整随机样本精度。
    function automatic real read_real(string	path);
        real				value;
        `aip_real(path, value, 7.0)
        return value;
    endfunction

    // 字符串列表由既有宏解释；raw getter 的原文行为在独立断言检查。
    function automatic string read_string(string	path);
        string				value;
        `aip_string(path, value, "default")
        return value;
    endfunction

    // 宽位 rand 必须覆盖高于 32 bit 的区域，避免退化为普通 int RNG。
    function automatic wide_t read_wide(string	path);
        wide_t				value;
        `aip_int(path, wide_t, value, '0)
        return value;
    endfunction

    // 枚举原来就共用来源；新增回归确保标量修改不改变这个契约。
    function automatic mode_t read_enum(string	path);
        mode_t				value;
        `aip_enum(path, mode_t, value, MODE0)
        return value;
    endfunction

    // 命令失败立即 fatal；避免把安装失败后的 plusarg 回退误判成 override 成功。
    task automatic command(string	text);
        int				status;
        string				result;
        aip_cmd::exec_result(text, SRC_INTERNAL, status, result);
        if (status != 0) $fatal(1, "SET_PARAM_COMMAND_FAIL %s: %s", text, result);
    endtask

    // 固定值的快速分流不能偷偷消耗随机数，否则已有发包 seed 会被无关配置读取扰动。
    // 安装命令可创建进程，因此只在安装结束后抓取并比较当前读参进程的 RNG 状态。
    task automatic check_literal_rng();
        process				owner;
        string				state_before;
        int				iv;
        real				rv;
        string				sv;

        owner = process::self();
        command("set_param path=literal.value value=200");
        state_before = owner.get_randstate();
        iv = read_int("literal");
        rv = read_real("literal");
        sv = read_string("literal");
        if (iv != 200 || rv != 200.0 || sv != "200" || owner.get_randstate() != state_before)
            $fatal(1, "SET_PARAM_LITERAL_RNG_CHANGED");
        command("set_param path=literal.value value=hello world");
        state_before = owner.get_randstate();
        sv = read_string("literal");
        if (sv != "hello world" || owner.get_randstate() != state_before)
            $fatal(1, "SET_PARAM_STRING_LITERAL_RNG_CHANGED");
        command("set_param path=literal.value value='hFACE");
        state_before = owner.get_randstate();
        iv = read_int("literal");
        if (iv != 'hFACE || owner.get_randstate() != state_before)
            $fatal(1, "SET_PARAM_HEX_LITERAL_RNG_CHANGED");
        command("clear_param path=literal.value");
    endtask

    // 保留来源优先级、显式空值及清除语义；这些边界不能被随机化支持覆盖掉。
    task automatic check_updates();
        int				default_int;
        bit [7:0]			bit_value;
        logic [7:0]			logic_value;
        logic [7:0]			default_logic;

        if (read_int("priority") != 19) $fatal(1, "SET_PARAM_PLUSARG_PRIORITY");
        command("set_param path=value value=23");
        if (read_int("priority") != 23) $fatal(1, "SET_PARAM_LEAF_PRIORITY");
        command("set_param path=priority.value value=[31:31]");
        if (read_int("priority") != 31) $fatal(1, "SET_PARAM_FULL_PRIORITY");
        command("set_param path=priority.value value=[42:42]");
        if (read_int("priority") != 42) $fatal(1, "SET_PARAM_UPDATE_STALE");
        if (aip_cmdline#(int)::get_cmdline_string("value", "priority") != "[42:42]")
            $fatal(1, "SET_PARAM_RAW_GETTER");
        command("set_param path=priority.value value=");
        if (read_int("priority") !== default_int || read_real("priority") != 0.0 ||
            read_string("priority") != "") $fatal(1, "SET_PARAM_EMPTY_OVERRIDE");
        aip_cmdline#(bit [7:0])::get_single_value("value", "priority", 8'hff, bit_value);
        aip_cmdline#(logic [7:0])::get_single_value("value", "priority", 8'hff, logic_value);
        if (bit_value !== 8'h00 || logic_value !== default_logic)
            $fatal(1, "SET_PARAM_EMPTY_TYPE_DEFAULT");
        command("clear_param path=priority.value");
        if (read_int("priority") != 23) $fatal(1, "SET_PARAM_CLEAR_FULL");
        command("clear_param path=value");
        if (read_int("priority") != 19 || read_int("absent") != 7)
            $fatal(1, "SET_PARAM_CLEAR_LEAF_DEFAULT");
    endtask

    // 数组/队列/schema 原有解析同样需要在两个来源下重跑；保留 seq/perm 数组语义。
    task automatic check_containers();
        int				array[];
        int				sequence_values[];
        int				permutation[];
        int				queue[$];
        real				reals[$];
        record_t			cfg;
        process				owner;

        owner = process::self();
        owner.srandom(901);
        `aip_int_list("probe", int, array, 0)
        `aip_int_list("probe", int, sequence_values, 0)
        `aip_int_list("probe", int, permutation, 0)
        `aip_int_queue("probe", int, queue, 0, -1)
        `aip_real_queue("probe", reals, 0.0, -1)
        `aip_struct_apply("probe.cfg", record_t, cfg)
        if (array.size() != 5 || queue.size() != 4 || reals.size() != 3 ||
            sequence_values.size() != 4 || permutation.size() != 4)
            $fatal(1, "SET_PARAM_CONTAINER_SIZE");
        foreach (array[i]) begin
            if (array[i] < 10 || array[i] > 90 || (i > 0 && array[i] <= array[i-1]))
                $fatal(1, "SET_PARAM_ARRAY_UNIQUE_SORT");
        end
        foreach (sequence_values[i])
            if (sequence_values[i] != 2 + i * 2) $fatal(1, "SET_PARAM_SEQ_GENERATOR");
        foreach (permutation[i]) begin
            if (!(permutation[i] inside {[10:13]})) $fatal(1, "SET_PARAM_PERM_RANGE");
            foreach (permutation[j])
                if (i != j && permutation[i] == permutation[j]) $fatal(1, "SET_PARAM_PERM_UNIQUE");
        end
        if (cfg.length < 64 || cfg.length > 128 || cfg.rate < 2.0 || cfg.rate >= 3.0 ||
            !(cfg.label inside {"red", "blue"}) || !(cfg.mode inside {MODE1, MODE2}))
            $fatal(1, "SET_PARAM_SCHEMA_VALUES");
        $display("SET_PARAM_TRACE containers array=%p seq=%p perm=%p queue=%p reals=%p cfg=%p",
                 array, sequence_values, permutation, queue, reals, cfg);
    endtask

    // 安装表达式后重置每个 case 的 RNG；命令调度产生的进程不影响样本比较。
    initial begin
        string				args[$];
        string				arg;
        string				key;
        string				path;
        string				expression;
        string				first_sample;
        string				sample;
        string				negative_kind;
        int				pos;
        int				iv;
        real				rv;
        wide_t				wv;
        mode_t				ev;
        bit				changed;
        bit				override_mode;
        process				owner;
        uvm_cmdline_processor		clp;

        aip_cmdline_print_control::configure(0, 0);
        override_mode = $test$plusargs("USE_OVERRIDE");
        owner         = process::self();
        clp           = aip_cmdline_source::get();
        clp.get_args(args);
        if (override_mode) begin
            foreach (args[i]) begin
                arg = args[i];
                if (arg.substr(0, 6) != "+probe.") continue;
                pos = aip_str::str_find(arg, "=");
                if (pos < 0) $fatal(1, "SET_PARAM_TEST_MALFORMED_ARG");
                key        = arg.substr(1, pos-1);
                expression = arg.substr(pos+1, arg.len()-1);
                command({"set_param path=", key, " value=", expression});
                if (!aip_cmdline_override::has(key) || aip_cmdline_override::get_val(key) != expression)
                    $fatal(1, "SET_PARAM_EXPRESSION_NOT_PRESERVED");
            end
        end

        if ($value$plusargs("NEGATIVE_KIND=%s", negative_kind)) begin
            if (negative_kind == "real") rv = read_real("probe.bad");
            else iv = read_int("probe.bad");
            $fatal(1, "SET_PARAM_UNEXPECTED_CONTINUE");
        end

        foreach (args[i]) begin
            arg = args[i];
            if (arg.substr(0, 6) != "+probe." || arg[8] != "_") continue;
            pos  = aip_str::str_find(arg, "=");
            key  = arg.substr(1, pos-1);
            path = key.substr(0, key.len()-7); // 去掉 .value；宏通过局部变量名补回。
            owner.srandom(12345);
            changed = 0;
            repeat (64) begin
                case (arg[7])
                    "i": begin
                        iv = read_int(path);
                        if (path == "probe.i_range" && !(iv inside {[50:200]}))
                            $fatal(1, "SET_PARAM_RANGE");
                        if (path == "probe.i_weight" && !(iv inside {50, [100:200]}))
                            $fatal(1, "SET_PARAM_ZERO_WEIGHT");
                        if (path == "probe.i_inc" && !(iv inside {2, 5, 8}))
                            $fatal(1, "SET_PARAM_STEP");
                        sample = $sformatf("%0d", iv);
                    end
                    "r": begin
                        rv = read_real(path);
                        if (path == "probe.r_range" && (rv < 50.0 || rv >= 200.0))
                            $fatal(1, "SET_PARAM_REAL_RANGE");
                        sample = $sformatf("%.17g", rv);
                    end
                    "s": sample = read_string(path);
                    "e": begin
                        ev = read_enum(path);
                        sample = ev.name();
                    end
                    "w": begin
                        wv = read_wide(path);
                        if (path == "probe.w_rand" && wv[255:32] == 0)
                            $fatal(1, "SET_PARAM_WIDE_RAND");
                        sample = $sformatf("%h", wv);
                    end
                    default: $fatal(1, "SET_PARAM_UNKNOWN_KIND");
                endcase
                if (first_sample != "" && sample != first_sample) changed = 1;
                first_sample = sample;
                $display("SET_PARAM_TRACE %s %s", path, sample);
            end
            if ((path == "probe.i_range" || path == "probe.r_range" ||
                 path == "probe.s_list" || path == "probe.w_rand") && !changed)
                $fatal(1, "SET_PARAM_SAMPLES_CACHED");
            first_sample = "";
        end
        check_containers();
        check_updates();
        check_literal_rng();
        $display("SET_PARAM_EXPRESSIONS_PASS");
        $finish;
    end
endmodule
