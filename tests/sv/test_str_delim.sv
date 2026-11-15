// Delimiter handling must use byte literals: on VCS Q-2020 `s[i] == "\t"` matches the letter 't'.
`include "aip_core_pkg.sv"

module test_str_delim;
    int fails = 0;

    task automatic check(string name, bit cond);
        if (cond) $display("[PASS] %s", name);
        else begin $display("[FAIL] %s", name); fails++; end
    endtask

    initial begin
        string parts[];
        string s;

        // "\r" is not an SV string escape (it yields the letter 'r'); build CR
        // from its byte value.
        s = {"a\tb c\nd", string'(8'd13), "e"};
        parts = aip_str::split(s, "");
        check("split on tab/space/lf/cr -> 5 parts", parts.size() == 5);
        check("split parts a..e", parts.size() == 5 && parts[0] == "a" && parts[1] == "b" &&
                                  parts[2] == "c" && parts[3] == "d" && parts[4] == "e");

        parts = aip_str::split("tnr x", "");
        check("split does not treat letters t/n/r as whitespace",
              parts.size() == 2 && parts[0] == "tnr" && parts[1] == "x");

        check("get_arg value containing t",   aip_cmd::get_arg("path=test_t val=n", "path") == "test_t");
        check("get_arg value n",              aip_cmd::get_arg("path=test_t val=n", "val")  == "n");
        check("get_arg key after tab",        aip_cmd::get_arg("a=1\tpath=trn", "path")     == "trn");
        check("get_arg value ends at tab",    aip_cmd::get_arg("path=x\tval=y", "path")     == "x");
        check("get_arg skips key embedded in a longer key",
              aip_cmd::get_arg("tpath=1 path=2", "path") == "2");
        check("get_arg embedded-only key -> empty",
              aip_cmd::get_arg("tpath=1 xpath=2", "path") == "");

        if (fails == 0) begin
            $display("STR_DELIM_PASS");
        end else begin
            $fatal(1, "STR_DELIM_FAIL fails=%0d", fails);
        end
        $finish;
    end
endmodule
