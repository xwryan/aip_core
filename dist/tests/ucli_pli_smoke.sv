// Minimal simulation host for the native UCLI PLI smoke test.
module ucli_pli_smoke;
    initial begin
        $display("UCLI_PLI_SV_READY");
        $stop;
    end
endmodule
