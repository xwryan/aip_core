`include "aip_log.sv"
`include "aip_cmdline.sv"
module wrong_etype;
  typedef enum { A0, A1 } a_t;
  typedef enum { B0, B1 } b_t;
  typedef struct { a_t value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_enum(b_t, value, B0)
  `aip_struct_type_end(rec_t)
  rec_t rec;
  initial begin `aip_struct_apply("compile.wrong_etype", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
