`include "aip_log.sv"
`include "aip_cmdline.sv"
module multidimensional_field;
  typedef struct { int values[2][2]; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int_sarray(int, values, 0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.multidim", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
