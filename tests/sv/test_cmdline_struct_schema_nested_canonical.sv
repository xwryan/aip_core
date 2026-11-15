`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_nested_canonical;
  typedef struct { int value; } leaf_t;
  `aip_struct_type_begin(leaf_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(leaf_t)

  typedef struct { int value; int values[]; string labels[]; } cfg_t;
  `aip_struct_type_begin(cfg_t)
    `aip_field_int(int, value, 0)
    `aip_field_int_darray(int, values, 0, 0)
    `aip_field_string_darray(labels, "", 0)
  `aip_struct_type_end(cfg_t)

  typedef struct { int base; } nested_t;
  `aip_struct_type_begin(nested_t)
    `aip_field_int(int, base, 0)
  `aip_struct_type_end(nested_t)

  typedef struct { int id; } bus_t;
  `aip_struct_type_begin(bus_t)
    `aip_field_int(int, id, 0)
  `aip_struct_type_end(bus_t)

  typedef struct { bus_t bus; int channels[]; nested_t nested[]; } outer_t;
  `aip_struct_type_begin(outer_t)
    `aip_field_struct(bus_t, bus)
    `aip_field_int_darray(int, channels, 0, 0)
    `aip_field_struct_darray(nested_t, nested, 0)
  `aip_struct_type_end(outer_t)

  cfg_t cfg;
  outer_t cfgs[];

  initial begin
    if ($test$plusargs("AIP_CANON_LEAF")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.value != 11)
        $fatal(1, "canonical leaf fallback isolation mismatch: %0d", cfg.value);
      $display("CMDLINE_STRUCT_SCHEMA_CANON_LEAF_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_COMPACT")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.values.size() != 4 || cfg.values[0] != 1 || cfg.values[1] != 2 ||
          cfg.values[2] != 3 || cfg.values[3] != 4)
        $fatal(1, "compact array baseline mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_COMPACT_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_DOTTED_SHADOW")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.values.size() != 2 || cfg.values[0] != 5 || cfg.values[1] != 6)
        $fatal(1, "direct dotted whole-rule shadow mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_DOTTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_INDEXED_SHADOW")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.values.size() != 4 || cfg.values[0] != 1 || cfg.values[1] != 9 ||
          cfg.values[2] != 3 || cfg.values[3] != 4)
        $fatal(1, "indexed compact override mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_INDEXED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_SPARSE")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.values.size() != 2 || cfg.values[0] != 0 || cfg.values[1] != 9)
        $fatal(1, "sparse indexed inference mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_SPARSE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_STRING")) begin
      `aip_struct_apply("cfg", cfg_t, cfg)
      if (cfg.labels.size() != 2 || cfg.labels[0] != "a,b" || cfg.labels[1] != "c")
        $fatal(1, "quoted string array decoding mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_STRING_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_METADATA_FILTER")) begin
      `aip_struct_darray_apply("cfgs", outer_t, cfgs, 0)
      if (cfgs.size() != 2 || cfgs[0].bus.id != 10 || cfgs[1].bus.id != 20)
        $fatal(1, "registered nested scalar length/filter mismatch: size=%0d", cfgs.size());
      $display("CMDLINE_STRUCT_SCHEMA_CANON_METADATA_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_BARE_CHILD")) begin
      `aip_struct_darray_apply("cfgs", outer_t, cfgs, 0)
      $display("CMDLINE_STRUCT_SCHEMA_CANON_BARE_CHILD_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_CANON_OUTER_EACH")) begin
      `aip_struct_darray_apply("cfgs", outer_t, cfgs, 0)
      if (cfgs.size() != 3)
        $fatal(1, "outer size mismatch: %0d", cfgs.size());
      if (cfgs[2].channels.size() != 3)
        $fatal(1, "concrete outer size override mismatch: %0d", cfgs[2].channels.size());
      if (cfgs[0].channels.size() < 2 || cfgs[0].channels.size() > 4 ||
          cfgs[1].channels.size() < 2 || cfgs[1].channels.size() > 4)
        $fatal(1, "outer each ragged size mismatch");
      foreach (cfgs[i]) begin
        if (cfgs[i].nested.size() != 2 || (i != 1 && cfgs[i].nested[0].base != 7))
          $fatal(1, "nested each baseline mismatch at %0d", i);
      end
      if (cfgs[1].nested[0].base != 9)
        $fatal(1, "concrete nested index override mismatch");
      $display("CMDLINE_STRUCT_SCHEMA_CANON_OUTER_PASS");
      $finish;
    end

    $fatal(1, "missing canonical nested test selector");
  end
endmodule
