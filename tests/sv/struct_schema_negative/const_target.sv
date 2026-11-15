`include "aip_log.sv"
`include "aip_cmdline.sv"
module const_target;
  typedef struct { int value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
  const rec_t rec = '{0};
  initial begin `aip_struct_apply("compile.const", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
