// tests/sv：测量标量宏读取的主机 CPU/墙钟开销，比较 plusarg 与 set_param 数据源。
// 依赖公开 standalone 入口和 tests/bench/cmdline_bench_clock.c；不推进仿真时间。
// 本模块拥有参数、目标变量及 checksum；override 仅在计时前安装一次，打印全程关闭。
// 同一源码可在旧基线编译；旧版 override 只测试固定值，随机表达式以旧版 plusarg 作参照。
`include "aip_log.sv"
`include "aip_cmdline.sv"

// 独立顶层排除 DUT/波形开销；测量包含宏的实际查表、解析、抽样和最小结果累加。
module test_set_param_benchmark;
    import "DPI-C" function real aip_cmdline_bench_cpu_seconds();
    import "DPI-C" function real aip_cmdline_bench_wall_seconds();

    string				kind        = "int";
    string				source_kind = "plusarg";
    string				expression;
    int					iterations  = 20000;
    int					repeats     = 1;
    int					iv;
    real				rv;
    longint unsigned			checksum    = 0;
    real				cpu_start;
    real				wall_start;
    real				cpu_elapsed;
    real				wall_elapsed;
    process				owner;

    // 真实宏调用；计时循环与预热共用同一路径，不缓存抽样值。
    // kind/表达式在运行前验证，读取错误由正式解析器 fatal。
    task automatic read_one();
        if (kind == "int") begin
            `aip_int("bench", int, iv, 0)
            checksum += iv;
        end else begin
            `aip_real("bench", rv, 0.0)
            checksum += longint'(rv * 1000.0);
        end
    endtask

    // 参数安装与预热不计时；wall/CPU 为仿真进程内部区间，排除编译和许可证等待。
    initial begin
        aip_cmdline_print_control::configure(0, 0);
        void'($value$plusargs("BENCH_KIND=%s", kind));
        void'($value$plusargs("BENCH_SOURCE=%s", source_kind));
        void'($value$plusargs("BENCH_ITERS=%d", iterations));
        void'($value$plusargs("BENCH_REPEATS=%d", repeats));
        if (!(kind inside {"int", "real"}) ||
            !(source_kind inside {"plusarg", "override"}) || iterations <= 0 || repeats <= 0)
            $fatal(1, "SET_PARAM_BENCH_BAD_CONFIG");

        if (!$value$plusargs({"bench.", kind == "int" ? "iv" : "rv", "=%s"}, expression))
            $fatal(1, "SET_PARAM_BENCH_MISSING_EXPRESSION");
        if (source_kind == "override")
            aip_cmdline_override::set_val({"bench.", kind == "int" ? "iv" : "rv"}, expression);

        // 多个样本共享进程以减少许可证启动等待；每轮重置 RNG 并重新预热，不计入测量。
        owner = process::self();
        for (int	rep = 0; rep < repeats; rep++) begin
            owner.srandom($get_initial_random_seed());
            repeat (100) read_one();
            checksum   = 0;
            cpu_start  = aip_cmdline_bench_cpu_seconds();
            wall_start = aip_cmdline_bench_wall_seconds();
            repeat (iterations) read_one();
            cpu_elapsed  = aip_cmdline_bench_cpu_seconds() - cpu_start;
            wall_elapsed = aip_cmdline_bench_wall_seconds() - wall_start;
            $display("SET_PARAM_BENCH kind=%s source=%s expr=%s reads=%0d cpu=%.9f wall=%.9f checksum=%0d repeat=%0d",
                     kind, source_kind, expression, iterations, cpu_elapsed, wall_elapsed, checksum, rep);
        end
        $finish;
    end
endmodule
