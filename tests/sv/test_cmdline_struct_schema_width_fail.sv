`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_width_fail;
  typedef logic [1024:0] too_wide_t;
  typedef struct { too_wide_t values[]; } bad_t;
  `aip_struct_type_begin(bad_t)
    `aip_field_int_darray(too_wide_t, values, '0, 1)
  `aip_struct_type_end(bad_t)
  bad_t value;
endmodule
