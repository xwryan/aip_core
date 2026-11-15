// tests/sv：逐调用结果上下文与旧字符串宏后台兼容的独立调度测试。
// 依赖 AIP package，不需要真实 DUT 或 sequencer。框架拥有注册对象/执行
// 进程；测试只保留公开上下文句柄用于生命周期验证，正常路径不修改其
// 内部字段。plusarg 负例必须独立运行，并由外层 runner 认定预期 fatal。
`timescale 1ns/1ps
`include "aip_core_pkg.sv"

// 单寄存器内存替身只覆盖 cpu_wait 的结果传播，不依赖 HDL backdoor 权限。
// 测试拥有此对象并经 cpu_mem 借给 loader；并发阶段仅由 cpu_wait 读取。
class result_context_region extends aip_cpu_region;
    bit [31:0] value;

    // 固定低地址避免 signed int 地址扩展干扰；仅支持一个 32-bit 寄存器。
    function new();
        name = "context_ready_register";
        base = 'h1000;
        size = 4;
        value = 0;
    endfunction

    // 写入只用于测试初始化，越界或宽度错误由测试立即终止。
    virtual task write_impl(input longint unsigned off,
                            input longint unsigned data, input int width);
        if (off != 0 || width != 32) $fatal(1, "CONTEXT_REGION_BAD_WRITE");
        value = data[31:0];
    endtask

    // 对合法读取返回寄存器和成功标志，不伪造 ready 或 timeout 的业务结果。
    virtual task read_impl(input longint unsigned off,
                           output longint unsigned data, input int width,
                           output bit status_ok);
        data = value;
        status_ok = (off == 0 && width == 32);
    endtask

    // 满足 region 接口的清零操作，不创建额外后台进程。
    virtual task zero_all();
        value = 0;
    endtask
endclass

// 观察记录与 task 实现放在业务层，避免测试依赖调度器的私有 busy/owner。
class result_context_ops;
    static int started[string];
    static int finished[string];
    static string entered[string];
    static string left[string];
    static aip_cmd_result_context saved_a;
    static aip_cmd_result_context saved_outer;
    static process saved_a_process;
    static int direct_reentrant_entries = 0;

    // 两个独立别名复用此业务：保存上下文、等待、提交非零结果；通过句柄
    // 二次读取参数确认 BUSY 拒绝没有覆盖本次输入。上下文只存活于本次执行。
    static task execute(string name, string text, int ns, int code);
        aip_cmd handle;
        aip_cmd_result_context context_handle;
        handle = aip_cmd::get_handle(name);
        context_handle = aip_cmd::get_current_context();
        if (context_handle == null) $fatal(1, "CONTEXT_MISSING %s", name);
        if (name == "ctx_a") begin
            saved_a = context_handle;
            saved_a_process = process::self();
        end
        started[name] = started.exists(name) ? started[name] + 1 : 1;
        entered[name] = handle.args_in;
        aip_cmd::set_result(code + 100, {"EARLY:", name, ":", text});
        #(ns * 1ns);
        context_handle.set_result(code, {"DONE:", name, ":", text});
        finished[name] = finished.exists(name) ? finished[name] + 1 : 1;
        left[name] = handle.args_in;
    endtask

    // 别名 A 使用自己的固定返回码，便于识别两条异步调用的结果串线。
    static task run_a(string text, int ns);
        execute("ctx_a", text, ns, 41);
    endtask

    // 别名 B 与 A 使用同一业务实现，但拥有独立的框架上下文。
    static task run_b(string text, int ns);
        execute("ctx_b", text, ns, 42);
    endtask

    // 普通 typed 宏仍按原约定写公开 handle，作为兼容前台命令。
    static task foreground(int ns);
        aip_cmd handle;
        handle = aip_cmd::get_handle("ctx_front");
        #(ns * 1ns);
        handle.status = 0;
        handle.result_out = "FRONT_DONE";
    endtask

    // 老业务在开始就写共享槽，等待期间不能被 STARTED 或前台镜像覆盖。
    static task legacy(string text, int ns);
        aip_cmd::__aip_cmd_last_status = 51;
        aip_cmd::__aip_cmd_last_result = {"LEGACY:", text};
        #(ns * 1ns);
    endtask

    // 第二个默认兼容宏用于确认全局槽在途时互斥，而不是只保护相同别名。
    static task legacy_other(string text);
        aip_cmd::__aip_cmd_last_status = 52;
        aip_cmd::__aip_cmd_last_result = {"OTHER:", text};
    endtask

    // 嵌套命令的结果经显式输出返回，不能覆盖外层的当前上下文绑定。
    static task inner(string text);
        aip_cmd::set_result(61, {"INNER:", text});
    endtask

    // 在内层执行前后读取当前上下文，验证查找是按执行进程而非静态单槽。
    static task outer(string text);
        aip_cmd_result_context before_context;
        int inner_status;
        string inner_result;
        before_context = aip_cmd::get_current_context();
        saved_outer = before_context;
        aip_cmd::set_result(160, "OUTER_BEFORE");
        aip_cmd::exec_result({"ctx_inner text=", text}, SRC_INTERNAL,
                             inner_status, inner_result);
        if (inner_status != 61 || inner_result != {"INNER:", text})
            $fatal(1, "NESTED_RESULT_LOST");
        if (aip_cmd::get_current_context() != before_context)
            $fatal(1, "NESTED_CONTEXT_LOST");
        aip_cmd::set_result(62, {"OUTER:", text});
    endtask

    // 用户自行 fork 时显式传递 ctx；子进程不需要继承隐藏的 process 绑定。
    static task child_result(string text);
        aip_cmd_result_context context_handle;
        context_handle = aip_cmd::get_current_context();
        fork
            begin
                #5ns;
                context_handle.set_result(63, {"CHILD:", text});
            end
        join
    endtask

    // typed 宏原本在 svtask 返回后自动设置成功；显式结果必须最终优先。
    static task typed_result(int n);
        aip_cmd::set_result(64, $sformatf("TYPED:%0d", n));
    endtask

    // 单字符串用于覆盖普通宏和 _status 宏的可选 LOCAL_RESULT 尾参。
    static task one(string a);
        aip_cmd::set_result(71, {"ONE:", a});
    endtask

    // 双字符串证明新返回机制不改变实参解析与默认值。
    static task two(string a, string b);
        aip_cmd::set_result(72, {"TWO:", a, ",", b});
    endtask

    // 三字符串用于普通第三参数和特殊 time= 的映射检查。
    static task three(string a, string b, string span);
        aip_cmd::set_result(73, {"THREE:", a, ",", b, ",", span});
    endtask

    // 整数在前的混合宏也必须支持局部返回，而不访问 legacy 全局槽。
    static task integer_string(int n, string a);
        aip_cmd::set_result(74, $sformatf("INT_STR:%0d,%s", n, a));
    endtask

    // 未提交结果的局部 task 应保持本次缺省值，不能继承上次上下文。
    static task silent(string a);
    endtask

    // 故意绕过调度器，在活动命令进程中直接调用别名的 cmd_exec；此时
    // 不能把外层 ctx 当作内层所有权。框架应明确 fatal，而非污染外层结果。
    static task direct_nested(string a);
        aip_cmd inner_handle;
        inner_handle = aip_cmd::get_handle("ctx_one");
        inner_handle.args_in = "a=forbidden_nested";
        inner_handle.cmd_exec();
    endtask

    // 同名 direct 重入也必须被拒绝；计数上限仅防无保护实现无限递归，
    // 若框架漏检则返回到负例尾部的 MISSING fatal，由 runner 判定为失败。
    static task direct_reentrant(string a);
        aip_cmd self_handle;
        direct_reentrant_entries++;
        if (direct_reentrant_entries > 1) return;
        self_handle = aip_cmd::get_handle("ctx_direct_reentrant");
        self_handle.cmd_exec();
    endtask
endclass

// 原有宏注册语法仅追加可选的尾参 1；旧业务省略该参数仍保持兼容模式。
`aip_cmd_str_1i1i(ctx_a, result_context_ops::run_a, string, text, "default_a", int, ns, 0, 1)
`aip_cmd_str_1i1i(ctx_b, result_context_ops::run_b, string, text, "default_b", int, ns, 0, 1)
`aip_cmd_1i(ctx_front, result_context_ops::foreground, int, ns, 0)
`aip_cmd_str_1i1i(ctx_legacy, result_context_ops::legacy, string, text, "", int, ns, 0)
`aip_cmd_str_1i(ctx_legacy_other, result_context_ops::legacy_other, text, "")
`aip_cmd_str_1i(ctx_inner, result_context_ops::inner, text, "", 1)
`aip_cmd_str_1i(ctx_outer, result_context_ops::outer, text, "", 1)
`aip_cmd_str_1i(ctx_child, result_context_ops::child_result, text, "", 1)
`aip_cmd_1i(ctx_typed_result, result_context_ops::typed_result, int, n, 0)
`aip_cmd_str_1i(ctx_one, result_context_ops::one, a, "default_a", 1)
`aip_cmd_str_2i(ctx_two, result_context_ops::two, a, "default_a", b, "default_b", 1)
`aip_cmd_str_1i_status(ctx_one_status, result_context_ops::one, a, "default_a", 1)
`aip_cmd_str_2i_status(ctx_two_status, result_context_ops::two, a, "default_a", b, "default_b", 1)
`aip_cmd_str_3i_status(ctx_three, result_context_ops::three,
                     a, "default_a", b, "default_b", span, "default_span", 1)
`aip_cmd_str_3i_status_time(ctx_time, result_context_ops::three,
                          a, "default_a", b, "default_b", duration, "default_span", 1)
`aip_cmd_1i1s(ctx_int_string, result_context_ops::integer_string,
             int, n, 3, string, a, "default_a", 1)
`aip_cmd_str_1i(ctx_silent, result_context_ops::silent, a, "", 1)
`aip_cmd_str_1i_status(ctx_silent_status, result_context_ops::silent, a, "", 1)
`aip_cmd_str_1i(ctx_direct_nested, result_context_ops::direct_nested, a, "", 1)
`aip_cmd_str_1i(ctx_direct_reentrant, result_context_ops::direct_reentrant, a, "", 1)

// 使用公开 exec_result 与 handle，不引入 bridge ACK 时序到核心生命周期门禁。
module test_cmd_result_context;
    int checks = 0;
    int fails = 0;

    // 累积断言，失败时给出稳定标记，最终 fatal 防止 runner 仅检查退出码漏报。
    task automatic check(string name, bit condition);
        checks++;
        if (condition) $display("CMD_RESULT_CONTEXT_CHECK_PASS %s", name);
        else begin
            fails++;
            $display("CMD_RESULT_CONTEXT_CHECK_FAIL %s", name);
        end
    endtask

    // 完成后读取公开 handle，确认逐次输出和后续诊断观察得到同一业务结果。
    task automatic check_handle(string name, int expected_status, string expected_result);
        aip_cmd handle;
        handle = aip_cmd::get_handle(name);
        check({name, " handle exists"}, handle != null);
        if (handle != null) begin
            check({name, " handle status"}, handle.status == expected_status);
            check({name, " handle result"}, handle.result_out == expected_result);
        end
    endtask

    // 同步执行并检查输出和句柄；不使用全局镜像作为并发命令的返回通道。
    task automatic invoke(string command_text, string name,
                          int expected_status, string expected_result);
        int result_status;
        string result_text;
        aip_cmd::exec_result(command_text, SRC_INTERNAL, result_status, result_text);
        check({name, " call status"}, result_status == expected_status);
        check({name, " call result"}, result_text == expected_result);
        check_handle(name, expected_status, expected_result);
    endtask

    // 旧式顺序 direct 入口在没有调度器时也能使用 LOCAL_RESULT，上下文
    // 由宏临时创建且必须在返回时释放；结果保留在常驻注册 handle。
    task automatic direct_invoke(string name, string arguments,
                                 int expected_status, string expected_result);
        aip_cmd handle;
        handle = aip_cmd::get_handle(name);
        check({name, " direct entry has no context"}, aip_cmd::get_current_context() == null);
        handle.args_in = arguments;
        handle.cmd_exec();
        check_handle(name, expected_status, expected_result);
        check({name, " direct context released"}, aip_cmd::get_current_context() == null);
    endtask

    // cpu_wait 仍由 typed 宏注册，验证真实 facade 的错误不会被宏末尾成功
    // 覆盖；wait=0 仅跳过前台等待，不取消业务自己的 timeout_ns。
    task automatic check_cpu_wait_results();
        aip_cpu_mem cpu;
        aip_cpu_loader loader;
        result_context_region ready_register;
        aip_cmd handle;
        int result_status;
        string result_text;
        realtime start_time;

        aip_cpu_loader_default::set(null);
        invoke("cpu_wait addr=0x1000 expected=1", "cpu_wait", -1,
               "aip_cpu_loader_default: not set (call set() in TB); ctx=wait_value");
        cpu = new();
        ready_register = new();
        cpu.add_region(ready_register);
        loader = new(cpu);
        aip_cpu_loader_default::set(loader);

        start_time = $realtime;
        aip_cmd::exec_result("cpu_wait addr=0x1000 expected=1 timeout_ns=200",
                             SRC_INTERNAL, result_status, result_text);
        check("cpu_wait preserves timeout error", result_status == -1 &&
              aip_str::str_find(result_text, "timeout 200 ns") == 0);
        check("cpu_wait synchronous deadline", $realtime - start_time == 200ns);

        start_time = $realtime;
        aip_cmd::exec_result("cpu_wait addr=0x1000 expected=1 timeout_ns=200 wait=0",
                             SRC_INTERNAL, result_status, result_text);
        check("cpu_wait asynchronous STARTED", result_status == 0 &&
              result_text == "STARTED: cpu_wait" && $realtime == start_time);
        #201ns;
        handle = aip_cmd::get_handle("cpu_wait");
        check("cpu_wait asynchronous deadline retained", handle.status == -1 &&
              aip_str::str_find(handle.result_out, "timeout 200 ns") == 0);

        ready_register.value = 1;
        aip_cmd::exec_result("cpu_wait addr=0x1000 expected=1 timeout_ns=200",
                             SRC_INTERNAL, result_status, result_text);
        check("cpu_wait ready result clears prior failure", result_status == 0 &&
              aip_str::str_find(result_text, "ready @") == 0);
        aip_cpu_loader_default::set(null);
    endtask

    initial begin
        string negative_case;
        int result_status;
        string result_text;
        int before_count;
        realtime start_time;
        aip_cmd_result_context old_context;
        aip_cmd_result_context first_outer_context;
        aip_cmd direct_handle;

        // 负例独立运行：非法 ctx 生命周期，以及绕过调度器的嵌套/重入调用。
        // 正常测试不会走这些故意 fatal 路径，runner 必须拒绝下面的 MISSING 标记。
        if ($value$plusargs("context_negative=%s", negative_case)) begin
            $display("CMD_RESULT_CONTEXT_NEGATIVE case=%s", negative_case);
            case (negative_case)
                "no_context": aip_cmd::set_result(1, "invalid outside command");
                "stale_context": begin
                    invoke("ctx_a text=finished ns=1", "ctx_a", 41, "DONE:ctx_a:finished");
                    result_context_ops::saved_a.set_result(1, "invalid after completion");
                end
                "killed_context": begin
                    aip_cmd::exec_result("ctx_a text=killed ns=1000 wait=0", SRC_INTERNAL,
                                         result_status, result_text);
                    #1ns;
                    result_context_ops::saved_a_process.kill();
                    #1ns;
                    result_context_ops::saved_a.set_result(1, "invalid after cancellation");
                end
                "direct_nested": begin
                    direct_handle = aip_cmd::get_handle("ctx_direct_nested");
                    direct_handle.args_in = "a=outer";
                    direct_handle.cmd_exec();
                end
                "direct_reentrant": begin
                    direct_handle = aip_cmd::get_handle("ctx_direct_reentrant");
                    direct_handle.args_in = "a=outer";
                    direct_handle.cmd_exec();
                end
                default: $fatal(1, "UNKNOWN_CONTEXT_NEGATIVE %s", negative_case);
            endcase
            $fatal(1, "EXPECTED_CONTEXT_FATAL_MISSING %s", negative_case);
        end

        // 八种局部模式宏均能编译、使用旧参数语法，并将非零显式结果保留下来。
        invoke("ctx_one a=x", "ctx_one", 71, "ONE:x");
        invoke("ctx_two a=x b=y", "ctx_two", 72, "TWO:x,y");
        invoke("ctx_one_status a=x", "ctx_one_status", 71, "ONE:x");
        invoke("ctx_two_status a=x b=y", "ctx_two_status", 72, "TWO:x,y");
        invoke("ctx_three a=x b=y span=z", "ctx_three", 73, "THREE:x,y,z");
        invoke("ctx_time a=x b=y time=25ns", "ctx_time", 73, "THREE:x,y,25ns");
        invoke("ctx_a text=x ns=1", "ctx_a", 41, "DONE:ctx_a:x");
        invoke("ctx_int_string n=0x12 a=x", "ctx_int_string", 74, "INT_STR:18,x");
        invoke("ctx_one", "ctx_one", 71, "ONE:default_a");
        invoke("ctx_two", "ctx_two", 72, "TWO:default_a,default_b");
        invoke("ctx_three", "ctx_three", 73, "THREE:default_a,default_b,default_span");
        invoke("ctx_time", "ctx_time", 73, "THREE:default_a,default_b,default_span");
        invoke("ctx_int_string", "ctx_int_string", 74, "INT_STR:3,default_a");
        invoke("ctx_silent", "ctx_silent", 0, "");
        invoke("ctx_one a=before_silent_status", "ctx_one", 71, "ONE:before_silent_status");
        invoke("ctx_silent_status", "ctx_silent_status", 0, "");

        // 全八种宏追加 LOCAL_RESULT 后仍保留旧顺序 direct 调用形式。
        direct_invoke("ctx_one", "a=direct", 71, "ONE:direct");
        direct_invoke("ctx_two", "a=direct b=two", 72, "TWO:direct,two");
        direct_invoke("ctx_one_status", "a=direct", 71, "ONE:direct");
        direct_invoke("ctx_two_status", "a=direct b=two", 72, "TWO:direct,two");
        direct_invoke("ctx_three", "a=direct b=two span=three", 73, "THREE:direct,two,three");
        direct_invoke("ctx_time", "a=direct b=two time=33ns", 73, "THREE:direct,two,33ns");
        direct_invoke("ctx_a", "text=direct ns=1", 41, "DONE:ctx_a:direct");
        direct_invoke("ctx_int_string", "n=7 a=direct", 74, "INT_STR:7,direct");
        direct_invoke("ctx_silent_status", "a=direct", 0, "");

        // 两个局部模式字符串命令真正同时在途；下一条默认仍同步等待。
        start_time = $realtime;
        aip_cmd::exec_result("ctx_a text=parallel_a ns=100 wait=0", SRC_INTERNAL,
                             result_status, result_text);
        check("local A STARTED", result_status == 0 && result_text == "STARTED: ctx_a");
        old_context = result_context_ops::saved_a;
        aip_cmd::exec_result("ctx_b text=parallel_b ns=40 wait=0", SRC_INTERNAL,
                             result_status, result_text);
        check("local B STARTED while A active", result_status == 0 && result_text == "STARTED: ctx_b");
        check("both async ACKs immediate", $realtime == start_time);
        before_count = result_context_ops::started["ctx_a"];
        aip_cmd::exec_result("ctx_a text=overwrite ns=0 wait=1", SRC_INTERNAL,
                             result_status, result_text);
        check("same alias BUSY", result_status != 0 && result_text.substr(0, 3) == "BUSY");
        check("BUSY no extra invocation", result_context_ops::started["ctx_a"] == before_count);
        invoke("ctx_front ns=60", "ctx_front", 0, "FRONT_DONE");
        check("next default command waits", $realtime - start_time == 60ns);
        check_handle("ctx_b", 42, "DONE:ctx_b:parallel_b");
        #50ns;
        check_handle("ctx_a", 41, "DONE:ctx_a:parallel_a");
        check("BUSY preserves original parameters",
              result_context_ops::left["ctx_a"] == "text=parallel_a ns=100");
        invoke("ctx_a text=reused ns=1", "ctx_a", 41, "DONE:ctx_a:reused");
        check("new invocation gets fresh context", result_context_ops::saved_a != old_context);

        // 旧全局写法可以后台运行，但只允许一条 legacy 在途；独立局部模式
        // 与普通前台命令不受此限制，镜像发布不能修改 legacy 保存的业务结果。
        aip_cmd::exec_result("ctx_legacy text=saved ns=100 wait=0", SRC_INTERNAL,
                             result_status, result_text);
        check("legacy wait0 accepted", result_status == 0 && result_text == "STARTED: ctx_legacy");
        aip_cmd::exec_result("ctx_b text=alongside_legacy ns=30 wait=0", SRC_INTERNAL,
                             result_status, result_text);
        check("local starts alongside legacy", result_status == 0 && result_text == "STARTED: ctx_b");
        aip_cmd::exec("ctx_front ns=40", SRC_INTERNAL);
        check_handle("ctx_front", 0, "FRONT_DONE");
        check_handle("ctx_b", 42, "DONE:ctx_b:alongside_legacy");
        check("foreground mirror preserves legacy status", aip_cmd::__aip_cmd_last_status == 51);
        check("foreground mirror preserves legacy text", aip_cmd::__aip_cmd_last_result == "LEGACY:saved");
        aip_cmd::exec_result("ctx_legacy_other text=must_not_run", SRC_INTERNAL,
                             result_status, result_text);
        check("different legacy alias BUSY", result_status != 0 && result_text.substr(0, 3) == "BUSY");
        #70ns;
        check_handle("ctx_legacy", 51, "LEGACY:saved");
        invoke("ctx_legacy_other text=released", "ctx_legacy_other", 52, "OTHER:released");

        // 捕获 child 的显式返回和 nested exec 的外层上下文，typed 宏自动
        // 设置的默认成功不能吞掉业务通过 set_result 提交的失败状态。
        invoke("ctx_outer text=nested", "ctx_outer", 62, "OUTER:nested");
        check_handle("ctx_inner", 61, "INNER:nested");
        first_outer_context = result_context_ops::saved_outer;
        invoke("ctx_outer text=nested_again", "ctx_outer", 62, "OUTER:nested_again");
        check("nested invocation context not reused", result_context_ops::saved_outer != first_outer_context);
        invoke("ctx_child text=from_fork", "ctx_child", 63, "CHILD:from_fork");
        invoke("ctx_typed_result n=19", "ctx_typed_result", 64, "TYPED:19");

        // fork 取消只终止本批未完成子调用；重入必须获得新 ctx，旧 worker
        // 不能在原截止时间恢复并把新调用的结果改写。
        before_count = result_context_ops::finished["ctx_a"];
        aip_cmd::exec_result("fork ctx_a text=canceled ns=1000, ctx_front ns=10 join_any disable_remaining=1",
                             SRC_INTERNAL, result_status, result_text);
        check("fork cancellation returns winner", result_status == 0);
        old_context = result_context_ops::saved_a;
        invoke("ctx_a text=after_cancel ns=1", "ctx_a", 41, "DONE:ctx_a:after_cancel");
        check("cancelled context not reused", result_context_ops::saved_a != old_context);
        #1100ns;
        check("cancelled worker never completes", result_context_ops::finished["ctx_a"] == before_count + 1);
        check_handle("ctx_a", 41, "DONE:ctx_a:after_cancel");

        // legacy owner 被取消后也必须释放共享槽，不能留下全局永久 BUSY。
        aip_cmd::exec_result("fork ctx_legacy text=canceled ns=1000, ctx_front ns=10 join_any disable_remaining=1",
                             SRC_INTERNAL, result_status, result_text);
        check("legacy fork cancellation returns winner", result_status == 0);
        invoke("ctx_legacy_other text=after_cancel", "ctx_legacy_other", 52, "OTHER:after_cancel");
        #1100ns;
        check_handle("ctx_legacy_other", 52, "OTHER:after_cancel");

        check_cpu_wait_results();
        if (fails != 0) $fatal(1, "CMD_RESULT_CONTEXT_FAIL fails=%0d checks=%0d", fails, checks);
        $display("CMD_RESULT_CONTEXT_PASS checks=%0d", checks);
        $finish;
    end
endmodule
