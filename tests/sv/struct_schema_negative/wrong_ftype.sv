`include "aip_log.sv"
`include "aip_cmdline.sv"
module wrong_ftype;
  typedef struct { longint value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.wrong_ftype", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
