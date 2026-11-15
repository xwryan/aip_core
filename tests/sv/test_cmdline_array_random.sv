// tests/sv/test_cmdline_array_random.sv — array modes for dynamic and static arrays
`include "aip_log.sv"
`include "aip_cmdline.sv"

module test_cmdline_array_random;
    int failures = 0;
    string errcase;

    task automatic check_true(string label, bit condition);
        if (!condition) begin
            failures++;
            $error("%s", label);
        end
    endtask

    // existing behavior (must not change)
    int d_list[];
    int d_one[];
    int d_idx[];
    int s_list[4];
    int s_part[4];
    int d_each[];
    int d_rsize[];
    int d_ovr[];
    int d_part2[];
    int s_each[4];
    int s_ovr[4];
    int d_seq[];
    int d_perm[];
    int s_seq[4];
    int s_perm[4];
    int d_uni[];
    int d_unifix[];
    int s_uni[4];
    string d_suni[];
    int d_sort[];
    int d_sortd[];
    int s_sort[4];
    string d_sseq[];
    string d_ssort[];

    // error-case targets
    int e_dyn[];
    int e_st[4];
    int e_i;

    initial begin
        if ($value$plusargs("AIP_ARR_ERRCASE=%s", errcase)) begin
            case (errcase)
                "static_size", "static_long": `aip_int_slist("", int, e_st, 0)
                "size_lt_list":               `aip_int_list("", int, e_dyn, 0)
                "each_nosize":                `aip_int_list("", int, e_dyn, 0)
                "seq_static_len", "perm_static_len": `aip_int_slist("", int, e_st, 0)
                "seq_scalar":                        `aip_int("", int, e_i, 0)
                "unique_short", "unique_dup":        `aip_int_list("", int, e_dyn, 0)
                "bad_sort":                          `aip_int_list("", int, e_dyn, 0)
                "size_negative", "bad_unique":       `aip_int_list("", int, e_dyn, 0)
                default: $fatal(1, "unknown AIP_ARR_ERRCASE %s", errcase);
            endcase
            $display("ARR_ACCEPTED");
            $finish;
        end

        `aip_int_list("", int, d_list, 0);     // +d_list=1,2,3
        `aip_int_list("", int, d_one, 0);      // +d_one=[1:10]
        `aip_int_list("", int, d_idx, 0);      // +d_idx[2]=7
        `aip_int_slist("", int, s_list, 0);    // +s_list=[4,3,2,1]
        `aip_int_slist("", int, s_part, 9);    // +s_part=5,6

        check_true("d_list plain list", d_list.size() == 3 && d_list[0] == 1 && d_list[1] == 2 && d_list[2] == 3);
        check_true("d_one keeps one element", d_one.size() == 1 && d_one[0] >= 1 && d_one[0] <= 10);
        check_true("d_idx index override sizes array", d_idx.size() == 3 && d_idx[0] == 0 && d_idx[1] == 0 && d_idx[2] == 7);
        check_true("s_list full static list", s_list[0] == 4 && s_list[1] == 3 && s_list[2] == 2 && s_list[3] == 1);
        check_true("s_part tail gets default", s_part[0] == 5 && s_part[1] == 6 && s_part[2] == 9 && s_part[3] == 9);

        `aip_int_list("", int, d_each, 0);     // +d_each.size=8 +d_each.each=[1:10]
        `aip_int_list("", int, d_rsize, 0);    // +d_rsize.size=[4:16] +d_rsize.each=[100:200]
        `aip_int_list("", int, d_ovr, 0);      // +d_ovr.size=4 +d_ovr.each=[1:10] +d_ovr[0]=99
        `aip_int_list("", int, d_part2, 0);    // +d_part2.size=4 +d_part2=5,6 +d_part2.each=[100:200]
        `aip_int_slist("", int, s_each, 0);    // +s_each.each=[1:10]
        `aip_int_slist("", int, s_ovr, 0);     // +s_ovr.each=[1:10] +s_ovr[3]=42

        check_true("d_each size", d_each.size() == 8);
        foreach (d_each[i]) check_true("d_each element in [1:10]", d_each[i] >= 1 && d_each[i] <= 10);
        check_true("d_rsize random size in [4:16]", d_rsize.size() >= 4 && d_rsize.size() <= 16);
        foreach (d_rsize[i]) check_true("d_rsize element in [100:200]", d_rsize[i] >= 100 && d_rsize[i] <= 200);
        check_true("d_ovr override beats each", d_ovr.size() == 4 && d_ovr[0] == 99);
        for (int i = 1; i < 4; i++) check_true("d_ovr rest from each", d_ovr[i] >= 1 && d_ovr[i] <= 10);
        check_true("d_part2 list then each", d_part2.size() == 4 && d_part2[0] == 5 && d_part2[1] == 6 &&
                   d_part2[2] >= 100 && d_part2[2] <= 200 && d_part2[3] >= 100 && d_part2[3] <= 200);
        foreach (s_each[i]) check_true("s_each element in [1:10]", s_each[i] >= 1 && s_each[i] <= 10);
        check_true("s_ovr override", s_ovr[3] == 42);
        for (int i = 0; i < 3; i++) check_true("s_ovr rest from each", s_ovr[i] >= 1 && s_ovr[i] <= 10);

        $display("ARRAY_VALUES d_each=%p d_rsize=%p s_each=%p", d_each, d_rsize, s_each);

        `aip_int_list("", int, d_seq, 0);      // +d_seq=seq:0x1000:0x1F00:0x100
        `aip_int_list("", int, d_perm, 0);     // +d_perm=perm:0:7
        `aip_int_slist("", int, s_seq, 0);     // +s_seq=seq:0:3
        `aip_int_slist("", int, s_perm, 0);    // +s_perm=perm:0:3

        check_true("d_seq size 16", d_seq.size() == 16);
        foreach (d_seq[i]) check_true("d_seq stride", d_seq[i] == 'h1000 + i * 'h100);
        check_true("d_perm size 8", d_perm.size() == 8);
        for (int k = 0; k < 8; k++) begin
            automatic int hits = 0;
            foreach (d_perm[i]) if (d_perm[i] == k) hits++;
            check_true("d_perm each value exactly once", hits == 1);
        end
        for (int i = 0; i < 4; i++) check_true("s_seq", s_seq[i] == i);
        for (int k = 0; k < 4; k++) begin
            automatic int hits = 0;
            for (int i = 0; i < 4; i++) if (s_perm[i] == k) hits++;
            check_true("s_perm each value exactly once", hits == 1);
        end

        `aip_int_list("", int, d_uni, 0);      // +d_uni.size=8 +d_uni.each=[0:9] +d_uni.unique=1
        `aip_int_list("", int, d_unifix, 0);   // +d_unifix.size=4 +d_unifix=3 +d_unifix.each=[0:4] +d_unifix.unique=1
        `aip_int_slist("", int, s_uni, 0);     // +s_uni.each=[0:3] +s_uni.unique=1

        check_true("d_uni size", d_uni.size() == 8);
        foreach (d_uni[i]) begin
            check_true("d_uni in range", d_uni[i] >= 0 && d_uni[i] <= 9);
            for (int j = 0; j < i; j++) check_true("d_uni distinct", d_uni[i] != d_uni[j]);
        end
        check_true("d_unifix keeps fixed", d_unifix[0] == 3);
        foreach (d_unifix[i]) for (int j = 0; j < i; j++) check_true("d_unifix distinct", d_unifix[i] != d_unifix[j]);
        for (int k = 0; k < 4; k++) begin
            automatic int hits = 0;
            for (int i = 0; i < 4; i++) if (s_uni[i] == k) hits++;
            check_true("s_uni is a permutation of 0..3", hits == 1);
        end

        `aip_str_list("", d_suni, "");         // +d_suni.size=3 +d_suni.each=a,b,c +d_suni.unique=1

        check_true("d_suni size", d_suni.size() == 3);
        foreach (d_suni[i]) check_true("d_suni in list", d_suni[i] == "a" || d_suni[i] == "b" || d_suni[i] == "c");
        check_true("d_suni distinct", d_suni[0] != d_suni[1] && d_suni[0] != d_suni[2] && d_suni[1] != d_suni[2]);

        `aip_int_list("", int, d_sort, 0);     // +d_sort.size=6 +d_sort.each=[1:100] +d_sort.sort=asc +d_sort[0]=1000
        `aip_int_list("", int, d_sortd, 0);    // +d_sortd=3,1,2 +d_sortd.sort=desc
        `aip_int_slist("", int, s_sort, 0);    // +s_sort.each=[1:100] +s_sort.sort=desc

        check_true("d_sort size", d_sort.size() == 6);
        for (int i = 1; i < 6; i++) check_true("d_sort ascending", d_sort[i-1] <= d_sort[i]);
        check_true("d_sort override participates", d_sort[5] == 1000);
        check_true("d_sortd desc list", d_sortd[0] == 3 && d_sortd[1] == 2 && d_sortd[2] == 1);
        for (int i = 1; i < 4; i++) check_true("s_sort descending", s_sort[i-1] >= s_sort[i]);

        `aip_str_list("", d_sseq, "");         // +d_sseq=seq:one,two  (string array: not a generator)
        `aip_str_list("", d_ssort, "");        // +d_ssort=c,a,b +d_ssort.sort=asc

        check_true("d_sseq string seq: is a plain list", d_sseq.size() == 2 && d_sseq[0] == "seq:one" && d_sseq[1] == "two");
        check_true("d_ssort string asc", d_ssort.size() == 3 && d_ssort[0] == "a" && d_ssort[1] == "b" && d_ssort[2] == "c");

        if (failures == 0) $display("CMDLINE_ARRAY_RANDOM_PASS");
        else $display("CMDLINE_ARRAY_RANDOM_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
