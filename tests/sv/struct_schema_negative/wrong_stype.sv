`include "aip_log.sv"
`include "aip_cmdline.sv"
module wrong_stype;
  typedef struct { int value; } child_a_t;
  `aip_struct_type_begin(child_a_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_a_t)
  typedef struct { int value; } child_b_t;
  `aip_struct_type_begin(child_b_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_b_t)
  typedef struct { child_a_t child; } parent_t;
  `aip_struct_type_begin(parent_t)
    `aip_field_struct(child_b_t, child)
  `aip_struct_type_end(parent_t)
  parent_t rec;
  initial begin `aip_struct_apply("compile.wrong_stype", parent_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
