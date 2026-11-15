//===========================================================
// 所属层次：tests/sv；结构体配置解析的只测量基准，不改变生产解析器或随机调用顺序。
// 依赖 standalone aip_log/aip_cmdline 聚合入口，以及 C 端提供的进程 CPU/单调 wall 时钟。
// 本模块持有所有目标结构体、数组和计时结果；每次仿真只跑一种 case，不跨仿真保留状态。
// init 包含第一次 schema 注册；repeat/array/lookup/compact 预热一次后测稳态工作量。
// dotted/compact 的 end-to-end 输入必须由真实 plusarg 提供；只有 override 显式写运行时表。
// defaults 仅用于 init/repeat 的零默认值对照，array 不接受 compact/defaults；compact 微基准
// 直接扫描固定的 16 成员文本，lookup 可用 BENCH_MISS=1 查询不存在的完整 key。
// size/records 表示有效工作量：apply 为每轮记录数/总记录数，lookup 为 1/总查询数，
// compact 为 16/总成员查询数；因此不同 case 的 records 不应直接混作同一种吞吐量。
// 计时包含最小 checksum 累加，不含完整字段验证、override 更新验证及输出；全部在零仿真时间执行。
//===========================================================
`include "aip_log.sv"
`include "aip_cmdline.sv"

// 独立顶层避免其它测试进程干扰 CPU 时间；DPI 必须读取真实主机时间而不是 $realtime。
module test_cmdline_benchmark;
    import "DPI-C" function real aip_cmdline_bench_cpu_seconds();
    import "DPI-C" function real aip_cmdline_bench_wall_seconds();

    typedef struct {
        int f00;
        int f01;
        int f02;
        int f03;
        int f04;
        int f05;
        int f06;
        int f07;
        int f08;
        int f09;
        int f10;
        int f11;
        int f12;
        int f13;
        int f14;
        int f15;
    } bench_record_t;

    // 所有默认值都是常量，排除默认函数求值和随机采样对结构体解析成本的干扰。
    `aip_struct_type_begin(bench_record_t)
        `aip_field_int(int, f00, 0)
        `aip_field_int(int, f01, 0)
        `aip_field_int(int, f02, 0)
        `aip_field_int(int, f03, 0)
        `aip_field_int(int, f04, 0)
        `aip_field_int(int, f05, 0)
        `aip_field_int(int, f06, 0)
        `aip_field_int(int, f07, 0)
        `aip_field_int(int, f08, 0)
        `aip_field_int(int, f09, 0)
        `aip_field_int(int, f10, 0)
        `aip_field_int(int, f11, 0)
        `aip_field_int(int, f12, 0)
        `aip_field_int(int, f13, 0)
        `aip_field_int(int, f14, 0)
        `aip_field_int(int, f15, 0)
    `aip_struct_type_end(bench_record_t)

    bench_record_t cfg;
    bench_record_t rows[];
    string bench_case = "repeat";
    string bench_source = "dotted";
    int iterations = 100;
    int requested_size = 16;
    int miss = 0;
    int effective_size;
    longint unsigned records;
    longint unsigned checksum = 0;
    longint unsigned expected_checksum;
    real cpu_start, wall_start, cpu_elapsed, wall_elapsed;

    string field_names[16];
    string compact_values[16];
    string compact_text = "{f00=1,f01=2,f02=3,f03=4,f04=5,f05=6,f06=7,f07=8,f08=9,f09=10,f10=11,f11=12,f12=13,f13=14,f14=15,f15=16}";
    bit compact_all_found = 1;
    bit member_found;
    string lookup_key;
    aip_struct_runtime::lookup_t lookup_result;

    // 在计时前读取控制参数并拒绝不支持的组合；实际 plusarg 字段不在这里查找或转换。
    // init 的有效迭代数固定为 1，保证结果代表第一次 apply，不与后续稳态调用混在一起。
    task automatic read_configuration();
        void'($value$plusargs("BENCH_CASE=%s", bench_case));
        void'($value$plusargs("BENCH_SOURCE=%s", bench_source));
        void'($value$plusargs("BENCH_ITERS=%d", iterations));
        void'($value$plusargs("BENCH_SIZE=%d", requested_size));
        void'($value$plusargs("BENCH_MISS=%d", miss));

        if (!(bench_case inside {"init", "repeat", "array", "lookup", "compact"}))
            $fatal(1, "BENCH_CONFIG unknown case '%s'", bench_case);
        if (!(bench_source inside {"dotted", "compact", "override", "defaults"}))
            $fatal(1, "BENCH_CONFIG unknown source '%s'", bench_source);
        if (iterations < 1 || iterations > 1000000000)
            $fatal(1, "BENCH_CONFIG BENCH_ITERS must be 1..1000000000");
        if (requested_size < 1 || requested_size > 1000000)
            $fatal(1, "BENCH_CONFIG BENCH_SIZE must be 1..1000000");
        if (!(miss inside {0, 1}) || (miss != 0 && bench_case != "lookup"))
            $fatal(1, "BENCH_CONFIG BENCH_MISS=1 is only valid for lookup");
        if (bench_source == "defaults" && !(bench_case inside {"init", "repeat"}))
            $fatal(1, "BENCH_CONFIG defaults source only supports init/repeat");
        if (bench_case == "array" && !(bench_source inside {"dotted", "override"}))
            $fatal(1, "BENCH_CONFIG array only supports dotted/override");
        if (bench_case == "lookup" && !(bench_source inside {"dotted", "override"}))
            $fatal(1, "BENCH_CONFIG lookup only supports dotted/override");
        if (bench_case == "compact" && bench_source != "compact")
            $fatal(1, "BENCH_CONFIG compact microbenchmark requires compact source");

        if (bench_case == "init") iterations = 1;
        effective_size = (bench_case == "array") ? requested_size :
                         (bench_case == "compact") ? 16 : 1;
        records = longint'(iterations) * effective_size;
        lookup_key = miss ? "bench.cfg.absent" : "bench.cfg.f00";
        foreach (field_names[i]) field_names[i] = $sformatf("f%02d", i);
    endtask

    // 只有 override 场景写表；scalar/lookup 使用精确字段，array 使用现有 canonical .each。
    // 默认长度通过公开 apply 宏传入，不注入虚假的 plusarg，也不提前调用 schema 注册。
    task automatic install_override();
        string prefix;
        if (bench_source != "override") return;
        prefix = (bench_case == "array") ? "bench.rows.each." : "bench.cfg.";
        foreach (field_names[i])
            aip_cmdline_override::set_val({prefix, field_names[i]}, $sformatf("%0d", i + 1));
    endtask

    // 在计时外验证完整 16 字段；first_value 支持更新验证，defaults 模式要求其余字段全零。
    // 采用四态严格比较，未知值也视为失败，避免仅 checksum 相同掩盖错误字段。
    task automatic validate_record(input bench_record_t item, input int first_value,
                                   input bit defaults_mode = 0);
        int values[16];
        int expected;
        values = '{item.f00, item.f01, item.f02, item.f03,
                   item.f04, item.f05, item.f06, item.f07,
                   item.f08, item.f09, item.f10, item.f11,
                   item.f12, item.f13, item.f14, item.f15};
        foreach (values[i]) begin
            expected = (i == 0) ? first_value : defaults_mode ? 0 : i + 1;
            if (values[i] !== expected)
                $fatal(1, "BENCH_FIELD field=%s expected=%0d actual=%0d",
                       field_names[i], expected, values[i]);
        end
    endtask

    // 主测量完成后再验证结果；微基准检查查找结果及来源，不把完整字符串比较混入热循环。
    // checksum 与最后一个结果同时验证，避免某一轮查找失败被最后一次成功覆盖。
    task automatic validate_result();
        case (bench_case)
            "init", "repeat": begin
                validate_record(cfg, bench_source == "defaults" ? 0 : 1,
                                bench_source == "defaults");
                expected_checksum = (bench_source == "defaults") ? 0 : longint'(iterations) * 17;
            end
            "array": begin
                if (rows.size() != requested_size)
                    $fatal(1, "BENCH_SIZE expected=%0d actual=%0d", requested_size, rows.size());
                foreach (rows[i]) validate_record(rows[i], 1);
                expected_checksum = longint'(iterations) * 17;
            end
            "lookup": begin
                if (miss) begin
                    if (lookup_result.found || lookup_result.value != "")
                        $fatal(1, "BENCH_LOOKUP expected missing key '%s'", lookup_key);
                    expected_checksum = 0;
                end else begin
                    if (!lookup_result.found || lookup_result.value != "1" ||
                        lookup_result.source != ((bench_source == "override") ? 2 : 1))
                        $fatal(1, "BENCH_LOOKUP unexpected value or source for '%s'", lookup_key);
                    expected_checksum = iterations;
                end
            end
            "compact": begin
                if (!compact_all_found) $fatal(1, "BENCH_COMPACT missing member");
                foreach (compact_values[i])
                    if (compact_values[i] != $sformatf("%0d", i + 1))
                        $fatal(1, "BENCH_COMPACT unexpected value of %s", field_names[i]);
                expected_checksum = longint'(iterations) * 23;
            end
        endcase
        if (checksum != expected_checksum)
            $fatal(1, "BENCH_CHECKSUM expected=%0d actual=%0d", expected_checksum, checksum);
    endtask

    // override 在测量及验证之后修改 f00，再通过原公开 apply 路径验证可见性。
    // 此步骤不计入 cpu_s/wall_s，用来防止未来缓存优化掩盖运行时更新；不修改生产实现。
    task automatic validate_override_update();
        if (bench_source != "override") return;
        if (bench_case == "array") begin
            aip_cmdline_override::set_val("bench.rows.each.f00", "101");
            `aip_struct_darray_apply("bench.rows", bench_record_t, rows, requested_size)
            if (rows.size() != requested_size) $fatal(1, "BENCH_UPDATE unexpected array size");
            foreach (rows[i]) validate_record(rows[i], 101);
        end else begin
            aip_cmdline_override::set_val("bench.cfg.f00", "101");
            `aip_struct_apply("bench.cfg", bench_record_t, cfg)
            validate_record(cfg, 101);
        end
    endtask

    // 预热与计时显式分开，array 沿用原 dynamic-array 宏的 fixed/each 两遍实现。
    // 计时区只留下待测调用及最少的观测操作；完整断言和最终报告在停止时钟之后执行。
    initial begin
        aip_cmdline_print_control::configure(0, 0);
        read_configuration();
        install_override();

        case (bench_case)
            "repeat": begin
                `aip_struct_apply("bench.cfg", bench_record_t, cfg)
            end
            "array": begin
                `aip_struct_darray_apply("bench.rows", bench_record_t, rows, requested_size)
                if (rows.size() != requested_size)
                    $fatal(1, "BENCH_WARMUP unexpected array size");
            end
            "lookup": lookup_result = aip_struct_runtime::lookup(lookup_key);
            "compact": begin
                foreach (field_names[i])
                    member_found = aip_struct_runtime::compact_member(compact_text, field_names[i], compact_values[i]);
            end
        endcase

        cpu_start = aip_cmdline_bench_cpu_seconds();
        wall_start = aip_cmdline_bench_wall_seconds();
        case (bench_case)
            "init", "repeat": begin
                repeat (iterations) begin
                    `aip_struct_apply("bench.cfg", bench_record_t, cfg)
                    checksum += cfg.f00 + cfg.f15;
                end
            end
            "array": begin
                repeat (iterations) begin
                    `aip_struct_darray_apply("bench.rows", bench_record_t, rows, requested_size)
                    checksum += rows[0].f00 + rows[requested_size - 1].f15;
                end
            end
            "lookup": begin
                repeat (iterations) begin
                    lookup_result = aip_struct_runtime::lookup(lookup_key);
                    checksum += lookup_result.found;
                end
            end
            "compact": begin
                repeat (iterations) begin
                    foreach (field_names[i]) begin
                        member_found = aip_struct_runtime::compact_member(compact_text, field_names[i], compact_values[i]);
                        compact_all_found &= member_found;
                        checksum += compact_values[i].len();
                    end
                end
            end
        endcase
        cpu_elapsed = aip_cmdline_bench_cpu_seconds() - cpu_start;
        wall_elapsed = aip_cmdline_bench_wall_seconds() - wall_start;

        if (cpu_elapsed < 0.0 || wall_elapsed < 0.0)
            $fatal(1, "BENCH_CLOCK measured a negative duration");
        validate_result();
        validate_override_update();
        $display("BENCH_RESULT case=%s source=%s iterations=%0d size=%0d records=%0d cpu_s=%0.9f wall_s=%0.9f checksum=%0d",
                 bench_case, bench_source, iterations, effective_size, records,
                 cpu_elapsed, wall_elapsed, checksum);
        $display("BENCH_PASS");
        $finish;
    end
endmodule
