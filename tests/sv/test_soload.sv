// aip_soload end-to-end test (no UVM, command framework only).
`include "aip_core_pkg.sv"

module test_soload;
    aip_clk_if clk0_if();
    aip_clk clk0;
    initial begin
        clk0 = new("clk0", clk0_if);
        clk0.set_freq(100e6);
        clk0.start();
    end
    initial begin
        $display("[TEST] test_soload start, entering TCL bridge...");
        aip_tcl_bridge::run_loop();
    end
endmodule
