// 真实 VCS UCLI/Tcl → set_param → 类型宏的集成验证；独立期限防止 Tcl 中途报错后无限等待。
`include "aip_core_pkg.sv"

// 向 Tcl 暴露实际宏读取结果，使引用/转义错误无法被直接 set_val 的单元测试掩盖。
class set_param_tcl_probe;
    static task sample();
        aip_cmd				handle;
        string				kind;
        handle = aip_cmd::get_handle("sp_sample");
        kind   = aip_cmd::get_arg(handle.args_in, "kind");
        case (kind)
            "int": begin
                int				value;
                `aip_int("tclcfg", int, value, 7)
                handle.result_out = $sformatf("%0d", value);
            end
            "real": begin
                real				value;
                `aip_real("tclcfg", value, 7.0)
                handle.result_out = $sformatf("%.17g", value);
            end
            "string": begin
                string				value;
                `aip_string("tclcfg", value, "default")
                handle.result_out = value;
            end
            "raw": handle.result_out = aip_cmdline#(int)::get_cmdline_string("value", "tclcfg");
            default: $fatal(1, "SET_PARAM_TCL_UNKNOWN_KIND %s", kind);
        endcase
        handle.status = 0;
    endtask
endclass

`aip_cmd_task(sp_sample, set_param_tcl_probe::sample)

module test_set_param_tcl;
    initial begin
        aip_cmdline_print_control::configure(0, 0);
        aip_tcl_bridge::run_loop();
        $display("SET_PARAM_TCL_SV_PASS");
        $finish;
    end

    initial begin
        #200000ns;
        $fatal(1, "SET_PARAM_TCL_DEADLINE");
    end
endmodule
