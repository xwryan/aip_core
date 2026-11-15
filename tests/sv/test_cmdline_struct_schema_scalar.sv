`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_scalar;
  class opaque_box; int cookie; endclass
  typedef enum { MODE_READ, MODE_WRITE } mode_e;
  typedef logic [127:0] addr_t;
  typedef struct { bit [7:0] id; int unsigned width; } bus_t;
  typedef struct {
    addr_t addr;
    int signed count;
    int unsigned len;
    string label;
    real rate;
    mode_e mode;
    bus_t bus;
    int opaque;
    opaque_box opaque_handle;
  } cfg_t;

  `aip_struct_type_begin(bus_t)
    `aip_field_int(bit [7:0], id, 8'h11)
    `aip_field_int(int unsigned, width, 32)
  `aip_struct_type_end(bus_t)

  `aip_struct_type_begin(cfg_t)
    `aip_field_int(addr_t, addr, 128'h1234)
    `aip_field_int(int, count, -3)
    `aip_field_int(int unsigned, len, 64)
    `aip_field_string(label, "default")
    `aip_field_real(rate, 1.25)
    `aip_field_enum(mode_e, mode, MODE_READ)
    `aip_field_struct(bus_t, bus)
  `aip_struct_type_end(cfg_t)

  cfg_t cfg;
  cfg_t plus_cfg;
  cfg_t empty_cfg;
  class holder; cfg_t cfg; endclass
  holder h;

  initial begin
    h = new();
    cfg.opaque_handle = new();
    h.cfg.opaque_handle = new();
    cfg.opaque = 32'hcafebabe;
    h.cfg.opaque = 32'hdeadbeef;
    `aip_struct_apply("dut.cfg", cfg_t, cfg)
    `aip_struct_apply("dut.hcfg", cfg_t, h.cfg)
    if (cfg.addr !== 128'h1234 || cfg.count !== -3 || cfg.len !== 64 ||
        cfg.label != "default" || cfg.rate != 1.25 || cfg.mode != MODE_READ ||
        cfg.bus.id !== 8'h11 || cfg.bus.width !== 32 || cfg.opaque !== 32'hcafebabe)
      $fatal(1, "schema defaults failed");
    if (h.cfg.opaque !== 32'hdeadbeef || cfg.opaque_handle == null ||
        h.cfg.opaque_handle == null) $fatal(1, "opaque preservation failed");

    // Exact runtime keys outrank compact members and preserve empty strings.
    aip_cmdline_override::set_val("dut.cfg", "{addr=64'h55,label=\"a,b\\\\c\",bus={id=8'h22,width=99}}");
    aip_cmdline_override::set_val("dut.cfg.addr", "128'h66");
    aip_cmdline_override::set_val("dut.cfg.bus.width", "101");
    aip_cmdline_override::set_val("dut.hcfg.label", "");
    `aip_struct_apply("dut.cfg", cfg_t, cfg)
    `aip_struct_apply("dut.hcfg", cfg_t, h.cfg)
    if (cfg.addr !== 128'h66 || cfg.label != "a,b\\c" ||
        cfg.bus.id !== 8'h22 || cfg.bus.width !== 101)
      $fatal(1, "exact/compact precedence failed");
    if (h.cfg.label != "") $fatal(1, "empty string override failed");
    if (cfg.opaque !== 32'hcafebabe || h.cfg.opaque !== 32'hdeadbeef)
      $fatal(1, "opaque preservation on reapply failed");

    // Make supplies these plusargs: compact nesting/quoting, dotted shadow,
    // exact runtime-over-plusarg, empty string, no leaf fallback/boundary leak.
    aip_cmdline_override::set_val("plus.cfg.addr", "128'h77");
    `aip_struct_apply("plus.cfg", cfg_t, plus_cfg)
    `aip_struct_apply("plus.empty", cfg_t, empty_cfg)
    if (plus_cfg.addr !== 128'h77 || plus_cfg.label != "x,y\\z" ||
        plus_cfg.bus.id !== 8'h33 || plus_cfg.bus.width !== 202)
      $fatal(1, "plusarg exact/compact/runtime precedence failed");
    if (empty_cfg.label != "") $fatal(1, "plusarg empty string failed");

    $display("CMDLINE_STRUCT_SCHEMA_SCALAR_PASS");
    $finish;
  end
endmodule

`ifdef AIP_STRUCT_NEG_WRONG_FTYPE
module aip_struct_neg_wrong_ftype;
  typedef struct { longint value; } wrong_t;
  `aip_struct_type_begin(wrong_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(wrong_t)
endmodule
`endif

`ifdef AIP_STRUCT_NEG_MISSING_COMPANION
module aip_struct_neg_missing_companion;
  typedef struct { int value; } missing_t;
  missing_t value;
  initial `aip_struct_apply("missing", missing_t, value)
endmodule
`endif

`ifdef AIP_STRUCT_NEG_RESERVED
module aip_struct_neg_reserved;
  typedef struct { int size; } reserved_t;
  `aip_struct_type_begin(reserved_t)
    `aip_field_int(int, size, 0)
  `aip_struct_type_end(reserved_t)
endmodule
`endif

`ifdef AIP_STRUCT_NEG_TOO_WIDE
module aip_struct_neg_too_wide;
  typedef struct { bit [1024:0] value; } wide_t;
  `aip_struct_type_begin(wide_t)
    `aip_field_int(bit [1024:0], value, '0)
  `aip_struct_type_end(wide_t)
  wide_t value;
  initial `aip_struct_apply("wide", wide_t, value)
endmodule
`endif
