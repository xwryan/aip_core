`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_containers;
  typedef struct { int value; } elem_t;
  `aip_struct_type_begin(elem_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(elem_t)
  typedef struct { int score; } key_t;
  `aip_struct_type_begin(key_t)
    `aip_field_int(int, score, 0)
  `aip_struct_type_end(key_t)

  elem_t fixed[2];
  elem_t dyn[];
  elem_t seqv[3];
  elem_t permv[4];
  elem_t ordered_v[4];
  typedef struct { int id; int rank; string label; key_t meta; } record_t;
  `aip_struct_type_begin(record_t)
    `aip_field_int(int, id, 0)
    `aip_field_int(int, rank, 0)
    `aip_field_string(label, "")
    `aip_field_struct(key_t, meta)
  `aip_struct_type_end(record_t)
  record_t records[4];

  elem_t precedence[3];
  elem_t inferred_seq[];
  elem_t inferred_q[$];
  elem_t runtime_inferred[];
  elem_t runtime_bounds[];
  elem_t each_unknown[];
  elem_t explicit_empty[];
  record_t inferred_records[];
  record_t conflicting_generators[];
  initial begin
    if ($test$plusargs("AIP_TEST_PRECEDENCE_ONLY")) begin
      `aip_struct_sarray_apply("cfg.precedence", elem_t, precedence)
      if (precedence[0].value != 4 || precedence[1].value != 9 ||
          precedence[2].value != 6)
        $fatal(1, "indexed/compact/overall/each precedence mismatch: %0d,%0d,%0d",
               precedence[0].value, precedence[1].value, precedence[2].value);
      $display("CMDLINE_STRUCT_SCHEMA_PRECEDENCE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_FIELD_LENGTH_ONLY")) begin
      `aip_struct_darray_apply("cfg.inferred_records", record_t, inferred_records, 0)
      `aip_struct_darray_apply("cfg.inferred_seq", elem_t, inferred_seq, 0)
      `aip_struct_queue_apply("cfg.inferred_q", elem_t, inferred_q, 0)
      if (inferred_records.size() != 3 ||
          inferred_records[0].id != 11 || inferred_records[1].id != 22 ||
          inferred_records[2].id != 33 || inferred_records[0].rank != 4 ||
          inferred_records[1].rank != 5 || inferred_records[2].rank != 0)
        $fatal(1, "field overall length/value inference mismatch");
      if (inferred_seq.size() != 3 || inferred_seq[0].value != 2 ||
          inferred_seq[1].value != 4 || inferred_seq[2].value != 6)
        $fatal(1, "field generator length/value inference mismatch");
      if (inferred_q.size() != 3 || inferred_q[0].value != 7 ||
          inferred_q[1].value != 8 || inferred_q[2].value != 9)
        $fatal(1, "queue field overall length/value inference mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_FIELD_LENGTH_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_GENERATOR_CONFLICT")) begin
      `aip_struct_darray_apply("cfg.conflicting", record_t,
                               conflicting_generators, 0)
      $fatal(1, "expected conflicting field generators to fail");
    end

    if ($test$plusargs("AIP_TEST_SOURCE_SIZE_ONLY")) begin
      aip_cmdline_override::set_val("cfg.runtime_inferred.value", "8,9");
      `aip_struct_darray_apply("cfg.runtime_inferred", elem_t,
                               runtime_inferred, 0)
      `aip_struct_darray_apply("cfg.explicit_empty", elem_t,
                               explicit_empty, 4)
      if (runtime_inferred.size() != 2 || runtime_inferred[0].value != 8 ||
          runtime_inferred[1].value != 9)
        $fatal(1, "exact runtime source did not shadow plusarg for length");
      if (explicit_empty.size() != 0)
        $fatal(1, "explicit zero size was treated as an overall field value");
      $display("CMDLINE_STRUCT_SCHEMA_SOURCE_SIZE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_RUNTIME_INDEX_BOUNDS")) begin
      aip_cmdline_override::set_val("cfg.runtime_bounds[2].value", "9");
      `aip_struct_darray_apply("cfg.runtime_bounds", elem_t,
                               runtime_bounds, 0)
      $fatal(1, "expected runtime indexed key beyond .size to fail");
    end

    if ($test$plusargs("AIP_TEST_RUNTIME_INDEX_NONCANONICAL")) begin
      aip_cmdline_override::set_val("cfg.runtime_bounds[02].value", "9");
      `aip_struct_darray_apply("cfg.runtime_bounds", elem_t,
                               runtime_bounds, 0)
      $fatal(1, "expected noncanonical runtime index to fail");
    end

    if ($test$plusargs("AIP_TEST_RUNTIME_INDEX_NEGATIVE")) begin
      aip_cmdline_override::set_val("cfg.runtime_bounds[-1].value", "9");
      `aip_struct_darray_apply("cfg.runtime_bounds", elem_t,
                               runtime_bounds, 0)
      $fatal(1, "expected negative runtime index to fail");
    end

    if ($test$plusargs("AIP_TEST_EACH_UNKNOWN")) begin
      `aip_struct_darray_apply("cfg.each_unknown", elem_t, each_unknown, 0)
      $fatal(1, "expected each-only container with no size source to fail");
    end

    `aip_struct_sarray_apply("cfg.fixed", elem_t, fixed)
    `aip_struct_darray_apply("cfg.dyn", elem_t, dyn, 2)
    if ($size(dyn) != 2) $fatal(1, "dynamic container size mismatch");
    // Overall generators are expanded slot-by-slot for integer fields.
    `aip_struct_sarray_apply("cfg.seqv", elem_t, seqv)
    `aip_struct_sarray_apply("cfg.permv", elem_t, permv)
    if (seqv[0].value != 0 || seqv[1].value != 2 || seqv[2].value != 4)
      $fatal(1, "seq generator mismatch: %0d,%0d,%0d", seqv[0].value, seqv[1].value, seqv[2].value);
    foreach (permv[i]) if (permv[i].value < 10 || permv[i].value > 13)
      $fatal(1, "perm generator out of range at %0d: %0d", i, permv[i].value);
    `aip_struct_sarray_apply("cfg.ordered", elem_t, ordered_v)
    if (ordered_v[0].value != 1 || ordered_v[1].value != 2 ||
        ordered_v[2].value != 2 || ordered_v[3].value != 3)
      $fatal(1, "stable sort mismatch: %0d,%0d,%0d,%0d",
             ordered_v[0].value, ordered_v[1].value, ordered_v[2].value, ordered_v[3].value);
    `aip_struct_sarray_apply("cfg.records", record_t, records)
    // Sorting by an arbitrary scalar key must move complete records, not just
    // the key field itself.  `rank` is intentionally different from `id`.
    if (records[0].rank != 1 || records[1].rank != 2 ||
        records[2].rank != 2 || records[3].rank != 3 ||
        records[0].id != 20 || records[1].id != 10 ||
        records[2].id != 40 || records[3].id != 30)
      $fatal(1, "arbitrary-key stable sort mismatch");
    if (records[0].meta.score != 4 || records[1].meta.score != 8 ||
        records[2].meta.score != 2 || records[3].meta.score != 6)
      $fatal(1, "nested-key record preservation mismatch");
    if (records[0].id == records[1].id || records[1].id == records[2].id ||
        records[2].id == records[3].id)
      $fatal(1, "unique control did not preserve distinct ids");

    // Explicit index overrides an indexed compact member, which overrides an
    // overall member list, then .each.
    `aip_struct_sarray_apply("cfg.precedence", elem_t, precedence)
    if (precedence[0].value != 4 || precedence[1].value != 9 ||
        precedence[2].value != 6)
      $fatal(1, "indexed/compact/overall/each precedence mismatch: %0d,%0d,%0d",
             precedence[0].value, precedence[1].value, precedence[2].value);

    `aip_struct_darray_apply("cfg.inferred_records", record_t, inferred_records, 0)
    `aip_struct_darray_apply("cfg.inferred_seq", elem_t, inferred_seq, 0)
    `aip_struct_queue_apply("cfg.inferred_q", elem_t, inferred_q, 0)
    if (inferred_records.size() != 3 || inferred_seq.size() != 3 ||
        inferred_q.size() != 3)
      $fatal(1, "field-level dynamic length inference mismatch");
    aip_cmdline_override::set_val("cfg.runtime_inferred.value", "8,9");
    `aip_struct_darray_apply("cfg.runtime_inferred", elem_t, runtime_inferred, 0)
    `aip_struct_darray_apply("cfg.explicit_empty", elem_t, explicit_empty, 4)
    if (runtime_inferred.size() != 2 || explicit_empty.size() != 0)
      $fatal(1, "source normalization or explicit zero size mismatch");
    $display("CMDLINE_STRUCT_SCHEMA_CONTAINERS_PASS");
    $finish;
  end
endmodule
