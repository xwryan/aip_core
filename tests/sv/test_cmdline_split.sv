// cmdline 拆分后的兼容测试：仍只经旧入口装载，公开类型与宏保持兼容；输出可过滤的随机轨迹供拆分前后逐字节比较。
`ifdef AIP_CMDLINE_SPLIT_PACKAGE
`include "aip_core_pkg.sv"
`include "aip_core_pkg.sv"
`include "aip_cmdline.sv"
`include "aip_cmdline.sv"

// consumer 必须与主模块共用同一 package 类型（不复制解析器定义），以发现静态 override 被分成两份的问题。
package cmdline_split_consumer_pkg;
    import aip_core_pkg::*;

    class cmdline_split_probe;
        static function void install(aip_cmdline#(int) parser);
            if (parser == null) $fatal(1, "CMDLINE_SPLIT_NULL_PARSER");
            aip_cmdline_override::set_val("split.shared", "41");
        endfunction

        // 主模块写回的值须能从 consumer 读到，检查静态状态双向一致。
        static function string read_back();
            return aip_cmdline_override::get_val("split.shared");
        endfunction
    endclass
endpackage
`else
`include "aip_log.sv"
`include "aip_cmdline.sv"
`include "aip_cmdline.sv"
`endif

// 聚合入口的内部装载许可不得泄漏到用户源码，否则会绕过直接 include 的边界检查。
`ifdef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_SPLIT_ERROR_INTERNAL_GUARD_LEAKED
`endif

// 让每个拆出的职责（scalar/schema/typed array/strict queue/调用位置）都至少经公开入口调用一次。
module test_cmdline_split;
`ifdef AIP_CMDLINE_SPLIT_PACKAGE
    import aip_core_pkg::*;
    import cmdline_split_consumer_pkg::*;
`endif

    typedef enum { MODE_IDLE, MODE_RUN } mode_t;
    typedef struct {
        int value;
        string label;
        real rate;
        mode_t mode;
        int words[];
    } record_t;

    `aip_struct_type_begin(record_t)
        `aip_field_int(int, value, 1)
        `aip_field_string(label, "default")
        `aip_field_real(rate, 1.0)
        `aip_field_enum(mode_t, mode, MODE_IDLE)
        `aip_field_int_darray(int, words, 2, 3)
    `aip_struct_type_end(record_t)

    record_t cfg;
    int shared, values[$], bad, draw;
    real real_draw;
    aip_cmdline#(int) parser;

    // 失败分支单独启动仿真，避免 FATAL 提前结束掩盖其后的正例。
    initial begin
        aip_cmdline_print_control::configure(0, 0);
        parser = new();
`ifdef AIP_CMDLINE_SPLIT_PACKAGE
        cmdline_split_probe::install(parser);
`else
        aip_cmdline_override::set_val("split.shared", "41");
`endif
        `aip_int("split", int, shared, 0)
        if (shared != 41) $fatal(1, "CMDLINE_SPLIT_SHARED_OVERRIDE");
        aip_cmdline_override::set_val("split.shared", "42");
`ifdef AIP_CMDLINE_SPLIT_PACKAGE
        if (cmdline_split_probe::read_back() != "42")
            $fatal(1, "CMDLINE_SPLIT_CONSUMER_STATE");
`endif

        aip_cmdline_override::set_val("split.cfg", "{value=5,label=hello,rate=2.5,mode=MODE_RUN}");
        aip_cmdline_override::set_val("split.cfg.value", "7");
        aip_cmdline_override::set_val("split.cfg.words.size", "3");
        aip_cmdline_override::set_val("split.cfg.words.each", "4");
        aip_cmdline_override::set_val("split.cfg.words[1]", "9");
        `aip_struct_apply("split.cfg", record_t, cfg)
        if (cfg.value != 7 || cfg.label != "hello" || cfg.rate != 2.5 ||
            cfg.mode != MODE_RUN || cfg.words.size() != 3 ||
            cfg.words[0] != 4 || cfg.words[1] != 9 || cfg.words[2] != 4)
            $fatal(1, "CMDLINE_SPLIT_SCHEMA");

        aip_cmdline_override::set_val("split.values", "3,1,2");
        aip_cmdline_override::set_val("split.values.sort", "asc");
        `aip_int_queue("split", int, values, 0, -1)
        if (values.size() != 3 || values[0] != 1 || values[1] != 2 || values[2] != 3)
            $fatal(1, "CMDLINE_SPLIT_QUEUE");

        for (int i = 0; i < 16; i++) begin
            draw = aip_cmdline#(int)::parse_value("{1:=0,[2:6]:=3,9:/1}");
            real_draw = aip_cmdline_real::parse_value("{1.0:=0,[2.0:3.0]:/3,9.0:=1}");
            if ((draw < 2 || draw > 6) && draw != 9)
                $fatal(1, "CMDLINE_SPLIT_INTEGER_DRAW");
            if ((real_draw < 2.0 || real_draw > 3.0) && real_draw != 9.0)
                $fatal(1, "CMDLINE_SPLIT_REAL_DRAW");
            $display("CMDLINE_SPLIT_TRACE index=%0d integer=%0d real=%0.16f", i, draw, real_draw);
        end

        // 宏调用全部返回后，裸 API 不再带用户来源，应回退到库内报错位置（诊断栈不能遗留 split.* 上下文）。
        if ($test$plusargs("AIP_SPLIT_DIRECT_FATAL")) begin
            bad = aip_cmdline#(int)::parse_value("not_an_int");
            $display("CMDLINE_SPLIT_UNEXPECTED_CONTINUE");
            $finish;
        end

        if ($test$plusargs("AIP_SPLIT_FATAL")) begin
            aip_cmdline_override::set_val("split.bad", "not_an_int");
            $display("SPLIT_EXPECT_LINE %0d", `__LINE__ + 1);
            `aip_int("split", int, bad, 0)
            $display("CMDLINE_SPLIT_UNEXPECTED_CONTINUE");
            $finish;
        end

        $display("CMDLINE_SPLIT_PASS");
        $finish;
    end
endmodule
