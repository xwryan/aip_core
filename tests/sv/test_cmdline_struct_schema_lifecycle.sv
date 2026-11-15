`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_struct_schema_lifecycle;
  class counters;
    static int root_calls;
    static int default_calls;
    static int max_calls;
    static string last_root;
    static int last_default_size;
    static int last_max_size;
    // The runtime argument keeps VCS from folding the call, so the counters measure the macro's
    // own argument evaluation; a second evaluation returns an invalid value so duplicates fail.
    static function string get_root_name(input int unsigned runtime_nonce);
      root_calls++;
      if (root_calls == 1)
        last_root = runtime_nonce[0] ? "life.records.alt" : "life.records";
      else
        last_root = "";
      return last_root;
    endfunction
    static function int get_default_size(input int unsigned runtime_nonce);
      default_calls++;
      last_default_size = (default_calls == 1) ? (runtime_nonce[0] ? 2 : 3) : -1;
      return last_default_size;
    endfunction
    static function int get_max_size(input int unsigned runtime_nonce);
      max_calls++;
      last_max_size = (max_calls == 1) ? (runtime_nonce[0] ? 4 : 5) : -1;
      return last_max_size;
    endfunction
    static function int root_count(); return root_calls; endfunction
    static function int default_count(); return default_calls; endfunction
    static function int max_count(); return max_calls; endfunction
  endclass
  class payload_c;
    int tag;
    function new(int t = 0); tag = t; endfunction
  endclass

  typedef struct { int value; int opaque; payload_c handle; } child_t;
  `aip_struct_type_begin(child_t)
    `aip_field_int(int, value, 0)
  `aip_struct_type_end(child_t)

  typedef struct {
    int value;
    int opaque;
    payload_c handle;
    child_t static_kids[2];
    child_t dynamic_kids[];
  } record_t;
  `aip_struct_type_begin(record_t)
    `aip_field_int(int, value, 0)
    `aip_field_struct_sarray(child_t, static_kids)
    `aip_field_struct_darray(child_t, dynamic_kids, 0)
  `aip_struct_type_end(record_t)

  typedef enum { E_ZERO, E_ONE, E_TWO } e_t;
  typedef struct {
    int ints[];
    string strs[];
    real reals[];
    e_t enums[];
  } zero_t;
  `aip_struct_type_begin(zero_t)
    `aip_field_int_darray(int, ints, 7, 3)
    `aip_field_string_darray(strs, "default", 3)
    `aip_field_real_darray(reals, 1.5, 3)
    `aip_field_enum_darray(e_t, enums, E_ONE, 3)
  `aip_struct_type_end(zero_t)

  record_t records[];
  record_t eval_records[];
  record_t static_records[2];
  record_t scalar_record;
  record_t queue[$];
  zero_t zero_record;
  int runtime_nonce;
  initial begin
    if ($test$plusargs("AIP_TEST_LIFECYCLE_REPEAT")) begin
      aip_cmdline_override::set_val("life.records.size", "2");
      aip_cmdline_override::set_val("life.records.value", "10,20");
      aip_cmdline_override::set_val("life.records[0].static_kids[0].value", "101");
      aip_cmdline_override::set_val("life.records[0].dynamic_kids.size", "1");
      aip_cmdline_override::set_val("life.records[0].dynamic_kids[0].value", "201");
      `aip_struct_darray_apply("life.records", record_t, records, 0)
      records[0].opaque = 9001;
      records[1].opaque = 9002;
      records[0].handle = new(91);
      records[1].handle = new(92);
      records[0].static_kids[0].opaque = 9101;
      records[0].static_kids[0].handle = new(911);
      records[0].dynamic_kids[0].opaque = 9201;
      records[0].dynamic_kids[0].handle = new(921);

      aip_cmdline_override::set_val("life.records.size", "3");
      aip_cmdline_override::set_val("life.records.value", "30,40,50");
      `aip_struct_darray_apply("life.records", record_t, records, 0)
      if (records.size() != 3 || records[0].value != 30 || records[1].value != 40 ||
          records[0].opaque != 9001 || records[1].opaque != 9002 ||
          records[0].handle == null || records[0].handle.tag != 91 ||
          records[1].handle == null || records[1].handle.tag != 92)
        $fatal(1, "top-level repeated apply lost opaque member or handle");
      if (records[0].static_kids[0].opaque != 9101 ||
          records[0].static_kids[0].handle == null ||
          records[0].static_kids[0].handle.tag != 911)
        $fatal(1, "nested static struct-array repeated apply lost old record");
      if (records[0].dynamic_kids.size() != 1 ||
          records[0].dynamic_kids[0].opaque != 9201 ||
          records[0].dynamic_kids[0].handle == null ||
          records[0].dynamic_kids[0].handle.tag != 921)
        $fatal(1, "nested dynamic struct-array repeated apply lost old record");
      if (records[2].opaque != 0 || records[2].handle != null)
        $fatal(1, "new record did not begin with default opaque state");
      $display("CMDLINE_STRUCT_SCHEMA_LIFECYCLE_REPEAT_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_LIFECYCLE_EVAL_ONCE")) begin
      runtime_nonce = $urandom();
      counters::root_calls = 0; counters::default_calls = 0; counters::max_calls = 0;
      aip_cmdline_override::clear_all();
      aip_cmdline_override::set_val("life.records.value", "11");
      aip_cmdline_override::set_val("life.records.alt.value", "22");
      `aip_struct_apply(counters::get_root_name(runtime_nonce), record_t, scalar_record)
      if ((counters::last_root == "life.records" && scalar_record.value != 11) ||
          (counters::last_root == "life.records.alt" && scalar_record.value != 22))
        $fatal(1, "scalar apply did not use runtime ROOT result");
      $display("COUNTS_SCALAR direct=%0d,%0d,%0d method=%0d,%0d,%0d", counters::root_calls, counters::default_calls, counters::max_calls, counters::root_count(), counters::default_count(), counters::max_count());
      if (counters::root_count() != 1 || counters::default_count() != 0 ||
          counters::max_count() != 0)
        $fatal(1, "scalar apply evaluated ROOT=%0d DEFAULT_SIZE=%0d MAX_SIZE=%0d times",
               counters::root_count(), counters::default_count(), counters::max_count());
      counters::root_calls = 0; counters::default_calls = 0;
      aip_cmdline_override::clear_all();
      `aip_struct_darray_apply(counters::get_root_name(runtime_nonce), record_t, eval_records, counters::get_default_size(runtime_nonce))
      $display("COUNTS_DARRAY root=%0d default=%0d max=%0d size=%0d", counters::root_calls, counters::default_calls, counters::max_calls, eval_records.size());
      if (eval_records.size() != counters::last_default_size)
        $fatal(1, "dynamic apply did not reuse ROOT/DEFAULT_SIZE entry values");
      if (counters::root_calls != 1 || counters::default_calls != 1 ||
          counters::max_calls != 0)
        $fatal(1, "dynamic apply evaluated ROOT=%0d DEFAULT_SIZE=%0d MAX_SIZE=%0d times",
               counters::root_calls, counters::default_calls, counters::max_calls);
      counters::root_calls = 0; counters::default_calls = 0; counters::max_calls = 0;
      aip_cmdline_override::clear_all();
      aip_cmdline_override::set_val("life.records[0].value", "31");
      aip_cmdline_override::set_val("life.records[1].value", "32");
      aip_cmdline_override::set_val("life.records.alt[0].value", "41");
      aip_cmdline_override::set_val("life.records.alt[1].value", "42");
      `aip_struct_sarray_apply(counters::get_root_name(runtime_nonce), record_t, static_records)
      $display("COUNTS_SARRAY root=%0d default=%0d max=%0d", counters::root_calls, counters::default_calls, counters::max_calls);
      if ((counters::last_root == "life.records" &&
           (static_records[0].value != 31 || static_records[1].value != 32)) ||
          (counters::last_root == "life.records.alt" &&
           (static_records[0].value != 41 || static_records[1].value != 42)))
        $fatal(1, "static-array apply did not use runtime ROOT result");
      if (counters::root_calls != 1 || counters::default_calls != 0 ||
          counters::max_calls != 0)
        $fatal(1, "static-array apply evaluated ROOT=%0d DEFAULT_SIZE=%0d MAX_SIZE=%0d times",
               counters::root_calls, counters::default_calls, counters::max_calls);
      counters::root_calls = 0; counters::default_calls = 0; counters::max_calls = 0;
      aip_cmdline_override::clear_all();
      `aip_struct_queue_apply(counters::get_root_name(runtime_nonce), record_t, queue, counters::get_default_size(runtime_nonce), counters::get_max_size(runtime_nonce))
      $display("COUNTS_QUEUE root=%0d default=%0d max=%0d size=%0d", counters::root_calls, counters::default_calls, counters::max_calls, queue.size());
      if (queue.size() != counters::last_default_size)
        $fatal(1, "queue apply did not reuse ROOT/DEFAULT_SIZE/MAX_SIZE entry values");
      if (counters::root_calls != 1 || counters::default_calls != 1 ||
          counters::max_calls != 1)
        $fatal(1, "queue apply evaluated ROOT=%0d DEFAULT_SIZE=%0d MAX_SIZE=%0d times",
               counters::root_calls, counters::default_calls, counters::max_calls);
      $display("CMDLINE_STRUCT_SCHEMA_LIFECYCLE_EVAL_PASS");
      $finish;
    end

    if ($test$plusargs("AIP_TEST_LIFECYCLE_EXPLICIT_ZERO")) begin
      aip_cmdline_override::set_val("life.zero.ints.size", "0");
      aip_cmdline_override::set_val("life.zero.strs.size", "0");
      aip_cmdline_override::set_val("life.zero.reals.size", "0");
      aip_cmdline_override::set_val("life.zero.enums.size", "0");
      `aip_struct_apply("life.zero", zero_t, zero_record)
      if (zero_record.ints.size() != 0 || zero_record.strs.size() != 0 ||
          zero_record.reals.size() != 0 || zero_record.enums.size() != 0)
        $fatal(1, "explicit primitive array size=0 was re-expanded by DEFAULT_SIZE");
      $display("CMDLINE_STRUCT_SCHEMA_LIFECYCLE_ZERO_PASS");
      $finish;
    end

    $fatal(1, "missing lifecycle selector");
  end
endmodule
