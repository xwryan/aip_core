`include "aip_core_pkg.sv"

module test_checkpoint_wait;
    reg [31:0] dut_status = 0;

    initial begin
        #20ns dut_status = 32'h1;
        #20ns dut_status = 32'h2;
        #20ns dut_status = 32'h3;
        #20ns dut_status = 32'h4;
    end

    initial aip_tcl_bridge::run_loop();
endmodule
