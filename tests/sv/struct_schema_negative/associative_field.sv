`include "aip_log.sv"
`include "aip_cmdline.sv"
module associative_field;
  typedef struct { int values[string]; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int_darray(int, values, 0, 0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.assoc", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
