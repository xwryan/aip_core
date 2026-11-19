`include "aip_core_pkg.sv"

package schema_wildcard_pkg;
  import aip_core_pkg::*;
  typedef struct { int value; } wildcard_cfg_t;
  `aip_struct_type_begin(wildcard_cfg_t)
    `aip_field_int(int, value, 11)
  `aip_struct_type_end(wildcard_cfg_t)
endpackage

package schema_selective_pkg;
  import aip_core_pkg::*;
  typedef struct { int value; } selective_cfg_t;
  `aip_struct_type_begin(selective_cfg_t)
    `aip_field_int(int, value, 12)
  `aip_struct_type_end(selective_cfg_t)
endpackage

module test_cmdline_struct_schema_integration;
  import aip_core_pkg::*;
  import schema_wildcard_pkg::*;
  import schema_selective_pkg::selective_cfg_t;
  import schema_selective_pkg::aip_struct_schema__selective_cfg_t;

  typedef schema_selective_pkg::selective_cfg_t local_cfg_t;
  typedef schema_selective_pkg::aip_struct_schema__selective_cfg_t
          aip_struct_schema__local_cfg_t;

  typedef struct { int value; int eachy; } module_cfg_t;
  `aip_struct_type_begin(module_cfg_t)
    `aip_field_int(int, value, 13)
    `aip_field_int(int, eachy, 0)
  `aip_struct_type_end(module_cfg_t)

  typedef struct { int value; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_t)

  typedef struct { child_t children[]; } parent_t;
  `aip_struct_type_begin(parent_t)
    `aip_field_struct_darray(child_t, children, 0)
  `aip_struct_type_end(parent_t)

  typedef logic signed [7:0] signed_byte_t;
  typedef logic [7:0] unsigned_byte_t;

  typedef struct { int addr; } legacy_cfg_t;
  class legacy_holder;
    legacy_cfg_t cfg;
  endclass

  class class_schema_holder;
    typedef struct { int value; } class_cfg_t;
    `aip_struct_type_begin(class_cfg_t)
      `aip_field_int(int, value, 14)
    `aip_struct_type_end(class_cfg_t)
    class_cfg_t cfg;

    function void apply_cfg();
      `aip_struct_apply("scope.class", class_cfg_t, cfg)
    endfunction
  endclass

  class object_holder;
    module_cfg_t cfg;
  endclass

  wildcard_cfg_t wildcard_cfg;
  selective_cfg_t selective_cfg;
  local_cfg_t local_cfg;
  module_cfg_t module_cfg;
  module_cfg_t boundary_cfg;
  module_cfg_t summary_disabled_q[$];
  module_cfg_t summary_segment_q[$];
  int summary_primitive_q[$];
  parent_t parents[2];
  signed_byte_t signed_q[$];
  unsigned_byte_t unsigned_q[$];
  legacy_cfg_t legacy_cfg;
  legacy_holder obj;
  class_schema_holder class_obj;
  object_holder object_obj;

  function automatic void enforce_post_apply(ref module_cfg_t cfg);
    if (cfg.value < 20) cfg.value = 20;
  endfunction

  task automatic check(bit condition, string message);
    if (!condition) $fatal(1, "INTEGRATION_CHECK_FAIL: %s", message);
  endtask

  task automatic run_api_scope_compatibility();
    obj = new();
    class_obj = new();
    object_obj = new();

    `aip_struct_apply("scope.wildcard", wildcard_cfg_t, wildcard_cfg)
    `aip_struct_apply("scope.selective", selective_cfg_t, selective_cfg)
    `aip_struct_apply("scope.alias", local_cfg_t, local_cfg)
    `aip_struct_apply("scope.module", module_cfg_t, module_cfg)
    class_obj.apply_cfg();
    `aip_struct_apply("scope.object", module_cfg_t, object_obj.cfg)

    check(wildcard_cfg.value == 21, "package wildcard import");
    check(selective_cfg.value == 22, "selective type and companion imports");
    check(local_cfg.value == 23, "paired local type and companion aliases");
    check(module_cfg.value == 24, "module-scope schema");
    check(class_obj.cfg.value == 25, "class-scope schema");
    check(object_obj.cfg.value == 26, "object-member schema apply");

    `aip_struct_begin("legacy", legacy_cfg)
      `aip_struct_int(legacy_cfg, addr, 1)
    `aip_struct_end(legacy_cfg)
    `aip_int("", int, obj.cfg.addr, 0)
    check(legacy_cfg.addr == 31, "legacy aip_struct_* compatibility");
    check(obj.cfg.addr == 32, "legacy dotted-lvalue aip_int compatibility");

    `aip_struct_apply("scope.post", module_cfg_t, module_cfg)
    enforce_post_apply(module_cfg);
    check(module_cfg.value == 20, "user-owned post-apply constraint");

    // A neighboring dut.cfg2 prefix is not a descendant of dut.cfg.
    `aip_struct_apply("dut.cfg", module_cfg_t, boundary_cfg)
    check(boundary_cfg.value == 13, "ROOT boundary excludes cfg2-style prefix");

    aip_cmdline_override::set_val("scope.signed_q", "8'hff,-128");
    aip_cmdline_override::set_val("scope.unsigned_q", "255,0");
    `aip_int_queue("scope", signed_byte_t, signed_q, '0, -1)
    `aip_int_queue("scope", unsigned_byte_t, unsigned_q, '0, -1)
    check(signed_q.size() == 2 && signed_q[0] === signed_byte_t'(8'hff) &&
          signed_q[1] === signed_byte_t'(8'h80),
          "signed 8-bit: based 8'hff is the pattern -1, decimal -128 is the minimum");
    check(unsigned_q.size() == 2 && unsigned_q[0] === 8'hff &&
          unsigned_q[1] === 8'h00,
          "unsigned 8-bit accepted boundary values (negatives are rejected)");

    $display("CMDLINE_STRUCT_SCHEMA_INTEGRATION_API_PASS");
  endtask

  task automatic run_inherited_generator();
    `aip_struct_sarray_apply("risk.parents", parent_t, parents)
    foreach (parents[i]) begin
      check(parents[i].children.size() == 3,
            $sformatf("inherited generator length for parent %0d", i));
      foreach (parents[i].children[j])
        check(parents[i].children[j].value == j + 1,
              $sformatf("inherited generator value [%0d][%0d]", i, j));
    end
    $display("CMDLINE_STRUCT_SCHEMA_INHERITED_GENERATOR_PASS");
  endtask

  task automatic run_summary_normalization();
    aip_cmdline_print_control::configure(1, 10);

    aip_cmdline_override::set_val("summary.disabled.size", "2");
    aip_cmdline_override::set_val("summary.disabled.value", "2,1");
    aip_cmdline_override::set_val("summary.disabled.each.value.unique", "0");
    aip_cmdline_override::set_val("summary.disabled.each.value.sort", "none");
    `aip_struct_queue_apply("summary.disabled", module_cfg_t,
                            summary_disabled_q, 0, -1)

    aip_cmdline_override::set_val("summary.segment.eachy", "4,5");
    `aip_struct_queue_apply("summary.segment", module_cfg_t,
                            summary_segment_q, 0, -1)

    aip_cmdline_override::set_val("summary.summary_primitive_q", "2,1");
    aip_cmdline_override::set_val("summary.summary_primitive_q.size", "2");
    aip_cmdline_override::set_val("summary.summary_primitive_q.unique", "0");
    aip_cmdline_override::set_val("summary.summary_primitive_q.sort", "none");
    `aip_int_queue("summary", int, summary_primitive_q, 0, -1)

    check(summary_disabled_q.size() == 2 &&
          summary_disabled_q[0].value == 2 &&
          summary_disabled_q[1].value == 1,
          "disabled sort preserves record order");
    check(summary_segment_q.size() == 2 &&
          summary_segment_q[0].eachy == 4 &&
          summary_segment_q[1].eachy == 5,
          "field with each prefix is ordinary canonical segment");
    check(summary_primitive_q.size() == 2 && summary_primitive_q[0] == 2 &&
          summary_primitive_q[1] == 1,
          "disabled primitive sort preserves queue order");
    $display("CMDLINE_STRUCT_SCHEMA_SUMMARY_NORMALIZATION_PASS");
  endtask

  initial begin
    if ($test$plusargs("AIP_INTEGRATION_API")) begin
      run_api_scope_compatibility();
      $finish;
    end
    if ($test$plusargs("AIP_INTEGRATION_INHERITED_GENERATOR")) begin
      run_inherited_generator();
      $finish;
    end
    if ($test$plusargs("AIP_INTEGRATION_SUMMARY")) begin
      run_summary_normalization();
      $finish;
    end
    $fatal(1, "select one integration scenario");
  end
endmodule
