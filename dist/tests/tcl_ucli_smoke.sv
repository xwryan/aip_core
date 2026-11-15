// Minimal UCLI host for validating the source-based Tcl bootstrap.
`include "aip_core_pkg.sv"

module tcl_ucli_smoke;
    aip_clk_if clk0_if();
    aip_clk clk0;
    initial begin
        clk0 = new("tcl_ucli_smoke_clk", clk0_if);
        clk0.set_freq(100e6);
        clk0.start();
    end
    initial begin
        aip_tcl_bridge::run_loop();
    end
endmodule
