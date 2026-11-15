`include "aip_log.sv"
`include "aip_cmdline.sv"

// Queue API coverage.  The QUEUE_OVERFLOW invocation is intentionally a
// negative runtime probe; the Makefile target runs it separately and expects
// the bounded-capacity check to terminate the simulation.
module test_cmdline_struct_schema_queue;
  typedef enum { Q_IDLE, Q_BUSY, Q_DONE } q_mode_t;

  class opaque_box;
    int cookie;
    function new(int c = 0); cookie = c; endfunction
  endclass

  typedef struct {
    int       value;
    string    label;
    q_mode_t  mode;
    opaque_box opaque;
    int       unregistered;
  } item_t;

  `aip_struct_type_begin(item_t)
    `aip_field_int(int, value, 0)
    `aip_field_string(label, "default")
    `aip_field_enum(q_mode_t, mode, Q_IDLE)
  `aip_struct_type_end(item_t)

  item_t items_q[$];
  item_t bounded_items_q[$:2];
  int    int_q[$];
  int    bounded_int_q[$:2];
  string str_q[$];
  real   real_q[$];
  q_mode_t enum_q[$];
  item_t function_q[$];

  class holder;
    item_t cfg_q[$];
  endclass
  holder obj;

  task automatic check(bit condition, string message);
    if (!condition) $fatal(1, "QUEUE_CHECK_FAIL: %s", message);
  endtask

  // A function call is part of the compile probe: queue macros must not
  // require an unbounded ref queue formal, which rejects bounded queues.
  function automatic void apply_from_function();
    `aip_struct_queue_apply("dut.function_q", item_t, function_q, 1, -1)
  endfunction

  initial begin
    int before_info;

    if ($test$plusargs("QUEUE_OVERFLOW")) begin
      // Explicitly request four records for a queue whose API capacity is 3.
      aip_cmdline_override::set_val("dut.bounded_items.size", "4");
      `aip_struct_queue_apply("dut.bounded_items", item_t,
                              bounded_items_q, 0, 3)
      $fatal(1, "bounded queue overflow was silently accepted");
    end

    obj = new();

    // Unbounded struct queue, indexed fields, object member target, and a
    // function-scope invocation all exercise the direct-copy queue path.
    aip_cmdline_override::set_val("dut.items.size", "2");
    aip_cmdline_override::set_val("dut.items[0].value", "22");
    aip_cmdline_override::set_val("dut.items[1].value", "11");
    aip_cmdline_override::set_val("dut.items[0].label", "first");
    aip_cmdline_override::set_val("dut.items[1].label", "second");
    aip_cmdline_override::set_val("dut.items.value.sort", "none");
    `aip_struct_queue_apply("dut.items", item_t, items_q, 0, -1)
    check(items_q.size() == 2, "unbounded struct queue size");
    check(items_q[0].value == 22 && items_q[1].value == 11,
          "sort=none preserves struct queue order");
    check(items_q[0].label == "first" && items_q[1].label == "second",
          "unbounded struct queue indexed strings");

    aip_cmdline_override::set_val("dut.objq.size", "1");
    aip_cmdline_override::set_val("dut.objq[0].value", "31");
    `aip_struct_queue_apply("dut.objq", item_t, obj.cfg_q, 0, -1)
    check(obj.cfg_q.size() == 1 && obj.cfg_q[0].value == 31,
          "object-member struct queue target");
    apply_from_function();
    check(function_q.size() == 1, "function-scope queue apply");

    // Bounded struct queue uses an explicit API capacity ([$:2] == 3 slots).
    aip_cmdline_override::set_val("dut.bounded_items.size", "3");
    aip_cmdline_override::set_val("dut.bounded_items[0].value", "41");
    aip_cmdline_override::set_val("dut.bounded_items[1].value", "42");
    aip_cmdline_override::set_val("dut.bounded_items[2].value", "43");
    `aip_struct_queue_apply("dut.bounded_items", item_t,
                            bounded_items_q, 0, 3)
    check(bounded_items_q.size() == 3, "bounded struct queue size");
    check(bounded_items_q[2].value == 43, "bounded struct queue tail");

    // Primitive queues retain list-compatible value grammar and defaults.
    aip_cmdline_override::set_val("dut.int_q", "1,2,3");
    aip_cmdline_override::set_val("dut.bounded_int_q", "4,5,6");
    aip_cmdline_override::set_val("dut.str_q", "left,right");
    aip_cmdline_override::set_val("dut.real_q", "1.5,2.5");
    aip_cmdline_override::set_val("dut.enum_q", "Q_BUSY,Q_DONE");
    `aip_int_queue("dut", int, int_q, 0, -1)
    `aip_int_queue("dut", int, bounded_int_q, 0, 3)
    `aip_str_queue("dut", str_q, "", -1)
    `aip_real_queue("dut", real_q, 0.0, -1)
    `aip_enum_queue("dut", q_mode_t, enum_q, Q_IDLE, -1)
    check(int_q.size() == 3 && int_q[0] == 1 && int_q[2] == 3,
          "primitive int queue");
    check(bounded_int_q.size() == 3 && bounded_int_q[1] == 5,
          "primitive bounded int queue");
    check(str_q.size() == 2 && str_q[0] == "left" && str_q[1] == "right",
          "primitive string queue");
    check(real_q.size() == 2 && real_q[0] > 1.49 && real_q[1] < 2.51,
          "primitive real queue");
    check(enum_q.size() == 2 && enum_q[0] == Q_BUSY && enum_q[1] == Q_DONE,
          "primitive enum queue");

    // Repeated apply must preserve unregistered struct members by index.
    items_q[0].unregistered = 77;
    items_q[0].opaque = new(1234);
    aip_cmdline_override::clear("dut.items[0].value");
    aip_cmdline_override::clear("dut.items[1].value");
    `aip_struct_queue_apply("dut.items", item_t, items_q, 0, -1)
    check(items_q[0].unregistered == 77 && items_q[0].opaque != null,
          "repeat apply preserves opaque/unregistered members");
    check(items_q[0].opaque.cookie == 1234, "opaque handle shallow copy");

    // One bounded registration summary per ROOT; print control suppresses the
    // second invocation and can disable summaries without disabling parsing.
    aip_cmdline_print_control::configure(1, 1);
    before_info = aip_log::get_count(aip_log::INFO);
    aip_cmdline_override::set_val("dut.int_q", "7");
    `aip_int_queue("dut", int, int_q, 0, -1)
    `aip_int_queue("dut", int, int_q, 0, -1)
    check(aip_log::get_count(aip_log::INFO) - before_info == 1,
          "per-ROOT registration summary throttling");
    aip_cmdline_print_control::configure(0, 10);
    before_info = aip_log::get_count(aip_log::INFO);
    `aip_int_queue("dut", int, int_q, 0, -1)
    check(aip_log::get_count(aip_log::INFO) - before_info == 0,
          "print_enable suppresses queue summary");
    check(int_q.size() == 1 && int_q[0] == 7,
          "print control does not disable queue parsing");

    $display("CMDLINE_STRUCT_SCHEMA_QUEUE_PASS");
    $finish;
  end
endmodule
