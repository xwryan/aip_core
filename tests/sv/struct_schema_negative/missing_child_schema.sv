`include "aip_log.sv"
`include "aip_cmdline.sv"
module missing_child_schema;
  typedef struct { int value; } child_t;
  typedef struct { child_t child; } parent_t;
  `aip_struct_type_begin(parent_t)
    `aip_field_struct(child_t, child)
  `aip_struct_type_end(parent_t)
  parent_t rec;
  initial begin `aip_struct_apply("compile.missing_child", parent_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
