// schema 容器适配：类型检查、无损比较键、整条记录排序及各类型字段数组解析。
// 内部 include 片段：只允许 aip_cmdline.sv 在其 include 窗口加载，拒绝直接包含以免创建第二份 $unit/package 类型。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
// Typed key adapter for integral/enum field macros: F is bound at the call site, so $bits(F) and signedness
// are the member's own; signedness is probed by extending all-ones by one bit (honors typedefs/enum bases).
class aip_struct_typed_key #(type F = int);
    localparam int WIDTH = $bits(F);

    static function bit declared_signed();
        F probe;
        logic [WIDTH:0] extended;
        probe = F'(-1);
        extended = probe;
        return extended[WIDTH];
    endfunction

    static function void record(string root, string field, input F value,
                                input int kind);
        logic [1023:0] bits;
        bits = '0;
        bits[WIDTH-1:0] = value;
        aip_struct_runtime::record_typed_bits(root, field, bits, WIDTH,
                                               declared_signed(), kind);
    endfunction
endclass

// Stable whole-record postprocessing for schema arrays: field adapters snapshot every scalar member, so
// controls may name any field or nested scalar path without hard-coding a member such as `.value`.
class aip_struct_array_postprocess #(type T = int);
    static function string descriptor_key(string root, int idx, string suffix);
        return $sformatf("%s|%0d|%s", root, idx, suffix);
    endfunction

    static function bit same_typed(string root, int ia, int ib, string suffix);
        int ka, kb, wa, wb;
        bit sa, sb;
        logic [1023:0] ba, bb;
        real ra, rb;
        string xa, xb;
        bit ha, hb;
        ha = aip_struct_runtime::get_typed_field(root, ia, suffix, ka, ba,
                                                  wa, sa, ra, xa);
        hb = aip_struct_runtime::get_typed_field(root, ib, suffix, kb, bb,
                                                  wb, sb, rb, xb);
        if (!ha || !hb || ka != kb) return 0;
        case (ka)
            1, 4: return (ba === bb);
            2:   return (xa == xb);
            3:   return (ra == rb);
            default: return 0;
        endcase
    endfunction

    static function int compare_typed(string root, int ia, int ib,
                                      string suffix);
        int ka, kb, wa, wb;
        bit sa, sb;
        logic [1023:0] ba, bb;
        logic signed [1023:0] bsa, bsb;
        logic [1023:0] bua, bub;
        real ra, rb;
        string xa, xb;
        bit ha, hb;
        ha = aip_struct_runtime::get_typed_field(root, ia, suffix, ka, ba,
                                                  wa, sa, ra, xa);
        hb = aip_struct_runtime::get_typed_field(root, ib, suffix, kb, bb,
                                                  wb, sb, rb, xb);
        if (!ha || !hb || ka != kb) return 0;
        case (ka)
            1, 4: begin
                if (sa) begin
                    bsa = ba;
                    bsb = bb;
                    // Descriptors hold only the field-width low bits; sign-extend before 1024-bit compares.
                    if (wa > 0 && wa < 1024) begin
                        if (ba[wa-1])
                            for (int q = wa; q < 1024; q++) bsa[q] = 1'b1;
                        else
                            for (int q = wa; q < 1024; q++) bsa[q] = 1'b0;
                        if (bb[wb-1])
                            for (int q = wb; q < 1024; q++) bsb[q] = 1'b1;
                        else
                            for (int q = wb; q < 1024; q++) bsb[q] = 1'b0;
                    end
                    if (bsa < bsb) return -1;
                    if (bsa > bsb) return 1;
                    return 0;
                end
                bua = ba;
                bub = bb;
                if (bua < bub) return -1;
                if (bua > bub) return 1;
                return 0;
            end
            2: begin
                if (xa < xb) return -1;
                if (xa > xb) return 1;
                return 0;
            end
            3: begin
                if (ra < rb) return -1;
                if (ra > rb) return 1;
                return 0;
            end
            default: return 0;
        endcase
    endfunction

    static function bit listed_name(string names[$], string suffix);
        foreach (names[i]) if (names[i] == suffix) return 1;
        return 0;
    endfunction

    // Struct-container controls belong to ROOT.each.<suffix>; reject indexed forms mistaken for per-record keys.
    // Primitive-array controls are absent from `names` and stay owned by their array resolver.
    static function void reject_indexed_controls(string root, string names[$]);
        string keys[$];
        string args[$];
        string key, arg, suffix, index_text, field_suffix, control;
        bit has_index;
        int eq;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!aip_struct_runtime::schema_descendant_suffix(root, key, suffix,
                                                               has_index, index_text) || !has_index)
                continue;
            control = "";
            if (suffix.len() > 5 &&
                suffix.substr(suffix.len()-5, suffix.len()-1) == ".sort") begin
                field_suffix = suffix.substr(0, suffix.len()-6);
                control = "sort";
            end else if (suffix.len() > 7 &&
                         suffix.substr(suffix.len()-7, suffix.len()-1) == ".unique") begin
                field_suffix = suffix.substr(0, suffix.len()-8);
                control = "unique";
            end
            if (control != "" && listed_name(names, field_suffix))
                aip_struct_runtime::fail($sformatf(
                    "%s[%s].%s.%s is invalid for a struct-container key; use %s.each.%s.%s",
                    root, index_text, field_suffix, control, root, field_suffix, control));
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!aip_struct_runtime::schema_descendant_suffix(root, key, suffix,
                                                               has_index, index_text) || !has_index)
                continue;
            control = "";
            if (suffix.len() > 5 &&
                suffix.substr(suffix.len()-5, suffix.len()-1) == ".sort") begin
                field_suffix = suffix.substr(0, suffix.len()-6);
                control = "sort";
            end else if (suffix.len() > 7 &&
                         suffix.substr(suffix.len()-7, suffix.len()-1) == ".unique") begin
                field_suffix = suffix.substr(0, suffix.len()-8);
                control = "unique";
            end
            if (control != "" && listed_name(names, field_suffix))
                aip_struct_runtime::fail($sformatf(
                    "%s[%s].%s.%s is invalid for a struct-container key; use %s.each.%s.%s",
                    root, index_text, field_suffix, control, root, field_suffix, control));
        end
    endfunction

    static function void apply(string root, ref T arr[]);
        string names[$];
        string runtime_names[$];
        string schema_id;
        string sort_suffix;
        string sort_direction;
        int active_sorts;
        int perm_order[];
        T sorted[];
        int oi;
        names = {};
        schema_id = aip_struct_runtime::container_schema.exists(root) ?
                    aip_struct_runtime::container_schema[root] : "";
        if (schema_id != "")
            aip_struct_runtime::collect_schema_scalar_suffixes(schema_id, "", names);
        runtime_names = aip_struct_runtime::field_names[root];
        foreach (runtime_names[ni]) begin
            if (!listed_name(names, runtime_names[ni])) names.push_back(runtime_names[ni]);
        end

        reject_indexed_controls(root, names);

        // Validate every control (and the single-active-sort rule) before moving any element.
        active_sorts = 0;
        foreach (names[ni]) begin
            string suffix = names[ni];
            aip_struct_runtime::lookup_t ul, sl;
            string normalized;
            begin
                string selected_key;
                ul = aip_struct_runtime::lookup_container_rule(
                    root, {".each.", suffix, ".unique"}, selected_key);
            end
            if (ul.found) begin
                aip_cmdline_diagnostic::select_value({root, ".each.", suffix, ".unique"}, ul.value);
                normalized = aip_str::lower(aip_str::strip(ul.value));
                if (normalized != "0" && normalized != "1")
                    aip_struct_runtime::fail($sformatf(
                        "%s.each.%s.unique must be 0 or 1", root, suffix));
            end
            begin
                string selected_key;
                sl = aip_struct_runtime::lookup_container_rule(
                    root, {".each.", suffix, ".sort"}, selected_key);
            end
            if (sl.found) begin
                aip_cmdline_diagnostic::select_value({root, ".each.", suffix, ".sort"}, sl.value);
                normalized = aip_str::lower(aip_str::strip(sl.value));
                if (normalized != "asc" && normalized != "desc" &&
                    normalized != "none")
                    aip_struct_runtime::fail($sformatf(
                        "%s.each.%s.sort must be asc, desc, or none", root, suffix));
                if (normalized == "asc" || normalized == "desc") begin
                    active_sorts++;
                    if (active_sorts == 1) begin
                        sort_suffix = suffix;
                        sort_direction = normalized;
                    end
                end
            end
        end
        if (active_sorts > 1)
            aip_struct_runtime::fail($sformatf(
                "%s has more than one active struct sort key", root));

        // Unique compares final typed descriptors, never strings, so packed width/signedness, exact real
        // values, case-sensitive strings and enum underlying bits are preserved.
        foreach (names[ni]) begin
            string suffix = names[ni];
            aip_struct_runtime::lookup_t ul;
            string normalized;
            begin
                string selected_key;
                ul = aip_struct_runtime::lookup_container_rule(
                    root, {".each.", suffix, ".unique"}, selected_key);
            end
            if (!ul.found) continue;
            normalized = aip_str::lower(aip_str::strip(ul.value));
            if (normalized != "1") continue;
            for (int i = 0; i < arr.size(); i++) begin
                for (int j = 0; j < i; j++) begin
                    if (same_typed(root, i, j, suffix))
                        aip_struct_runtime::fail($sformatf(
                            "%s.each.%s.unique: duplicate final typed value at indices %0d and %0d",
                            root, suffix, j, i));
                end
            end
        end

        if (active_sorts == 0) return;

        // Stable insertion sort over record indices; the final move is on whole T values, so unregistered
        // fields and opaque handles stay attached.
        perm_order = new[arr.size()];
        for (int i = 0; i < arr.size(); i++) perm_order[i] = i;
        for (int i = 1; i < perm_order.size(); i++) begin
            int j = i;
            while (j > 0) begin
                int c = compare_typed(root, perm_order[j-1], perm_order[j], sort_suffix);
                if ((sort_direction == "asc" && c <= 0) ||
                    (sort_direction == "desc" && c >= 0)) break;
                oi = perm_order[j-1];
                perm_order[j-1] = perm_order[j];
                perm_order[j] = oi;
                j--;
            end
        end
        sorted = new[arr.size()];
        for (int i = 0; i < arr.size(); i++) sorted[i] = arr[perm_order[i]];
        for (int i = 0; i < arr.size(); i++) arr[i] = sorted[i];
    endfunction
endclass

class aip_struct_refcheck #(type T = int);
    static function void check(ref T value);
    endfunction
endclass

// Typed check for dynamic arrays via an open-array ref formal: indexing an element would hit a run-time
// out-of-bounds reference on an empty array before the schema can resize it.
class aip_struct_array_refcheck #(type T = int);
    static function void check(ref T value[]);
    endfunction
endclass

// Canonical resolver for primitive schema arrays: unlike resolve_array it never probes a bare leaf or legacy
// path; all rules are rooted at the schema element path and compact members are only an inherited baseline.
class aip_struct_schema_array_runtime #(type T = int);
    static function void postprocess(string root, string field, ref T arr[]);
        aip_cmdline_diagnostic::push({root, ".", field});
        postprocess_impl(root, field, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 对最终数组校验 unique/sort 并原地排序。
    protected static function void postprocess_impl(string root, string field, ref T arr[]);
        aip_struct_runtime::lookup_t ul, sl;
        string u, s;
        if (aip_struct_runtime::metadata_mode) return;
        ul = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
        sl = aip_struct_runtime::lookup_array_rule(root, field, ".sort");
        if (ul.found) begin
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ul.value);
            u = aip_str::lower(aip_str::strip(ul.value));
            if (u != "0" && u != "1") aip_struct_runtime::fail($sformatf("%s.%s.unique must be 0 or 1", root, field));
            if (u == "1") for (int i=0;i<arr.size();i++) for (int j=0;j<i;j++) if (arr[i] === arr[j]) aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value at indices %0d and %0d",root,field,j,i));
        end
        if (sl.found) begin
            aip_cmdline_diagnostic::select_value({root, ".", field, ".sort"}, sl.value);
            s = aip_str::lower(aip_str::strip(sl.value));
            if (s != "asc" && s != "desc" && s != "none") aip_struct_runtime::fail($sformatf("%s.%s.sort must be asc, desc, or none", root, field));
            if (s == "asc" || s == "desc") begin
                for (int i=1;i<arr.size();i++) begin T v; int j; v=arr[i]; j=i; while(j>0 && ((s=="asc" && v < arr[j-1]) || (s=="desc" && v > arr[j-1]))) begin arr[j]=arr[j-1]; j--; end arr[j]=v; end
            end
        end
    endfunction
    static function aip_struct_runtime::lookup_t rule(string root, string field, string suffix);
        aip_struct_runtime::lookup_t r;
        r = aip_struct_runtime::lookup_array_rule(root, field, suffix);
        return r;
    endfunction

    static function void resolve(string root, string field, string compact,
                                  T default_val, int fixed_size, int default_size,
                                  ref T arr[]);
        aip_cmdline_diagnostic::push_value({root, ".", field}, compact);
        resolve_impl(root, field, compact, default_val, fixed_size, default_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按 schema 的整体值、each 与索引规则生成整数数组，检查静态容量、长度及唯一性。
    protected static function void resolve_impl(string root, string field, string compact,
                                  T default_val, int fixed_size, int default_size,
                                  ref T arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, il;
        aip_struct_runtime::lookup_t winners[];
        string overall, size_str, each_str, parts[$];
        int n, max_idx;
        bit have_size, unique_each, each_used;
        bit from_each[];
        if (aip_struct_runtime::metadata_mode) begin
            n = (fixed_size >= 0) ? fixed_size : 0;
            arr = new[n];
            foreach (arr[i]) arr[i] = default_val;
            return;
        end
        ol = aip_struct_runtime::lookup_field_with_compact(root, field, compact);
        sl = rule(root, field, ".size");
        el = rule(root, field, ".each");
        overall = ol.found ? ol.value : "";
        size_str = sl.found ? sl.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
        if (ol.found && overall == "") aip_struct_runtime::fail($sformatf("empty value for %s.%s", root, field));
        begin
            aip_struct_runtime::lookup_t ur;
            string normalized_unique;
            ur = rule(root, field, ".unique");
            normalized_unique = ur.found ?
                aip_str::lower(aip_str::strip(ur.value)) : "0";
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.value);
            if (ur.found && normalized_unique != "0" &&
                normalized_unique != "1")
                aip_struct_runtime::fail($sformatf(
                    "%s.%s.unique must be 0 or 1", root, field));
            unique_each = (normalized_unique == "1");
        end
        have_size = sl.found;
        max_idx = -1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".size"}, size_str);
        if (fixed_size >= 0) begin
            if (have_size) aip_struct_runtime::fail($sformatf("%s.%s.size not allowed for static array (declared size %0d)", root, field, fixed_size));
            n = fixed_size;
        end else if (have_size) begin
            n = aip_struct_runtime::normalize_size(size_str,
                                                    {root, ".", field, ".size"});
        end else begin
            n = -1;
        end
        if (overall != "") begin
            bit gen; int glen;
            aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
            aip_struct_runtime::validate_generator_target(overall,
                                                           {root, ".", field},
                                                           $bits(T));
            glen = aip_struct_runtime::overall_length(overall, gen);
            if (fixed_size >= 0 && gen && glen != fixed_size)
                aip_struct_runtime::fail($sformatf("%s.%s generator length %0d does not match static size %0d", root, field, glen, fixed_size));
            if (fixed_size >= 0 && !gen && glen > fixed_size) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds static size", root, field));
            if (n >= 0 && gen && glen != n)
                aip_struct_runtime::fail($sformatf("%s.%s.size conflicts with generator length %0d", root, field, glen));
            if (n >= 0 && glen > n) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds size", root, field));
            if (n < 0) n = glen;
        end
        max_idx = aip_struct_runtime::schema_array_index_extent(root, field) - 1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (n < 0) begin
            if (max_idx >= 0) n = max_idx + 1;
            else if (default_size > 0) n = default_size;
            else if (each_str != "") aip_struct_runtime::fail($sformatf("%s.%s.each given but size unknown", root, field));
            else n = 0;
        end
        aip_cmdline_diagnostic::select_value(sl.found ? {root, ".", field, ".size"} : {root, ".", field},
            sl.found ? sl.value : overall);
        if (fixed_size < 0) aip_struct_runtime::charge_allocation({root, ".", field}, n);
        arr = new[n]; from_each = new[n];
        winners = new[n];
        // A full integral permutation consumes its whole shuffle even if indexed winners later shadow every slot.
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
            aip_struct_runtime::prepare_container_generator(
                {root, ".", field}, overall);
        end
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::schema_array_slot_rule(
                root, field, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (each_used && each_str == "")
            aip_struct_runtime::fail($sformatf(
                "empty value for %s.%s.each", root, field));
        if (unique_each)
            aip_strict_int_queue_runtime#(T)::preflight_unique(
                {root, ".", field}, each_str, winners, from_each, default_val);
        for (int i = 0; i < n; i++) begin
            if (!winners[i].found) arr[i] = default_val;
            else arr[i] = aip_strict_int_queue_runtime#(T)::draw_strict(
                winners[i].value,
                winners[i].from_each ? {root, ".", field, ".each"} :
                $sformatf("%s.%s[%0d]", root, field, i));
        end
        if (max_idx >= n) begin
            aip_struct_runtime::lookup_t index_rule;
            index_rule = aip_struct_runtime::lookup_array_rule(root, field, $sformatf("[%0d]", max_idx));
            aip_cmdline_diagnostic::select_value($sformatf("%s.%s[%0d]", root, field, max_idx), index_rule.value);
            aip_struct_runtime::fail($sformatf("%s.%s indexed value out of range", root, field));
        end
        if (unique_each) begin
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, "1");
            for (int i = 0; i < n; i++) if (from_each[i]) begin
                int attempts = 0; bit dup;
                do begin
                    dup = 0;
                    for (int j = 0; j < n; j++)
                        if (j != i && (!from_each[j] || j < i) && arr[j] === arr[i]) dup = 1;
                    if (!dup) break;
                    attempts++;
                    if (attempts > 100) aip_struct_runtime::fail($sformatf("%s.%s.unique: candidate shortage",root,field));
                    arr[i] = aip_strict_int_queue_runtime#(T)::draw_strict(
                        each_str, {root, ".", field, ".each"});
                end while (dup);
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value",root,field));
        end
        postprocess(root, field, arr);
    endfunction
endclass

// String schema arrays need a non-parameterized adapter: VCS elaborates both branches of a run-time
// `$typename(T)` check, so T'(string) casts in the integral resolver make even int specializations fail
// with SV-WMIBC. Normalization and precedence match the integral resolver.
class aip_struct_string_array_runtime;
    static function void postprocess(string root, string field, ref string arr[]);
        aip_cmdline_diagnostic::push({root, ".", field});
        postprocess_impl(root, field, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 对最终字符串数组校验 unique/sort 并原地排序，拒绝 seq/perm。
    protected static function void postprocess_impl(string root, string field, ref string arr[]);
        aip_struct_runtime::lookup_t ul, sl, ql; string u,s;
        if (aip_struct_runtime::metadata_mode) return;
        ul=aip_struct_runtime::lookup_array_rule(root,field,".unique"); sl=aip_struct_runtime::lookup_array_rule(root,field,".sort");
        ql=aip_struct_runtime::lookup_array_rule(root,field,".seq");
        aip_cmdline_diagnostic::select_value({root, ".", field, ".seq"}, ql.value);
        if(!ql.found) begin
            ql=aip_struct_runtime::lookup_array_rule(root,field,".perm");
            aip_cmdline_diagnostic::select_value({root, ".", field, ".perm"}, ql.value);
        end
        if(ql.found) aip_struct_runtime::fail($sformatf("%s.%s seq/perm unsupported for string primitive schema array",root,field));
        if(ul.found) begin aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ul.value); u=aip_str::lower(aip_str::strip(ul.value)); if(u!="0"&&u!="1") aip_struct_runtime::fail($sformatf("%s.%s.unique must be 0 or 1",root,field)); if(u=="1") for(int i=0;i<arr.size();i++) for(int j=0;j<i;j++) if(arr[i]==arr[j]) aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value",root,field)); end
        if(sl.found) begin aip_cmdline_diagnostic::select_value({root, ".", field, ".sort"}, sl.value); s=aip_str::lower(aip_str::strip(sl.value)); if(s!="asc"&&s!="desc"&&s!="none") aip_struct_runtime::fail($sformatf("%s.%s.sort must be asc, desc, or none",root,field)); if(s=="asc"||s=="desc") for(int i=1;i<arr.size();i++) begin string v; int j; v=arr[i]; j=i; while(j>0 && ((s=="asc"&&v<arr[j-1])||(s=="desc"&&v>arr[j-1]))) begin arr[j]=arr[j-1]; j--; end arr[j]=v; end end
    endfunction

    static function bit deterministic_value(
        aip_struct_runtime::lookup_t winner,
        string default_val,
        output string value);
        string tokens[$];
        string values[$];
        string candidate;
        int status;
        bit seen;
        if (!winner.found) begin
            value = default_val;
            return 1;
        end
        if (winner.value == "") begin
            value = "";
            return 1;
        end
        status = aip_struct_runtime::finite_candidate_tokens(
            winner.value, tokens, 2);
        if (status < 0) return 0;
        foreach (tokens[i]) begin
            candidate = aip_struct_runtime::decode_string(tokens[i]);
            seen = 0;
            foreach (values[j])
                if (values[j] == candidate) seen = 1;
            if (!seen) values.push_back(candidate);
        end
        if (values.size() != 1) return 0;
        value = values[0];
        return 1;
    endfunction

    static function void preflight_unique(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        string default_val);
        aip_cmdline_diagnostic::push_value({path, ".unique"}, "1");
        preflight_unique_impl(path, each_expr, winners, from_each, default_val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 不抽样：检查固定值冲突与 each 候选容量，无法有限枚举时留给后续有界重抽。
    protected static function void preflight_unique_impl(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        string default_val);
        string tokens[$];
        string candidates[$];
        string fixed_values[];
        bit fixed_known[];
        string candidate;
        int status, each_slots, available;
        bit seen, occupied;

        fixed_values = new[winners.size()];
        fixed_known = new[winners.size()];
        each_slots = 0;
        foreach (winners[i]) begin
            if (from_each[i]) begin
                each_slots++;
                continue;
            end
            // 预检先于抽样，固定候选也需绑定自己的索引和完整原文。
            aip_cmdline_diagnostic::push_value($sformatf("%s[%0d]", path, i), winners[i].value);
            fixed_known[i] = deterministic_value(
                winners[i], default_val, fixed_values[i]);
            aip_cmdline_diagnostic::pop();
        end
        foreach (fixed_values[i]) begin
            if (!fixed_known[i]) continue;
            for (int j = 0; j < i; j++)
                if (fixed_known[j] && fixed_values[i] == fixed_values[j])
                    aip_struct_runtime::fail($sformatf(
                        "%s.unique: duplicate fixed value at indices %0d and %0d",
                        path, j, i));
        end

        if (each_slots == 0) return;
        aip_cmdline_diagnostic::select_value({path, ".each"}, each_expr);
        if (each_expr == "") begin
            candidates.push_back("");
        end else begin
            status = aip_struct_runtime::finite_candidate_tokens(
                each_expr, tokens, 2);
            if (status < 0) return;
            foreach (tokens[i]) begin
                candidate = aip_struct_runtime::decode_string(tokens[i]);
                seen = 0;
                foreach (candidates[j])
                    if (candidates[j] == candidate) seen = 1;
                if (!seen) candidates.push_back(candidate);
            end
        end
        available = candidates.size();
        foreach (candidates[i]) begin
            occupied = 0;
            foreach (fixed_values[j])
                if (fixed_known[j] && fixed_values[j] == candidates[i]) begin
                    occupied = 1;
                    break;
                end
            if (occupied) available--;
        end
        if (available < each_slots)
            aip_struct_runtime::fail($sformatf(
                "%s.unique: only %0d candidates for %0d elements",
                path, available, each_slots));
    endfunction

    static function void resolve(string root, string field, string compact,
                                 string default_val, int fixed_size, int default_size,
                                 ref string arr[]);
        aip_cmdline_diagnostic::push_value({root, ".", field}, compact);
        resolve_impl(root, field, compact, default_val, fixed_size, default_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按 schema 优先级选择各槽位并检查容量、转义与唯一性；不支持 seq/perm，允许合法空字符串。
    protected static function void resolve_impl(string root, string field, string compact,
                                 string default_val, int fixed_size, int default_size,
                                 ref string arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, il;
        aip_struct_runtime::lookup_t winners[];
        string overall, size_str, each_str;
        int n, max_idx;
        bit have_size, unique_each, each_used;
        bit from_each[];
        if (aip_struct_runtime::metadata_mode) begin
            n = (fixed_size >= 0) ? fixed_size : 0;
            arr = new[n];
            foreach (arr[i]) arr[i] = default_val;
            return;
        end
        ol = aip_struct_runtime::lookup_field_with_compact(root, field, compact);
        sl = aip_struct_runtime::lookup_array_rule(root, field, ".size");
        el = aip_struct_runtime::lookup_array_rule(root, field, ".each");
        overall = ol.found ? ol.value : "";
        size_str = sl.found ? sl.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
        if (ol.found &&
            (aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "seq:") == 0 ||
             aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "perm:") == 0))
            aip_struct_runtime::fail($sformatf("%s.%s seq/perm unsupported for string primitive schema array", root, field));
        begin
            aip_struct_runtime::lookup_t ur;
            string normalized_unique;
            ur = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
            normalized_unique = ur.found ?
                aip_str::lower(aip_str::strip(ur.value)) : "0";
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.value);
            if (ur.found && normalized_unique != "0" &&
                normalized_unique != "1")
                aip_struct_runtime::fail($sformatf(
                    "%s.%s.unique must be 0 or 1", root, field));
            unique_each = (normalized_unique == "1");
        end
        have_size = sl.found;
        max_idx = -1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".size"}, size_str);
        if (fixed_size >= 0) begin
            if (have_size)
                aip_struct_runtime::fail($sformatf("%s.%s.size not allowed for static array (declared size %0d)", root, field, fixed_size));
            n = fixed_size;
        end else if (have_size) begin
            n = aip_struct_runtime::normalize_size(size_str,
                                                    {root, ".", field, ".size"});
        end else begin
            n = -1;
        end
        if (ol.found) begin
            bit gen;
            int glen;
            aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
            glen = (overall == "") ? 1 : aip_struct_runtime::overall_length(overall, gen);
            if (fixed_size >= 0 && gen && glen != fixed_size)
                aip_struct_runtime::fail($sformatf("%s.%s generator length %0d does not match static size %0d", root, field, glen, fixed_size));
            if (fixed_size >= 0 && !gen && glen > fixed_size)
                aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds static size", root, field));
            if (n >= 0 && gen && glen != n)
                aip_struct_runtime::fail($sformatf("%s.%s.size conflicts with generator length %0d", root, field, glen));
            if (n >= 0 && glen > n)
                aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds size", root, field));
            if (n < 0) n = glen;
        end
        max_idx = aip_struct_runtime::schema_array_index_extent(root, field) - 1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (n < 0) begin
            if (max_idx >= 0) n = max_idx + 1;
            else if (default_size > 0) n = default_size;
            else if (el.found)
                aip_struct_runtime::fail($sformatf("%s.%s.each given but size unknown", root, field));
            else n = 0;
        end
        aip_cmdline_diagnostic::select_value(sl.found ? {root, ".", field, ".size"} : {root, ".", field},
            sl.found ? sl.value : overall);
        if (fixed_size < 0) aip_struct_runtime::charge_allocation({root, ".", field}, n);
        arr = new[n]; from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::schema_array_slot_rule(
                root, field, ol, el, i, 1);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (each_used &&
            (aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "seq:") == 0 ||
             aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "perm:") == 0))
            aip_struct_runtime::fail($sformatf(
                "%s.%s seq/perm unsupported for string primitive schema array",
                root, field));
        if (unique_each)
            preflight_unique({root, ".", field}, each_str, winners,
                             from_each, default_val);
        for (int i = 0; i < n; i++) begin
            if (!winners[i].found) arr[i] = default_val;
            else begin
                aip_cmdline_diagnostic::select_value(winners[i].from_each ?
                    {root, ".", field, ".each"} : $sformatf("%s.%s[%0d]", root, field, i), winners[i].value);
                arr[i] = aip_struct_runtime::resolve_string(winners[i].value);
            end
        end
        if (max_idx >= n) begin
            aip_struct_runtime::lookup_t index_rule;
            index_rule = aip_struct_runtime::lookup_array_rule(root, field, $sformatf("[%0d]", max_idx));
            aip_cmdline_diagnostic::select_value($sformatf("%s.%s[%0d]", root, field, max_idx), index_rule.value);
            aip_struct_runtime::fail($sformatf("%s.%s indexed value out of range", root, field));
        end
        if (unique_each) begin
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, "1");
            for (int i = 0; i < n; i++) if (from_each[i]) begin
                int attempts = 0; bit dup;
                do begin
                    dup = 0;
                    for (int j = 0; j < n; j++)
                        if (j != i && (!from_each[j] || j < i) && arr[j] == arr[i]) dup = 1;
                    if (!dup) break;
                    attempts++;
                    if (attempts > 100) aip_struct_runtime::fail($sformatf("%s.%s.unique: candidate shortage",root,field));
                    aip_cmdline_diagnostic::push_value({root, ".", field, ".each"}, each_str);
                    arr[i] = aip_struct_runtime::resolve_string(each_str);
                    aip_cmdline_diagnostic::pop();
                end while (dup);
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value",root,field));
        end
        // caller performs final typed uniqueness/sort validation
    endfunction
endclass

// Adapter over the legacy real resolver (dynamic-array entry only): adds static-size checks and
// schema DEFAULT_SIZE behavior for real members without changing the legacy public signature.
class aip_struct_real_array_runtime;
    // 保留 schema 既有 API，文本溢出检查统一交给公共 real 解析层。
    static function bit decimal_overflow(string token);
        return aip_cmdline_real::decimal_overflow(token);
    endfunction

    static function real strict_parse(string token, string path);
        string c, tail, low; real v; int m;
        c = aip_str::remove_all_spaces(aip_str::strip(token)); low = aip_str::lower(c);
        if (c == "" || low=="nan" || low=="inf" || low=="+inf" || low=="-inf" ||
            low=="infinity" || low=="+infinity" || low=="-infinity")
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'",path,token));
        if (decimal_overflow(c))
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'",path,token));
        m = $sscanf(c, "%g%s", v, tail);
        if (m != 1 || v != v ||
            ((v > 0.0 || v < 0.0) && (v + v == v)))
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'",path,token));
        return v;
    endfunction
    // Validate the complete real grammar (every token consumed) before sampling; keeping validation
    // separate from sampling preserves the legacy RNG draw order.
    static function void validate_range_or_literal(string token, string path,
                                                   bit allow_unwrapped = 0);
        string s, p[$];
        real lo, hi;
        s = aip_str::strip(token);
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]") begin
            s = s.substr(1, s.len()-2);
            aip_struct_runtime::split_top(s, ":", p);
            if (p.size() != 2)
                aip_struct_runtime::fail($sformatf("%s invalid real range '%s'", path, token));
            lo = strict_parse(p[0], path);
            hi = strict_parse(p[1], path);
            if (lo > hi)
                aip_struct_runtime::fail($sformatf("%s invalid real range '%s'", path, token));
            return;
        end
        if (aip_str::str_find(s, "[") != -1 ||
            aip_str::str_find(s, "]") != -1)
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'", path, token));
        if (aip_str::str_find(s, ":") != -1) begin
            if (!allow_unwrapped)
                aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'", path, token));
            p = {};
            aip_struct_runtime::split_top(s, ":", p);
            if (p.size() != 2)
                aip_struct_runtime::fail($sformatf("%s invalid real range '%s'", path, token));
            lo = strict_parse(p[0], path);
            hi = strict_parse(p[1], path);
            if (lo > hi)
                aip_struct_runtime::fail($sformatf("%s invalid real range '%s'", path, token));
            return;
        end
        void'(strict_parse(s, path));
    endfunction

    // 不消费 RNG；权重须为 0..INT_MAX 整数，零权重项仍校验左侧，整组全零在抽样前报错。
    static function void validate_scalar_expr(string expr, string path);
        string s, p[$], wparts[$], item, left, right;
        int op_eq, op_sl, op, op_count;
        real start_val, end_val, step_val, weight_val;
        bit is_inc, has_positive_weight;
        aip_cmdline_diagnostic::select_expression(path, expr);
        s = aip_str::strip(expr);
        if (s == "")
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'", path, expr));

        // A wrapped group is a weighted group, not a parenthesized number; validate every arm,
        // including arms the eventual draw does not select.
        if ((s[0] == "{" || s[0] == "(") &&
            ((s[0] == "{" && s[s.len()-1] == "}") ||
             (s[0] == "(" && s[s.len()-1] == ")"))) begin
            wparts = {};
            aip_struct_runtime::split_top(s.substr(1, s.len()-2), ",", wparts);
            if (wparts.size() == 0)
                aip_struct_runtime::fail($sformatf("%s invalid real weight group '%s'", path, expr));
            has_positive_weight = 0;
            foreach (wparts[i]) begin
                item = aip_str::strip(wparts[i]);
                op_eq = aip_str::str_find(item, ":=");
                op_sl = aip_str::str_find(item, ":/");
                op_count = (op_eq >= 0) + (op_sl >= 0);
                if (op_count != 1)
                    aip_struct_runtime::fail($sformatf("%s invalid real weight item '%s'", path, item));
                op = (op_eq >= 0) ? op_eq : op_sl;
                left = aip_str::strip(item.substr(0, op-1));
                right = aip_str::strip(item.substr(op+2, item.len()-1));
                if (left == "" || right == "")
                    aip_struct_runtime::fail($sformatf("%s invalid real weight item '%s'", path, item));
                validate_range_or_literal(left, path);
                weight_val = strict_parse(right, path);
                if (weight_val < 0.0 || weight_val > 2147483647.0 || int'(weight_val) != weight_val)
                    aip_struct_runtime::fail($sformatf("%s real weight must be an integer >= 0 and <= 2147483647 in item[%0d] '%s'", path, i, item));
                if (weight_val > 0.0) has_positive_weight = 1;
            end
            if (!has_positive_weight)
                aip_struct_runtime::fail($sformatf("%s weighted group total must be > 0; all weights are zero in '%s'", path, expr));
            return;
        end
        if (s[0] == "{" || s[0] == "(" ||
            s[s.len()-1] == "}" || s[s.len()-1] == ")")
            aip_struct_runtime::fail($sformatf("%s invalid real expression '%s'", path, expr));

        // inc:/dec: take two or three literals; matching the prefix (not a substring search)
        // rejects trailing garbage such as `1inc:2:3`.
        if (s.len() >= 4 && (s.substr(0,3) == "inc:" || s.substr(0,3) == "dec:")) begin
            is_inc = (s.substr(0,3) == "inc:");
            p = {};
            aip_struct_runtime::split_top(s.substr(4), ":", p);
            if (p.size() < 2 || p.size() > 3)
                aip_struct_runtime::fail($sformatf("%s invalid real %s expression '%s'", path, is_inc ? "inc" : "dec", expr));
            start_val = strict_parse(p[0], path);
            end_val = strict_parse(p[1], path);
            step_val = (p.size() == 3) ? strict_parse(p[2], path) : 1.0;
            if (step_val <= 0.0 || (is_inc && start_val > end_val) ||
                (!is_inc && start_val < end_val))
                aip_struct_runtime::fail($sformatf("%s invalid real %s expression '%s'", path, is_inc ? "inc" : "dec", expr));
            return;
        end

        // Bracketed or unwrapped, a range is exactly one colon pair; any extra colon is garbage.
        if (s[0] == "[") begin
            if (s.len() < 3 || s[s.len()-1] != "]")
                aip_struct_runtime::fail($sformatf("%s invalid real range '%s'", path, expr));
            validate_range_or_literal(s, path, 1);
            return;
        end
        op = aip_str::str_find(s, ":=");
        if (op < 0) op = aip_str::str_find(s, ":/");
        if (op >= 0) begin
            // aip_cmdline_real accepts an unwrapped weight item; apply the same strict arm checks.
            left = aip_str::strip(s.substr(0, op-1));
            right = aip_str::strip(s.substr(op+2, s.len()-1));
            if (left == "" || right == "")
                aip_struct_runtime::fail($sformatf("%s invalid real weight item '%s'", path, expr));
            validate_range_or_literal(left, path);
            weight_val = strict_parse(right, path);
            if (weight_val < 0.0 || weight_val > 2147483647.0 || int'(weight_val) != weight_val)
                aip_struct_runtime::fail($sformatf("%s real weight must be an integer >= 0 and <= 2147483647 in item '%s'", path, expr));
            if (weight_val == 0.0)
                aip_struct_runtime::fail($sformatf("%s weighted group total must be > 0; all weights are zero in '%s'", path, expr));
            return;
        end
        if (aip_str::str_find(s, ":") >= 0) begin
            validate_range_or_literal(s, path, 1);
            return;
        end
        validate_range_or_literal(s, path);
    endfunction

    static function void validate_expr(string expr, string path);
        string s, parts[$];
        s = aip_str::remove_all_spaces(aip_str::strip(expr));
        if (s == "")
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'", path, expr));
        aip_struct_runtime::split_top(s, ",", parts);
        if (parts.size() == 0)
            aip_struct_runtime::fail($sformatf("%s invalid real literal '%s'", path, expr));
        foreach (parts[i]) validate_scalar_expr(parts[i], path);
    endfunction

    // 先完整校验再沿原算法抽样，校验本身不消费 RNG。
    static function real draw_strict(string expr, string path);
        real result;
        aip_cmdline_diagnostic::push_value(path, expr);
        validate_expr(expr, path);
        aip_cmdline_diagnostic::select_value(path, expr);
        result = aip_cmdline_real::parse_value(expr);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    static function bit deterministic_value(
        aip_struct_runtime::lookup_t winner,
        real default_val,
        string path,
        output real value);
        bit result;
        aip_cmdline_diagnostic::push_value(path, winner.value);
        result = deterministic_value_impl(winner, default_val, path, value);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 不消费 RNG；多候选或不可有限枚举返回 0，非法数字在外层绑定的索引上下文中 fatal。
    protected static function bit deterministic_value_impl(
        aip_struct_runtime::lookup_t winner,
        real default_val,
        string path,
        output real value);
        string tokens[$];
        real values[$];
        real candidate;
        int status;
        bit seen;
        if (!winner.found) begin
            value = default_val;
            return 1;
        end
        status = aip_struct_runtime::finite_candidate_tokens(
            winner.value, tokens, 3);
        if (status < 0) return 0;
        foreach (tokens[i]) begin
            candidate = strict_parse(tokens[i], path);
            seen = 0;
            foreach (values[j])
                if (values[j] == candidate) seen = 1;
            if (!seen) values.push_back(candidate);
        end
        if (values.size() != 1) return 0;
        value = values[0];
        return 1;
    endfunction

    // Real finite analysis is separate from integral enumeration: fixed/list and discrete inc/dec
    // can be proven, while continuous and weighted ranges keep bounded rejection.
    static function void preflight_unique(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        real default_val);
        aip_cmdline_diagnostic::push_value({path, ".unique"}, "1");
        preflight_unique_impl(path, each_expr, winners, from_each, default_val);
        aip_cmdline_diagnostic::pop();
    endfunction

    protected static function void preflight_unique_impl(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        real default_val);
        string tokens[$];
        real candidates[$];
        real fixed_values[];
        bit fixed_known[];
        real candidate;
        int status, each_slots, available;
        bit seen, occupied;

        fixed_values = new[winners.size()];
        fixed_known = new[winners.size()];
        each_slots = 0;
        foreach (winners[i]) begin
            if (from_each[i]) begin
                each_slots++;
                continue;
            end
            fixed_known[i] = deterministic_value(
                winners[i], default_val, $sformatf("%s[%0d]", path, i),
                fixed_values[i]);
        end
        foreach (fixed_values[i]) begin
            if (!fixed_known[i]) continue;
            for (int j = 0; j < i; j++)
                if (fixed_known[j] && fixed_values[i] == fixed_values[j])
                    aip_struct_runtime::fail($sformatf(
                        "%s.unique: duplicate fixed value at indices %0d and %0d",
                        path, j, i));
        end

        if (each_slots == 0) return;
        aip_cmdline_diagnostic::select_value({path, ".each"}, each_expr);
        status = aip_struct_runtime::finite_candidate_tokens(
            each_expr, tokens, 3);
        if (status < 0) return;
        foreach (tokens[i]) begin
            candidate = strict_parse(tokens[i], {path, ".each"});
            seen = 0;
            foreach (candidates[j])
                if (candidates[j] == candidate) seen = 1;
            if (!seen) candidates.push_back(candidate);
        end
        available = candidates.size();
        foreach (candidates[i]) begin
            occupied = 0;
            foreach (fixed_values[j])
                if (fixed_known[j] && fixed_values[j] == candidates[i]) begin
                    occupied = 1;
                    break;
                end
            if (occupied) available--;
        end
        if (available < each_slots)
            aip_struct_runtime::fail($sformatf(
                "%s.unique: only %0d candidates for %0d elements",
                path, available, each_slots));
    endfunction

    static function void postprocess(string root,string field,ref real arr[]);
        aip_cmdline_diagnostic::push({root, ".", field});
        postprocess_impl(root, field, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 对最终 real 数组校验 unique/sort 并原地排序，拒绝 seq/perm。
    protected static function void postprocess_impl(string root,string field,ref real arr[]);
        aip_struct_runtime::lookup_t ul,sl,ql; string u,s;
        if (aip_struct_runtime::metadata_mode) return;
        ul=aip_struct_runtime::lookup_array_rule(root,field,".unique"); sl=aip_struct_runtime::lookup_array_rule(root,field,".sort");
        ql=aip_struct_runtime::lookup_array_rule(root,field,".seq");
        aip_cmdline_diagnostic::select_value({root, ".", field, ".seq"}, ql.value);
        if(!ql.found) begin
            ql=aip_struct_runtime::lookup_array_rule(root,field,".perm");
            aip_cmdline_diagnostic::select_value({root, ".", field, ".perm"}, ql.value);
        end
        if(ql.found) aip_struct_runtime::fail($sformatf("%s.%s seq/perm unsupported for real primitive schema array",root,field));
        if(ul.found) begin aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ul.value); u=aip_str::lower(aip_str::strip(ul.value)); if(u!="0"&&u!="1") aip_struct_runtime::fail($sformatf("%s.%s.unique must be 0 or 1",root,field)); if(u=="1") for(int i=0;i<arr.size();i++) for(int j=0;j<i;j++) if(arr[i]==arr[j]) aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value",root,field)); end
        if(sl.found) begin aip_cmdline_diagnostic::select_value({root, ".", field, ".sort"}, sl.value); s=aip_str::lower(aip_str::strip(sl.value)); if(s!="asc"&&s!="desc"&&s!="none") aip_struct_runtime::fail($sformatf("%s.%s.sort must be asc, desc, or none",root,field)); if(s=="asc"||s=="desc") for(int i=1;i<arr.size();i++) begin real v; int j; v=arr[i]; j=i; while(j>0&&((s=="asc"&&v<arr[j-1])||(s=="desc"&&v>arr[j-1]))) begin arr[j]=arr[j-1]; j--; end arr[j]=v; end end
    endfunction

    static function void resolve_schema(string root, string field, string compact,
                                        real default_val, int fixed_size, int default_size,
                                        ref real arr[]);
        aip_cmdline_diagnostic::push_value({root, ".", field}, compact);
        resolve_schema_impl(root, field, compact, default_val, fixed_size, default_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按 schema 优先级确定大小与各槽位；动态数组先扣分配预算，unique 时先预检再抽样。
    protected static function void resolve_schema_impl(string root, string field, string compact,
                                        real default_val, int fixed_size, int default_size,
                                        ref real arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, il;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str, parts[$];
        int n, max_idx;
        bit each_used, unique_on;
        bit from_each[];
        if (aip_struct_runtime::metadata_mode) begin
            n = (fixed_size >= 0) ? fixed_size : 0;
            arr = new[n];
            foreach (arr[i]) arr[i] = default_val;
            return;
        end
        ol = aip_struct_runtime::lookup_field_with_compact(root, field, compact);
        sl = aip_struct_runtime::lookup_array_rule(root, field, ".size");
        el = aip_struct_runtime::lookup_array_rule(root, field, ".each");
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
        if (ol.found && overall == "") aip_struct_runtime::fail($sformatf("empty value for %s.%s", root, field));
        if (aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "seq:") == 0 ||
            aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "perm:") == 0)
            aip_struct_runtime::fail($sformatf(
                "%s.%s seq/perm unsupported for real primitive schema array",
                root, field));
        aip_cmdline_diagnostic::select_value({root, ".", field, ".size"}, sl.value);
        if (fixed_size >= 0) begin
            if (sl.found) aip_struct_runtime::fail($sformatf("%s.%s.size not allowed for static array", root, field));
            n = fixed_size;
        end else if (sl.found) begin
            n = aip_struct_runtime::normalize_size(sl.value,
                                                    {root, ".", field, ".size"});
        end else n = -1;
        max_idx = -1;
        if (overall != "") begin
            bit gen; int olen;
            aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
            olen = aip_struct_runtime::overall_length(overall, gen);
            if (n < 0) n = olen;
            if (olen > n) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds size", root, field));
            if (fixed_size >= 0 && olen > fixed_size) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds static size", root, field));
        end
        max_idx = aip_struct_runtime::schema_array_index_extent(root, field) - 1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (n < 0) begin
            if (max_idx >= 0) n = max_idx + 1;
            else if (default_size > 0) n = default_size;
            else if (each_str != "") aip_struct_runtime::fail($sformatf("%s.%s.each given but size unknown", root, field));
            else n = 0;
        end
        if (max_idx >= n) begin
            aip_struct_runtime::lookup_t index_rule;
            index_rule = aip_struct_runtime::lookup_array_rule(root, field, $sformatf("[%0d]", max_idx));
            aip_cmdline_diagnostic::select_value($sformatf("%s.%s[%0d]", root, field, max_idx), index_rule.value);
            aip_struct_runtime::fail($sformatf("%s.%s indexed value out of range", root, field));
        end
        aip_cmdline_diagnostic::select_value(sl.found ? {root, ".", field, ".size"} : {root, ".", field},
            sl.found ? sl.value : overall);
        if (fixed_size < 0) aip_struct_runtime::charge_allocation({root, ".", field}, n);
        arr = new[n]; from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::schema_array_slot_rule(
                root, field, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (each_used &&
            (aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "seq:") == 0 ||
             aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "perm:") == 0))
            aip_struct_runtime::fail($sformatf(
                "%s.%s seq/perm unsupported for real primitive schema array",
                root, field));
        begin
            aip_struct_runtime::lookup_t ur;
            string normalized_unique;
            ur = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
            normalized_unique = ur.found ?
                aip_str::lower(aip_str::strip(ur.value)) : "0";
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.value);
            if (ur.found && normalized_unique != "0" &&
                normalized_unique != "1")
                aip_struct_runtime::fail($sformatf(
                    "%s.%s.unique must be 0 or 1", root, field));
            unique_on = (normalized_unique == "1");
        end
        if (unique_on)
            preflight_unique({root, ".", field}, each_str, winners,
                             from_each, default_val);
        for (int i = 0; i < n; i++) begin
            if (!winners[i].found) arr[i] = default_val;
            else arr[i] = draw_strict(
                winners[i].value,
                winners[i].from_each ? {root, ".", field, ".each"} :
                $sformatf("%s.%s[%0d]", root, field, i));
        end
        begin
            aip_struct_runtime::lookup_t ur; bit enabled;
            ur = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.value);
            enabled = ur.found && aip_str::lower(aip_str::strip(ur.value)) == "1";
            if (ur.found && !enabled && aip_str::lower(aip_str::strip(ur.value)) != "0") aip_struct_runtime::fail($sformatf("%s.%s.unique must be 0 or 1", root, field));
            if (enabled) for (int i = 0; i < n; i++) if (from_each[i]) begin
                int attempts = 0; bit dup;
                do begin
                    dup = 0;
                    for (int j = 0; j < n; j++)
                        if (j != i && (!from_each[j] || j < i) && arr[j] == arr[i]) dup = 1;
                    if (!dup) break;
                    attempts++; if (attempts > 100) aip_struct_runtime::fail($sformatf("%s.%s.unique: candidate shortage", root, field));
                    arr[i] = draw_strict(each_str, $sformatf("%s.%s.each", root, field));
                end while (dup);
            end
            if (enabled) for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value", root, field));
        end
        // caller performs final typed uniqueness/sort validation
    endfunction

    static function void resolve(string name, string path, real default_val,
                                 int fixed_size, int default_size,
                                 ref real arr[]);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path));
        resolve_impl(name, path, default_val, fixed_size, default_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 旧 real 数组适配入口：先定长度，再依次填 default/each、整体列表、索引覆盖，保持既有覆盖顺序。
    protected static function void resolve_impl(string name, string path, real default_val,
                                 int fixed_size, int default_size,
                                 ref real arr[]);
        string base = (path == "") ? name : {path, ".", name};
        aip_struct_runtime::lookup_t sl, ol, el, il;
        string parts[$];
        int n, extent;

        aip_struct_runtime::validate_default_size(real'(default_size));
        sl = aip_struct_runtime::lookup({base, ".size"});
        aip_cmdline_diagnostic::select_value({base, ".size"}, sl.value);
        if (fixed_size >= 0) begin
            if (sl.found)
                aip_struct_runtime::fail($sformatf("%s.size not allowed for static array (declared size %0d)", name, fixed_size));
            n = fixed_size;
        end else if (sl.found) begin
            string ss = aip_str::strip(sl.value);
            if (ss == "" || aip_str::str_find(ss, ",") != -1 || aip_str::str_find(ss, ":") != -1)
                aip_struct_runtime::fail($sformatf("invalid %s.size '%s'", base, sl.value));
            n = aip_cmdline#(int)::parse_value(ss);
            if (n < 0 || n > 1000000)
                aip_struct_runtime::fail($sformatf("invalid %s.size %0d", base, n));
        end else n = -1;

        ol = aip_struct_runtime::lookup(base);
        aip_cmdline_diagnostic::select_value(base, ol.value);
        if (ol.found && ol.value != "") begin
            aip_struct_runtime::split_top(ol.value, ",", parts);
            if (fixed_size >= 0 && parts.size() > fixed_size)
                aip_struct_runtime::fail($sformatf("%s overall list has %0d elements, static array holds %0d", name, parts.size(), fixed_size));
            if (n >= 0 && parts.size() > n)
                aip_struct_runtime::fail($sformatf("%s overall list has %0d elements, .size is %0d", name, parts.size(), n));
            if (n < 0) n = parts.size();
        end

        extent = aip_struct_runtime::container_index_extent(base);
        if (n < 0) begin
            if (extent > 0) n = extent;
            else if (default_size > 0) n = default_size;
            else n = 0;
        end else if (extent > n)
            aip_struct_runtime::fail($sformatf("index %0d out of range for %s[%0d]", extent-1, base, n));

        el = aip_struct_runtime::lookup({base, ".each"});
        aip_cmdline_diagnostic::select_value({base, ".each"}, el.value);
        if (el.found && n == 0 && !ol.found)
            aip_struct_runtime::fail($sformatf("%s.each given but size is zero", base));
        arr = new[n];
        foreach (arr[i]) begin
            arr[i] = default_val;
            if (el.found && el.value != "") arr[i] = aip_cmdline_real::parse_value(el.value);
        end
        foreach (parts[i]) begin
            aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", base, i), ol.value);
            arr[i] = aip_cmdline_real::parse_value(parts[i]);
        end
        for (int i = 0; i < n; i++) begin
            il = aip_struct_runtime::lookup($sformatf("%s[%0d]", base, i));
            aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", base, i), il.value);
            if (il.found) begin
                if (il.value == "") aip_struct_runtime::fail($sformatf("empty value for %s[%0d]", base, i));
                arr[i] = aip_cmdline_real::parse_value(il.value);
            end
        end
    endfunction
endclass

// schema 枚举数组：typed 解析与后处理共用 E，按最终位值做唯一性检查与排序。
class aip_struct_enum_array_postprocess #(type E = int);
    // 对已生成数组应用 .unique/.sort（拒绝 .seq/.perm）；metadata 阶段直接返回。
    static function void apply(string root,string field,ref E arr[]);
        aip_struct_runtime::lookup_t ul, sl, ql;
        string u, s, path, generator_suffix;
        if (aip_struct_runtime::metadata_mode) return;
        path = {root, ".", field};
        aip_cmdline_diagnostic::push(path);
        ul = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
        sl = aip_struct_runtime::lookup_array_rule(root, field, ".sort");
        generator_suffix = ".seq";
        ql = aip_struct_runtime::lookup_array_rule(root, field, generator_suffix);
        if (!ql.found) begin
            generator_suffix = ".perm";
            ql = aip_struct_runtime::lookup_array_rule(root, field, generator_suffix);
        end
        if (ql.found) begin
            aip_cmdline_diagnostic::select_value({path, generator_suffix}, ql.value);
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for enum primitive schema array", path));
        end
        if (ul.found) begin
            aip_cmdline_diagnostic::select_value({path, ".unique"}, ul.value);
            u = aip_str::lower(aip_str::strip(ul.value));
            if (u != "0" && u != "1")
                aip_struct_runtime::fail($sformatf("%s.unique must be 0 or 1", path));
            if (u == "1") for (int i = 0; i < arr.size(); i++)
                for (int j = 0; j < i; j++) if (arr[i] === arr[j])
                    aip_struct_runtime::fail($sformatf("%s.unique: duplicate final value", path));
        end
        if (sl.found) begin
            aip_cmdline_diagnostic::select_value({path, ".sort"}, sl.value);
            s = aip_str::lower(aip_str::strip(sl.value));
            if (s != "asc" && s != "desc" && s != "none")
                aip_struct_runtime::fail($sformatf("%s.sort must be asc, desc, or none", path));
            if (s == "asc" || s == "desc") for (int i = 1; i < arr.size(); i++) begin
                E v;
                int j;
                v = arr[i];
                j = i;
                while (j > 0 && ((s == "asc" && v < arr[j-1]) ||
                                (s == "desc" && v > arr[j-1]))) begin
                    arr[j] = arr[j-1];
                    j--;
                end
                arr[j] = v;
            end
        end
        aip_cmdline_diagnostic::pop();
    endfunction

    static function void resolve(string root, string field, string compact,
                                 E default_val, int fixed_size, int default_size,
                                 input string names[$], input logic [1023:0] bits[$],
                                 ref E arr[]);
        aip_cmdline_diagnostic::push_value({root, ".", field}, compact);
        resolve_impl(root, field, compact, default_val, fixed_size, default_size,
                     names, bits, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    static function void resolve_impl(string root, string field, string compact,
                                 E default_val, int fixed_size, int default_size,
                                 input string names[$], input logic [1023:0] bits[$],
                                 ref E arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, il;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str;
        int n, max_idx;
        bit each_used, unique_on;
        bit from_each[];
        if (aip_struct_runtime::metadata_mode) begin
            n = (fixed_size >= 0) ? fixed_size : 0;
            arr = new[n];
            foreach (arr[i]) arr[i] = default_val;
            return;
        end
        ol = aip_struct_runtime::lookup_field_with_compact(root, field, compact);
        sl = aip_struct_runtime::lookup_array_rule(root, field, ".size");
        el = aip_struct_runtime::lookup_array_rule(root, field, ".each");
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
        if (ol.found && overall == "") aip_struct_runtime::fail($sformatf("empty value for %s.%s", root, field));
        if (aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "seq:") == 0 ||
            aip_str::str_find(aip_str::lower(aip_str::strip(overall)), "perm:") == 0)
            aip_struct_runtime::fail($sformatf("%s.%s seq/perm unsupported for enum primitive schema array", root, field));
        aip_cmdline_diagnostic::select_value({root, ".", field, ".size"}, sl.found ? sl.value : "");
        if (fixed_size >= 0) begin
            if (sl.found) aip_struct_runtime::fail($sformatf("%s.%s.size not allowed for static array (declared size %0d)", root, field, fixed_size));
            n = fixed_size;
        end else if (sl.found) begin
            n = aip_struct_runtime::normalize_size(sl.value,
                                                    {root, ".", field, ".size"});
        end else n = -1;
        max_idx = -1;
        if (ol.found) begin
            bit gen; int olen;
            aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
            olen = (overall == "") ? 1 : aip_struct_runtime::overall_length(overall, gen);
            if (n < 0) n = olen;
            if (olen > n) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds size", root, field));
            if (fixed_size >= 0 && olen > fixed_size) aip_struct_runtime::fail($sformatf("%s.%s overall list exceeds static size", root, field));
        end
        max_idx = aip_struct_runtime::schema_array_index_extent(root, field) - 1;
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (n < 0) begin
            if (max_idx >= 0) n = max_idx + 1;
            else if (default_size > 0) n = default_size;
            else if (each_str != "") aip_struct_runtime::fail($sformatf("%s.%s.each given but size unknown", root, field));
            else n = 0;
        end
        if (fixed_size < 0) aip_struct_runtime::charge_allocation({root, ".", field}, n);
        arr = new[n]; from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::schema_array_slot_rule(
                root, field, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({root, ".", field, ".each"}, each_str);
        if (each_used &&
            (aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "seq:") == 0 ||
             aip_str::str_find(aip_str::lower(aip_str::strip(each_str)), "perm:") == 0))
            aip_struct_runtime::fail($sformatf(
                "%s.%s seq/perm unsupported for enum primitive schema array",
                root, field));
        begin
            aip_struct_runtime::lookup_t ur;
            string normalized_unique;
            ur = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
            normalized_unique = ur.found ?
                aip_str::lower(aip_str::strip(ur.value)) : "0";
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.found ? ur.value : "0");
            if (ur.found && normalized_unique != "0" &&
                normalized_unique != "1")
                aip_struct_runtime::fail($sformatf(
                    "%s.%s.unique must be 0 or 1", root, field));
            unique_on = (normalized_unique == "1");
        end
        if (unique_on)
            aip_strict_enum_queue_runtime#(E)::preflight_unique(
                {root, ".", field}, each_str, winners, from_each,
                default_val, names, bits);
        for (int i = 0; i < n; i++) begin
            if (!winners[i].found) arr[i] = default_val;
            else arr[i] = aip_strict_enum_queue_runtime#(E)::draw(
                winners[i].value,
                winners[i].from_each ? {root, ".", field, ".each"} :
                $sformatf("%s.%s[%0d]", root, field, i),
                names, bits);
        end
        aip_cmdline_diagnostic::select_value({root, ".", field}, overall);
        if (max_idx >= n) aip_struct_runtime::fail($sformatf("%s.%s indexed value out of range", root, field));
        begin
            aip_struct_runtime::lookup_t ur; bit enabled;
            ur = aip_struct_runtime::lookup_array_rule(root, field, ".unique");
            aip_cmdline_diagnostic::select_value({root, ".", field, ".unique"}, ur.found ? ur.value : "0");
            enabled = ur.found && aip_str::lower(aip_str::strip(ur.value)) == "1";
            if (ur.found && !enabled && aip_str::lower(aip_str::strip(ur.value)) != "0") aip_struct_runtime::fail($sformatf("%s.%s.unique must be 0 or 1", root, field));
            if (enabled) begin
                for (int i = 0; i < n; i++) if (from_each[i]) begin
                    int attempts = 0; bit dup;
                    do begin
                        dup = 0;
                        for (int j = 0; j < n; j++)
                            if (j != i && (!from_each[j] || j < i) && arr[j] === arr[i]) dup = 1;
                        if (!dup) break;
                        attempts++;
                        if (attempts > 100) aip_struct_runtime::fail($sformatf("%s.%s.unique: candidate shortage", root, field));
                        arr[i] = aip_strict_enum_queue_runtime#(E)::draw(
                            each_str, {root, ".", field, ".each"},
                            names, bits);
                    end while (dup);
                end
            end
            if (enabled) for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf("%s.%s.unique: duplicate final value", root, field));
        end
    endfunction
endclass
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
