`include "aip_log.sv"
`include "aip_cmdline.sv"
module expression_target;
  typedef struct { int value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
  rec_t a, b;
  bit choose;
  initial begin `aip_struct_apply("compile.expression", rec_t, (choose ? a : b)) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
