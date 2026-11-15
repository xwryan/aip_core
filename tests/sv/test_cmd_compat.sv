// tests/sv：命令重构后的旧 SV 入口、嵌套 legacy 调用及原始参数保真回归。
// 依赖 AIP package、UVM HDL backdoor 和 1ns 时间单位；顶层拥有 DUT 信号与
// CPU 寄存器替身，框架拥有注册句柄和每次调用上下文。测试只使用公开 API，
// 不写框架私有锁；取消定时 force 后显式 release，不把取消误当作资源回滚。
`timescale 1ns/1ps
`include "aip_core_pkg.sv"

// 单寄存器替身只用于 cpu_wait 的成功/超时路径，避免把镜像文件和真实 CPU
// 引入命令兼容门禁；寄存器对象由顶层创建并借给 CPU memory facade。
class cmd_compat_region extends aip_cpu_region;
    bit [31:0] value;

    // 固定低地址和 32-bit 宽度；测试写 value 后才启动轮询。
    function new();
        name = "compat_ready_register";
        base = 'h1000;
        size = 4;
        value = 0;
    endfunction

    // 仅接受一个完整寄存器写入，错误访问立即失败以免制造假 ready。
    virtual task write_impl(input longint unsigned off,
                            input longint unsigned data, input int width);
        if (off != 0 || width != 32) $fatal(1, "CMD_COMPAT_REGION_BAD_WRITE");
        value = data[31:0];
    endtask

    // 合法读取显式返回成功，不替 cpu_wait 合成结果或跳过轮询时间。
    virtual task read_impl(input longint unsigned off,
                           output longint unsigned data, input int width,
                           output bit status_ok);
        data = value;
        status_ok = (off == 0 && width == 32);
    endtask

    // 满足 region 的清零契约，不创建后台工作。
    virtual task zero_all();
        value = 0;
    endtask
endclass

typedef enum int {COMPAT_IDLE, COMPAT_ACTIVE} cmd_compat_mode_e;

// 全部断言共享一个明确的检查器，业务 task 也能记录嵌套期间的中间状态。
// 业务仍通过真实注册宏/dispatch 执行，不通过修改 handle 假造调用结果。
class cmd_compat_ops;
    static int checks = 0;
    static int failures = 0;
    static int leaf_calls = 0;
    static int raw_calls = 0;
    static bit owned_child_done = 0;
    static process cancellable_child_process;
    static bit cancellable_child_started = 0;

    // 收集正常组断言；最终顶层以 fatal 和锚定 PASS 区分成功/失败。
    static function void check(string label, bit condition);
        checks++;
        if (condition) $display("CMD_COMPAT_CHECK_PASS %s", label);
        else begin
            failures++;
            $display("CMD_COMPAT_CHECK_FAIL %s", label);
        end
    endfunction

    // 同时核对两个旧全局槽，避免只检查状态而漏掉串线的返回文本。
    static function void check_globals(string label, int code, string text);
        check({label, " status"}, aip_cmd::__aip_cmd_last_status == code);
        check({label, " result"}, aip_cmd::__aip_cmd_last_result == text);
    endfunction

    // 无参宏也需支持直接调用上下文；显式非零结果必须优先于宏默认成功。
    static task typed_zero();
        check("zero typed has context", aip_cmd::get_current_context() != null);
        aip_cmd::set_result(21, "ZERO");
    endtask

    // 以默认参数复用不同输入数量的 typed 宏，检查实参值未被包装层改变。
    static task typed_sum(int a = 0, int b = 0, int c = 0, int d = 0,
                          int e = 0, int f = 0, int g = 0, int h = 0,
                          int i = 0, int j = 0);
        check("typed input has context", aip_cmd::get_current_context() != null);
        aip_cmd::set_result(22, $sformatf("SUM:%0d", a+b+c+d+e+f+g+h+i+j));
    endtask

    // 不显式提交结果的 output 变体仍应保留原有输出拼装，并发布直接调用镜像。
    static task typed_output(int value, output int result);
        check("typed output has context", aip_cmd::get_current_context() != null);
        result = value + 1;
    endtask

    // 最大输出数量的代表：即使宏会自动拼装三项 output，显式失败仍不能丢失。
    static task typed_many_outputs(int a, int b, int c, int d, int e,
                                   output int x, output int y, output int z);
        x = a + b;
        y = c + d;
        z = e;
        aip_cmd::set_result(23, $sformatf("OUTPUTS:%0d,%0d,%0d", x, y, z));
    endtask

    // enum 输入同样需要直接入口上下文，不能只覆盖整数/字符串宏。
    static task typed_enum(cmd_compat_mode_e mode);
        aip_cmd::set_result(24, {"ENUM:", mode.name()});
    endtask

    // enum/output 变体保留自动输出格式，检查另一类 typed 生成路径。
    static task typed_enum_output(cmd_compat_mode_e mode, output int result);
        check("enum output has context", aip_cmd::get_current_context() != null);
        result = int'(mode) + 10;
    endtask

    // 最内层坚持旧 task 直接写静态槽，不使用新 setter；允许真实时间等待，
    // 以便证明借出的 legacy 所有权在嵌套返回前不会提前释放给无关调用者。
    static task legacy_leaf(string text);
        leaf_calls++;
        aip_cmd::__aip_cmd_last_status = 71;
        aip_cmd::__aip_cmd_last_result = {"LEAF:", text};
        #2ns;
    endtask

    // 中层先用 output API（返回后恢复父全局槽），再用旧 exec API（通过镜像
    // 让父 task 读到子返回值），两者不可混为同一个返回契约。
    static task legacy_middle(string text);
        int code;
        string result;
        aip_cmd_result_context parent_context;
        parent_context = aip_cmd::get_current_context();
        aip_cmd::__aip_cmd_last_status = 81;
        aip_cmd::__aip_cmd_last_result = "MIDDLE_BEFORE";
        aip_cmd::exec_result({"compat_leaf text=", text}, SRC_INTERNAL, code, result);
        check("middle output nested status", code == 71);
        check("middle output nested text", result == {"LEAF:", text});
        check_globals("middle output restores globals", 81, "MIDDLE_BEFORE");
        check("middle context restored", aip_cmd::get_current_context() == parent_context);

        aip_cmd::exec({"compat_leaf text=", text}, SRC_INTERNAL);
        check_globals("middle exec exposes child", 71, {"LEAF:", text});
        aip_cmd::__aip_cmd_last_status = 82;
        aip_cmd::__aip_cmd_last_result = {"MIDDLE:", text};
    endtask

    // 独立结果 helper 位于 legacy 父/子之间；同步调用链仍应可借出同一槽，
    // 不能把 helper 的非 legacy 属性误认为不相关线程。
    static task local_middle(string text);
        int code;
        string result;
        int parent_status;
        string parent_text;
        aip_cmd_result_context own_context;
        own_context = aip_cmd::get_current_context();
        parent_status = aip_cmd::__aip_cmd_last_status;
        parent_text = aip_cmd::__aip_cmd_last_result;
        aip_cmd::exec_result({"compat_leaf text=", text}, SRC_INTERNAL, code, result);
        check("local middle legacy status", code == 71);
        check("local middle legacy text", result == {"LEAF:", text});
        check_globals("local middle restores parent globals", parent_status, parent_text);
        check("local middle context restored", aip_cmd::get_current_context() == own_context);
        aip_cmd::set_result(84, {"LOCAL:", text});
    endtask

    // 同步 local 中转使用旧 exec 时，也要能观察内层 legacy 的全局镜像；
    // 这与 exec_result 的父槽恢复契约不同，不能被不相关线程保护误屏蔽。
    static task local_middle_exec(string text);
        aip_cmd::exec({"compat_leaf text=", text}, SRC_INTERNAL);
        check_globals("local exec observes legacy child", 71, {"LEAF:", text});
        aip_cmd::set_result(85, {"LOCAL_EXEC:", text});
    endtask

    // 最外层涵盖多层借槽和必须拒绝的异步/另一个 fork 子线程。hold 模式
    // 留出外部并发窗口，测试父线程未让出 legacy 槽时无关命令仍收到 BUSY。
    static task legacy_outer(string text);
        int code;
        string result;
        int before_leaf_calls;
        aip_cmd_result_context outer_context;
        outer_context = aip_cmd::get_current_context();
        aip_cmd::__aip_cmd_last_status = 91;
        aip_cmd::__aip_cmd_last_result = "OUTER_BEFORE";
        if (text == "hold") #20ns;

        aip_cmd::exec_result({"compat_middle text=", text}, SRC_INTERNAL, code, result);
        check("outer multilevel status", code == 82);
        check("outer multilevel result", result == {"MIDDLE:", text});
        check_globals("outer globals restored", 91, "OUTER_BEFORE");
        check("outer context restored", aip_cmd::get_current_context() == outer_context);

        aip_cmd::exec_result({"compat_local_middle text=", text}, SRC_INTERNAL, code, result);
        check("outer local middle status", code == 84);
        check("outer local middle result", result == {"LOCAL:", text});
        check_globals("outer local middle preserves globals", 91, "OUTER_BEFORE");

        aip_cmd::exec_result({"compat_local_exec text=", text}, SRC_INTERNAL, code, result);
        check("outer local exec status", code == 85);
        check("outer local exec result", result == {"LOCAL_EXEC:", text});
        check_globals("outer sees helper exec child mirror", 71, {"LEAF:", text});
        aip_cmd::__aip_cmd_last_status = 91;
        aip_cmd::__aip_cmd_last_result = "OUTER_BEFORE";

        before_leaf_calls = leaf_calls;
        aip_cmd::exec_result("compat_leaf text=forbidden_async wait=0", SRC_INTERNAL,
                             code, result);
        check("nested asynchronous legacy is BUSY", code != 0 &&
              aip_str::str_find(result, "BUSY") == 0);
        check("nested async did not launch", leaf_calls == before_leaf_calls);
        check_globals("nested async preserves globals", 91, "OUTER_BEFORE");

        fork
            begin
                aip_cmd::exec_result("compat_leaf text=forbidden_child", SRC_INTERNAL,
                                     code, result);
            end
        join
        check("unbound fork child legacy is BUSY", code != 0 &&
              aip_str::str_find(result, "BUSY") == 0);
        check("unbound fork child did not launch", leaf_calls == before_leaf_calls);
        check_globals("fork child preserves globals", 91, "OUTER_BEFORE");
        aip_cmd::__aip_cmd_last_status = 92;
        aip_cmd::__aip_cmd_last_result = {"OUTER:", text};
    endtask

    // 被取消的是内层 worker 本身，而不是父调用栈；retry 不等待，验证同名
    // 句柄和 legacy 槽恢复之后确实可再次执行，不能只返回父级伪造的成功。
    static task legacy_cancel_child(string mode);
        aip_cmd::__aip_cmd_last_status = 101;
        aip_cmd::__aip_cmd_last_result = {"CANCEL_CHILD:", mode};
        if (mode == "block") begin
            cancellable_child_process = process::self();
            cancellable_child_started = 1;
            #100ns;
        end
    endtask

    // 父主线程同步调用，独立 killer 只杀子 worker。取消返回后必须恢复父
    // 上下文/legacy 所有权，并允许同名子命令重试；最终 join 回收测试线程。
    static task legacy_cancel_parent(string unused);
        int code;
        string result;
        aip_cmd_result_context parent_context;
        parent_context = aip_cmd::get_current_context();
        aip_cmd::__aip_cmd_last_status = 111;
        aip_cmd::__aip_cmd_last_result = "CANCEL_PARENT_BEFORE";
        cancellable_child_started = 0;
        fork
            begin
                wait (cancellable_child_started);
                #1ns;
                cancellable_child_process.kill();
            end
        join_none
        aip_cmd::exec_result("compat_cancel_child mode=block", SRC_INTERNAL, code, result);
        check("killed nested worker returns cancelled", code != 0 &&
              aip_str::str_find(result, "CANCELLED") == 0);
        check_globals("killed child restores parent globals", 111, "CANCEL_PARENT_BEFORE");
        check("killed child preserves parent context", aip_cmd::get_current_context() == parent_context);
        aip_cmd::exec_result("compat_cancel_child mode=retry", SRC_INTERNAL, code, result);
        check("killed nested worker permits retry", code == 101 && result == "CANCEL_CHILD:retry");
        check_globals("retry restores parent globals", 111, "CANCEL_PARENT_BEFORE");
        wait fork;
        aip_cmd::__aip_cmd_last_status = 112;
        aip_cmd::__aip_cmd_last_result = "CANCEL_PARENT_DONE";
    endtask

    // 旧业务可直接调用 DUT facade 后立即读旧槽，再覆盖成自己的业务结果。
    // facade 不可在 owner 的 ctx 留下更高优先级 assigned 值，吞掉最后的覆盖。
    static task legacy_dut_wrapper(string text);
        aip_cmd::__aip_cmd_last_status = 120;
        aip_cmd::__aip_cmd_last_result = "LEGACY_DUT_BEFORE";
        aip_dut_control_ops::deposit_signal("test_cmd_compat.dut_signal", "1");
        check_globals("legacy wrapper sees DUT deposit", 0,
                      "deposited test_cmd_compat.dut_signal=1");
        aip_dut_control_ops::get_signal("");
        check_globals("legacy wrapper sees DUT error", 1, "get failed");
        aip_cmd::__aip_cmd_last_status = 121;
        aip_cmd::__aip_cmd_last_result = {"LEGACY_DUT_FINAL:", text};
    endtask

    // loader 未绑定是可控的 facade 错误，不触发底层镜像日志。旧调用方读取
    // 错误后仍可把它翻译成自己的业务状态，注册宏最终必须采用该翻译结果。
    static task legacy_loader_wrapper(string text);
        aip_cmd::__aip_cmd_last_status = 122;
        aip_cmd::__aip_cmd_last_result = "LEGACY_LOADER_BEFORE";
        aip_cpu_loader_default::load_image("unused.hex", 0, "hex");
        check_globals("legacy wrapper sees loader error", -1,
          "aip_cpu_loader_default: not set (call set() in TB); ctx=load_image");
        aip_cmd::__aip_cmd_last_status = 123;
        aip_cmd::__aip_cmd_last_result = {"LEGACY_LOADER_FINAL:", text};
    endtask

    // 同一 facade 在 local 注册模式中必须提交当前 ctx，而不能因外部存在
    // legacy owner 就直接写全局槽。保留 facade 原始结果供顶层继续核对。
    static task local_dut_wrapper(string unused);
        int before_status;
        string before_result;
        before_status = aip_cmd::__aip_cmd_last_status;
        before_result = aip_cmd::__aip_cmd_last_result;
        aip_cmd::set_result(130, "LOCAL_DUT_BEFORE");
        aip_dut_control_ops::deposit_signal("test_cmd_compat.dut_signal", "1");
        check_globals("local DUT facade preserves unrelated globals", before_status, before_result);
    endtask

    // local loader 错误应沿自身结果通道返回，不能改变另一个在途 legacy 的状态。
    static task local_loader_wrapper(string unused);
        int before_status;
        string before_result;
        before_status = aip_cmd::__aip_cmd_last_status;
        before_result = aip_cmd::__aip_cmd_last_result;
        aip_cmd::set_result(131, "LOCAL_LOADER_BEFORE");
        aip_cpu_loader_default::load_image("unused.hex", 0, "hex");
        check_globals("local loader facade preserves unrelated globals", before_status, before_result);
    endtask

    // 原始参数消费者故意不经过 get_arg，检验逗号、空白和嵌套 wait 字面量。
    // 只有真正顶层 wait token 可被框架处理，业务字节不能被无意重新拼接。
    static task raw();
        aip_cmd handle;
        handle = aip_cmd::get_handle("compat_raw");
        raw_calls++;
        aip_cmd::set_result(0, handle.args_in);
    endtask

    // 外部 wait fork 不承诺等待调度器创建的孙进程；需要等待的业务显式在
    // 自己的 task 内 join 子工作，框架同步调用再等待整个 task 返回。
    static task owned_fork();
        owned_child_done = 0;
        fork
            begin
                #7ns;
                owned_child_done = 1;
            end
        join
        aip_cmd::set_result(0, "OWNED_CHILD_JOINED");
    endtask
endclass

// typed/task/enum 的直接调用代表覆盖首尾输入数、自动输出和显式结果优先级。
`aip_cmd_task(compat_zero, cmd_compat_ops::typed_zero)
`aip_cmd_1i(compat_one, cmd_compat_ops::typed_sum, int, a, 0)
`aip_cmd_4i(compat_four, cmd_compat_ops::typed_sum,
            int, a, 0, int, b, 0, int, c, 0, int, d, 0)
`aip_cmd_10i(compat_ten, cmd_compat_ops::typed_sum,
             int, a, 0, int, b, 0, int, c, 0, int, d, 0, int, e, 0,
             int, f, 0, int, g, 0, int, h, 0, int, i, 0, int, j, 0)
`aip_cmd_1i1o(compat_output, cmd_compat_ops::typed_output, int, value, 0, int, result)
`aip_cmd_5i3o(compat_outputs, cmd_compat_ops::typed_many_outputs,
              int, a, 0, int, b, 0, int, c, 0, int, d, 0, int, e, 0,
              int, x, int, y, int, z)
`aip_cmd_enum_1i(compat_enum, cmd_compat_ops::typed_enum,
                 cmd_compat_mode_e, mode, COMPAT_IDLE)
`aip_cmd_enum_1i1o(compat_enum_output, cmd_compat_ops::typed_enum_output,
                   cmd_compat_mode_e, mode, COMPAT_IDLE, int, result)
`aip_cmd_str_1i(compat_leaf, cmd_compat_ops::legacy_leaf, text, "")
`aip_cmd_str_1i(compat_middle, cmd_compat_ops::legacy_middle, text, "")
`aip_cmd_str_1i(compat_local_middle, cmd_compat_ops::local_middle, text, "", 1'b1)
`aip_cmd_str_1i(compat_local_exec, cmd_compat_ops::local_middle_exec, text, "", 1'b1)
`aip_cmd_str_1i(compat_outer, cmd_compat_ops::legacy_outer, text, "")
`aip_cmd_str_1i(compat_cancel_child, cmd_compat_ops::legacy_cancel_child, mode, "retry")
`aip_cmd_str_1i(compat_cancel_parent, cmd_compat_ops::legacy_cancel_parent, unused, "")
`aip_cmd_str_1i(compat_legacy_dut, cmd_compat_ops::legacy_dut_wrapper, text, "")
`aip_cmd_str_1i(compat_legacy_loader, cmd_compat_ops::legacy_loader_wrapper, text, "")
`aip_cmd_str_1i(compat_local_dut, cmd_compat_ops::local_dut_wrapper, unused, "", 1'b1)
`aip_cmd_str_1i(compat_local_loader, cmd_compat_ops::local_loader_wrapper, unused, "", 1'b1)
`aip_cmd_task(compat_raw, cmd_compat_ops::raw)
`aip_cmd_task(compat_owned_fork, cmd_compat_ops::owned_fork)

// 本模块只负责场景编排和真实 HDL 所有权；使用普通 initial，避免 UVM
// objection/report 提前结束而掩盖最后的直接 facade 和参数保真检查。
module test_cmd_compat;
    logic dut_signal;
    // 固件成功路径只写首个 64-bit row；其余地址不在本兼容门禁覆盖范围。
    logic [63:0] rom_word [0:0];

    // 直接 cmd_exec 必须同时留下 handle/global 两套旧观察结果并回收上下文。
    task automatic direct_invoke(string name, string args, int code, string result);
        aip_cmd handle;
        handle = aip_cmd::get_handle(name);
        cmd_compat_ops::check({name, " direct pre-context empty"},
                              aip_cmd::get_current_context() == null);
        handle.args_in = args;
        handle.cmd_exec();
        cmd_compat_ops::check({name, " direct status"}, handle.status == code);
        cmd_compat_ops::check({name, " direct result"}, handle.result_out == result);
        cmd_compat_ops::check_globals({name, " direct globals"}, code, result);
        cmd_compat_ops::check({name, " direct context released"},
                              aip_cmd::get_current_context() == null);
        cmd_compat_ops::check({name, " direct handle idle"}, !handle.is_busy());
    endtask

    // 原始参数按字符串逐字比对；此处没有业务 parser 帮框架抹平空白/逗号差异。
    task automatic raw_invoke(string args, string expected);
        int code;
        string result;
        aip_cmd::exec_result({"compat_raw ", args}, SRC_INTERNAL, code, result);
        cmd_compat_ops::check({"raw status: ", args}, code == 0);
        cmd_compat_ops::check({"raw preserved: ", args}, result == expected);
        if (result != expected)
            $display("CMD_COMPAT_RAW_DETAIL got=<%s> expected=<%s>", result, expected);
    endtask

    // 直接 CPU typed 入口要覆盖未绑定 loader，以及真实等待后的超时/成功。
    task automatic check_cpu_direct();
        aip_cpu_mem cpu;
        aip_cpu_loader loader;
        cmd_compat_region ready;
        aip_cpu_rom_region rom;
        aip_cmd handle;
        realtime began;
        int image_file;
        aip_cpu_loader_default::set(null);
        direct_invoke("cpu_wait", "addr=0x1000 expected=1", -1,
          "aip_cpu_loader_default: not set (call set() in TB); ctx=wait_value");
        direct_invoke("load_image", "file=unused.hex start=0 format=hex", -1,
          "aip_cpu_loader_default: not set (call set() in TB); ctx=load_image");
        aip_cpu_loader_default::load_image("unused.hex", 0, "hex");
        cmd_compat_ops::check_globals("static loader missing", -1,
          "aip_cpu_loader_default: not set (call set() in TB); ctx=load_image");
        cmd_compat_ops::check("static loader missing scope released",
                              aip_cmd::get_current_context() == null);

        cpu = new();
        ready = new();
        cpu.add_region(ready);
        loader = new(cpu);
        aip_cpu_loader_default::set(loader);
        handle = aip_cmd::get_handle("cpu_wait");
        handle.args_in = "addr=0x1000 expected=1 timeout_ns=200";
        began = $realtime;
        handle.cmd_exec();
        cmd_compat_ops::check("direct cpu_wait waits for own deadline", $realtime - began == 200ns);
        cmd_compat_ops::check("direct cpu_wait timeout status", handle.status == -1);
        cmd_compat_ops::check("direct cpu_wait timeout text",
                              aip_str::str_find(handle.result_out, "timeout 200 ns") == 0);
        cmd_compat_ops::check_globals("direct cpu_wait timeout mirror", handle.status, handle.result_out);
        cmd_compat_ops::check("direct cpu_wait timeout scope released",
                              aip_cmd::get_current_context() == null && !handle.is_busy());

        ready.value = 1;
        began = $realtime;
        handle.cmd_exec();
        cmd_compat_ops::check("direct cpu_wait ready status", handle.status == 0);
        cmd_compat_ops::check("direct cpu_wait ready returns immediately", $realtime == began);
        cmd_compat_ops::check("direct cpu_wait ready text",
                              aip_str::str_find(handle.result_out, "ready @") == 0);
        cmd_compat_ops::check_globals("direct cpu_wait ready mirror", handle.status, handle.result_out);
        cmd_compat_ops::check("direct cpu_wait ready scope released",
                              aip_cmd::get_current_context() == null && !handle.is_busy());

        aip_cpu_loader_default::wait_value('h1000, 1, 0, 200);
        cmd_compat_ops::check("static cpu_wait ready status", aip_cmd::__aip_cmd_last_status == 0);
        cmd_compat_ops::check("static cpu_wait ready text",
                              aip_str::str_find(aip_cmd::__aip_cmd_last_result, "ready @") == 0);
        cmd_compat_ops::check("static cpu_wait ready scope released",
                              aip_cmd::get_current_context() == null);

        // 成功装载必须真的到达 HDL 存储，不能只看框架返回的 loaded 字符串。
        // fixture 文件归本测试所有，runner 的 clean 负责回收此唯一固定产物。
        rom_word[0] = 0;
        rom = new("compat_rom", 'h8000, 1);
        rom.set_path(0, 0, "test_cmd_compat.rom_word");
        cpu.add_region(rom);
        image_file = $fopen("cmd_compat_rom.hex", "w");
        if (image_file == 0) $fatal(1, "CMD_COMPAT_FIXTURE_OPEN_FAILED");
        $fwrite(image_file, "@00008000\n12 34 56 78\n");
        $fclose(image_file);
        direct_invoke("load_image", "file=cmd_compat_rom.hex start=0 format=hex", 0,
                      "image loaded file=cmd_compat_rom.hex start=0x0 format=hex");
        cmd_compat_ops::check("direct load_image writes actual ROM",
                              rom_word[0] === 64'h78563412);
        cmd_compat_ops::check("load_image success scope released",
                              aip_cmd::get_current_context() == null);
        aip_cpu_loader_default::set(null);
    endtask

    // 真实 HDL 直接 facade 的成功和失败都必须正常返回；取消 force_time 后
    // 只回收命令 scope，保留 HDL force 至显式 release，不添加隐含信号回滚。
    task automatic check_dut_direct();
        process timed_owner;
        bit timed_returned;
        int code;
        string result;
        realtime began;
        string path;
        path = "test_cmd_compat.dut_signal";
        dut_signal = 0;
        aip_dut_control_ops::deposit_signal(path, "1");
        cmd_compat_ops::check("static deposit changes signal", dut_signal === 1'b1);
        cmd_compat_ops::check_globals("static deposit mirror", 0, {"deposited ", path, "=1"});
        aip_dut_control_ops::force_signal(path, "0");
        cmd_compat_ops::check_globals("static force mirror", 0, {"forced ", path, "=0"});
        dut_signal = 1;
        #1ns;
        cmd_compat_ops::check("static force persists", dut_signal === 1'b0);
        aip_dut_control_ops::get_signal(path);
        cmd_compat_ops::check("static get status", aip_cmd::__aip_cmd_last_status == 0);
        cmd_compat_ops::check("static get result exists", aip_cmd::__aip_cmd_last_result.len() > 0);
        aip_dut_control_ops::release_signal(path);
        cmd_compat_ops::check_globals("static release mirror", 0, {"released ", path});
        dut_signal = 1;
        #1ns;
        cmd_compat_ops::check("static release restores assignment", dut_signal === 1'b1);
        aip_dut_control_ops::get_signal("");
        cmd_compat_ops::check_globals("static get failure mirror", 1, "get failed");
        cmd_compat_ops::check("static get failure scope released",
                              aip_cmd::get_current_context() == null);

        began = $realtime;
        aip_dut_control_ops::force_signal_time(path, "0", "5ns");
        cmd_compat_ops::check("static force-time waits", $realtime - began == 5ns);
        cmd_compat_ops::check_globals("static force-time mirror", 0,
                                      {"forced ", path, "=0 for 5ns, released"});
        dut_signal = 1;
        #1ns;
        cmd_compat_ops::check("static force-time releases", dut_signal === 1'b1);

        timed_returned = 0;
        fork
            begin
                timed_owner = process::self();
                aip_dut_control_ops::force_signal_time(path, "0", "50ns");
                timed_returned = 1;
            end
        join_none
        #1ns;
        cmd_compat_ops::check("cancel target force active", dut_signal === 1'b0);
        aip_cmd::exec_result("compat_leaf text=facade_conflict", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("active direct facade reserves legacy slot", code != 0 &&
                              aip_str::str_find(result, "BUSY") == 0);
        raw_invoke("during=direct_facade,", "during=direct_facade,");
        cmd_compat_ops::check("local command does not end direct force", dut_signal === 1'b0);
        timed_owner.kill();
        #0;
        cmd_compat_ops::check("cancelled facade did not return", !timed_returned);
        cmd_compat_ops::check("cancelled facade does not rollback force", dut_signal === 1'b0);
        aip_cmd::exec_result("compat_leaf text=after_cancel", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("cancelled facade legacy slot recovered", code == 71 &&
                              result == "LEAF:after_cancel");
        aip_dut_control_ops::release_signal(path);
        cmd_compat_ops::check_globals("release after cancelled facade", 0, {"released ", path});
        dut_signal = 1;
        #1ns;
        cmd_compat_ops::check("cancelled force explicitly released", dut_signal === 1'b1);
        cmd_compat_ops::check("cancelled facade scope cleaned",
                              aip_cmd::get_current_context() == null);
    endtask

    // 同步嵌套与外部并发必须分开：前者可借槽，后者 BUSY 且不能改句柄参数。
    task automatic check_legacy_nesting();
        int code;
        string result;
        aip_cmd leaf;
        aip_cmd outer;
        int before_calls;
        string previous_args;
        aip_cmd::exec_result("compat_outer text=sync", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("legacy multilevel top status", code == 92);
        cmd_compat_ops::check("legacy multilevel top result", result == "OUTER:sync");
        cmd_compat_ops::check("legacy multilevel context released",
                              aip_cmd::get_current_context() == null);

        leaf = aip_cmd::get_handle("compat_leaf");
        outer = aip_cmd::get_handle("compat_outer");
        previous_args = leaf.args_in;
        before_calls = cmd_compat_ops::leaf_calls;
        aip_cmd::exec_result("compat_outer text=hold wait=0", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("legacy outer background started", code == 0 &&
                              result == "STARTED: compat_outer");
        aip_cmd::exec_result("compat_leaf text=outside", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("external legacy stays BUSY", code != 0 &&
                              aip_str::str_find(result, "BUSY") == 0);
        cmd_compat_ops::check("external legacy does not overwrite args", leaf.args_in == previous_args);
        cmd_compat_ops::check("external legacy does not execute", cmd_compat_ops::leaf_calls == before_calls);
        raw_invoke("outside=local,", "outside=local,");
        cmd_compat_ops::check_globals("local dispatch preserves external legacy", 91, "OUTER_BEFORE");
        aip_cmd::exec_result("compat_local_dut", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("local DUT wrapper returns facade result", code == 0 &&
                              result == "deposited test_cmd_compat.dut_signal=1");
        cmd_compat_ops::check_globals("local DUT wrapper preserves external legacy", 91, "OUTER_BEFORE");
        aip_cmd::exec_result("compat_local_loader", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("local loader wrapper returns facade result", code == -1 &&
          result == "aip_cpu_loader_default: not set (call set() in TB); ctx=load_image");
        cmd_compat_ops::check_globals("local loader wrapper preserves external legacy", 91, "OUTER_BEFORE");
        #30ns;
        cmd_compat_ops::check("background nested outer completed", !outer.is_busy() &&
                              outer.status == 92 && outer.result_out == "OUTER:hold");
        aip_cmd::exec_result("compat_leaf text=after_hold", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("legacy slot reusable after nested background", code == 71 &&
                              result == "LEAF:after_hold");
        aip_cmd::exec_result("compat_cancel_parent", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("cancelled child leaves parent runnable", code == 112 &&
                              result == "CANCEL_PARENT_DONE");
    endtask

    // 组合兼容不是仅保留 facade 签名：旧注册用户 task 内的立即读槽、最终
    // 覆盖，以及宏直接入口/统一 dispatch 两条路径都必须保持原有优先级。
    task automatic check_facade_wrappers();
        int code;
        string result;
        aip_cpu_loader_default::set(null);
        aip_cmd::exec_result("compat_legacy_dut text=dispatch", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("legacy DUT wrapper final override survives", code == 121 &&
                              result == "LEGACY_DUT_FINAL:dispatch");
        cmd_compat_ops::check("legacy DUT wrapper actually deposits", dut_signal === 1'b1);
        aip_cmd::exec_result("compat_legacy_loader text=dispatch", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("legacy loader wrapper final override survives", code == 123 &&
                              result == "LEGACY_LOADER_FINAL:dispatch");
        direct_invoke("compat_legacy_dut", "text=direct", 121, "LEGACY_DUT_FINAL:direct");
        direct_invoke("compat_legacy_loader", "text=direct", 123, "LEGACY_LOADER_FINAL:direct");
    endtask

    // 参数测试既覆盖无 wait 的零修改保证，也覆盖首/中/尾控制词和真实后台派发。
    // 业务自己的 quoted/braced wait 不能开后台、不能触发重复 wait 拒参。
    task automatic check_raw_arguments();
        int code;
        string result;
        aip_cmd handle;
        raw_invoke("a=1,", "a=1,");
        raw_invoke("a=1,,", "a=1,,");
        raw_invoke("a=1,\t b=2,,", "a=1,\t b=2,,");
        raw_invoke("payload=\"quoted wait=0\",", "payload=\"quoted wait=0\",");
        raw_invoke("payload={wait=0 nested{wait=1}},", "payload={wait=0 nested{wait=1}},");
        raw_invoke("\"wait=0\" a=1,", "\"wait=0\" a=1,");
        raw_invoke("wait=1 a=1,", "a=1,");
        raw_invoke("a=1 wait=1 b=2,", "a=1 b=2,");
        raw_invoke("a=1,wait=1,b=2,", "a=1,b=2,");
        raw_invoke("a=1, wait=1", "a=1,");
        raw_invoke("wait=1", "");
        raw_invoke("payload={wait=0 nested{wait=1}} wait=1 tail=2,",
                   "payload={wait=0 nested{wait=1}} tail=2,");
        raw_invoke("payload=\"quoted wait=0\" wait=1 tail=2,",
                   "payload=\"quoted wait=0\" tail=2,");
        aip_cmd::exec_result("compat_raw wait=0 a=1,", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("raw background starts", code == 0 && result == "STARTED: compat_raw");
        #1ns;
        handle = aip_cmd::get_handle("compat_raw");
        cmd_compat_ops::check("raw background preserves trailing comma",
                              !handle.is_busy() && handle.status == 0 && handle.result_out == "a=1,");
    endtask

    initial begin
        int code;
        string result;
        realtime began;
        string negative_case;

        // 直接 facade 无 output 参数可返回 BUSY，故外部 legacy 占槽时必须在
        // 操作 DUT 前明确 fatal；兼容 setter 也不能被用来无 scope 裸写全局。
        // 不把下面测试自带的兜底 fatal 计作框架拒绝。
        if ($value$plusargs("compat_negative=%s", negative_case)) begin
            $display("CMD_COMPAT_NEGATIVE case=%s", negative_case);
            if (negative_case == "facade_busy") begin
                dut_signal = 1;
                aip_cmd::exec_result("compat_outer text=hold wait=0", SRC_INTERNAL, code, result);
                if (code != 0 || result != "STARTED: compat_outer")
                    $fatal(1, "CMD_COMPAT_NEGATIVE_SETUP_FAILED");
                aip_dut_control_ops::force_signal("test_cmd_compat.dut_signal", "0");
                $fatal(1, "EXPECTED_COMPAT_FATAL_MISSING signal=%b", dut_signal);
            end else if (negative_case == "compat_no_context") begin
                aip_cmd::set_compat_result(141, "forbidden without compatibility scope");
                $fatal(1, "EXPECTED_COMPAT_FATAL_MISSING case=compat_no_context");
            end else $fatal(1, "UNKNOWN_COMPAT_NEGATIVE case=%s", negative_case);
        end

        direct_invoke("compat_zero", "", 21, "ZERO");
        direct_invoke("compat_one", "a=7", 22, "SUM:7");
        direct_invoke("compat_four", "a=1 b=2 c=3 d=4", 22, "SUM:10");
        direct_invoke("compat_ten", "a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9 j=10", 22, "SUM:55");
        direct_invoke("compat_output", "value=7", 0, "result=0x8");
        direct_invoke("compat_outputs", "a=1 b=2 c=3 d=4 e=5", 23, "OUTPUTS:3,7,5");
        direct_invoke("compat_enum", "mode=COMPAT_ACTIVE", 24, "ENUM:COMPAT_ACTIVE");
        direct_invoke("compat_enum_output", "mode=COMPAT_ACTIVE", 0, "result=0xb");
        check_cpu_direct();
        check_dut_direct();
        check_facade_wrappers();
        check_legacy_nesting();
        check_raw_arguments();

        began = $realtime;
        aip_cmd::exec_result("compat_owned_fork", SRC_INTERNAL, code, result);
        cmd_compat_ops::check("business internal join completes", code == 0 &&
                              result == "OWNED_CHILD_JOINED" && cmd_compat_ops::owned_child_done);
        cmd_compat_ops::check("business internal join time", $realtime - began == 7ns);
        if (cmd_compat_ops::failures != 0)
            $fatal(1, "CMD_COMPAT_FAILED checks=%0d failures=%0d",
                   cmd_compat_ops::checks, cmd_compat_ops::failures);
        $display("CMD_COMPAT_PASS checks=%0d", cmd_compat_ops::checks);
        $finish;
    end
endmodule
