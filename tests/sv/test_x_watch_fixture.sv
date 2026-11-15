// tests/sv：aip_watch x/z 的真实四态变化夹具。
`include "aip_core_pkg.sv"

module test_x_watch_fixture;
    timeunit 1ns;
    timeprecision 1ps;

    logic [7:0] x_data = 8'h00;
    logic [7:0] z_data = 8'h00;

    initial aip_tcl_bridge::run_loop();

    initial begin
        #10ns x_data = 8'h01;
        #10ns x_data = 8'h0x;
        #10ns z_data = 8'hzz;
        #10ns x_data = 8'hff;
        #20ns x_data = 8'h00;
    end
endmodule
