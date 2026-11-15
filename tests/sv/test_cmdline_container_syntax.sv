`include "aip_log.sv"
`include "aip_cmdline.sv"

class cmdline_wrapper_probe extends aip_cmdline#(int);
    static function bit detect(string s);
        return has_outer_list_wrapper(s);
    endfunction
endclass

module test_cmdline_container_syntax;
    int failures;
    int compact_pick, bracket_pick, range_pick, range_list_pick;
    int malformed_pick;
    int brace_weight, paren_weight;
    int compact_arr[], bracket_arr[], signed_arr[];
    int nested_brace_arr[], nested_paren_arr[];

    task automatic check_true(string label, bit condition);
        if (!condition) begin
            failures++;
            $error("%s", label);
        end
    endtask

    task automatic check_array(string label, int actual[], int expected[]);
        if (actual.size() != expected.size()) begin
            failures++;
            $error("%s size: got %0d expected %0d", label, actual.size(), expected.size());
            return;
        end
        foreach (expected[i]) begin
            if (actual[i] != expected[i]) begin
                failures++;
                $error("%s[%0d]: got %0d expected %0d", label, i, actual[i], expected[i]);
            end
        end
    endtask

    task automatic check_wrapper(string s, bit expected);
        bit actual = cmdline_wrapper_probe::detect(s);
        if (actual != expected) begin
            failures++;
            if (!expected && actual)
                $display("MALFORMED_ACCEPTED input=%s", s);
            $error("wrapper detection for '%s': got %0d expected %0d",
                   s, actual, expected);
        end
    endtask

    initial begin
        if ($test$plusargs("AIP_CONTAINER_MALFORMED")) begin
            `aip_int("", int, malformed_pick, 0);
            $display("MALFORMED_ACCEPTED value=%0d", malformed_pick);
            $finish;
        end else begin
            int expected_pos[] = '{1, 2, 3};
            int expected_neg[] = '{-3, -2, -1};
            failures = 0;

            `aip_int("", int, compact_pick, 0);
            `aip_int("", int, bracket_pick, 0);
            `aip_int("", int, range_pick, 0);
            `aip_int("", int, range_list_pick, 0);
            `aip_int("", int, brace_weight, -1);
            `aip_int("", int, paren_weight, -1);
            `aip_int_list("", int, compact_arr);
            `aip_int_list("", int, bracket_arr);
            `aip_int_list("", int, signed_arr);
            `aip_int_list("", int, nested_brace_arr);
            `aip_int_list("", int, nested_paren_arr);

            check_true("compact scalar list", compact_pick inside {1, 2, 3});
            check_true("bracket scalar list", bracket_pick inside {1, 2, 3});
            check_true("range remains range", range_pick >= 4 && range_pick <= 6);
            check_true("compact range list", range_list_pick inside {1, 2, 3, 4});
            check_true("brace distribution", brace_weight >= 0 && brace_weight <= 3);
            check_true("paren distribution", paren_weight >= 0 && paren_weight <= 3);
            check_array("compact array", compact_arr, expected_pos);
            check_array("bracket array", bracket_arr, expected_pos);
            check_array("signed bracket array", signed_arr, expected_neg);
            check_true("nested brace array size", nested_brace_arr.size() == 2);
            if (nested_brace_arr.size() == 2) begin
                check_true("nested brace distribution", nested_brace_arr[0] >= 0 &&
                           nested_brace_arr[0] <= 3);
                check_true("nested brace trailing element", nested_brace_arr[1] == 4);
            end
            check_true("nested paren array size", nested_paren_arr.size() == 2);
            if (nested_paren_arr.size() == 2) begin
                check_true("nested paren distribution", nested_paren_arr[0] >= 0 &&
                           nested_paren_arr[0] <= 3);
                check_true("nested paren trailing element", nested_paren_arr[1] == 4);
            end

            check_wrapper("[1,2,3]", 1);
            check_wrapper("[-3,-2,-1]", 1);
            check_wrapper("[1,[2:3],4]", 1);
            check_wrapper("[{0:=1,[1:3]:=1},4]", 1);
            check_wrapper("[(0:=1,[1:3]:=1),4]", 1);
            check_wrapper("[1,]", 0);
            check_wrapper("[,1]", 0);
            check_wrapper("[1,,2]", 0);
            check_wrapper("[1],[2]", 0);
            check_wrapper("[1:3]", 0);
            check_wrapper("[1,2", 0);
            check_wrapper("[1],2]", 0);
            check_wrapper("[{0:=1,1]", 0);
            check_wrapper("[},1]", 0);
            check_wrapper("[(0:=1,1]", 0);
            check_wrapper("[),1]", 0);
            check_wrapper("[({)},1]", 0);
            check_wrapper("[{(}),1]", 0);
            check_wrapper("[([)],1]", 0);
            check_wrapper("[{0:=1,[1:3]:=1}]", 0);
            check_wrapper("[(0:=1,[1:3]:=1)]", 0);

            if (failures != 0)
                $fatal(1, "CMDLINE_CONTAINER_FAIL failures=%0d", failures);
            $display("CMDLINE_CONTAINER_PASS");
            $finish;
        end
    end
endmodule
