`include "aip_log.sv"
`include "aip_cmdline.sv"
module scalar_width_1025;
  typedef logic [1024:0] wide_t;
  typedef struct { wide_t value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(wide_t, value, '0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.wide", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
