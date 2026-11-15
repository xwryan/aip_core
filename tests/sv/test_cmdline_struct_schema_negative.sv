`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_negative;
  typedef enum { NEG_IDLE, NEG_BUSY } neg_mode_t;
  typedef logic signed [7:0] signed_byte_t;
  typedef logic [7:0] unsigned_byte_t;

  typedef struct { int score; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, score, 0)
  `aip_struct_type_end(child_t)

  typedef struct {
    signed_byte_t s8;
    unsigned_byte_t u8;
    int value;
    string label;
    real rate;
    neg_mode_t mode;
    int tags[];
    string labels[];
    real rates[];
    neg_mode_t modes[];
    child_t children[];
  } neg_t;
  `aip_struct_type_begin(neg_t)
    `aip_field_int(signed_byte_t, s8, '0)
    `aip_field_int(unsigned_byte_t, u8, '0)
    `aip_field_int(int, value, 0)
    `aip_field_string(label, "")
    `aip_field_real(rate, 0.0)
    `aip_field_enum(neg_mode_t, mode, NEG_IDLE)
    `aip_field_int_darray(int, tags, 0, 0)
    `aip_field_string_darray(labels, "", 0)
    `aip_field_real_darray(rates, 0.0, 0)
    `aip_field_enum_darray(neg_mode_t, modes, NEG_IDLE, 0)
    `aip_field_struct_darray(child_t, children, 0)
  `aip_struct_type_end(neg_t)

  typedef struct { logic bad; } x_default_t;
  `aip_struct_type_begin(x_default_t)
    `aip_field_int(logic, bad, 1'bx)
  `aip_struct_type_end(x_default_t)

  typedef struct { logic bad; } z_default_t;
  `aip_struct_type_begin(z_default_t)
    `aip_field_int(logic, bad, 1'bz)
  `aip_struct_type_end(z_default_t)

  class neg_holder;
    neg_t cfg;
  endclass

  neg_t one;
  neg_t many[];
  neg_t fixed[2];
  neg_t bounded_q[$:1];
  x_default_t x_default;
  z_default_t z_default;
  signed_byte_t signed_q[$];
  unsigned_byte_t unsigned_q[$];
  neg_holder null_obj;

  function automatic void unexpected(string test_case);
    $display("AIP_STRUCT_NEG_%s_UNEXPECTED_PASS", test_case);
    $finish;
  endfunction

  initial begin
    string test_case;
    string bad_root;
    if (!$value$plusargs("AIP_NEG_CASE=%s", test_case))
      $fatal(1, "missing AIP_NEG_CASE");

    if (test_case == "root_empty" || test_case == "root_space" ||
        test_case == "root_digit" || test_case == "root_repeat_dot" ||
        test_case == "root_trailing_dot" || test_case == "root_plus" ||
        test_case == "root_equal" || test_case == "root_index") begin
      case (test_case)
        "root_empty":        bad_root = "";
        "root_space":        bad_root = "neg root";
        "root_digit":        bad_root = "1neg.root";
        "root_repeat_dot":   bad_root = "neg..root";
        "root_trailing_dot": bad_root = "neg.root.";
        "root_plus":         bad_root = "+neg.root";
        "root_equal":        bad_root = "neg=root";
        default:              bad_root = "neg.root[0]";
      endcase
      `aip_struct_apply(bad_root, neg_t, one)
      unexpected(test_case);
    end

    if (test_case == "index_noncanonical") begin
      aip_cmdline_override::set_val("neg.many[01].value", "1");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end
    if (test_case == "index_negative") begin
      aip_cmdline_override::set_val("neg.many[-1].value", "1");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end
    if (test_case == "index_oob") begin
      aip_cmdline_override::set_val("neg.fixed[2].value", "1");
      `aip_struct_sarray_apply("neg.fixed", neg_t, fixed)
      unexpected(test_case);
    end

    if (test_case == "compact_unknown" || test_case == "compact_duplicate" ||
        test_case == "compact_missing_equal" ||
        test_case == "compact_empty_nonstring" ||
        test_case == "compact_unbalanced" ||
        test_case == "compact_bad_escape") begin
      case (test_case)
        "compact_unknown":         aip_cmdline_override::set_val("neg.one", "{unknown=1}");
        "compact_duplicate":       aip_cmdline_override::set_val("neg.one", "{value=1,value=2}");
        "compact_missing_equal":   aip_cmdline_override::set_val("neg.one", "{value}");
        "compact_empty_nonstring": aip_cmdline_override::set_val("neg.one", "{value=}");
        "compact_unbalanced":      aip_cmdline_override::set_val("neg.one", "{value=[1,2}");
        default:                    aip_cmdline_override::set_val("neg.one", "{label=\"bad\\q\"}");
      endcase
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end

    if (test_case == "default_size_negative") begin
      `aip_struct_darray_apply("neg.default_size", neg_t, many, -1)
      unexpected(test_case);
    end
    if (test_case == "default_size_fractional") begin
      `aip_struct_darray_apply("neg.default_size", neg_t, many, 1.5)
      unexpected(test_case);
    end
    if (test_case == "max_size_negative") begin
      `aip_struct_queue_apply("neg.max_size", neg_t, bounded_q, 0, -2)
      unexpected(test_case);
    end
    if (test_case == "size_list_conflict") begin
      aip_cmdline_override::set_val("neg.many.size", "1");
      aip_cmdline_override::set_val("neg.many.value", "1,2");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end
    if (test_case == "size_index_conflict") begin
      aip_cmdline_override::set_val("neg.many.size", "1");
      aip_cmdline_override::set_val("neg.many[1].value", "2");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end
    if (test_case == "size_generator_conflict") begin
      aip_cmdline_override::set_val("neg.many.size", "2");
      aip_cmdline_override::set_val("neg.many.value", "seq:0:2");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end

    if (test_case == "default_x") begin
      `aip_struct_apply("neg.default_x", x_default_t, x_default)
      unexpected(test_case);
    end
    if (test_case == "default_z") begin
      `aip_struct_apply("neg.default_z", z_default_t, z_default)
      unexpected(test_case);
    end
    if (test_case == "command_x" || test_case == "command_z") begin
      aip_cmdline_override::set_val("neg.unsigned_q",
                                    test_case == "command_x" ? "8'hx" : "8'hz");
      `aip_int_queue("neg", unsigned_byte_t, unsigned_q, '0, -1)
      unexpected(test_case);
    end

    if (test_case == "signed_256" || test_case == "signed_neg256" ||
        test_case == "signed_wide_literal") begin
      case (test_case)
        "signed_256":          aip_cmdline_override::set_val("neg.signed_q", "256");
        "signed_neg256":       aip_cmdline_override::set_val("neg.signed_q", "-256");
        default:                aip_cmdline_override::set_val("neg.signed_q", "9'h0ff");
      endcase
      `aip_int_queue("neg", signed_byte_t, signed_q, '0, -1)
      unexpected(test_case);
    end
    if (test_case == "unsigned_256" || test_case == "unsigned_neg256" ||
        test_case == "unsigned_wide_literal") begin
      case (test_case)
        "unsigned_256":        aip_cmdline_override::set_val("neg.unsigned_q", "256");
        "unsigned_neg256":     aip_cmdline_override::set_val("neg.unsigned_q", "-256");
        default:                aip_cmdline_override::set_val("neg.unsigned_q", "9'h0ff");
      endcase
      `aip_int_queue("neg", unsigned_byte_t, unsigned_q, '0, -1)
      unexpected(test_case);
    end

    if (test_case == "schema_command_x" || test_case == "schema_command_z") begin
      aip_cmdline_override::set_val("neg.one.u8",
                                    test_case == "schema_command_x" ? "8'hx" : "8'hz");
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end
    if (test_case == "schema_signed_256" ||
        test_case == "schema_signed_neg256" ||
        test_case == "schema_signed_wide_literal") begin
      case (test_case)
        "schema_signed_256":      aip_cmdline_override::set_val("neg.one.s8", "256");
        "schema_signed_neg256":   aip_cmdline_override::set_val("neg.one.s8", "-256");
        default:                   aip_cmdline_override::set_val("neg.one.s8", "9'h0ff");
      endcase
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end
    if (test_case == "schema_unsigned_256" ||
        test_case == "schema_unsigned_neg256" ||
        test_case == "schema_unsigned_wide_literal") begin
      case (test_case)
        "schema_unsigned_256":    aip_cmdline_override::set_val("neg.one.u8", "256");
        "schema_unsigned_neg256": aip_cmdline_override::set_val("neg.one.u8", "-256");
        default:                   aip_cmdline_override::set_val("neg.one.u8", "9'h0ff");
      endcase
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end

    if (test_case == "real_nan" || test_case == "real_inf" ||
        test_case == "real_garbage") begin
      case (test_case)
        "real_nan":     aip_cmdline_override::set_val("neg.one.rate", "NaN");
        "real_inf":     aip_cmdline_override::set_val("neg.one.rate", "Inf");
        default:         aip_cmdline_override::set_val("neg.one.rate", "1.0junk");
      endcase
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end
    if (test_case == "enum_invalid") begin
      aip_cmdline_override::set_val("neg.one.mode", "NOT_A_MODE");
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end

    if (test_case == "seq_string" || test_case == "perm_real" ||
        test_case == "seq_enum") begin
      if (test_case == "seq_string")
        aip_cmdline_override::set_val("neg.one.labels", "seq:a:b");
      if (test_case == "perm_real")
        aip_cmdline_override::set_val("neg.one.rates", "perm:1:2");
      if (test_case == "seq_enum")
        aip_cmdline_override::set_val("neg.one.modes", "seq:NEG_IDLE:NEG_BUSY");
      `aip_struct_apply("neg.one", neg_t, one)
      unexpected(test_case);
    end
    if (test_case == "sort_through_container") begin
      aip_cmdline_override::set_val("neg.fixed.each.children.score.sort", "asc");
      `aip_struct_sarray_apply("neg.fixed", neg_t, fixed)
      unexpected(test_case);
    end

    if (test_case == "unique_shortage") begin
      aip_cmdline_override::set_val("neg.many.size", "3");
      aip_cmdline_override::set_val("neg.many.each.value", "0,1");
      aip_cmdline_override::set_val("neg.many.each.value.unique", "1");
      `aip_struct_darray_apply("neg.many", neg_t, many, 0)
      unexpected(test_case);
    end
    if (test_case == "unique_fixed_collision") begin
      aip_cmdline_override::set_val("neg.fixed.value", "7,7");
      aip_cmdline_override::set_val("neg.fixed.each.value.unique", "1");
      `aip_struct_sarray_apply("neg.fixed", neg_t, fixed)
      unexpected(test_case);
    end
    if (test_case == "sort_multiple") begin
      aip_cmdline_override::set_val("neg.fixed.each.value.sort", "asc");
      aip_cmdline_override::set_val("neg.fixed.each.s8.sort", "desc");
      `aip_struct_sarray_apply("neg.fixed", neg_t, fixed)
      unexpected(test_case);
    end
    if (test_case == "sort_invalid") begin
      aip_cmdline_override::set_val("neg.fixed.each.value.sort", "sideways");
      `aip_struct_sarray_apply("neg.fixed", neg_t, fixed)
      unexpected(test_case);
    end

    if (test_case == "queue_overflow") begin
      aip_cmdline_override::set_val("neg.bounded.size", "3");
      `aip_struct_queue_apply("neg.bounded", neg_t, bounded_q, 0, 2)
      unexpected(test_case);
    end
    if (test_case == "queue_declaration_mismatch") begin
      aip_cmdline_override::set_val("neg.bounded.size", "3");
      `aip_struct_queue_apply("neg.bounded", neg_t, bounded_q, 0, 3)
      unexpected(test_case);
    end
    if (test_case == "null_object") begin
      `aip_struct_apply("neg.null", neg_t, null_obj.cfg)
      unexpected(test_case);
    end

    $fatal(1, "unknown AIP_NEG_CASE '%s'", test_case);
  end
endmodule
