`include "aip_log.sv"
`include "aip_cmdline.sv"
module function_target;
  typedef struct { int value; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(rec_t)
  function automatic rec_t make_rec(); rec_t r; return r; endfunction
  initial begin `aip_struct_apply("compile.function", rec_t, make_rec()) $display("COMPILE_NEGATIVE_SIMV_LAUNCHED"); end
endmodule
