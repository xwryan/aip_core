`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_nested;
  typedef enum { COLD, WARM, HOT } temp_e;
  typedef struct { int value; string label; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, value, 0)
    `aip_field_string(label, "default")
  `aip_struct_type_end(child_t)

  typedef struct {
    int tags[3];
    string labels[];
    child_t kids[2];
    child_t dynkids[];
    real weights[2];
    real dynweights[];
    temp_e status[2];
    temp_e dynstatus[];
  } cfg_t;
  `aip_struct_type_begin(cfg_t)
    `aip_field_int_sarray(int, tags, 0)
    `aip_field_string_darray(labels, "", 1)
    `aip_field_struct_sarray(child_t, kids)
    `aip_field_struct_darray(child_t, dynkids, 1)
    `aip_field_real_sarray(weights, 1.0)
    `aip_field_real_darray(dynweights, 2.0, 1)
    `aip_field_enum_sarray(temp_e, status, COLD)
    `aip_field_enum_darray(temp_e, dynstatus, WARM, 1)
  `aip_struct_type_end(cfg_t)

  cfg_t cfg;
  initial begin
    `aip_struct_apply("cfg", cfg_t, cfg)
    if (cfg.tags[0] != 1 || cfg.tags[1] != 2 || cfg.tags[2] != 3)
      $fatal(1, "nested static integer array mismatch: %0d,%0d,%0d",
             cfg.tags[0], cfg.tags[1], cfg.tags[2]);
    if (cfg.labels.size() != 2 || cfg.labels[0] != "a" || cfg.labels[1] != "b")
      $fatal(1, "nested dynamic string array mismatch");
    if (cfg.kids[0].value != 7 || cfg.kids[1].value != 8)
      $fatal(1, "nested static struct array mismatch");
    if (cfg.dynkids.size() != 2 || cfg.dynkids[0].value != 4 || cfg.dynkids[1].value != 9)
      $fatal(1, "nested dynamic struct array mismatch");
    if (cfg.weights[0] != 1.5 || cfg.weights[1] != 2.5)
      $fatal(1, "nested static real array mismatch");
    if (cfg.dynweights.size() != 2 || cfg.dynweights[0] != 3.5 || cfg.dynweights[1] != 4.5)
      $fatal(1, "nested dynamic real array mismatch");
    if (cfg.status[0] != HOT || cfg.status[1] != WARM)
      $fatal(1, "nested static enum array mismatch");
    if (cfg.dynstatus.size() != 2 || cfg.dynstatus[0] != COLD || cfg.dynstatus[1] != HOT)
      $fatal(1, "nested dynamic enum array mismatch");
    $display("CMDLINE_STRUCT_SCHEMA_NESTED_PASS");
    $finish;
  end
endmodule
