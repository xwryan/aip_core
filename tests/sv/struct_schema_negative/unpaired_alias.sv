`include "aip_log.sv"
`include "aip_cmdline.sv"
package unpaired_alias_pkg;
  typedef struct { int value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
endpackage
module unpaired_alias;
  typedef unpaired_alias_pkg::rec_t local_rec_t;
  local_rec_t rec;
  initial begin `aip_struct_apply("compile.alias", local_rec_t, rec) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
