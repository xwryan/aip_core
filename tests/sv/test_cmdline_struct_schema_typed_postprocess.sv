`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_typed_postprocess;
  class opaque_marker;
    int tag;
    function new(int t = 0);
      tag = t;
    endfunction
  endclass

  typedef struct { int score; } meta_t;
  `aip_struct_type_begin(meta_t)
    `aip_field_int(int, score, 0)
  `aip_struct_type_end(meta_t)

  typedef logic signed [127:0] signed_wide_t;
  typedef enum logic [7:0] {
    MODE_LOW  = 8'h02,
    MODE_MID  = 8'h10,
    MODE_HIGH = 8'h80
  } mode_t;

  // marker and opaque are deliberately not registered.  A whole-record sort
  // must carry both values with the registered fields that determine order.
  typedef struct {
    int id;
    int rank;
    string label;
    meta_t meta;
    signed_wide_t wide;
    real precise;
    mode_t mode;
    int marker;
    opaque_marker opaque;
  } record_t;
  `aip_struct_type_begin(record_t)
    `aip_field_int(int, id, 0)
    `aip_field_int(int, rank, 0)
    `aip_field_string(label, "")
    `aip_field_struct(meta_t, meta)
    `aip_field_int(signed_wide_t, wide, '0)
    `aip_field_real(precise, 0.0)
    `aip_field_enum(mode_t, mode, MODE_LOW)
  `aip_struct_type_end(record_t)

  record_t stable[4];
  record_t nested[3];
  record_t multi[3];
  record_t wide_dups[2];
  record_t real_values[3];
  record_t enum_values[3];
  record_t override_values[3];
  record_t shortage_values[];
  record_t redraw_values[3];
  record_t fixed_collision_values[3];
  record_t fixed_later_values[3];
  record_t real_each_values[3];
  record_t wide_each_values[3];
  record_t enum_each_values[3];
  record_t zero_values[];

  initial begin
    if ($test$plusargs("AIP_TEST_TYPED_STABLE")) begin
      foreach (stable[i]) begin
        stable[i].marker = 100 + i;
        stable[i].opaque = new(100 + i);
      end
      `aip_struct_sarray_apply("typed.stable", record_t, stable)
      if (stable[0].rank != 3 || stable[1].rank != 2 ||
          stable[2].rank != 2 || stable[3].rank != 1 ||
          stable[0].id != 30 || stable[1].id != 20 ||
          stable[2].id != 40 || stable[3].id != 10)
        $fatal(1, "typed stable sort mismatch");
      if (stable[0].marker != 103 || stable[1].marker != 101 ||
          stable[2].marker != 102 || stable[3].marker != 100 ||
          stable[0].opaque.tag != 103 || stable[1].opaque.tag != 101 ||
          stable[2].opaque.tag != 102 || stable[3].opaque.tag != 100)
        $fatal(1, "whole-record marker/opaque preservation mismatch");
      $display("CMDLINE_STRUCT_TYPED_STABLE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_NESTED")) begin
      foreach (nested[i]) begin
        nested[i].marker = 200 + i;
        nested[i].opaque = new(200 + i);
      end
      `aip_struct_sarray_apply("typed.nested", record_t, nested)
      if (nested[0].meta.score != 1 || nested[1].meta.score != 2 ||
          nested[2].meta.score != 2 || nested[0].id != 11 ||
          nested[1].id != 13 || nested[2].id != 12)
        $fatal(1, "nested typed sort mismatch");
      if (nested[0].marker != 201 || nested[1].marker != 200 ||
          nested[2].marker != 202)
        $fatal(1, "nested whole-record preservation mismatch");
      $display("CMDLINE_STRUCT_TYPED_NESTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_MULTI_SORT")) begin
      `aip_struct_sarray_apply("typed.multi", record_t, multi)
      $fatal(1, "expected multiple active struct sort keys to fail");
    end

    if ($test$plusargs("AIP_TEST_TYPED_WIDE_UNIQUE")) begin
      `aip_struct_sarray_apply("typed.wide", record_t, wide_dups)
      $fatal(1, "expected signed wide typed unique collision to fail");
    end

    if ($test$plusargs("AIP_TEST_TYPED_REAL")) begin
      foreach (real_values[i]) begin
        real_values[i].marker = 300 + i;
        real_values[i].opaque = new(300 + i);
      end
      `aip_struct_sarray_apply("typed.real", record_t, real_values)
      if (!(real_values[0].precise < real_values[1].precise) ||
          !(real_values[1].precise < real_values[2].precise) ||
          real_values[0].marker != 302 || real_values[1].marker != 301 ||
          real_values[2].marker != 300)
        $fatal(1, "real precision-sensitive sort mismatch");
      $display("CMDLINE_STRUCT_TYPED_REAL_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_ENUM")) begin
      foreach (enum_values[i]) begin
        enum_values[i].marker = 400 + i;
        enum_values[i].opaque = new(400 + i);
      end
      `aip_struct_sarray_apply("typed.enum", record_t, enum_values)
      if (enum_values[0].mode != MODE_LOW || enum_values[1].mode != MODE_MID ||
          enum_values[2].mode != MODE_HIGH || enum_values[0].marker != 401 ||
          enum_values[1].marker != 402 || enum_values[2].marker != 400)
        $fatal(1, "enum underlying-value sort mismatch");
      $display("CMDLINE_STRUCT_TYPED_ENUM_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_UNIQUE_OVERRIDE")) begin
      aip_cmdline_override::set_val("typed.override.each.rank.unique", "0");
      `aip_struct_sarray_apply("typed.override", record_t, override_values)
      $display("CMDLINE_STRUCT_TYPED_UNIQUE_OVERRIDE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_EACH_SHORTAGE")) begin
      `aip_struct_darray_apply("typed.shortage", record_t, shortage_values)
      $fatal(1, "expected finite each candidate shortage to fail");
    end

    if ($test$plusargs("AIP_TEST_TYPED_EACH_REDRAW")) begin
      foreach (redraw_values[i]) begin
        redraw_values[i].marker = 500 + i;
        redraw_values[i].opaque = new(500 + i);
      end
      `aip_struct_sarray_apply("typed.redraw", record_t, redraw_values)
      if (redraw_values[0].rank == redraw_values[1].rank ||
          redraw_values[0].rank == redraw_values[2].rank ||
          redraw_values[1].rank == redraw_values[2].rank)
        $fatal(1, "typed each redraw left a duplicate");
      if (redraw_values[0].id != 100 || redraw_values[1].id != 101 ||
          redraw_values[2].id != 102 || redraw_values[0].marker != 500 ||
          redraw_values[1].marker != 501 || redraw_values[2].marker != 502 ||
          redraw_values[0].opaque.tag != 500 || redraw_values[1].opaque.tag != 501 ||
          redraw_values[2].opaque.tag != 502)
        $fatal(1, "typed each redraw changed unrelated fields");
      $display("CMDLINE_STRUCT_TYPED_EACH_REDRAW_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_FIXED_COLLISION")) begin
      `aip_struct_sarray_apply("typed.fixed_collision", record_t, fixed_collision_values)
      $fatal(1, "expected fixed typed unique collision to fail");
    end

    if ($test$plusargs("AIP_TEST_TYPED_FIXED_LATER")) begin
      foreach (fixed_later_values[i]) begin
        fixed_later_values[i].marker = 550 + i;
        fixed_later_values[i].opaque = new(550 + i);
      end
      `aip_struct_sarray_apply("typed.fixed_later", record_t, fixed_later_values)
      if (fixed_later_values[0].rank == fixed_later_values[1].rank ||
          fixed_later_values[0].rank == fixed_later_values[2].rank ||
          fixed_later_values[1].rank == fixed_later_values[2].rank)
        $fatal(1, "fixed-later typed each left a duplicate");
      if (fixed_later_values[1].rank != 1 || fixed_later_values[0].id != 10 ||
          fixed_later_values[1].id != 11 || fixed_later_values[2].id != 12 ||
          fixed_later_values[0].marker != 550 || fixed_later_values[1].marker != 551 ||
          fixed_later_values[2].marker != 552 || fixed_later_values[0].opaque.tag != 550 ||
          fixed_later_values[1].opaque.tag != 551 || fixed_later_values[2].opaque.tag != 552)
        $fatal(1, "fixed-later redraw changed fixed or unrelated fields");
      if (!aip_struct_runtime::redraw_attempts.exists("typed.fixed_later|rank") ||
          aip_struct_runtime::redraw_attempts["typed.fixed_later|rank"] == 0)
        $fatal(1, "fixed-later case did not exercise earlier each redraw");
      $display("CMDLINE_STRUCT_TYPED_FIXED_LATER_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_EACH_REAL")) begin
      `aip_struct_sarray_apply("typed.real_each", record_t, real_each_values)
      if (real_each_values[0].precise == real_each_values[1].precise ||
          real_each_values[0].precise == real_each_values[2].precise ||
          real_each_values[1].precise == real_each_values[2].precise)
        $fatal(1, "real each inc sequence left a duplicate");
      $display("CMDLINE_STRUCT_TYPED_REAL_EACH_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_WIDE_EACH")) begin
      `aip_struct_sarray_apply("typed.wide_each", record_t, wide_each_values)
      if (wide_each_values[0].wide == wide_each_values[1].wide ||
          wide_each_values[0].wide == wide_each_values[2].wide ||
          wide_each_values[1].wide == wide_each_values[2].wide)
        $fatal(1, "wide each list left a duplicate");
      $display("CMDLINE_STRUCT_TYPED_WIDE_EACH_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_EACH_ENUM")) begin
      `aip_struct_sarray_apply("typed.enum_each", record_t, enum_each_values)
      if (enum_each_values[0].mode == enum_each_values[1].mode ||
          enum_each_values[0].mode == enum_each_values[2].mode ||
          enum_each_values[1].mode == enum_each_values[2].mode)
        $fatal(1, "enum each list left a duplicate");
      $display("CMDLINE_STRUCT_TYPED_ENUM_EACH_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_TYPED_INDEXED_REJECT")) begin
      `aip_struct_sarray_apply("typed.indexed", record_t, stable)
      $fatal(1, "expected indexed struct-container control to fail");
    end

    if ($test$plusargs("AIP_TEST_TYPED_SIZE_ZERO_CONTROL")) begin
      `aip_struct_darray_apply("typed.zero", record_t, zero_values)
      $fatal(1, "expected invalid zero-sized struct control to fail");
    end

    $fatal(1, "no typed postprocess selector");
  end
endmodule
