// 内部 include 片段，只能由 aip_cmdline.sv 加载。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else

// 判断 <path>.<name>（含 name[i]、name.x 及无路径叶名回退）是否被命令行或运行期 override 显式给出。
// 只读键、不求值、不消费随机数，可在决定是否重建容器前调用。
class aip_cmdline_query;
    // check_unsigned=1：对每个命中的键检查获胜值（已含 override），出现负数即 hard fatal。
    static function bit present(string path, string name, bit check_unsigned = 0);
        string                args[$];
        string                keys[$];
        string                roots[2];
        uvm_cmdline_processor clp;
        bit                   found;

        found    = 0;
        roots[0] = {path, ".", name};
        roots[1] = name;
        clp = aip_cmdline_source::get();
        clp.get_plusargs(args);
        aip_cmdline_override::get_keys(keys);
        foreach (args[i]) begin
            int eq;
            eq = aip_str::str_find(args[i], "=");
            if (eq > 1) keys.push_back(args[i].substr(1, eq - 1));  // 去掉前导 '+'
        end
        foreach (keys[i]) begin
            foreach (roots[j]) begin
                int    n;
                string suffix;
                string value;
                n = roots[j].len();
                if (!(keys[i] == roots[j] ||
                      (keys[i].len() > n && keys[i].substr(0, n - 1) == roots[j] &&
                       (keys[i][n] == "." || keys[i][n] == "["))))
                    continue;
                found = 1;
                if (!check_unsigned) continue;
                suffix = (keys[i].len() == n) ? "" : keys[i].substr(n);
                value  = aip_cmdline#(int)::get_cmdline_string({name, suffix}, path);
                if (aip_str::str_find(value, "-") >= 0)
                    aip_cmdline_diagnostic::report("[AIP_CMDLINE]",
                        $sformatf("%s.%s%s requires unsigned values: %s", path, name, suffix, value),
                        `__FILE__, `__LINE__);
            end
        end
        return found;
    endfunction
endclass

`endif // AIP_CMDLINE_INTERNAL_INCLUDE
