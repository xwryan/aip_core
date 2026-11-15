`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_final_review;
`ifdef AIP_FINAL_RECURSIVE_VALUE_COMPILE
  typedef final_recursive_value_t;
  typedef struct {
    int value;
    final_recursive_value_t children[];
  } final_recursive_value_t;
`endif

  typedef enum logic [1:0] {
    FINAL_LOW,
    FINAL_MID,
    FINAL_HIGH
  } final_mode_e;

  typedef logic [7:0] final_byte_t;
  typedef logic [95:0] final_wide_t;
  typedef enum logic [63:0] {
    FINAL_WIDE_LOW  = 64'h0000_0001_0000_002a,
    FINAL_WIDE_MID  = 64'h0000_0002_0000_002a,
    FINAL_WIDE_HIGH = 64'h0000_0003_0000_002a
  } final_wide_mode_e;

  typedef struct {
    int ints[3];
    string strings[3];
    real reals[3];
    final_mode_e enums[3];
  } final_primitive_t;

  `aip_struct_type_begin(final_primitive_t)
    `aip_field_int_sarray(int, ints, 0)
    `aip_field_string_sarray(strings, "")
    `aip_field_real_sarray(reals, 0.0)
    `aip_field_enum_sarray(final_mode_e, enums, FINAL_LOW)
  `aip_struct_type_end(final_primitive_t)

  typedef struct {
    final_byte_t narrow_values[];
    final_wide_t wide_values[];
    final_wide_mode_e wide_enums[];
  } final_unique_t;

  `aip_struct_type_begin(final_unique_t)
    `aip_field_int_darray(final_byte_t, narrow_values, '0, 0)
    `aip_field_int_darray(final_wide_t, wide_values, '0, 0)
    `aip_field_enum_darray(final_wide_mode_e, wide_enums,
                          FINAL_WIDE_LOW, 0)
  `aip_struct_type_end(final_unique_t)

  typedef struct {
    int value;
  } final_child_t;

  `aip_struct_type_begin(final_child_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(final_child_t)

  localparam int F7_OLD_SIZE = 262144;

  class f7_opaque_box;
    int cookie;
    function new(int value); cookie = value; endfunction
  endclass

  typedef struct {
    int value;
    bit [4095:0] opaque_bits;
    f7_opaque_box opaque_handle;
  } f7_item_t;

  `aip_struct_type_begin(f7_item_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(f7_item_t)

  typedef struct {
    f7_item_t children[];
  } f7_parent_t;

  `aip_struct_type_begin(f7_parent_t)
    `aip_field_struct_darray(f7_item_t, children, 0)
  `aip_struct_type_end(f7_parent_t)

  typedef struct { final_child_t values[3:5]; } f5_nested_asc_t;
  `aip_struct_type_begin(f5_nested_asc_t)
    `aip_field_struct_sarray(final_child_t, values)
  `aip_struct_type_end(f5_nested_asc_t)

  typedef struct { final_child_t values[2:0]; } f5_nested_desc_t;
  `aip_struct_type_begin(f5_nested_desc_t)
    `aip_field_struct_sarray(final_child_t, values)
  `aip_struct_type_end(f5_nested_desc_t)

  typedef struct { int values[3:5]; } f5_int_asc_t;
  `aip_struct_type_begin(f5_int_asc_t)
    `aip_field_int_sarray(int, values, 0)
  `aip_struct_type_end(f5_int_asc_t)

  typedef struct { int values[2:0]; } f5_int_desc_t;
  `aip_struct_type_begin(f5_int_desc_t)
    `aip_field_int_sarray(int, values, 0)
  `aip_struct_type_end(f5_int_desc_t)

  typedef struct { string values[3:5]; } f5_string_asc_t;
  `aip_struct_type_begin(f5_string_asc_t)
    `aip_field_string_sarray(values, "")
  `aip_struct_type_end(f5_string_asc_t)

  typedef struct { string values[2:0]; } f5_string_desc_t;
  `aip_struct_type_begin(f5_string_desc_t)
    `aip_field_string_sarray(values, "")
  `aip_struct_type_end(f5_string_desc_t)

  typedef struct { real values[3:5]; } f5_real_asc_t;
  `aip_struct_type_begin(f5_real_asc_t)
    `aip_field_real_sarray(values, 0.0)
  `aip_struct_type_end(f5_real_asc_t)

  typedef struct { real values[2:0]; } f5_real_desc_t;
  `aip_struct_type_begin(f5_real_desc_t)
    `aip_field_real_sarray(values, 0.0)
  `aip_struct_type_end(f5_real_desc_t)

  typedef struct { final_mode_e values[3:5]; } f5_enum_asc_t;
  `aip_struct_type_begin(f5_enum_asc_t)
    `aip_field_enum_sarray(final_mode_e, values, FINAL_LOW)
  `aip_struct_type_end(f5_enum_asc_t)

  typedef struct { final_mode_e values[2:0]; } f5_enum_desc_t;
  `aip_struct_type_begin(f5_enum_desc_t)
    `aip_field_enum_sarray(final_mode_e, values, FINAL_LOW)
  `aip_struct_type_end(f5_enum_desc_t)

  typedef struct {
    int addr;
    int tags[2];
    int values[];
    final_child_t children[3];
  } final_channel_t;

  `aip_struct_type_begin(final_channel_t)
    `aip_field_int(int, addr, 0)
    `aip_field_int_sarray(int, tags, 0)
    `aip_field_int_darray(int, values, 0, 0)
    `aip_field_struct_sarray(final_child_t, children)
  `aip_struct_type_end(final_channel_t)

  typedef struct {
    final_channel_t channels[2];
  } final_cfg_t;

  `aip_struct_type_begin(final_cfg_t)
    `aip_field_struct_sarray(final_channel_t, channels)
  `aip_struct_type_end(final_cfg_t)

  final_cfg_t cfgs[3];
  final_primitive_t primitive_cfg;
  final_unique_t unique_cfg;
  final_wide_t final_wide_q[$];
  final_wide_mode_e final_wide_enum_q[$];
  real final_real_q[$];
  int final_fixed_q[$];
  int final_rng_base_q[$];
  int final_rng_unique_q[$];
  final_child_t f5_top_asc[3:5];
  final_child_t f5_top_desc[2:0];
  f5_nested_asc_t f5_nested_asc;
  f5_nested_desc_t f5_nested_desc;
  f5_int_asc_t f5_int_asc;
  f5_int_desc_t f5_int_desc;
  f5_string_asc_t f5_string_asc;
  f5_string_desc_t f5_string_desc;
  f5_real_asc_t f5_real_asc;
  f5_real_desc_t f5_real_desc;
  f5_enum_asc_t f5_enum_asc;
  f5_enum_desc_t f5_enum_desc;
  int f5_zero_probe[0:-1];
  f7_item_t f7_top[];
  f7_parent_t f7_parent;

  task automatic prepare_f7_top();
    f7_top = new[F7_OLD_SIZE];
    foreach (f7_top[i]) f7_top[i].opaque_bits[4095] = i[0];
    f7_top[0].opaque_bits[31:0] = 32'ha0a0_0000;
    f7_top[1].opaque_bits[31:0] = 32'hb0b0_0001;
    f7_top[0].opaque_handle = new(1001);
    f7_top[1].opaque_handle = new(2002);
  endtask

  task automatic prepare_f7_nested();
    f7_parent.children = new[F7_OLD_SIZE];
    foreach (f7_parent.children[i])
      f7_parent.children[i].opaque_bits[4095] = i[0];
    f7_parent.children[0].opaque_bits[31:0] = 32'hc0c0_0000;
    f7_parent.children[1].opaque_bits[31:0] = 32'hd0d0_0001;
    f7_parent.children[0].opaque_handle = new(3003);
    f7_parent.children[1].opaque_handle = new(4004);
  endtask

  function automatic void check_sorted_children(string label);
    foreach (cfgs[i]) begin
      foreach (cfgs[i].channels[j]) begin
        if (cfgs[i].channels[j].children[0].value != 1 ||
            cfgs[i].channels[j].children[1].value != 2 ||
            cfgs[i].channels[j].children[2].value != 3)
          $fatal(1, "%s child sort mismatch at [%0d][%0d]: %0d,%0d,%0d",
                 label, i, j,
                 cfgs[i].channels[j].children[0].value,
                 cfgs[i].channels[j].children[1].value,
                 cfgs[i].channels[j].children[2].value);
      end
    end
  endfunction

  function automatic void check_unique_children(string label);
    foreach (cfgs[i]) begin
      foreach (cfgs[i].channels[j]) begin
        if (cfgs[i].channels[j].children[0].value ==
              cfgs[i].channels[j].children[1].value ||
            cfgs[i].channels[j].children[0].value ==
              cfgs[i].channels[j].children[2].value ||
            cfgs[i].channels[j].children[1].value ==
              cfgs[i].channels[j].children[2].value)
          $fatal(1, "%s child unique mismatch at [%0d][%0d]", label, i, j);
        if (cfgs[i].channels[j].children[2].value != 2)
          $fatal(1, "%s inherited indexed winner missing at [%0d][%0d]",
                 label, i, j);
      end
    end
  endfunction

  initial begin
    if ($test$plusargs("AIP_FINAL_SELECTOR_PRECEDENCE")) begin
      `aip_struct_sarray_apply("f1.cfgs", final_cfg_t, cfgs)
      if (cfgs[0].channels[0].addr != 1 ||
          cfgs[0].channels[1].addr != 11 ||
          cfgs[2].channels[0].addr != 22 ||
          cfgs[2].channels[1].addr != 221)
        $fatal(1, "recursive selector precedence mismatch: %0d,%0d,%0d,%0d",
               cfgs[0].channels[0].addr, cfgs[0].channels[1].addr,
               cfgs[2].channels[0].addr, cfgs[2].channels[1].addr);
      foreach (cfgs[i]) begin
        foreach (cfgs[i].channels[j]) begin
          if (cfgs[i].channels[j].tags[0] != 5 ||
              cfgs[i].channels[j].tags[1] != 9)
            $fatal(1, "inherited primitive indexed winner mismatch at [%0d][%0d]",
                   i, j);
        end
      end
      if (cfgs[0].channels[0].values.size() != 1 ||
          cfgs[0].channels[1].values.size() != 2 ||
          cfgs[2].channels[0].values.size() != 3 ||
          cfgs[2].channels[1].values.size() != 4)
        $fatal(1, "recursive size precedence mismatch: %0d,%0d,%0d,%0d",
               cfgs[0].channels[0].values.size(),
               cfgs[0].channels[1].values.size(),
               cfgs[2].channels[0].values.size(),
               cfgs[2].channels[1].values.size());
      $display("CMDLINE_STRUCT_FINAL_SELECTOR_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_INHERITED_SORT")) begin
      `aip_struct_sarray_apply("f1sort.cfgs", final_cfg_t, cfgs)
      check_sorted_children("inherited sort");
      $display("CMDLINE_STRUCT_FINAL_INHERITED_SORT_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_INHERITED_UNIQUE_FIXED")) begin
      `aip_struct_sarray_apply("f1fixed.cfgs", final_cfg_t, cfgs)
      $display("CMDLINE_STRUCT_FINAL_INHERITED_UNIQUE_FIXED_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_INHERITED_PREFLIGHT")) begin
      `aip_struct_sarray_apply("f1pre.cfgs", final_cfg_t, cfgs)
      $display("CMDLINE_STRUCT_FINAL_INHERITED_PREFLIGHT_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_INHERITED_REDRAW")) begin
      `aip_struct_sarray_apply("f1redraw.cfgs", final_cfg_t, cfgs)
      check_unique_children("inherited redraw");
      $display("CMDLINE_STRUCT_FINAL_INHERITED_REDRAW_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_SHADOW_INVALID_INT")) begin
      `aip_struct_apply("f2badint", final_primitive_t, primitive_cfg)
      if (primitive_cfg.ints[0] != 10 || primitive_cfg.ints[1] != 11 ||
          primitive_cfg.ints[2] != 12)
        $fatal(1, "integral overall winners changed");
      $display("CMDLINE_STRUCT_FINAL_SHADOW_INVALID_INT_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_SHADOW_INVALID_STRING")) begin
      `aip_struct_apply("f2badstr", final_primitive_t, primitive_cfg)
      if (primitive_cfg.strings[0] != "a" || primitive_cfg.strings[1] != "b" ||
          primitive_cfg.strings[2] != "c")
        $fatal(1, "string overall winners changed");
      $display("CMDLINE_STRUCT_FINAL_SHADOW_INVALID_STRING_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_SHADOW_INVALID_REAL")) begin
      `aip_struct_apply("f2badreal", final_primitive_t, primitive_cfg)
      if (primitive_cfg.reals[0] != 1.0 || primitive_cfg.reals[1] != 2.0 ||
          primitive_cfg.reals[2] != 3.0)
        $fatal(1, "real overall winners changed");
      $display("CMDLINE_STRUCT_FINAL_SHADOW_INVALID_REAL_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_SHADOW_INVALID_ENUM")) begin
      `aip_struct_apply("f2badenum", final_primitive_t, primitive_cfg)
      if (primitive_cfg.enums[0] != FINAL_LOW || primitive_cfg.enums[1] != FINAL_MID ||
          primitive_cfg.enums[2] != FINAL_HIGH)
        $fatal(1, "enum overall winners changed");
      $display("CMDLINE_STRUCT_FINAL_SHADOW_INVALID_ENUM_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_SHADOW_RNG")) begin
      process self;
      int unsigned baseline_rng;
      int unsigned shadow_rng;

      self = process::self();

      aip_cmdline_override::set_val("f2rng_int_base.ints", "10,11,12");
      aip_cmdline_override::set_val("f2rng_int_shadow.ints", "10,11,12");
      aip_cmdline_override::set_val("f2rng_int_shadow.ints.each", "1,2,3");
      self.srandom(32'h1020_3040);
      `aip_struct_apply("f2rng_int_base", final_primitive_t, primitive_cfg)
      baseline_rng = $urandom();
      self.srandom(32'h1020_3040);
      `aip_struct_apply("f2rng_int_shadow", final_primitive_t, primitive_cfg)
      shadow_rng = $urandom();
      if (baseline_rng != shadow_rng)
        $fatal(1, "shadowed integral each consumed RNG: %0h != %0h",
               baseline_rng, shadow_rng);

      aip_cmdline_override::set_val("f2rng_str_base.strings[0]", "a");
      aip_cmdline_override::set_val("f2rng_str_base.strings[1]", "b");
      aip_cmdline_override::set_val("f2rng_str_base.strings[2]", "c");
      aip_cmdline_override::set_val("f2rng_str_shadow.strings[0]", "a");
      aip_cmdline_override::set_val("f2rng_str_shadow.strings[1]", "b");
      aip_cmdline_override::set_val("f2rng_str_shadow.strings[2]", "c");
      aip_cmdline_override::set_val("f2rng_str_shadow.strings.each", "x,y,z");
      self.srandom(32'h2030_4050);
      `aip_struct_apply("f2rng_str_base", final_primitive_t, primitive_cfg)
      baseline_rng = $urandom();
      self.srandom(32'h2030_4050);
      `aip_struct_apply("f2rng_str_shadow", final_primitive_t, primitive_cfg)
      shadow_rng = $urandom();
      if (baseline_rng != shadow_rng)
        $fatal(1, "shadowed string each consumed RNG: %0h != %0h",
               baseline_rng, shadow_rng);

      aip_cmdline_override::set_val("f2rng_real_base.reals", "1.0,2.0,3.0");
      aip_cmdline_override::set_val("f2rng_real_shadow.reals", "1.0,2.0,3.0");
      aip_cmdline_override::set_val("f2rng_real_shadow.reals.each", "1.0:2.0");
      self.srandom(32'h3040_5060);
      `aip_struct_apply("f2rng_real_base", final_primitive_t, primitive_cfg)
      baseline_rng = $urandom();
      self.srandom(32'h3040_5060);
      `aip_struct_apply("f2rng_real_shadow", final_primitive_t, primitive_cfg)
      shadow_rng = $urandom();
      if (baseline_rng != shadow_rng)
        $fatal(1, "shadowed real each consumed RNG: %0h != %0h",
               baseline_rng, shadow_rng);

      aip_cmdline_override::set_val("f2rng_enum_base.enums[0]", "FINAL_LOW");
      aip_cmdline_override::set_val("f2rng_enum_base.enums[1]", "FINAL_MID");
      aip_cmdline_override::set_val("f2rng_enum_base.enums[2]", "FINAL_HIGH");
      aip_cmdline_override::set_val("f2rng_enum_shadow.enums[0]", "FINAL_LOW");
      aip_cmdline_override::set_val("f2rng_enum_shadow.enums[1]", "FINAL_MID");
      aip_cmdline_override::set_val("f2rng_enum_shadow.enums[2]", "FINAL_HIGH");
      aip_cmdline_override::set_val("f2rng_enum_shadow.enums.each",
                                    "FINAL_LOW,FINAL_MID,FINAL_HIGH");
      self.srandom(32'h4050_6070);
      `aip_struct_apply("f2rng_enum_base", final_primitive_t, primitive_cfg)
      baseline_rng = $urandom();
      self.srandom(32'h4050_6070);
      `aip_struct_apply("f2rng_enum_shadow", final_primitive_t, primitive_cfg)
      shadow_rng = $urandom();
      if (baseline_rng != shadow_rng)
        $fatal(1, "shadowed enum each consumed RNG: %0h != %0h",
               baseline_rng, shadow_rng);

      $display("CMDLINE_STRUCT_FINAL_SHADOW_RNG_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_PERM_PREWARM")) begin
      process self;
      int unsigned no_perm_rng;
      int unsigned perm_rng;
      int unsigned perm_repeat_rng;

      self = process::self();
      aip_cmdline_override::set_val("f2perm_base.ints[0]", "10");
      aip_cmdline_override::set_val("f2perm_base.ints[1]", "11");
      aip_cmdline_override::set_val("f2perm_base.ints[2]", "12");
      aip_cmdline_override::set_val("f2perm_shadow.ints", "perm:1:3");
      aip_cmdline_override::set_val("f2perm_shadow.ints[0]", "10");
      aip_cmdline_override::set_val("f2perm_shadow.ints[1]", "11");
      aip_cmdline_override::set_val("f2perm_shadow.ints[2]", "12");
      self.srandom(32'h5060_7080);
      `aip_struct_apply("f2perm_base", final_primitive_t, primitive_cfg)
      no_perm_rng = $urandom();
      self.srandom(32'h5060_7080);
      `aip_struct_apply("f2perm_shadow", final_primitive_t, primitive_cfg)
      perm_rng = $urandom();
      self.srandom(32'h5060_7080);
      `aip_struct_apply("f2perm_shadow", final_primitive_t, primitive_cfg)
      perm_repeat_rng = $urandom();
      if (perm_rng == no_perm_rng)
        $fatal(1, "fully shadowed perm failed to prewarm");
      if (perm_rng != perm_repeat_rng)
        $fatal(1, "fully shadowed perm RNG was not repeatable");
      if (primitive_cfg.ints[0] != 10 || primitive_cfg.ints[1] != 11 ||
          primitive_cfg.ints[2] != 12)
        $fatal(1, "indexed winners did not shadow perm values");
      $display("CMDLINE_STRUCT_FINAL_PERM_PREWARM_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STRICT_ARRAY_ERROR")) begin
      `aip_struct_apply("f3", final_primitive_t, primitive_cfg)
      $display("CMDLINE_STRUCT_FINAL_STRICT_ARRAY_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_STATIC_SHORTAGE")) begin
      aip_cmdline_override::set_val("f4static.ints.each", "0,1");
      aip_cmdline_override::set_val("f4static.ints.unique", "1");
      `aip_struct_apply("f4static", final_primitive_t, primitive_cfg)
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_STATIC_SHORTAGE_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_STATIC_FIXED")) begin
      aip_cmdline_override::set_val("f4fixed.strings[0]", "same");
      aip_cmdline_override::set_val("f4fixed.strings[1]", "other");
      aip_cmdline_override::set_val("f4fixed.strings[2]", "same");
      aip_cmdline_override::set_val("f4fixed.strings.unique", "1");
      `aip_struct_apply("f4fixed", final_primitive_t, primitive_cfg)
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_STATIC_FIXED_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_DYNAMIC_CAST")) begin
      aip_cmdline_override::set_val("f4cast.narrow_values.size", "3");
      aip_cmdline_override::set_val("f4cast.narrow_values.each",
                                    "-1,8'hff,1");
      aip_cmdline_override::set_val("f4cast.narrow_values.unique", "1");
      `aip_struct_apply("f4cast", final_unique_t, unique_cfg)
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_DYNAMIC_CAST_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_REAL_SHORTAGE")) begin
      aip_cmdline_override::set_val("f4q.final_real_q.size", "3");
      aip_cmdline_override::set_val("f4q.final_real_q.each",
                                    "inc:1.0:2.0:1.0");
      aip_cmdline_override::set_val("f4q.final_real_q.unique", "1");
      `aip_real_queue("f4q", final_real_q, 0.0, -1)
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_REAL_SHORTAGE_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_QUEUE_FIXED")) begin
      aip_cmdline_override::set_val("f4q.final_fixed_q.size", "3");
      aip_cmdline_override::set_val("f4q.final_fixed_q.each", "1,2,3");
      aip_cmdline_override::set_val("f4q.final_fixed_q[0]", "7");
      aip_cmdline_override::set_val("f4q.final_fixed_q[2]", "7");
      aip_cmdline_override::set_val("f4q.final_fixed_q.unique", "1");
      `aip_int_queue("f4q", int, final_fixed_q, 0, -1)
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_QUEUE_FIXED_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_TYPED_POSITIVE")) begin
      aip_cmdline_override::set_val("f4typed.narrow_values.size", "3");
      aip_cmdline_override::set_val("f4typed.narrow_values.each", "0,1,2");
      aip_cmdline_override::set_val("f4typed.narrow_values[2]", "2");
      aip_cmdline_override::set_val("f4typed.narrow_values.unique", "1");
      aip_cmdline_override::set_val("f4typed.wide_values.size", "3");
      aip_cmdline_override::set_val(
          "f4typed.wide_values.each",
          "96'h00000001_00000000_0000002a,96'h00000002_00000000_0000002a,96'h00000003_00000000_0000002a");
      aip_cmdline_override::set_val("f4typed.wide_values.unique", "1");
      aip_cmdline_override::set_val("f4typed.wide_enums.size", "3");
      aip_cmdline_override::set_val(
          "f4typed.wide_enums.each",
          "FINAL_WIDE_LOW,FINAL_WIDE_MID,FINAL_WIDE_HIGH");
      aip_cmdline_override::set_val("f4typed.wide_enums.unique", "1");
      `aip_struct_apply("f4typed", final_unique_t, unique_cfg)
      if (unique_cfg.narrow_values.size() != 3 ||
          unique_cfg.narrow_values[0] == unique_cfg.narrow_values[1] ||
          unique_cfg.narrow_values[0] == unique_cfg.narrow_values[2] ||
          unique_cfg.narrow_values[1] == unique_cfg.narrow_values[2] ||
          unique_cfg.narrow_values[2] != 2)
        $fatal(1, "dynamic array later fixed slot was not reserved");
      if (unique_cfg.wide_values.size() != 3 ||
          unique_cfg.wide_values[0] == unique_cfg.wide_values[1] ||
          unique_cfg.wide_values[0] == unique_cfg.wide_values[2] ||
          unique_cfg.wide_values[1] == unique_cfg.wide_values[2])
        $fatal(1, "96-bit candidates were truncated during preflight");
      if (unique_cfg.wide_enums.size() != 3 ||
          unique_cfg.wide_enums[0] == unique_cfg.wide_enums[1] ||
          unique_cfg.wide_enums[0] == unique_cfg.wide_enums[2] ||
          unique_cfg.wide_enums[1] == unique_cfg.wide_enums[2])
        $fatal(1, "wide enum candidates were truncated during preflight");

      aip_cmdline_override::set_val("f4q.final_wide_q.size", "3");
      aip_cmdline_override::set_val(
          "f4q.final_wide_q.each",
          "96'h00000001_00000000_0000002a,96'h00000002_00000000_0000002a,96'h00000003_00000000_0000002a");
      aip_cmdline_override::set_val("f4q.final_wide_q[2]",
                                    "96'h00000003_00000000_0000002a");
      aip_cmdline_override::set_val("f4q.final_wide_q.unique", "1");
      `aip_int_queue("f4q", final_wide_t, final_wide_q, '0, -1)
      if (final_wide_q.size() != 3 ||
          final_wide_q[0] == final_wide_q[1] ||
          final_wide_q[0] == final_wide_q[2] ||
          final_wide_q[1] == final_wide_q[2] ||
          final_wide_q[2] != 96'h00000003_00000000_0000002a)
        $fatal(1, "wide queue later fixed slot was not reserved");

      aip_cmdline_override::set_val("f4q.final_wide_enum_q.size", "3");
      aip_cmdline_override::set_val(
          "f4q.final_wide_enum_q.each",
          "FINAL_WIDE_LOW,FINAL_WIDE_MID,FINAL_WIDE_HIGH");
      aip_cmdline_override::set_val("f4q.final_wide_enum_q.unique", "1");
      `aip_enum_queue("f4q", final_wide_mode_e, final_wide_enum_q,
                      FINAL_WIDE_LOW, -1)
      if (final_wide_enum_q.size() != 3 ||
          final_wide_enum_q[0] == final_wide_enum_q[1] ||
          final_wide_enum_q[0] == final_wide_enum_q[2] ||
          final_wide_enum_q[1] == final_wide_enum_q[2])
        $fatal(1, "wide enum queue candidates were truncated during preflight");
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_TYPED_POSITIVE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_CUTOFF")) begin
      string raw;
      string tokens[$];
      int status;
      raw = "0";
      repeat (16) raw = {raw, ",", raw};
      status = aip_struct_runtime::finite_candidate_tokens(raw, tokens, 1);
      if (status != 65536 || tokens.size() != 65536)
        $fatal(1, "65,536 raw candidates classified as %0d/%0d",
               status, tokens.size());
      raw = {raw, ",0"};
      status = aip_struct_runtime::finite_candidate_tokens(raw, tokens, 1);
      if (status >= 0)
        $fatal(1, "65,537 raw candidates incorrectly enumerated: %0d", status);
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_CUTOFF_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_UNIQUE_NO_PREFLIGHT_RNG")) begin
      process self;
      int unsigned baseline_rng;
      int unsigned unique_rng;

      self = process::self();
      aip_cmdline_override::set_val("f4rng_base.narrow_values.size", "1");
      aip_cmdline_override::set_val("f4rng_base.narrow_values.each", "10,20,30");
      aip_cmdline_override::set_val("f4rng_unique.narrow_values.size", "1");
      aip_cmdline_override::set_val("f4rng_unique.narrow_values.each", "10,20,30");
      aip_cmdline_override::set_val("f4rng_unique.narrow_values.unique", "1");
      self.srandom(32'h6172_8394);
      `aip_struct_apply("f4rng_base", final_unique_t, unique_cfg)
      baseline_rng = $urandom();
      self.srandom(32'h6172_8394);
      `aip_struct_apply("f4rng_unique", final_unique_t, unique_cfg)
      unique_rng = $urandom();
      if (baseline_rng != unique_rng)
        $fatal(1, "schema-array preflight consumed RNG: %0h != %0h",
               baseline_rng, unique_rng);

      aip_cmdline_override::set_val("f4rng.final_rng_base_q.size", "1");
      aip_cmdline_override::set_val("f4rng.final_rng_base_q.each", "10,20,30");
      aip_cmdline_override::set_val("f4rng.final_rng_unique_q.size", "1");
      aip_cmdline_override::set_val("f4rng.final_rng_unique_q.each", "10,20,30");
      aip_cmdline_override::set_val("f4rng.final_rng_unique_q.unique", "1");
      self.srandom(32'h7283_94a5);
      `aip_int_queue("f4rng", int, final_rng_base_q, 0, -1)
      baseline_rng = $urandom();
      self.srandom(32'h7283_94a5);
      `aip_int_queue("f4rng", int, final_rng_unique_q, 0, -1)
      unique_rng = $urandom();
      if (baseline_rng != unique_rng)
        $fatal(1, "queue preflight consumed RNG: %0h != %0h",
               baseline_rng, unique_rng);
      $display("CMDLINE_STRUCT_FINAL_UNIQUE_NO_PREFLIGHT_RNG_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_TOP_ASC")) begin
      `aip_struct_sarray_apply("f5.top_asc", final_child_t, f5_top_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_TOP_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_TOP_DESC")) begin
      `aip_struct_sarray_apply("f5.top_desc", final_child_t, f5_top_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_TOP_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_NESTED_ASC")) begin
      `aip_struct_apply("f5.nested_asc", f5_nested_asc_t, f5_nested_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_NESTED_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_NESTED_DESC")) begin
      `aip_struct_apply("f5.nested_desc", f5_nested_desc_t, f5_nested_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_NESTED_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_INT_ASC")) begin
      `aip_struct_apply("f5.int_asc", f5_int_asc_t, f5_int_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_INT_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_INT_DESC")) begin
      `aip_struct_apply("f5.int_desc", f5_int_desc_t, f5_int_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_INT_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_STRING_ASC")) begin
      `aip_struct_apply("f5.string_asc", f5_string_asc_t, f5_string_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_STRING_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_STRING_DESC")) begin
      `aip_struct_apply("f5.string_desc", f5_string_desc_t, f5_string_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_STRING_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_REAL_ASC")) begin
      `aip_struct_apply("f5.real_asc", f5_real_asc_t, f5_real_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_REAL_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_REAL_DESC")) begin
      `aip_struct_apply("f5.real_desc", f5_real_desc_t, f5_real_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_REAL_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_ENUM_ASC")) begin
      `aip_struct_apply("f5.enum_asc", f5_enum_asc_t, f5_enum_asc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_ENUM_ASC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_ENUM_DESC")) begin
      `aip_struct_apply("f5.enum_desc", f5_enum_desc_t, f5_enum_desc)
      $display("CMDLINE_STRUCT_FINAL_STATIC_ENUM_DESC_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_STATIC_ZERO_PROBE")) begin
      if ($unpacked_dimensions(f5_zero_probe) != 1 ||
          $size(f5_zero_probe) != 2 || $left(f5_zero_probe) != 0 ||
          $right(f5_zero_probe) != -1 || $low(f5_zero_probe) != -1 ||
          $high(f5_zero_probe) != 0)
        $fatal(1, "unexpected VCS [0:-1] representation: dims=%0d size=%0d left=%0d right=%0d low=%0d high=%0d",
               $unpacked_dimensions(f5_zero_probe), $size(f5_zero_probe),
               $left(f5_zero_probe), $right(f5_zero_probe),
               $low(f5_zero_probe), $high(f5_zero_probe));
      $display("CMDLINE_STRUCT_FINAL_STATIC_ZERO_PROBE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_DARRAY_MEMORY_BASELINE")) begin
      prepare_f7_top();
      $display("CMDLINE_STRUCT_FINAL_DARRAY_MEMORY_BASELINE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_DARRAY_TOP_SHRINK")) begin
      prepare_f7_top();
      aip_cmdline_override::set_val("f7.top.size", "2");
      aip_cmdline_override::set_val("f7.top[0].value", "20");
      aip_cmdline_override::set_val("f7.top[1].value", "10");
      aip_cmdline_override::set_val("f7.top.each.value.sort", "asc");
      `aip_struct_darray_apply("f7.top", f7_item_t, f7_top, 0)
      if (f7_top.size() != 2 || f7_top[0].value != 10 ||
          f7_top[0].opaque_bits[31:0] != 32'hb0b0_0001 ||
          f7_top[0].opaque_handle == null ||
          f7_top[0].opaque_handle.cookie != 2002 ||
          f7_top[1].value != 20 ||
          f7_top[1].opaque_bits[31:0] != 32'ha0a0_0000 ||
          f7_top[1].opaque_handle == null ||
          f7_top[1].opaque_handle.cookie != 1001)
        $fatal(1, "top-level shrink lost an overlapping complete record");
      `aip_struct_darray_apply("f7.top", f7_item_t, f7_top, 0)
      if (f7_top[0].value != 10 ||
          f7_top[0].opaque_bits[31:0] != 32'ha0a0_0000 ||
          f7_top[0].opaque_handle == null ||
          f7_top[0].opaque_handle.cookie != 1001 ||
          f7_top[1].value != 20 ||
          f7_top[1].opaque_bits[31:0] != 32'hb0b0_0001 ||
          f7_top[1].opaque_handle == null ||
          f7_top[1].opaque_handle.cookie != 2002)
        $fatal(1, "top-level repeated apply lost overlap preservation");
      $display("CMDLINE_STRUCT_FINAL_DARRAY_TOP_SHRINK_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_DARRAY_NESTED_SHRINK")) begin
      prepare_f7_nested();
      aip_cmdline_override::set_val("f7.parent.children.size", "2");
      aip_cmdline_override::set_val("f7.parent.children[0].value", "40");
      aip_cmdline_override::set_val("f7.parent.children[1].value", "30");
      aip_cmdline_override::set_val(
          "f7.parent.children.each.value.sort", "asc");
      `aip_struct_apply("f7.parent", f7_parent_t, f7_parent)
      if (f7_parent.children.size() != 2 ||
          f7_parent.children[0].value != 30 ||
          f7_parent.children[0].opaque_bits[31:0] != 32'hd0d0_0001 ||
          f7_parent.children[0].opaque_handle == null ||
          f7_parent.children[0].opaque_handle.cookie != 4004 ||
          f7_parent.children[1].value != 40 ||
          f7_parent.children[1].opaque_bits[31:0] != 32'hc0c0_0000 ||
          f7_parent.children[1].opaque_handle == null ||
          f7_parent.children[1].opaque_handle.cookie != 3003)
        $fatal(1, "nested shrink lost an overlapping complete record");
      `aip_struct_apply("f7.parent", f7_parent_t, f7_parent)
      if (f7_parent.children[0].value != 30 ||
          f7_parent.children[0].opaque_bits[31:0] != 32'hc0c0_0000 ||
          f7_parent.children[0].opaque_handle == null ||
          f7_parent.children[0].opaque_handle.cookie != 3003 ||
          f7_parent.children[1].value != 40 ||
          f7_parent.children[1].opaque_bits[31:0] != 32'hd0d0_0001 ||
          f7_parent.children[1].opaque_handle == null ||
          f7_parent.children[1].opaque_handle.cookie != 4004)
        $fatal(1, "nested repeated apply lost overlap preservation");
      $display("CMDLINE_STRUCT_FINAL_DARRAY_NESTED_SHRINK_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_FINAL_RECURSION_GUARD_INTERNAL")) begin
      string schema_id;
      schema_id = aip_struct_schema__final_child_t::schema_id();
      aip_struct_runtime::schema_begin(schema_id);
      aip_struct_schema__final_child_t::register_schema();
      $display("CMDLINE_STRUCT_FINAL_RECURSION_GUARD_UNEXPECTED_PASS");
      $finish;
    end

    $fatal(1, "missing final-review test selector");
  end
endmodule
