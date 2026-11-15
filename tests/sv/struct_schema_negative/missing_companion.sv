`include "aip_log.sv"
`include "aip_cmdline.sv"
module missing_companion;
  typedef struct { int value; } rec_t;
  rec_t rec;
  initial begin `aip_struct_apply("compile.missing_companion", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
