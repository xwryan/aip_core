`include "aip_log.sv"
`include "aip_cmdline.sv"
module test_cmdline_struct_schema_primitive_arrays;
  typedef enum logic [63:0] {
    ELOW  = 64'h0000_0000_0000_0001,
    EMID  = 64'h0000_0001_0000_0000,
    EHIGH = 64'h0000_0002_0000_0000
  } wide_e;
  typedef struct { int ia[3]; string sa[3]; string sd[2]; real ra[3]; wide_e mode; wide_e ea[3]; } rec_t;
  `aip_struct_type_begin(rec_t)
    `aip_field_int_sarray(int, ia, 0)
    `aip_field_string_sarray(sa, "")
    `aip_field_string_sarray(sd, "kept")
    `aip_field_real_sarray(ra, 0.0)
    `aip_field_enum(wide_e, mode, ELOW)
    `aip_field_enum_sarray(wide_e, ea, ELOW)
  `aip_struct_type_end(rec_t)
  rec_t r;
  typedef struct { int ia[]; string sa[]; real ra[]; wide_e mode; wide_e ea[]; } drec_t;
  `aip_struct_type_begin(drec_t)
    `aip_field_int_darray(int, ia, 0)
    `aip_field_string_darray(sa, "", 0)
    `aip_field_real_darray(ra, 0.0, 0)
    `aip_field_enum(wide_e, mode, ELOW)
    `aip_field_enum_darray(wide_e, ea, ELOW, 0)
  `aip_struct_type_end(drec_t)
  drec_t d;
  localparam int PRIM_DEFAULT_SIZE = 1 + 2;
  typedef struct { int ia[]; string sa[]; real ra[]; wide_e ea[]; } sized_t;
  `aip_struct_type_begin(sized_t)
    `aip_field_int_darray(int, ia, 7, PRIM_DEFAULT_SIZE)
    `aip_field_string_darray(sa, "fill", PRIM_DEFAULT_SIZE)
    `aip_field_real_darray(ra, 2.5, PRIM_DEFAULT_SIZE)
    `aip_field_enum_darray(wide_e, ea, EMID, PRIM_DEFAULT_SIZE)
  `aip_struct_type_end(sized_t)
  sized_t sized;
  typedef struct { int id; int tags[3]; int marker; } tagged_rec_t;
  `aip_struct_type_begin(tagged_rec_t)
    `aip_field_int(int, id, 0)
    `aip_field_int_sarray(int, tags, 0)
  `aip_struct_type_end(tagged_rec_t)
  tagged_rec_t cfgs[2];
  initial begin
    if ($test$plusargs("AIP_TEST_PRIM_SORT")) begin
      `aip_struct_apply("prim", rec_t, r)
      if (r.ia[0] != 1 || r.ia[1] != 2 || r.ia[2] != 3) $fatal(1,"int sort");
      if (r.sa[0] != "A" || r.sa[1] != "a" || r.sa[2] != "b") $fatal(1,"string sort");
      if (r.ra[0] != 1.25 || r.ra[1] != 2.5 ||
          r.ra[2] != 1.7976931348623157e308) $fatal(1,"real sort");
      if (r.ea[0] != ELOW || r.ea[1] != EMID || r.ea[2] != EHIGH) $fatal(1,"enum sort");
      if (r.mode != EHIGH) $fatal(1,"wide enum scalar");
      $display("CMDLINE_STRUCT_PRIM_SORT_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_INNER_SORT")) begin
      foreach (cfgs[i]) cfgs[i].marker = 700 + i;
      `aip_struct_sarray_apply("cfgs", tagged_rec_t, cfgs)
      if (cfgs[0].id != 20 || cfgs[1].id != 10 ||
          cfgs[0].marker != 700 || cfgs[1].marker != 701)
        $fatal(1,"primitive array sort became outer whole-record sort key");
      if (cfgs[0].tags[0] != 1 || cfgs[0].tags[1] != 2 || cfgs[0].tags[2] != 3 ||
          cfgs[1].tags[0] != 4 || cfgs[1].tags[1] != 5 || cfgs[1].tags[2] != 6)
        $fatal(1,"per-record primitive array sort");
      $display("CMDLINE_STRUCT_PRIM_INNER_SORT_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_UNSUPPORTED") ||
        $test$plusargs("AIP_TEST_PRIM_UNSUPPORTED_REAL") ||
        $test$plusargs("AIP_TEST_PRIM_UNSUPPORTED_ENUM")) begin
      `aip_struct_apply("prim", rec_t, r)
      $fatal(1,"expected unsupported generator to fail");
    end
    if ($test$plusargs("AIP_TEST_PRIM_REAL_BAD")) begin
      `aip_struct_apply("prim", rec_t, r)
      $fatal(1,"expected bad real to fail");
    end
    if ($test$plusargs("AIP_TEST_PRIM_DYN")) begin
      `aip_struct_apply("dyn", drec_t, d)
      if (d.ia.size()!=3 || d.ia[0]!=1 || d.sa[0]!="a" || d.ea[0]!=ELOW || d.mode != EHIGH) $fatal(1,"dynamic primitive arrays");
      if (d.ia[0] == d.ia[1] || d.ia[0] == d.ia[2] || d.ia[1] == d.ia[2]) $fatal(1,"dynamic integral unique");
      $display("CMDLINE_STRUCT_PRIM_DYN_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_DEFAULT_EACH")) begin
      `aip_struct_apply("defaults", sized_t, sized)
      if (sized.ia.size() != PRIM_DEFAULT_SIZE ||
          sized.sa.size() != PRIM_DEFAULT_SIZE ||
          sized.ra.size() != PRIM_DEFAULT_SIZE ||
          sized.ea.size() != PRIM_DEFAULT_SIZE)
        $fatal(1,"positive DEFAULT_SIZE with .each did not materialize all arrays");
      foreach (sized.ia[i]) if (sized.ia[i] != 7) $fatal(1,"int DEFAULT_SIZE each value");
      foreach (sized.sa[i]) if (sized.sa[i] != "fill") $fatal(1,"string DEFAULT_SIZE each value");
      foreach (sized.ra[i]) if (sized.ra[i] != 2.5) $fatal(1,"real DEFAULT_SIZE each value");
      foreach (sized.ea[i]) if (sized.ea[i] != EMID) $fatal(1,"enum DEFAULT_SIZE each value");
      $display("CMDLINE_STRUCT_PRIM_DEFAULT_EACH_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_EACH_UNKNOWN")) begin
      `aip_struct_apply("unknown", drec_t, d)
      $fatal(1,"expected each-only primitive array with no positive size source to fail");
    end
    if ($test$plusargs("AIP_TEST_PRIM_INT_GENERATOR")) begin
      `aip_struct_apply("igen_static", rec_t, r)
      if (r.ia[0] != 1 || r.ia[1] != 2 || r.ia[2] != 3)
        $fatal(1,"static integral seq generator");
      `aip_struct_apply("igen_dynamic", drec_t, d)
      if (d.ia.size() != 4 || d.ia[0] < 1 || d.ia[0] > 4 ||
          d.ia[1] < 1 || d.ia[1] > 4 || d.ia[2] < 1 || d.ia[2] > 4 ||
          d.ia[3] < 1 || d.ia[3] > 4 ||
          d.ia[0] == d.ia[1] || d.ia[0] == d.ia[2] || d.ia[0] == d.ia[3] ||
          d.ia[1] == d.ia[2] || d.ia[1] == d.ia[3] || d.ia[2] == d.ia[3])
        $fatal(1,"dynamic integral perm generator");
      $display("CMDLINE_STRUCT_PRIM_INT_GENERATOR_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_REAL_GRAMMAR")) begin
      `aip_struct_apply("grammar", drec_t, d)
      if (d.ra.size()!=8 || d.ra[0] < 1.0 || d.ra[0] > 3.0 ||
          d.ra[1] != 2.0 || d.ra[2] != 3.0 ||
          d.ra[3] < 4.0 || d.ra[3] > 5.0 ||
          d.ra[4] != 6.0 || d.ra[5] != 7.0 ||
          d.ra[6] != 8.0 || d.ra[7] != 9.0)
        $fatal(1,"real grammar");
      $display("CMDLINE_STRUCT_PRIM_REAL_GRAMMAR_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_REAL_SPARSE")) begin
      `aip_struct_apply("sparse", drec_t, d)
      if (d.ra.size()!=6 || d.ra[5] != 5.5) $fatal(1,"real sparse indexed inference");
      $display("CMDLINE_STRUCT_PRIM_REAL_SPARSE_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_EMPTY")) begin
      `aip_struct_apply("empty", rec_t, r)
      if (r.sa[0] != "" || r.sd[0] != "kept" || r.sd[1] != "kept")
        $fatal(1,"empty string found/default semantics");
      $display("CMDLINE_STRUCT_PRIM_EMPTY_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_STRING_REFILL")) begin
      `aip_struct_apply("strfill", rec_t, r)
      if (r.sa[0] == r.sa[1] || r.sa[0] == r.sa[2] || r.sa[1] == r.sa[2])
        $fatal(1,"string each unique refill");
      if (r.sa[2] != "c") $fatal(1,"string fixed later index");
      $display("CMDLINE_STRUCT_PRIM_STRING_REFILL_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_STRING_BRACKET_EMPTY_UNIQUE")) begin
      `aip_struct_apply("emptybr", drec_t, d)
      if (d.sa.size() != 1 || d.sa[0] != "")
        $fatal(1,"empty bracket string candidate");
      $display("CMDLINE_STRUCT_PRIM_STRING_BRACKET_EMPTY_UNIQUE_PASS"); $finish;
    end
    if ($test$plusargs("AIP_TEST_PRIM_REFILL")) begin
      `aip_struct_apply("refill", rec_t, r)
      $display("REF ra=%f,%f,%f ea=%s,%s,%s", r.ra[0], r.ra[1], r.ra[2], r.ea[0].name(), r.ea[1].name(), r.ea[2].name());
      if (r.ra[0] == r.ra[1] || r.ra[0] == r.ra[2] || r.ra[1] == r.ra[2]) $fatal(1,"real each unique refill");
      if (r.ra[2] != 2.0) $fatal(1,"real fixed later index");
      if (r.ea[0] == r.ea[1] || r.ea[0] == r.ea[2] || r.ea[1] == r.ea[2]) $fatal(1,"enum each unique refill");
      if (r.ea[2] != EHIGH) $fatal(1,"enum fixed later index");
      $display("CMDLINE_STRUCT_PRIM_REFILL_PASS"); $finish;
    end
    $fatal(1,"no selector");
  end
endmodule
