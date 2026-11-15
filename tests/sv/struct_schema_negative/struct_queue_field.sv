`include "aip_log.sv"
`include "aip_cmdline.sv"
module struct_queue_field;
  typedef struct { int value; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_t)
  typedef struct { child_t children[$]; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_struct_darray(child_t, children, 0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.struct_queue", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
