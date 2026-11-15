`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_strict_queue;
  typedef logic [7:0] narrow_t;
  typedef logic [1023:0] wide_t;
  typedef enum logic [39:0] {
    WIDE_IDLE = 40'h01_0000_0000,
    WIDE_BUSY = 40'h80_0000_0000,
    WIDE_DONE = 40'hff_0000_0000
  } wide_mode_t;
  typedef enum { Q_IDLE, Q_BUSY, Q_DONE } q_mode_t;

  class opaque_box;
    int cookie;
    function new(int c = 0); cookie = c; endfunction
  endclass

  typedef struct {
    int value;
    int opaque_value;
    opaque_box opaque;
  } item_t;

  `aip_struct_type_begin(item_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(item_t)

  class queue_holder;
    int values[$];
  endclass

  q_mode_t enum_default_q[$];
  wide_mode_t wide_enum_q[$];
  real real_each_q[$];
  real real_sort_q[$];
  wide_t wide_q[$];
  string empty_q[$];
  int plus_precedence_q[$];
  int eval_q[$];
  int summary_q[$];
  int shadow_q[$];
  int shadow_overall_q[$];
  string shadow_str_q[$];
  real shadow_real_q[$];
  q_mode_t shadow_enum_q[$];
  int perm_shadow_q[$];
  int unique_later_fixed_q[$];
  int fixed_collision_q[$];
  int shortage_q[$];
  int int_q[$];
  narrow_t narrow_q[$];
  string str_q[$];
  real real_q[$];
  q_mode_t enum_q[$];
  int bounded_q[$:1];
  item_t struct_q[$];
  int legacy_int_q[];
  queue_holder holder;

  int path_evals;
  int default_evals;
  int max_evals;

  function automatic string counted_path();
    path_evals++;
    return "eval";
  endfunction

  function automatic int counted_default();
    default_evals++;
    return 13;
  endfunction

  function automatic int counted_max();
    max_evals++;
    return 2;
  endfunction

  task automatic check(bit condition, string message);
    if (!condition) $fatal(1, "STRICT_QUEUE_CHECK_FAIL: %s", message);
  endtask

  task automatic run_positive();
    holder = new();

    aip_cmdline_override::set_val("strict.enum_default_q.size", "2");
    `aip_enum_queue("strict", q_mode_t, enum_default_q, Q_IDLE, -1)
    check(enum_default_q.size() == 2 && enum_default_q[0] == Q_IDLE &&
          enum_default_q[1] == Q_IDLE,
          "enum queue uses the caller DEFAULT_VAL");

    aip_cmdline_override::set_val("strict.real_each_q.size", "3");
    aip_cmdline_override::set_val("strict.real_each_q.each", "2.5");
    aip_cmdline_override::set_val("strict.real_each_q[1]", "0.5");
    `aip_real_queue("strict", real_each_q, 9.0, -1)
    check(real_each_q.size() == 3 && real_each_q[0] == 2.5 &&
          real_each_q[1] == 0.5 && real_each_q[2] == 2.5,
          "real queue each baseline and indexed override");

    aip_cmdline_override::set_val("strict.real_sort_q", "2.5,-1.0,0.25");
    aip_cmdline_override::set_val("strict.real_sort_q.sort", "asc");
    `aip_real_queue("strict", real_sort_q, 0.0, -1)
    check(real_sort_q.size() == 3 && real_sort_q[0] == -1.0 &&
          real_sort_q[1] == 0.25 && real_sort_q[2] == 2.5,
          "real queue typed numeric sort");

    aip_cmdline_override::set_val("strict.wide_q", "seq:0x100000000:0x100000002");
    aip_cmdline_override::set_val("strict.wide_q.sort", "desc");
    `aip_int_queue("strict", wide_t, wide_q, '0, -1)
    check(wide_q.size() == 3 && wide_q[0] == wide_t'(64'h1_0000_0002) &&
          wide_q[2] == wide_t'(64'h1_0000_0000),
          "1024-bit integer queue generator and typed sort");

    aip_cmdline_override::set_val("strict.wide_enum_q", "WIDE_DONE,WIDE_IDLE,WIDE_BUSY");
    aip_cmdline_override::set_val("strict.wide_enum_q.sort", "asc");
    `aip_enum_queue("strict", wide_mode_t, wide_enum_q, WIDE_IDLE, -1)
    check(wide_enum_q.size() == 3 && wide_enum_q[0] == WIDE_IDLE &&
          wide_enum_q[1] == WIDE_BUSY && wide_enum_q[2] == WIDE_DONE,
          "wide enum queue compares full typed underlying values");

    aip_cmdline_override::set_val("strict.empty_q", "");
    `aip_str_queue("strict", empty_q, "fallback", -1)
    check(empty_q.size() == 1 && empty_q[0] == "",
          "empty string rule remains distinct from no rule");

    aip_cmdline_override::set_val("plus_precedence_q", "7");
    `aip_int_queue("strict", int, plus_precedence_q, 0, -1)
    check(plus_precedence_q.size() == 1 && plus_precedence_q[0] == 7,
          "runtime leaf shadows plusarg full");
    aip_cmdline_override::set_val("strict.plus_precedence_q", "8");
    `aip_int_queue("strict", int, plus_precedence_q, 0, -1)
    check(plus_precedence_q.size() == 1 && plus_precedence_q[0] == 8,
          "runtime full shadows runtime leaf");
    aip_cmdline_override::clear("strict.plus_precedence_q");
    aip_cmdline_override::clear("plus_precedence_q");
    `aip_int_queue("strict", int, plus_precedence_q, 0, -1)
    check(plus_precedence_q.size() == 1 && plus_precedence_q[0] == 31,
          "last plusarg full shadows last plusarg leaf");

    aip_cmdline_override::set_val("strict.holder.values", "4,5");
    `aip_int_queue("strict", int, holder.values, 0, -1)
    check(holder.values.size() == 2 && holder.values[0] == 4 &&
          holder.values[1] == 5,
          "object-member primitive queue target");

    $display("CMDLINE_STRICT_QUEUE_POSITIVE_PASS");
  endtask

  task automatic run_eval_once();
    path_evals = 0;
    default_evals = 0;
    max_evals = 0;
    aip_cmdline_override::set_val("eval.eval_q.size", "2");
    `aip_int_queue(counted_path(), int, eval_q, counted_default(), counted_max())
    check(path_evals == 1, "PATH expression evaluated exactly once");
    check(default_evals == 1, "DEFAULT_VAL expression evaluated exactly once");
    check(max_evals == 1, "MAX_SIZE expression evaluated exactly once");
    check(eval_q.size() == 2 && eval_q[0] == 13 && eval_q[1] == 13,
          "once-bound default materialized both queue elements");
    $display("CMDLINE_STRICT_QUEUE_EVAL_ONCE_PASS");
  endtask

  task automatic run_struct_sort_reapply();
    aip_cmdline_override::set_val("strict.struct_q.size", "2");
    aip_cmdline_override::set_val("strict.struct_q[0].value", "20");
    aip_cmdline_override::set_val("strict.struct_q[1].value", "10");
    aip_cmdline_override::set_val("strict.struct_q.each.value.sort", "asc");
    `aip_struct_queue_apply("strict.struct_q", item_t, struct_q, 0, -1)
    check(struct_q[0].value == 10 && struct_q[1].value == 20,
          "initial struct queue typed sort");
    struct_q[0].opaque_value = 101;
    struct_q[0].opaque = new(1001);
    struct_q[1].opaque_value = 202;
    struct_q[1].opaque = new(2002);
    `aip_struct_queue_apply("strict.struct_q", item_t, struct_q, 0, -1)
    check(struct_q[0].value == 10 && struct_q[0].opaque_value == 202 &&
          struct_q[0].opaque != null && struct_q[0].opaque.cookie == 2002,
          "reapply sort moves complete second record");
    check(struct_q[1].value == 20 && struct_q[1].opaque_value == 101 &&
          struct_q[1].opaque != null && struct_q[1].opaque.cookie == 1001,
          "reapply sort moves complete first record");
    $display("CMDLINE_STRICT_QUEUE_STRUCT_REAPPLY_PASS");
  endtask

  task automatic run_summary();
    aip_cmdline_print_control::configure(1, 1);
    aip_cmdline_override::set_val("strict.summary_q", "2,1");
    aip_cmdline_override::set_val("strict.summary_q.size", "2");
    aip_cmdline_override::set_val("strict.summary_q.unique", "0");
    aip_cmdline_override::set_val("strict.summary_q.sort", "asc");
    `aip_int_queue("strict", int, summary_q, 0, -1)
    `aip_int_queue("strict", int, summary_q, 0, -1)
    check(summary_q.size() == 2 && summary_q[0] == 1 && summary_q[1] == 2,
          "summary mode still resolves and sorts queue");
    $display("CMDLINE_STRICT_QUEUE_SUMMARY_PASS");
  endtask

  task automatic run_shadow_invalid();
    aip_cmdline_override::set_val("strict.shadow_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_q.each", "not_an_integer");
    aip_cmdline_override::set_val("strict.shadow_q", "11");
    aip_cmdline_override::set_val("strict.shadow_q[1]", "22");
    `aip_int_queue("strict", int, shadow_q, 0, -1)
    check(shadow_q.size() == 2 && shadow_q[0] == 11 && shadow_q[1] == 22,
          "overall and indexed winners suppress a shadowed invalid each rule");

    aip_cmdline_override::set_val("strict.shadow_str_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_str_q.each", "seq:1:2");
    aip_cmdline_override::set_val("strict.shadow_str_q", "left,right");
    `aip_str_queue("strict", shadow_str_q, "", -1)
    check(shadow_str_q.size() == 2 && shadow_str_q[0] == "left" &&
          shadow_str_q[1] == "right",
          "string overall winners suppress unsupported shadowed each");

    aip_cmdline_override::set_val("strict.shadow_real_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_real_q.each", "not-a-real");
    aip_cmdline_override::set_val("strict.shadow_real_q", "1.25,2.5");
    `aip_real_queue("strict", shadow_real_q, 0.0, -1)
    check(shadow_real_q.size() == 2 && shadow_real_q[0] == 1.25 &&
          shadow_real_q[1] == 2.5,
          "real overall winners suppress malformed shadowed each");

    aip_cmdline_override::set_val("strict.shadow_enum_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_enum_q.each", "NOT_A_MODE");
    aip_cmdline_override::set_val("strict.shadow_enum_q", "Q_IDLE,Q_BUSY");
    `aip_enum_queue("strict", q_mode_t, shadow_enum_q, Q_DONE, -1)
    check(shadow_enum_q.size() == 2 && shadow_enum_q[0] == Q_IDLE &&
          shadow_enum_q[1] == Q_BUSY,
          "enum overall winners suppress malformed shadowed each");
    $display("CMDLINE_STRICT_QUEUE_SHADOW_INVALID_PASS");
  endtask

  task automatic run_shadow_rng();
    int unsigned seed;
    int unsigned expected_next;
    int unsigned actual_next;

    seed = 32'h31415926;
    void'($urandom(seed));
    expected_next = $urandom();
    seed = 32'h31415926;
    void'($urandom(seed));
    aip_cmdline_override::set_val("strict.shadow_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_q.each", "[1:100]");
    aip_cmdline_override::set_val("strict.shadow_q", "11");
    aip_cmdline_override::set_val("strict.shadow_q[1]", "22");
    `aip_int_queue("strict", int, shadow_q, 0, -1)
    actual_next = $urandom();
    check(actual_next == expected_next,
          "fixed winners do not consume RNG through shadowed each rules");

    seed = 32'h27182818;
    void'($urandom(seed));
    expected_next = $urandom();
    seed = 32'h27182818;
    void'($urandom(seed));
    aip_cmdline_override::set_val("strict.shadow_overall_q", "[1:100]");
    aip_cmdline_override::set_val("strict.shadow_overall_q[0]", "33");
    `aip_int_queue("strict", int, shadow_overall_q, 0, -1)
    actual_next = $urandom();
    check(shadow_overall_q.size() == 1 && shadow_overall_q[0] == 33,
          "indexed winner shadows an overall random expression");
    check(actual_next == expected_next,
          "indexed winner does not consume RNG through shadowed overall rule");

    seed = 32'h42424242;
    void'($urandom(seed));
    expected_next = $urandom();
    seed = 32'h42424242;
    void'($urandom(seed));
    aip_cmdline_override::set_val("strict.shadow_str_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_str_q.each", "a,b");
    aip_cmdline_override::set_val("strict.shadow_str_q", "left,right");
    `aip_str_queue("strict", shadow_str_q, "", -1)
    aip_cmdline_override::set_val("strict.shadow_real_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_real_q.each", "[1.0:2.0]");
    aip_cmdline_override::set_val("strict.shadow_real_q", "1.25,2.5");
    `aip_real_queue("strict", shadow_real_q, 0.0, -1)
    aip_cmdline_override::set_val("strict.shadow_enum_q.size", "2");
    aip_cmdline_override::set_val("strict.shadow_enum_q.each", "Q_IDLE,Q_BUSY");
    aip_cmdline_override::set_val("strict.shadow_enum_q", "Q_BUSY,Q_DONE");
    `aip_enum_queue("strict", q_mode_t, shadow_enum_q, Q_IDLE, -1)
    actual_next = $urandom();
    check(actual_next == expected_next,
          "string, real, and enum fixed winners suppress shadowed RNG draws");
    $display("CMDLINE_STRICT_QUEUE_SHADOW_RNG_PASS");
  endtask

  task automatic run_perm_rng();
    int unsigned seed;
    int unsigned expected_next;
    int unsigned actual_next;

    seed = 32'h16180339;
    void'($urandom(seed));
    void'($urandom_range(3));
    void'($urandom_range(2));
    void'($urandom_range(1));
    expected_next = $urandom();
    seed = 32'h16180339;
    void'($urandom(seed));
    aip_cmdline_override::set_val("strict.perm_shadow_q", "perm:1:4");
    for (int i = 0; i < 4; i++)
      aip_cmdline_override::set_val($sformatf("strict.perm_shadow_q[%0d]", i),
                                    $sformatf("%0d", 40 + i));
    `aip_int_queue("strict", int, perm_shadow_q, 0, -1)
    actual_next = $urandom();
    check(perm_shadow_q.size() == 4 && perm_shadow_q[0] == 40 &&
          perm_shadow_q[3] == 43,
          "indexed winners still replace all permutation values");
    check(actual_next == expected_next,
          "fully shadowed perm consumes exactly its complete shuffle");
    $display("CMDLINE_STRICT_QUEUE_PERM_RNG_PASS");
  endtask

  task automatic run_unique_later_fixed();
    int unsigned seed;
    int fixed_value;

    seed = 32'h12345678;
    void'($urandom(seed));
    fixed_value = ($urandom_range(1) == 0) ? 10 : 20;
    seed = 32'h12345678;
    void'($urandom(seed));
    aip_cmdline_override::set_val("strict.unique_later_fixed_q.size", "2");
    aip_cmdline_override::set_val("strict.unique_later_fixed_q.each", "10,20");
    aip_cmdline_override::set_val("strict.unique_later_fixed_q.unique", "1");
    aip_cmdline_override::set_val("strict.unique_later_fixed_q[1]",
                                  $sformatf("%0d", fixed_value));
    `aip_int_queue("strict", int, unique_later_fixed_q, 0, -1)
    check(unique_later_fixed_q.size() == 2 &&
          unique_later_fixed_q[0] != unique_later_fixed_q[1] &&
          unique_later_fixed_q[1] == fixed_value,
          "each slot redraws against a later fixed winner");
    $display("CMDLINE_STRICT_QUEUE_UNIQUE_LATER_FIXED_PASS");
  endtask

  task automatic run_large_struct_shrink();
    item_t item;
    struct_q.delete();
    item.value = 0;
    item.opaque_value = 0;
    item.opaque = null;
    for (int i = 0; i < 1000001; i++) struct_q.push_back(item);
    struct_q[0].opaque_value = 101;
    struct_q[0].opaque = new(1001);
    struct_q[1].opaque_value = 202;
    struct_q[1].opaque = new(2002);
    aip_cmdline_override::set_val("strict.struct_q.size", "2");
    aip_cmdline_override::set_val("strict.struct_q[0].value", "20");
    aip_cmdline_override::set_val("strict.struct_q[1].value", "10");
    aip_cmdline_override::set_val("strict.struct_q.each.value.sort", "asc");
    `aip_struct_queue_apply("strict.struct_q", item_t, struct_q, 0, 2)
    check(struct_q.size() == 2 && struct_q[0].value == 10 &&
          struct_q[0].opaque_value == 202 && struct_q[0].opaque != null &&
          struct_q[0].opaque.cookie == 2002,
          "large shrink preserves the overlapping second opaque record");
    check(struct_q[1].value == 20 && struct_q[1].opaque_value == 101 &&
          struct_q[1].opaque != null && struct_q[1].opaque.cookie == 1001,
          "large shrink preserves the overlapping first opaque record");
    $display("CMDLINE_STRICT_QUEUE_LARGE_STRUCT_SHRINK_PASS");
  endtask

  initial begin
    if ($test$plusargs("STRICT_QUEUE_POSITIVE")) begin
      run_positive();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_EVAL_ONCE")) begin
      run_eval_once();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_STRUCT_REAPPLY")) begin
      run_struct_sort_reapply();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_SUMMARY")) begin
      run_summary();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_SHADOW_INVALID")) begin
      run_shadow_invalid();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_SHADOW_RNG")) begin
      run_shadow_rng();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_PERM_RNG")) begin
      run_perm_rng();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_UNIQUE_LATER_FIXED")) begin
      run_unique_later_fixed();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_LARGE_STRUCT_SHRINK")) begin
      run_large_struct_shrink();
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_STRING_BRACKET_UNIQUE")) begin
      `aip_str_queue("strict", str_q, "", -1)
      check(str_q.size() == 3 &&
            str_q[0] != str_q[1] && str_q[0] != str_q[2] &&
            str_q[1] != str_q[2] && str_q[2] == "c",
            "bracketed string list retains three unique candidates");
      $display("CMDLINE_STRICT_QUEUE_STRING_BRACKET_UNIQUE_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_STRING_BRACKET_EMPTY_UNIQUE")) begin
      `aip_str_queue("strict", str_q, "", -1)
      check(str_q.size() == 1 && str_q[0] == "",
            "empty bracket string candidate");
      $display("CMDLINE_STRICT_QUEUE_STRING_BRACKET_EMPTY_UNIQUE_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_INT_OOB")) begin
      aip_cmdline_override::set_val("strict.int_q.size", "1");
      aip_cmdline_override::set_val("strict.int_q[2]", "9");
      `aip_int_queue("strict", int, int_q, 5, -1)
      $display("CMDLINE_STRICT_QUEUE_INT_OOB_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_SEQ_SIZE")) begin
      aip_cmdline_override::set_val("strict.int_q.size", "4");
      aip_cmdline_override::set_val("strict.int_q", "seq:1:3");
      `aip_int_queue("strict", int, int_q, 0, -1)
      $display("CMDLINE_STRICT_QUEUE_SEQ_SIZE_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_STRING_GENERATOR")) begin
      aip_cmdline_override::set_val("strict.str_q", "seq:1:3");
      `aip_str_queue("strict", str_q, "", -1)
      $display("CMDLINE_STRICT_QUEUE_STRING_GENERATOR_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_REAL_GENERATOR")) begin
      aip_cmdline_override::set_val("strict.real_q", "perm:1:3");
      `aip_real_queue("strict", real_q, 0.0, -1)
      $display("CMDLINE_STRICT_QUEUE_REAL_GENERATOR_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_ENUM_GENERATOR")) begin
      aip_cmdline_override::set_val("strict.enum_q", "seq:1:3");
      `aip_enum_queue("strict", q_mode_t, enum_q, Q_IDLE, -1)
      $display("CMDLINE_STRICT_QUEUE_ENUM_GENERATOR_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_BOUND_MISMATCH")) begin
      aip_cmdline_override::set_val("strict.bounded_q.size", "3");
      aip_cmdline_override::set_val("strict.bounded_q", "1,2,3");
      `aip_int_queue("strict", int, bounded_q, 0, 3)
      $display("CMDLINE_STRICT_QUEUE_BOUND_MISMATCH_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_SIZE_LIMIT")) begin
      aip_cmdline_override::set_val("strict.int_q.size", "1000001");
      `aip_int_queue("strict", int, int_q, 0, -1)
      $display("CMDLINE_STRICT_QUEUE_SIZE_LIMIT_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_ENUM_DEFAULT_INVALID")) begin
      aip_cmdline_override::set_val("strict.enum_q.size", "1");
      `aip_enum_queue("strict", q_mode_t, enum_q, q_mode_t'(3), -1)
      $display("CMDLINE_STRICT_QUEUE_ENUM_DEFAULT_INVALID_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_FIXED_COLLISION")) begin
      aip_cmdline_override::set_val("strict.fixed_collision_q.size", "2");
      aip_cmdline_override::set_val("strict.fixed_collision_q[0]", "7");
      aip_cmdline_override::set_val("strict.fixed_collision_q[1]", "7");
      aip_cmdline_override::set_val("strict.fixed_collision_q.unique", "1");
      `aip_int_queue("strict", int, fixed_collision_q, 0, -1)
      $display("CMDLINE_STRICT_QUEUE_FIXED_COLLISION_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_CANDIDATE_SHORTAGE")) begin
      aip_cmdline_override::set_val("strict.shortage_q.size", "2");
      aip_cmdline_override::set_val("strict.shortage_q.each", "5");
      aip_cmdline_override::set_val("strict.shortage_q.unique", "1");
      `aip_int_queue("strict", int, shortage_q, 0, -1)
      $display("CMDLINE_STRICT_QUEUE_CANDIDATE_SHORTAGE_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_INTEGRAL_XZ")) begin
      aip_cmdline_override::set_val("strict.narrow_q", "8'hx");
      `aip_int_queue("strict", narrow_t, narrow_q, '0, -1)
      $display("CMDLINE_STRICT_QUEUE_INTEGRAL_XZ_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_INTEGRAL_OVERFLOW")) begin
      aip_cmdline_override::set_val("strict.narrow_q", "256");
      `aip_int_queue("strict", narrow_t, narrow_q, '0, -1)
      $display("CMDLINE_STRICT_QUEUE_INTEGRAL_OVERFLOW_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_INTEGRAL_MALFORMED")) begin
      aip_cmdline_override::set_val("strict.narrow_q", "12oops");
      `aip_int_queue("strict", narrow_t, narrow_q, '0, -1)
      $display("CMDLINE_STRICT_QUEUE_INTEGRAL_MALFORMED_UNEXPECTED_PASS");
      $finish;
    end
    if ($test$plusargs("STRICT_QUEUE_LEGACY_DIAGNOSTIC")) begin
      aip_cmdline_override::set_val("strict.legacy_int_q", "12oops");
      `aip_int_list("strict", int, legacy_int_q, 0)
      $display("CMDLINE_STRICT_QUEUE_LEGACY_DIAGNOSTIC_UNEXPECTED_PASS");
      $finish;
    end
    $fatal(1, "select one strict queue scenario");
  end
endmodule

`ifdef AIP_STRICT_QUEUE_WIDTH_FAIL
module test_cmdline_strict_queue_width_fail;
  typedef logic [1024:0] too_wide_t;
  too_wide_t too_wide_q[$];
  initial begin
    `aip_int_queue("strict", too_wide_t, too_wide_q, '0, -1)
  end
endmodule
`endif
