`include "aip_log.sv"
`include "aip_cmdline.sv"
`include "aip_core_pkg.sv"

module test_core_package_preinclude;
    initial begin
        $display("UNEXPECTED_PREINCLUDE_COMPILE_SUCCESS");
        $finish;
    end
endmodule
