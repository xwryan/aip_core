`include "aip_core_pkg.sv"

package core_package_consumer_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    class core_package_probe;
        static function int read_max_prints();
            return aip_cmdline_print_control::max_prints;
        endfunction
    endclass
endpackage

module test_core_package;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import core_package_consumer_pkg::*;

    aip_clk_if clk_if();
    aip_clk clk;

    reg [31:0] rsp_mem [0:255];
    wire irq_sink;
    bit rsp_event_seen = 0;

    assign irq_sink = aip_core_pkg::__cpu_bridge_irq;

    `aip_cpu_bridge_monitor(rsp_mem, 0)

    initial begin
        rsp_mem[130] = 0;
        aip_core_pkg::__cpu_bridge_irq = 0;

        clk = new("probe", clk_if);
        if (core_package_probe::read_max_prints() != 10)
            $fatal(1, "consumer package could not read max_prints");

        fork
            begin
                @(aip_core_pkg::__cpu_bridge_rsp_event);
                rsp_event_seen = 1;
            end
        join_none

        #1;
        rsp_mem[130] = 1;
        #1;
        if (!rsp_event_seen)
            $fatal(1, "CPU bridge response event was not received");

        aip_core_pkg::__cpu_bridge_irq = 1;
        #1;
        if (irq_sink !== 1'b1)
            $fatal(1, "package IRQ did not reach irq_sink");

        aip_cmd::exec("set_cmdline_print enable=0 max_prints=4");
        if (aip_cmdline_print_control::print_enable != 0)
            $fatal(1, "set_cmdline_print did not disable printing");
        if (aip_cmdline_print_control::max_prints != 4)
            $fatal(1, "set_cmdline_print max_prints mismatch");

        $display("CORE_PACKAGE_SV_PASS");
        $finish;
    end
endmodule
