// tests/sv：旧字符串命令注册语法与全局返回值业务的同步兼容门禁。
// 依赖 AIP package；宏创建的注册对象由框架持有到仿真结束，测试仅检查
// 公开句柄与兼容镜像。业务 task 刻意保留直接写全局变量的旧代码，不能
// 全部换成新 set_result 后误称旧业务兼容；逐调用上下文另有专门测试。
`include "aip_core_pkg.sv"

// 保留旧业务返回约定，覆盖八种字符串宏的实参映射和缺省结果清理。
class str_result_ops;
    // 返回一个字符串实参及非零状态，证明兼容结果没有被默认成功覆盖。
    static task s1(string a);
        aip_cmd::__aip_cmd_last_status = 7;
        aip_cmd::__aip_cmd_last_result = {"s1:", a};
    endtask
    // 返回两个字符串，区分参数位置和各自缺省值。
    static task s2(string a, string b);
        aip_cmd::__aip_cmd_last_status = 8;
        aip_cmd::__aip_cmd_last_result = {"s2:", a, ",", b};
    endtask
    // 返回字符串与整数，验证原有整数转换及参数顺序。
    static task s1i(string a, int n);
        aip_cmd::__aip_cmd_last_status = 9;
        aip_cmd::__aip_cmd_last_result = $sformatf("s1i:%s,%0d", a, n);
    endtask
    // 返回整数与字符串，验证混合宏与 string-first 宏没有混用实参顺序。
    static task i1s(int n, string a);
        aip_cmd::__aip_cmd_last_status = 10;
        aip_cmd::__aip_cmd_last_result = $sformatf("i1s:%0d,%s", n, a);
    endtask
    // 三字符串覆盖普通第三参数与对外保留 time= 的特殊宏。
    static task s3(string a, string b, string span);
        aip_cmd::__aip_cmd_last_status = 11;
        aip_cmd::__aip_cmd_last_result = {"s3:", a, ",", b, ",", span};
    endtask

    // 故意不写返回槽；框架必须给本次调用独立的 0/空串缺省结果。
    static task silent(string a);
    endtask
endclass

`aip_cmd_str_1i  (t_s1,     str_result_ops::s1,     a, "")
`aip_cmd_str_2i  (t_s2,     str_result_ops::s2,     a, "", b, "")
`aip_cmd_str_1i1i(t_s1i,    str_result_ops::s1i,    string, a, "", int, n, 0)
`aip_cmd_1i1s    (t_i1s,    str_result_ops::i1s,    int, n, 0, string, a, "")
`aip_cmd_str_1i  (t_silent, str_result_ops::silent, a, "")
`aip_cmd_str_1i_status(t_s1_status, str_result_ops::s1, a, "default_a")
`aip_cmd_str_2i_status(t_s2_status, str_result_ops::s2, a, "default_a", b, "default_b")
`aip_cmd_str_3i_status(t_s3_status, str_result_ops::s3,
                     a, "default_a", b, "default_b", span, "default_span")
`aip_cmd_str_3i_status_time(t_s3_time, str_result_ops::s3,
                          a, "default_a", b, "default_b", duration, "default_span")
`aip_cmd_str_1i_status(t_silent_status, str_result_ops::silent, a, "")

// 不启动 UVM 环境；覆盖公共调度入口和旧 handle.cmd_exec 顺序入口，
// 结束前汇总所有断言。直接入口不具备并发调度能力，测试不并发改写 args_in。
module test_cmd_str_result;
    int fails = 0;

    // 汇总失败而不提前退出，最终非零 fatal 保证外层 runner 不漏报。
    task automatic check(string name, bit cond);
        if (cond) $display("[PASS] %s", name);
        else begin
            $display("[FAIL] %s (status=%0d result='%s')", name,
                     aip_cmd::__aip_cmd_last_status, aip_cmd::__aip_cmd_last_result);
            fails++;
        end
    endtask

    // 每次同时检查兼容镜像和公开句柄，避免结果只写到其中一个通道。
    task automatic check_handle(string name, int expected_status, string expected_result);
        aip_cmd handle;
        handle = aip_cmd::get_handle(name);
        check({name, " handle exists"}, handle != null);
        if (handle != null) begin
            check({name, " handle status"}, handle.status == expected_status);
            check({name, " handle result"}, handle.result_out == expected_result);
        end
        check({name, " mirror status"}, aip_cmd::__aip_cmd_last_status == expected_status);
        check({name, " mirror result"}, aip_cmd::__aip_cmd_last_result == expected_result);
    endtask

    // 旧 loader 测试直接设置 args_in 后调用 cmd_exec；宏需要临时建立并释放
    // 上下文，同时保留 handle 与 legacy 全局结果，不能把调用改成要求调度器。
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

    initial begin
        aip_cmd::exec("t_s1 a=hello", SRC_INTERNAL);
        check("str_1i forwards status", aip_cmd::__aip_cmd_last_status == 7);
        check("str_1i forwards result", aip_cmd::__aip_cmd_last_result == "s1:hello");
        check_handle("t_s1", 7, "s1:hello");

        aip_cmd::exec("t_s2 a=x b=y", SRC_INTERNAL);
        check("str_2i forwards status", aip_cmd::__aip_cmd_last_status == 8);
        check("str_2i forwards result", aip_cmd::__aip_cmd_last_result == "s2:x,y");
        check_handle("t_s2", 8, "s2:x,y");

        aip_cmd::exec("t_s1i a=f n=5", SRC_INTERNAL);
        check("str_1i1i forwards status", aip_cmd::__aip_cmd_last_status == 9);
        check("str_1i1i forwards result", aip_cmd::__aip_cmd_last_result == "s1i:f,5");
        check_handle("t_s1i", 9, "s1i:f,5");

        aip_cmd::exec("t_i1s n=3 a=g", SRC_INTERNAL);
        check("1i1s forwards status", aip_cmd::__aip_cmd_last_status == 10);
        check("1i1s forwards result", aip_cmd::__aip_cmd_last_result == "i1s:3,g");
        check_handle("t_i1s", 10, "i1s:3,g");

        // 普通宏与 _status 宏都不能泄漏上一条命令的失败状态/文本。
        aip_cmd::exec("t_silent a=z", SRC_INTERNAL);
        check("silent task yields status 0", aip_cmd::__aip_cmd_last_status == 0);
        check("silent task yields empty result", aip_cmd::__aip_cmd_last_result == "");
        check_handle("t_silent", 0, "");

        aip_cmd::exec("t_s1_status a=one", SRC_INTERNAL);
        check_handle("t_s1_status", 7, "s1:one");
        aip_cmd::exec("t_s2_status a=two b=three", SRC_INTERNAL);
        check_handle("t_s2_status", 8, "s2:two,three");
        aip_cmd::exec("t_s3_status a=four b=five span=six", SRC_INTERNAL);
        check_handle("t_s3_status", 11, "s3:four,five,six");
        aip_cmd::exec("t_s3_time a=path b=value time=100ns", SRC_INTERNAL);
        check_handle("t_s3_time", 11, "s3:path,value,100ns");
        aip_cmd::exec("t_silent_status a=z", SRC_INTERNAL);
        check_handle("t_silent_status", 0, "");

        // 不传参时仍使用宏注册时声明的缺省值，time 特例也不能漏掉。
        aip_cmd::exec("t_s1", SRC_INTERNAL);
        check_handle("t_s1", 7, "s1:");
        aip_cmd::exec("t_s2", SRC_INTERNAL);
        check_handle("t_s2", 8, "s2:,");
        aip_cmd::exec("t_s1i", SRC_INTERNAL);
        check_handle("t_s1i", 9, "s1i:,0");
        aip_cmd::exec("t_i1s", SRC_INTERNAL);
        check_handle("t_i1s", 10, "i1s:0,");
        aip_cmd::exec("t_s1_status", SRC_INTERNAL);
        check_handle("t_s1_status", 7, "s1:default_a");
        aip_cmd::exec("t_s2_status", SRC_INTERNAL);
        check_handle("t_s2_status", 8, "s2:default_a,default_b");
        aip_cmd::exec("t_s3_status", SRC_INTERNAL);
        check_handle("t_s3_status", 11, "s3:default_a,default_b,default_span");
        aip_cmd::exec("t_s3_time", SRC_INTERNAL);
        check_handle("t_s3_time", 11, "s3:default_a,default_b,default_span");

        // 全八种旧宏都保留顺序 direct 调用；状态宏也必须清理 silent 缺省值。
        direct_invoke("t_s1", "a=direct", 7, "s1:direct");
        direct_invoke("t_s2", "a=direct b=two", 8, "s2:direct,two");
        direct_invoke("t_s1i", "a=direct n=5", 9, "s1i:direct,5");
        direct_invoke("t_i1s", "n=6 a=direct", 10, "i1s:6,direct");
        direct_invoke("t_s1_status", "a=direct", 7, "s1:direct");
        direct_invoke("t_s2_status", "a=direct b=two", 8, "s2:direct,two");
        direct_invoke("t_s3_status", "a=direct b=two span=three", 11, "s3:direct,two,three");
        direct_invoke("t_s3_time", "a=direct b=two time=33ns", 11, "s3:direct,two,33ns");
        direct_invoke("t_silent_status", "a=direct", 0, "");

        if (fails == 0) begin
            $display("CMD_STR_RESULT_PASS");
        end else begin
            $fatal(1, "CMD_STR_RESULT_FAIL fails=%0d", fails);
        end
        $finish;
    end
endmodule
