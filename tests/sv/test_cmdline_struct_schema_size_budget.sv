`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_size_budget;
  typedef logic [127:0] wide_t;
  typedef logic [1023:0] widest_t;

  typedef struct { wide_t value; } wide_rec_t;
  `aip_struct_type_begin(wide_rec_t)
    `aip_field_int(wide_t, value, '0)
  `aip_struct_type_end(wide_rec_t)

  typedef struct { widest_t value; } widest_rec_t;
  `aip_struct_type_begin(widest_rec_t)
    `aip_field_int(widest_t, value, '0)
  `aip_struct_type_end(widest_rec_t)

  typedef struct { int values[]; } leaf_t;
  `aip_struct_type_begin(leaf_t)
    `aip_field_int_darray(int, values, 0, 0)
  `aip_struct_type_end(leaf_t)

  class default_counter;
    static int struct_calls;
    static int primitive_calls;
    static function int next_struct_size();
      struct_calls++;
      return 2;
    endfunction
    static function int next_primitive_size();
      primitive_calls++;
      return 2;
    endfunction
  endclass

  typedef struct { int value; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_t)

  typedef struct { child_t fixed_children[3]; } nested_parent_t;
  `aip_struct_type_begin(nested_parent_t)
    `aip_field_struct_sarray(child_t, fixed_children)
  `aip_struct_type_end(nested_parent_t)

  typedef struct { child_t children[]; int values[]; } parent_t;
  `aip_struct_type_begin(parent_t)
    `aip_field_struct_darray(child_t, children, default_counter::next_struct_size())
    `aip_field_int_darray(int, values, 0, default_counter::next_primitive_size())
  `aip_struct_type_end(parent_t)

  wide_rec_t wide_seq[3];
  wide_rec_t wide_perm[2];
  widest_rec_t widest_seq[3];
  widest_rec_t widest_perm[2];
  widest_rec_t widest_bad[2];
  wide_rec_t indexed_perm[3];
  wide_rec_t short_static[3];
  wide_rec_t sized[];
  wide_rec_t budget_queue[$];
  leaf_t budget_outer[2];
  leaf_t bad_leaf;
  parent_t parent;
  parent_t parents[2];
  nested_parent_t nested_parents[2];

  task automatic check_size_grammar();
    string exprs[6] = '{"0", "[2:4]", "1,3,5", "{2:=1,[3:4]:/2}",
                        "inc:2:6:2", "dec:6:2:2"};
    int lo[6] = '{0,2,1,2,2,2};
    int hi[6] = '{0,4,5,4,6,6};
    for (int i = 0; i < 6; i++) begin
      string root = $sformatf("sizes.r%0d", i);
      aip_cmdline_override::set_val({root, ".size"}, exprs[i]);
      `aip_struct_darray_apply(root, wide_rec_t, sized, 9)
      if (sized.size() < lo[i] || sized.size() > hi[i] ||
          (i == 2 && sized.size() != 1 && sized.size() != 3 && sized.size() != 5) ||
          (i == 3 && sized.size() != 2 && sized.size() != 3 && sized.size() != 4) ||
          (i == 4 && sized.size() != 2 && sized.size() != 4 && sized.size() != 6) ||
          (i == 5 && sized.size() != 2 && sized.size() != 4 && sized.size() != 6))
        $fatal(1, "size grammar mismatch for %s: %0d", exprs[i], sized.size());
    end
    $display("CMDLINE_STRUCT_SIZE_GRAMMAR_PASS");
  endtask

  task automatic check_budget_reset_and_logical_queue();
    aip_cmdline_override::set_val("budget.ok1.each.values.size", "500000");
    `aip_struct_sarray_apply("budget.ok1", leaf_t, budget_outer)
    if (budget_outer[0].values.size() != 500000 ||
        budget_outer[1].values.size() != 500000)
      $fatal(1, "exact allocation budget was not accepted");
    aip_cmdline_override::set_val("budget.ok2.each.values.size", "500000");
    `aip_struct_sarray_apply("budget.ok2", leaf_t, budget_outer)
    if (budget_outer[0].values.size() != 500000 ||
        budget_outer[1].values.size() != 500000)
      $fatal(1, "allocation budget did not reset per top-level apply");
    aip_cmdline_override::set_val("budget.queue.size", "500001");
    `aip_struct_queue_apply("budget.queue", wide_rec_t, budget_queue, 0)
    if (budget_queue.size() != 500001)
      $fatal(1, "logical queue allocation was double charged");
    $display("CMDLINE_STRUCT_SIZE_BUDGET_PASS");
  endtask

  task automatic check_draw_once();
    process p;
    string after_apply, after_one_draw;
    int expected;
    p = process::self();
    aip_cmdline_override::set_val("draw.records.size", "[2:4]");
    p.srandom(32'h12345678);
    `aip_struct_darray_apply("draw.records", wide_rec_t, sized, 0)
    after_apply = p.get_randstate();
    p.srandom(32'h12345678);
    expected = aip_cmdline#(int)::parse_value("[2:4]");
    after_one_draw = p.get_randstate();
    if (sized.size() != expected || after_apply != after_one_draw)
      $fatal(1, "schema .size was not drawn exactly once");
    $display("CMDLINE_STRUCT_SIZE_DRAW_ONCE_PASS");
  endtask

  task automatic check_perm_draw_order();
    process p;
    string after_apply, after_baseline;
    int ignored;
    p = process::self();
    aip_cmdline_override::set_val("draw.perm.value", "perm:0:2");
    aip_cmdline_override::set_val("draw.perm[0].value", "10");
    aip_cmdline_override::set_val("draw.perm[1].value", "11");
    aip_cmdline_override::set_val("draw.perm[2].value", "12");
    p.srandom(32'h31415926);
    `aip_struct_sarray_apply("draw.perm", wide_rec_t, indexed_perm)
    after_apply = p.get_randstate();
    p.srandom(32'h31415926);
    ignored = $urandom_range(2);
    ignored = $urandom_range(1);
    after_baseline = p.get_randstate();
    if (after_apply != after_baseline || indexed_perm[0].value != 10 ||
        indexed_perm[1].value != 11 || indexed_perm[2].value != 12)
      $fatal(1, "perm baseline draw order changed under indexed overrides");
    $display("CMDLINE_STRUCT_PERM_DRAW_ORDER_PASS");
  endtask

  task automatic check_nested_perm_draw_order();
    process p;
    string after_apply, after_baselines;
    int ignored;
    p = process::self();
    aip_cmdline_override::set_val("nested.parents.each.fixed_children.value",
                                  "perm:0:2");
    for (int i = 0; i < 2; i++)
      for (int j = 0; j < 3; j++)
        aip_cmdline_override::set_val(
          $sformatf("nested.parents[%0d].fixed_children[%0d].value", i, j),
          $sformatf("%0d", 10 + i*3 + j));
    p.srandom(32'h27182818);
    `aip_struct_sarray_apply("nested.parents", nested_parent_t, nested_parents)
    after_apply = p.get_randstate();
    p.srandom(32'h27182818);
    // Each concrete three-element nested container owns one complete
    // Fisher-Yates baseline, even when every materialized slot is overridden.
    repeat (2) begin
      ignored = $urandom_range(2);
      ignored = $urandom_range(1);
    end
    after_baselines = p.get_randstate();
    for (int i = 0; i < 2; i++)
      for (int j = 0; j < 3; j++)
        if (nested_parents[i].fixed_children[j].value != 10 + i*3 + j)
          $fatal(1, "nested indexed perm override mismatch at [%0d][%0d]", i, j);
    if (after_apply != after_baselines)
      $fatal(1, "nested perm baseline was missing, repeated, or shared");
    $display("CMDLINE_STRUCT_NESTED_PERM_DRAW_ORDER_PASS");
  endtask

  task automatic check_nested_perm_values();
    aip_cmdline_override::set_val(
      "nested.materialized.each.fixed_children.value", "perm:0:2");
    `aip_struct_sarray_apply("nested.materialized", nested_parent_t, nested_parents)
    for (int i = 0; i < 2; i++) begin
      for (int j = 0; j < 3; j++)
        if (nested_parents[i].fixed_children[j].value < 0 ||
            nested_parents[i].fixed_children[j].value > 2)
          $fatal(1, "nested perm value outside endpoints at [%0d][%0d]", i, j);
      if (nested_parents[i].fixed_children[0].value ==
            nested_parents[i].fixed_children[1].value ||
          nested_parents[i].fixed_children[0].value ==
            nested_parents[i].fixed_children[2].value ||
          nested_parents[i].fixed_children[1].value ==
            nested_parents[i].fixed_children[2].value)
        $fatal(1, "nested perm did not materialize all slots for container %0d", i);
    end
    $display("CMDLINE_STRUCT_NESTED_PERM_VALUES_PASS");
  endtask

  task automatic check_reachable_inc_dec_endpoints();
    aip_cmdline_override::set_val("reachable.inc_nondiv.size", "inc:1:6:4");
    `aip_struct_queue_apply("reachable.inc_nondiv", wide_rec_t, budget_queue, 0, 5)
    if (budget_queue.size() != 1 && budget_queue.size() != 5)
      $fatal(1, "inc non-divisible reachable set mismatch: %0d", budget_queue.size());

    aip_cmdline_override::set_val("reachable.inc_wide_step.size", "inc:2:6:10");
    `aip_struct_queue_apply("reachable.inc_wide_step", wide_rec_t, budget_queue, 0, 3)
    if (budget_queue.size() != 2)
      $fatal(1, "inc wide-step reachable set mismatch: %0d", budget_queue.size());

    aip_cmdline_override::set_val("reachable.dec_nondiv.size", "dec:5:-2:4");
    `aip_struct_queue_apply("reachable.dec_nondiv", wide_rec_t, budget_queue, 0, 5)
    if (budget_queue.size() != 5 && budget_queue.size() != 1)
      $fatal(1, "dec non-divisible reachable set mismatch: %0d", budget_queue.size());

    aip_cmdline_override::set_val("reachable.dec_wide_step.size", "dec:2:-2:10");
    `aip_struct_queue_apply("reachable.dec_wide_step", wide_rec_t, budget_queue, 0, 3)
    if (budget_queue.size() != 2)
      $fatal(1, "dec wide-step reachable set mismatch: %0d", budget_queue.size());
    $display("CMDLINE_STRUCT_SIZE_REACHABLE_ENDPOINTS_PASS");
  endtask

  task automatic check_widest_generators();
    string high_prefix, seq_start, seq_end, perm_start, perm_end;
    widest_t high_bit;
    high_prefix = "1024'h8";
    repeat (254) high_prefix = {high_prefix, "0"};
    seq_start = {high_prefix, "0"};
    seq_end = {high_prefix, "4"};
    perm_start = {high_prefix, "a"};
    perm_end = {high_prefix, "b"};
    high_bit = '0;
    high_bit[1023] = 1'b1;
    aip_cmdline_override::set_val("widest.seq.value",
                                  {"seq:", seq_start, ":", seq_end, ":2"});
    aip_cmdline_override::set_val("widest.perm.value",
                                  {"perm:", perm_start, ":", perm_end});
    `aip_struct_sarray_apply("widest.seq", widest_rec_t, widest_seq)
    if (widest_seq[0].value != high_bit ||
        widest_seq[1].value != high_bit + 2 ||
        widest_seq[2].value != high_bit + 4)
      $fatal(1, "1024-bit seq boundary truncation");
    `aip_struct_sarray_apply("widest.perm", widest_rec_t, widest_perm)
    if (!((widest_perm[0].value == high_bit + 10 &&
           widest_perm[1].value == high_bit + 11) ||
          (widest_perm[1].value == high_bit + 10 &&
           widest_perm[0].value == high_bit + 11)))
      $fatal(1, "1024-bit perm boundary truncation/endpoints");
    $display("CMDLINE_STRUCT_WIDEST_GENERATORS_PASS");
  endtask

  initial begin
    if ($test$plusargs("AIP_SIZE_INVALID_DOMAIN")) begin
      `aip_struct_apply("bad.domain", leaf_t, bad_leaf)
      $display("CMDLINE_STRUCT_SIZE_INVALID_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_BARE_RAND")) begin
      `aip_struct_darray_apply("bad.rand", wide_rec_t, sized, 0)
      $display("CMDLINE_STRUCT_SIZE_RAND_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_OTHER_INVALID")) begin
      `aip_struct_darray_apply("bad.other", wide_rec_t, sized, 0)
      $display("CMDLINE_STRUCT_SIZE_OTHER_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_STATIC_REJECT")) begin
      `aip_struct_sarray_apply("bad.static", wide_rec_t, short_static)
      $display("CMDLINE_STRUCT_SIZE_STATIC_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_STATIC_SIZE_TOP")) begin
      `aip_struct_sarray_apply("bad.static_size", wide_rec_t, short_static)
      $display("CMDLINE_STRUCT_STATIC_SIZE_TOP_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_STATIC_SIZE_NESTED")) begin
      `aip_struct_sarray_apply("nested.static", nested_parent_t, nested_parents)
      $display("CMDLINE_STRUCT_STATIC_SIZE_NESTED_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_GENERATOR_CONFLICT")) begin
      `aip_struct_darray_apply("bad.gen", wide_rec_t, sized, 0)
      $display("CMDLINE_STRUCT_SIZE_GEN_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_BUDGET_OVERFLOW")) begin
      `aip_struct_sarray_apply("budget.outer", leaf_t, budget_outer)
      $display("CMDLINE_STRUCT_SIZE_BUDGET_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_MAX_PREFLIGHT")) begin
      `aip_struct_queue_apply("bad.max", wide_rec_t, budget_queue, 0, 3)
      $display("CMDLINE_STRUCT_SIZE_MAX_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("AIP_SIZE_DEFAULT_ONCE")) begin
      aip_struct_schema__parent_t::register_schema();
      default_counter::struct_calls = 0;
      default_counter::primitive_calls = 0;
      `aip_struct_apply("once.parent", parent_t, parent)
      if (default_counter::struct_calls != 1 ||
          default_counter::primitive_calls != 1 ||
          parent.children.size() != 2 || parent.values.size() != 2)
        $fatal(1, "scalar parent DEFAULT_SIZE struct_calls=%0d primitive_calls=%0d",
               default_counter::struct_calls, default_counter::primitive_calls);
      default_counter::struct_calls = 0;
      default_counter::primitive_calls = 0;
      `aip_struct_sarray_apply("once.parents", parent_t, parents)
      if (default_counter::struct_calls != 2 ||
          default_counter::primitive_calls != 2)
        $fatal(1, "container DEFAULT_SIZE struct_calls=%0d primitive_calls=%0d",
               default_counter::struct_calls, default_counter::primitive_calls);
      $display("CMDLINE_STRUCT_SIZE_DEFAULT_ONCE_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_NESTED_PERM_ONLY")) begin
      check_nested_perm_draw_order();
      $finish;
    end

    if ($test$plusargs("AIP_NESTED_PERM_VALUES_ONLY")) begin
      check_nested_perm_values();
      $finish;
    end

    if ($test$plusargs("AIP_REACHABLE_ENDPOINTS_ONLY")) begin
      check_reachable_inc_dec_endpoints();
      $finish;
    end

    if ($test$plusargs("AIP_WIDEST_ONLY")) begin
      check_widest_generators();
      $finish;
    end

    if ($test$plusargs("AIP_WIDEST_X_INVALID")) begin
      aip_cmdline_override::set_val("bad.widest.value",
                                    "seq:1024'hx:1024'h1");
      `aip_struct_sarray_apply("bad.widest", widest_rec_t, widest_bad)
      $display("CMDLINE_STRUCT_WIDEST_X_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_WIDEST_Z_INVALID")) begin
      aip_cmdline_override::set_val("bad.widest.value",
                                    "perm:1024'h0:1024'hz");
      `aip_struct_sarray_apply("bad.widest", widest_rec_t, widest_bad)
      $display("CMDLINE_STRUCT_WIDEST_Z_UNEXPECTED_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_SIZE_WIDE_ONLY")) begin
      `aip_struct_sarray_apply("wide.seq", wide_rec_t, wide_seq)
      if (wide_seq[0].value != 128'h1_0000_0000 ||
          wide_seq[1].value != 128'h1_0000_0002 ||
          wide_seq[2].value != 128'h1_0000_0004)
        $fatal(1, "wide seq truncation");
      `aip_struct_sarray_apply("wide.perm", wide_rec_t, wide_perm)
      if (!((wide_perm[0].value == 128'h2_0000_0000 &&
             wide_perm[1].value == 128'h2_0000_0001) ||
            (wide_perm[1].value == 128'h2_0000_0000 &&
             wide_perm[0].value == 128'h2_0000_0001)))
        $fatal(1, "wide perm truncation/endpoints");
      $display("CMDLINE_STRUCT_WIDE_GENERATORS_PASS");
      $finish;
    end

    check_size_grammar();
    check_draw_once();
    check_perm_draw_order();
    check_nested_perm_draw_order();
    check_nested_perm_values();
    check_reachable_inc_dec_endpoints();
    check_budget_reset_and_logical_queue();
    `aip_struct_sarray_apply("wide.seq", wide_rec_t, wide_seq)
    if (wide_seq[0].value != 128'h1_0000_0000 ||
        wide_seq[1].value != 128'h1_0000_0002 ||
        wide_seq[2].value != 128'h1_0000_0004)
      $fatal(1, "wide seq truncation");
    `aip_struct_sarray_apply("wide.perm", wide_rec_t, wide_perm)
    if (!((wide_perm[0].value == 128'h2_0000_0000 &&
           wide_perm[1].value == 128'h2_0000_0001) ||
          (wide_perm[1].value == 128'h2_0000_0000 &&
           wide_perm[0].value == 128'h2_0000_0001)))
      $fatal(1, "wide perm truncation/endpoints");
    $display("CMDLINE_STRUCT_WIDE_GENERATORS_PASS");
    check_widest_generators();
    $finish;
  end
endmodule
