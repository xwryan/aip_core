`include "aip_log.sv"
`include "aip_cmdline.sv"
module reserved_size;
  typedef struct { int size; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, size, 0)
  `aip_struct_type_end(rec_t)
  initial $display("COMPILE_NEGATIVE_SIMV_LAUNCHED");
endmodule
