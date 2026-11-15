`include "aip_log.sv"
`include "aip_cmdline.sv"
package selective_missing_pkg;
  typedef struct { int value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
endpackage
module selective_missing_companion;
  import selective_missing_pkg::rec_t;
  rec_t rec;
  initial begin `aip_struct_apply("compile.selective", rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
