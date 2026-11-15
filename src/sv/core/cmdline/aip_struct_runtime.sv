// schema 共享运行时：字段元数据、配置查询、长度/索引校验、生成器及类型化来源，供 schema 宏和容器适配器调用。
// 内部 include 片段，只能由 aip_cmdline.sv 加载（直接包含会产生第二份 $unit/package 类型）。
// 所有 CLI 查询须经共享参数源 aip_cmdline_source，恢复后才会重取当前进程参数。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
class aip_struct_runtime;
    static int perm_values[string][$];
    static aip_svec_t perm_wide_values[string][$];
    static int allocation_scope_depth;
    static int allocation_used;
    static int ALLOCATION_LIMIT = 1000000;
    // Per-container field snapshots, keyed <container-root>|<index>|<relative-field-path>.
    static string field_values[string];
    static int field_kinds[string]; // 1 integral, 2 string, 3 real, 4 enum
    static string field_names[string][$];

    // Lossless typed descriptors for unique/sort: the string snapshots above would lose width, sign, precision
    // or the enum value. 1024 bits matches the schema width guard (1..1024).
    static logic [1023:0] field_bits[string];
    static int field_width[string];
    static bit field_signed[string];
    static real field_real_values[string];
    static string field_string_values[string];
    static int field_typed_kinds[string];
    // from_each: value came from ROOT.each.<suffix> and may be redrawn for unique; all other sources are fixed.
    static bit field_from_each[string];
    static string field_each_raw[string];
    // Struct arrays materialize in two passes: PHASE_FIXED records all explicit/overall/compact/default values,
    // then PHASE_EACH draws only .each fields against that complete fixed set (nested arrays share the phase).
    static int materialization_phase;
    static int PHASE_NORMAL = 0;
    static int PHASE_FIXED = 1;
    static int PHASE_EACH = 2;
    static int redraw_attempts[string];

    // Registered in the metadata pass: finite .each preflight needs it even before any concrete descriptor exists.
    static int schema_scalar_typed_kinds[string];
    static int schema_scalar_width[string];
    static bit schema_scalar_signed[string];
    // Lets preflight map enum names to packed values without the legacy 32-bit enum helper arrays.
    static string schema_enum_names[string][$];
    static logic [1023:0] schema_enum_bits[string][$];

    // Lets the postprocessor validate controls even for a zero-sized container with no descriptors.
    static string container_schema[string];
    static int container_sizes[string];

    // Schema shape, keyed <schema-type>|<field>; registered in a metadata-only pass because sizing happens
    // before any record (and thus field_values/field_names) exists.
    static int schema_field_kinds[string]; // 1 scalar, 2 primitive array, 3 struct, 4 struct array
    static string schema_field_children[string];
    static string schema_field_names[string][$];
    static bit schema_registered[string];
    static bit schema_registering[string];
    // Registration pass: lookups must not consume user rules or allocate dynamic members (static arrays still get a default buffer).
    static bit metadata_mode = 0;

    static function void begin_allocation_scope();
        if (allocation_scope_depth == 0) begin
            allocation_used = 0;
            perm_wide_values.delete();
        end
        allocation_scope_depth++;
    endfunction

    static function void end_allocation_scope();
        if (allocation_scope_depth > 0) allocation_scope_depth--;
    endfunction

    static function void charge_allocation(string path, int n);
        if (n < 0 || n > ALLOCATION_LIMIT)
            fail($sformatf("invalid dynamic allocation size %0d for %s", n, path));
        if (allocation_used > ALLOCATION_LIMIT - n)
            fail($sformatf("allocation budget exceeded before %s: used %0d, requested %0d, limit %0d",
                           path, allocation_used, n, ALLOCATION_LIMIT));
        allocation_used += n;
    endfunction

    typedef enum int {
        META_UNKNOWN = 0,
        META_SCALAR = 1,
        META_PRIMITIVE_ARRAY = 2,
        META_STRUCT = 3,
        META_STRUCT_ARRAY = 4,
        META_CONTROL = 5,
        META_SCALAR_ELEMENT = 6,
        META_BARE_ARRAY = 7
    } schema_match_kind_t;
    typedef struct {
        bit    found;
        string value;
        int    source;
        bit    from_each;
    } lookup_t;

    static function void schema_begin(string schema_id);
        schema_registering[schema_id] = 1;
    endfunction

    static function void schema_finish(string schema_id);
        schema_registering[schema_id] = 0;
        schema_registered[schema_id] = 1;
    endfunction

    static function bit schema_is_registered(string schema_id);
        return schema_registered.exists(schema_id) && schema_registered[schema_id];
    endfunction

    static function bit schema_is_registering(string schema_id);
        return schema_registering.exists(schema_id) && schema_registering[schema_id];
    endfunction

    static function void register_schema_field(string schema_id, string field,
                                               int kind, string child_id);
        string key;
        bit seen;
        key = {schema_id, "|", field};
        if (schema_field_kinds.exists(key)) begin
            if (schema_field_kinds[key] != kind ||
                schema_field_children[key] != child_id)
                fail($sformatf("conflicting schema metadata for %s.%s", schema_id, field));
            return;
        end
        schema_field_kinds[key] = kind;
        schema_field_children[key] = child_id;
        seen = 0;
        foreach (schema_field_names[schema_id][i])
            if (schema_field_names[schema_id][i] == field) seen = 1;
        if (!seen) schema_field_names[schema_id].push_back(field);
    endfunction

    static function void register_schema_typed_field(string schema_id,
                                                      string field,
                                                      int kind, int width,
                                                      bit is_signed);
        string key;
        key = {schema_id, "|", field};
        schema_scalar_typed_kinds[key] = kind;
        schema_scalar_width[key] = width;
        schema_scalar_signed[key] = is_signed;
    endfunction

    static function void register_schema_enum_value(string schema_id,
                                                     string field,
                                                     string enum_name,
                                                     logic [1023:0] bits);
        string key;
        bit seen;
        key = {schema_id, "|", field};
        seen = 0;
        foreach (schema_enum_names[key][i]) begin
            if (schema_enum_names[key][i] == enum_name &&
                schema_enum_bits[key][i] === bits) begin
                seen = 1;
                break;
            end
        end
        if (!seen) begin
            schema_enum_names[key].push_back(enum_name);
            schema_enum_bits[key].push_back(bits);
        end
    endfunction

    static function bit schema_typed_field(string schema_id, string suffix,
                                           output int kind, output int width,
                                           output bit is_signed);
        string toks[$];
        string child_id, next_id, tok, key;
        int i, fk;
        bit ok;
        kind = 0;
        width = 0;
        is_signed = 0;
        split_schema_path(suffix, toks, ok);
        if (!ok || toks.size() == 0) return 0;
        child_id = schema_id;
        for (i = 0; i < toks.size(); i++) begin
            tok = toks[i];
            next_id = "";
            if (!schema_field(child_id, tok, fk, next_id)) return 0;
            if (fk == META_STRUCT && i + 1 < toks.size()) begin
                child_id = next_id;
                continue;
            end
            if (fk != META_SCALAR || i + 1 != toks.size()) return 0;
            key = {child_id, "|", tok};
            if (!schema_scalar_typed_kinds.exists(key)) return 0;
            kind = schema_scalar_typed_kinds[key];
            width = schema_scalar_width.exists(key) ? schema_scalar_width[key] : 0;
            is_signed = schema_scalar_signed.exists(key) ? schema_scalar_signed[key] : 0;
            return 1;
        end
        return 0;
    endfunction

    // Names are case-insensitive, matching aip_cmdline_enum.
    static function bit schema_enum_literal(string schema_id, string suffix,
                                             string token,
                                             output logic [1023:0] bits);
        string toks[$];
        string child_id, next_id, tok, key, cleaned;
        int i, fk;
        bit ok;
        bits = '0;
        split_schema_path(suffix, toks, ok);
        if (!ok || toks.size() == 0) return 0;
        child_id = schema_id;
        cleaned = aip_str::lower(aip_str::strip(token));
        for (i = 0; i < toks.size(); i++) begin
            tok = toks[i];
            next_id = "";
            if (!schema_field(child_id, tok, fk, next_id)) return 0;
            if (fk == META_STRUCT && i + 1 < toks.size()) begin
                child_id = next_id;
                continue;
            end
            if (fk != META_SCALAR || i + 1 != toks.size()) return 0;
            key = {child_id, "|", tok};
            if (!schema_enum_names.exists(key)) return 0;
            foreach (schema_enum_names[key][j]) begin
                if (aip_str::lower(schema_enum_names[key][j]) == cleaned) begin
                    bits = schema_enum_bits[key][j];
                    return 1;
                end
            end
            return 0;
        end
        return 0;
    endfunction

    static function bit field_should_apply(bit from_each);
        if (materialization_phase == PHASE_FIXED) return !from_each;
        if (materialization_phase == PHASE_EACH) return from_each;
        return 1;
    endfunction

    static function bit nonstruct_array_should_apply();
        return materialization_phase != PHASE_EACH;
    endfunction

    static function bit nested_array_should_allocate();
        return materialization_phase != PHASE_EACH;
    endfunction

    static function bit schema_field(string schema_id, string field,
                                     output int kind, output string child_id);
        string key;
        key = {schema_id, "|", field};
        if (!schema_field_kinds.exists(key)) begin
            kind = META_UNKNOWN;
            child_id = "";
            return 0;
        end
        kind = schema_field_kinds[key];
        child_id = schema_field_children[key];
        return 1;
    endfunction

    // Scalar leaves only: array members' controls belong to the nested array resolver (prefix e.g. meta.).
    static function void collect_schema_scalar_suffixes(
            string schema_id, string prefix, ref string out[$]);
        int kind;
        string child_id, suffix, field;
        bit seen;
        foreach (schema_field_names[schema_id][i]) begin
            field = schema_field_names[schema_id][i];
            if (!schema_field(schema_id, field, kind, child_id)) continue;
            suffix = {prefix, field};
            if (kind == META_SCALAR) begin
                seen = 0;
                foreach (out[j]) if (out[j] == suffix) seen = 1;
                if (!seen) out.push_back(suffix);
            end else if (kind == META_STRUCT) begin
                collect_schema_scalar_suffixes(child_id, {suffix, "."}, out);
            end
        end
    endfunction

    // 公共 hard fatal，附带用户位置和配置原文；[AIP_STRUCT] 前缀保持不变。
    static function void fail(string msg);
        aip_cmdline_diagnostic::report("[AIP_STRUCT]", msg, `__FILE__, `__LINE__);
    endfunction

    static function bit is_ident_start(byte c);
        return ((c >= "A" && c <= "Z") || (c >= "a" && c <= "z") ||
                c == "_" || c == "$");
    endfunction

    static function bit is_ident_char(byte c);
        return is_ident_start(c) || (c >= "0" && c <= "9");
    endfunction

    static function void validate_root(string root);
        if (root == "") fail("schema ROOT must not be empty");
        if (!is_ident_start(root[0])) fail($sformatf("invalid ROOT '%s'", root));
        for (int i = 1; i < root.len(); i++) begin
            if (root[i] == ".") begin
                if (i == root.len()-1 || !is_ident_start(root[i+1]))
                    fail($sformatf("invalid ROOT '%s'", root));
            end else if (!is_ident_char(root[i])) begin
                fail($sformatf("invalid ROOT '%s'", root));
            end
        end
    endfunction

    static function void validate_generated_root(string root);
        // Generated paths may contain canonical numeric [index] segments.
        if (root == "") fail("schema ROOT must not be empty");
        for (int i = 0; i < root.len(); i++) begin
            if (root[i] == "[") begin
                int j = i+1;
                if (j >= root.len() || root[j] < "0" || root[j] > "9") fail($sformatf("invalid ROOT '%s'", root));
                while (j < root.len() && root[j] >= "0" && root[j] <= "9") j++;
                if (j >= root.len() || root[j] != "]") fail($sformatf("invalid ROOT '%s'", root));
                i = j;
            end else if (root[i] == ".") begin
                if (i == root.len()-1 || !is_ident_start(root[i+1])) fail($sformatf("invalid ROOT '%s'", root));
            end else if (!is_ident_char(root[i])) fail($sformatf("invalid ROOT '%s'", root));
        end
    endfunction

    static function lookup_t lookup(string key);
        lookup_t r;
        string vals[$];
        uvm_cmdline_processor clp;
        r = '{found:0, value:"", source:0, from_each:0};
        if (metadata_mode) return r;
        if (aip_cmdline_override::has(key)) begin
            r.found = 1;
            r.value = aip_cmdline_override::get_val(key);
            r.source = 2;
            return r;
        end
        clp = aip_cmdline_source::get();
        clp.get_arg_values($sformatf("+%s=", key), vals);
        if (vals.size() != 0) begin
            r.found = 1;
            r.value = vals[vals.size()-1];
            r.source = 1;
        end
        return r;
    endfunction

    // lookup(full) then lookup(leaf) would rank a plusarg full key above a runtime leaf key, breaking the legacy
    // four-level queue order; lookup_queue_rule therefore checks all runtime sources first.
    static function lookup_t lookup_plusarg_only(string key);
        lookup_t r;
        string vals[$];
        uvm_cmdline_processor clp;
        r = '{found:0, value:"", source:0, from_each:0};
        clp = aip_cmdline_source::get();
        clp.get_arg_values($sformatf("+%s=", key), vals);
        if (vals.size() != 0) begin
            r.found = 1;
            r.value = vals[vals.size()-1];
            r.source = 1;
        end
        return r;
    endfunction

    static function lookup_t lookup_queue_rule(string full_root,
                                               string leaf_root,
                                               string suffix = "");
        lookup_t r;
        string full_key, leaf_key;
        r = '{found:0, value:"", source:0, from_each:0};
        full_key = {full_root, suffix};
        leaf_key = {leaf_root, suffix};
        if (aip_cmdline_override::has(full_key)) begin
            r.found = 1;
            r.value = aip_cmdline_override::get_val(full_key);
            r.source = 4;
            return r;
        end
        if (leaf_key != full_key && aip_cmdline_override::has(leaf_key)) begin
            r.found = 1;
            r.value = aip_cmdline_override::get_val(leaf_key);
            r.source = 3;
            return r;
        end
        r = lookup_plusarg_only(full_key);
        if (r.found) begin
            r.source = 2;
            return r;
        end
        if (leaf_key != full_key) r = lookup_plusarg_only(leaf_key);
        return r;
    endfunction

    // key (already stripped of '+' and value) may use the PATH.NAME root or the legacy leaf fallback.
    static function bit queue_index_from_key(string full_root,
                                             string leaf_root,
                                             string key,
                                             string source_text,
                                             output int idx);
        string base, token;
        int close;
        idx = -1;
        base = "";
        if (aip_str::str_find(key, {full_root, "["}) == 0)
            base = full_root;
        else if (leaf_root != full_root &&
                 aip_str::str_find(key, {leaf_root, "["}) == 0)
            base = leaf_root;
        else
            return 0;
        close = aip_str::str_find(key, "]", base.len()+1);
        if (close <= base.len()+1 || close != key.len()-1)
            fail($sformatf("malformed index in %s%s", source_text, key));
        token = key.substr(base.len(), close);
        if (!schema_index_token(token, idx))
            fail($sformatf("noncanonical index in %s%s", source_text, key));
        if (idx > ALLOCATION_LIMIT)
            fail($sformatf("index exceeds primitive queue limit in %s%s",
                           source_text, key));
        return 1;
    endfunction

    // 每个键单独压/弹诊断帧：出错时定位到该键，且不残留给后续字段。
    static function int queue_index_extent(string full_root,
                                           string leaf_root);
        string keys[$], args[$];
        string key, arg;
        int eq, idx, max_idx;
        max_idx = -1;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            aip_cmdline_diagnostic::push_value(key, aip_cmdline_override::get_val(key));
            if (queue_index_from_key(full_root, leaf_root, key,
                                     "runtime key ", idx) && idx > max_idx)
                max_idx = idx;
            aip_cmdline_diagnostic::pop();
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            if (eq < 0) continue;
            key = arg.substr(0, eq-1);
            aip_cmdline_diagnostic::push_value(key, arg.substr(eq+1, arg.len()-1));
            if (queue_index_from_key(full_root, leaf_root, key, "+", idx) &&
                idx > max_idx)
                max_idx = idx;
            aip_cmdline_diagnostic::pop();
        end
        return max_idx + 1;
    endfunction

    static function int queue_index_rule_count(string full_root,
                                               string leaf_root);
        string keys[$], args[$];
        string key, arg;
        bit seen[int];
        int eq, idx;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (queue_index_from_key(full_root, leaf_root, key,
                                     "runtime key ", idx)) seen[idx] = 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            if (eq < 0) continue;
            key = arg.substr(0, eq-1);
            if (queue_index_from_key(full_root, leaf_root, key, "+", idx))
                seen[idx] = 1;
        end
        return seen.num();
    endfunction

    static function void queue_rule_stats(string full_root, string leaf_root,
                                          output int rules,
                                          output int controls,
                                          output string flags);
        lookup_t r;
        string raw;
        rules = queue_index_rule_count(full_root, leaf_root);
        controls = 0;
        flags = "";
        r = lookup_queue_rule(full_root, leaf_root);
        if (r.found) begin
            rules++;
            raw = aip_str::lower(aip_str::strip(r.value));
            if (raw.len() >= 4 && raw.substr(0,3) == "seq:") flags = "seq";
            else if (raw.len() >= 5 && raw.substr(0,4) == "perm:") flags = "perm";
        end
        r = lookup_queue_rule(full_root, leaf_root, ".size");
        if (r.found) begin rules++; controls++; flags = (flags == "") ? "size" : {flags, ",size"}; end
        r = lookup_queue_rule(full_root, leaf_root, ".each");
        if (r.found) begin rules++; controls++; flags = (flags == "") ? "each" : {flags, ",each"}; end
        r = lookup_queue_rule(full_root, leaf_root, ".unique");
        if (r.found) begin
            rules++;
            controls++;
            raw = aip_str::lower(aip_str::strip(r.value));
            if (raw == "1")
                flags = (flags == "") ? "unique" : {flags, ",unique"};
        end
        r = lookup_queue_rule(full_root, leaf_root, ".sort");
        if (r.found) begin
            rules++;
            controls++;
            raw = aip_str::lower(aip_str::strip(r.value));
            if (raw == "asc" || raw == "desc")
                flags = (flags == "") ? "sort" : {flags, ",sort"};
        end
        if (flags == "") flags = "none";
    endfunction

    static function bit summary_has_suffix(string text, string suffix);
        if (text.len() < suffix.len()) return 0;
        return text.substr(text.len()-suffix.len(), text.len()-1) == suffix;
    endfunction

    // Classified through schema metadata, so record descendants never reach the primitive exact-index parser.
    static function bit struct_summary_rule_known(string schema_id,
                                                  string suffix,
                                                  bit has_index);
        string child_suffix;
        int kind;
        if (suffix == "") return 1;
        if (!has_index && suffix == "size") return 1;
        if (!has_index &&
            (suffix == "each" || aip_str::str_find(suffix, "each.") == 0)) begin
            if (suffix == "each") return 1;
            child_suffix = suffix.substr(5, suffix.len()-1);
            kind = schema_classify_suffix(schema_id, child_suffix, 1);
        end else begin
            kind = schema_classify_suffix(schema_id, suffix, has_index);
        end
        return kind != META_UNKNOWN && kind != META_BARE_ARRAY;
    endfunction

    // Runtime entries shadow the same plusarg key and repeated plusargs keep the last value, as in lookup().
    static function void struct_queue_rule_stats(string root,
                                                 string schema_id,
                                                 output int rules,
                                                 output int controls,
                                                 output string flags);
        string keys[$], args[$];
        string selected[string];
        bit runtime_key[string];
        string key, arg, value, low;
        int eq;
        string suffix, index_text;
        bit has_index;
        bit have_size, have_each, have_unique, have_sort, have_seq, have_perm;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!schema_descendant_suffix(root, key, suffix, has_index,
                                          index_text) ||
                !struct_summary_rule_known(schema_id, suffix, has_index))
                continue;
            selected[key] = aip_cmdline_override::get_val(key);
            runtime_key[key] = 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            if (eq < 0) continue;
            key = arg.substr(0, eq-1);
            if (!schema_descendant_suffix(root, key, suffix, has_index,
                                          index_text) ||
                !struct_summary_rule_known(schema_id, suffix, has_index) ||
                runtime_key.exists(key))
                continue;
            value = arg.substr(eq+1, arg.len()-1);
            selected[key] = value;
        end
        rules = selected.num();
        controls = 0;
        have_size = 0;
        have_each = 0;
        have_unique = 0;
        have_sort = 0;
        have_seq = 0;
        have_perm = 0;
        foreach (selected[k]) begin
            string path_tokens[$];
            bit path_ok;
            low = aip_str::lower(aip_str::strip(selected[k]));
            void'(schema_descendant_suffix(root, k, suffix, has_index,
                                           index_text));
            split_schema_path(suffix, path_tokens, path_ok);
            if (summary_has_suffix(k, ".size")) begin
                controls++;
                have_size = 1;
            end
            if (path_ok)
                foreach (path_tokens[i])
                    if (path_tokens[i] == "each") have_each = 1;
            if (summary_has_suffix(k, ".unique")) begin
                controls++;
                if (low == "1") have_unique = 1;
            end
            if (summary_has_suffix(k, ".sort")) begin
                controls++;
                if (low == "asc" || low == "desc") have_sort = 1;
            end
            if (low.len() >= 4 && low.substr(0,3) == "seq:") have_seq = 1;
            if (low.len() >= 5 && low.substr(0,4) == "perm:") have_perm = 1;
        end
        flags = "";
        if (have_size) flags = "size";
        if (have_each) flags = (flags == "") ? "each" : {flags, ",each"};
        if (have_unique) flags = (flags == "") ? "unique" : {flags, ",unique"};
        if (have_sort) flags = (flags == "") ? "sort" : {flags, ",sort"};
        if (have_seq) flags = (flags == "") ? "seq" : {flags, ",seq"};
        if (have_perm) flags = (flags == "") ? "perm" : {flags, ",perm"};
        if (flags == "") flags = "none";
    endfunction

    static function int schema_registered_field_count(string schema_id);
        return schema_field_names[schema_id].size();
    endfunction

    // Specificity order, outer selectors first: cfgs[2].channels[1], cfgs[2].channels.each,
    // cfgs.each.channels[1], cfgs.each.channels.each. Single source of fallback order for every consumer.
    static function void recursive_selector_paths(string concrete,
                                                  ref string paths[$]);
        string literals[$];
        string selectors[$];
        string prefixes[$];
        string next[$];
        int start, close;
        paths = {};
        start = 0;
        for (int i = 0; i < concrete.len(); i++) begin
            if (concrete[i] != "[") continue;
            close = aip_str::str_find(concrete, "]", i + 1);
            if (close <= i + 1) begin
                paths.push_back(concrete);
                return;
            end
            literals.push_back(concrete.substr(start, i - 1));
            selectors.push_back(concrete.substr(i, close));
            start = close + 1;
            i = close;
        end
        if (selectors.size() == 0) begin
            paths.push_back(concrete);
            return;
        end
        literals.push_back((start < concrete.len()) ?
                           concrete.substr(start, concrete.len() - 1) : "");
        prefixes.push_back("");
        foreach (selectors[i]) begin
            next = {};
            foreach (prefixes[p]) begin
                next.push_back({prefixes[p], literals[i], selectors[i]});
                next.push_back({prefixes[p], literals[i], ".each"});
            end
            prefixes = next;
        end
        foreach (prefixes[p]) paths.push_back({prefixes[p], literals[literals.size()-1]});
    endfunction

    static function lookup_t lookup_recursive_selectors(string concrete,
                                                         string suffix,
                                                         output string selected_key);
        lookup_t r;
        string paths[$];
        selected_key = {concrete, suffix};
        recursive_selector_paths(concrete, paths);
        foreach (paths[i]) begin
            selected_key = {paths[i], suffix};
            r = lookup(selected_key);
            if (r.found) return r;
        end
        return r;
    endfunction

    static function lookup_t lookup_array_index_rule(string root, string field,
                                                      int idx);
        lookup_t r;
        string selected_key;
        r = lookup_recursive_selectors(
            root, {".", field, $sformatf("[%0d]", idx)}, selected_key);
        return r;
    endfunction

    // Per parent branch: explicit index > field overall slot > each rule; only then relax the next outer selector.
    static function lookup_t lookup_field(string root, string field);
        lookup_t r;
        string inner_base, inner_suffix, inner_key, inner_desc_key;
        string parent_paths[$];
        int inner_idx;
        if (!field_location(root, field, inner_base, inner_idx, inner_suffix,
                            inner_desc_key))
            return lookup({root, ".", field});
        recursive_selector_paths(inner_base, parent_paths);
        foreach (parent_paths[p]) begin
            bit slot_found;
            string raw, slot;
            inner_key = {parent_paths[p], $sformatf("[%0d].%s", inner_idx,
                                                   inner_suffix)};
            r = lookup(inner_key);
            if (r.found) begin
                r.source += 20;
                return r;
            end
            inner_key = {parent_paths[p], ".", inner_suffix};
            r = lookup(inner_key);
            if (r.found) begin
                raw = aip_str::strip(r.value);
                if ((raw.len() >= 4 && raw.substr(0,3) == "seq:") ||
                    (raw.len() >= 5 && raw.substr(0,4) == "perm:")) begin
                    r.source += 10;
                    return r;
                end
                slot = overall_slot(r.value, inner_idx, inner_key, slot_found);
                if (slot_found) begin
                    r.value = slot;
                    r.source += 10;
                    return r;
                end
            end
            inner_key = {parent_paths[p], ".each.", inner_suffix};
            r = lookup(inner_key);
            if (r.found) begin
                r.from_each = 1;
                return r;
            end
        end
        return r;
    endfunction

    // Unlike scalar resolvers, never picks randomly from a list: slot idx takes item idx; a perm: is shuffled once and cached.
    static function string overall_slot(string raw, int idx, input string cache_key,
                                        output bit found);
        string s, p[$];
        string pk;
        aip_svec_t a, b, st, count, value, pv;
        int n, pj;
        found = 0;
        s = aip_str::strip(raw);
        if (s == "") return "";
        if (s.len() >= 4 && s.substr(0,3) == "seq:") begin
            split_top(s, ":", p);
            if (p.size() < 3 || p.size() > 4) fail($sformatf("invalid seq generator '%s'", raw));
            if (!finite_int_literal(p[1], a) || !finite_int_literal(p[2], b) ||
                (p.size() == 4 && !finite_int_literal(p[3], st)))
                fail($sformatf("invalid seq generator '%s'", raw));
            if (p.size() != 4) st = 1;
            if (st <= 0 || a > b) fail($sformatf("invalid seq generator '%s'", raw));
            value = a + aip_svec_t'(idx) * st;
            if (value <= b) begin found = 1; return $sformatf("%0d", value); end
            return "";
        end
        if (s.len() >= 5 && s.substr(0,4) == "perm:") begin
            split_top(s, ":", p);
            if (p.size() != 3) fail($sformatf("invalid perm generator '%s'", raw));
            if (!finite_int_literal(p[1], a) || !finite_int_literal(p[2], b))
                fail($sformatf("invalid perm generator '%s'", raw));
            if (a > b) fail($sformatf("invalid perm generator '%s'", raw));
            count = b - a + 1;
            if (count <= 0 || count > 1000000)
                fail($sformatf("perm generator expands outside 1..1000000 elements: '%s'", raw));
            n = int'(count);
            if (idx >= n) return "";
            pk = {"field|", cache_key, "|", raw};
            if (!perm_wide_values.exists(pk)) begin
                perm_wide_values[pk].delete();
                for (int pi = 0; pi < n; pi++) perm_wide_values[pk].push_back(a + pi);
                for (int pi = n-1; pi > 0; pi--) begin
                    pj = $urandom_range(pi);
                    pv = perm_wide_values[pk][pi];
                    perm_wide_values[pk][pi] = perm_wide_values[pk][pj];
                    perm_wide_values[pk][pj] = pv;
                end
            end
            found = 1;
            return $sformatf("%0d", perm_wide_values[pk][idx]);
        end
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]" &&
            aip_str::str_find(s, ":") == -1)
            s = s.substr(1, s.len()-2);
        split_top(s, ",", p);
        if (idx < p.size()) begin found = 1; return p[idx]; end
        return "";
    endfunction

    static function void split_top(string s, byte delimiter, ref string out[$]);
        int b, c, p;
        bit quoted, escaped;
        string cur = "";
        out = {};
        for (int i = 0; i < s.len(); i++) begin
            byte ch = s[i];
            if (quoted) begin
                cur = {cur, ch};
                if (escaped) begin
                    if (ch != "\\" && ch != 8'd34)
                        fail($sformatf("invalid escape in '%s'", s));
                    escaped = 0;
                end else if (ch == "\\") escaped = 1;
                else if (ch == 8'd34) quoted = 0;
                continue;
            end
            if (ch == 8'd34) begin quoted = 1; cur = {cur, ch}; continue; end
            case (ch)
                "{": b++;
                "}": begin b--; if (b < 0) fail($sformatf("unbalanced delimiters in '%s'", s)); end
                "[": c++;
                "]": begin c--; if (c < 0) fail($sformatf("unbalanced delimiters in '%s'", s)); end
                "(": p++;
                ")": begin p--; if (p < 0) fail($sformatf("unbalanced delimiters in '%s'", s)); end
            endcase
            if (ch == delimiter && b == 0 && c == 0 && p == 0) begin
                if (aip_str::strip(cur) == "") fail("empty compact/list slot");
                out.push_back(aip_str::strip(cur));
                cur = "";
            end else cur = {cur, ch};
        end
        if (quoted || escaped || b != 0 || c != 0 || p != 0)
            fail($sformatf("unbalanced delimiters or quote in '%s'", s));
        if (aip_str::strip(cur) != "") out.push_back(aip_str::strip(cur));
        else if (s != "") fail("trailing delimiter in compact/list value");
    endfunction

    static function string decode_string(string token);
        string s = aip_str::strip(token);
        string r = "";
        if (s == "") return "";
        if (s[0] == 8'd34) begin
            if (s.len() < 2 || s[s.len()-1] != 8'd34)
                fail($sformatf("unterminated quoted string '%s'", token));
            for (int i = 1; i < s.len()-1; i++) begin
                if (s[i] == "\\") begin
                    if (i+1 >= s.len()-1 || (s[i+1] != "\\" && s[i+1] != 8'd34))
                        fail($sformatf("invalid string escape '%s'", token));
                    r = {r, s[i+1]}; i++;
                end else r = {r, s[i]};
            end
            return r;
        end
        if (s[s.len()-1] == 8'd34) fail($sformatf("invalid quoted string '%s'", token));
        if (aip_str::str_find(s, "\\") != -1)
            fail($sformatf("backslash must be escaped in quoted string '%s'", token));
        return s;
    endfunction

    static function string normalize_string_list_wrapper(string raw);
        string s = aip_str::strip(raw);
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]" &&
            aip_str::str_find(s, ":") == -1)
            return s.substr(1, s.len()-2);
        return s;
    endfunction

    static function string resolve_string(string text);
        string parts[$];
        string s = normalize_string_list_wrapper(text);
        if (s == "") return "";
        split_top(s, ",", parts);
        if (parts.size() > 1)
            return decode_string(parts[$urandom_range(parts.size()-1)]);
        return decode_string(s);
    endfunction

    static function bit compact_member(string compact, string field, output string value);
        string body;
        string segs[$];
        bit member_found = 0;
        value = "";
        if (compact == "") return 0;
        if (compact.len() < 2 || compact[0] != "{" || compact[compact.len()-1] != "}")
            fail($sformatf("compact value must be wrapped in {}: %s", compact));
        body = compact.substr(1, compact.len()-2);
        if (aip_str::strip(body) == "") return 0;
        split_top(body, ",", segs);
        foreach (segs[i]) begin
            int eq = aip_str::str_find(segs[i], "=");
            string k;
            if (eq <= 0)
                fail($sformatf("malformed compact member '%s'", segs[i]));
            k = aip_str::strip(segs[i].substr(0, eq-1));
            if (k == field) begin
                if (member_found) fail($sformatf("duplicate compact field '%s'", field));
                member_found = 1;
                value = aip_str::strip(segs[i].substr(eq+1, segs[i].len()-1));
            end
        end
        return member_found;
    endfunction

    // An indexed compact member beats field-overall and .each rules but not an exact ROOT[i].field rule;
    // on a single struct it stays below the direct child key.
    static function lookup_t lookup_field_with_compact(string root, string field,
                                                        string compact);
        lookup_t r;
        string cv;
        bit cf;
        aip_cmdline_diagnostic::push_value(root, compact);
        r = lookup_field(root, field);
        if (aip_str::str_find(root, "[") > 0 && r.source < 20) begin
            cf = compact_member(compact, field, cv);
            if (cf) begin
                r.found = 1;
                r.value = cv;
                r.source = 5;
                r.from_each = 0;
            end
        end else if (!r.found) begin
            cf = compact_member(compact, field, cv);
            if (cf) begin
                r.found = 1;
                r.value = cv;
                r.source = 5;
                r.from_each = 0;
            end
        end
        aip_cmdline_diagnostic::pop();
        return r;
    endfunction

    static function lookup_t lookup_array_rule(string root, string field, string suffix);
        lookup_t r;
        string selected_key;
        r = lookup_recursive_selectors(root, {".", field, suffix}, selected_key);
        return r;
    endfunction

    // Inherits via the outer-array fallback like size/postprocess controls, but cache_key names the concrete
    // owner, not the shared canonical plusarg.
    static function lookup_t lookup_container_rule(string root, string suffix,
                                                    output string cache_key);
        lookup_t r;
        string selected_key;
        cache_key = {root, suffix};
        r = lookup_recursive_selectors(root, suffix, selected_key);
        return r;
    endfunction

    // Dots separate tokens and each [index] is its own token. Deliberately permissive about identifiers:
    // the metadata lookup decides whether a path belongs to the schema.
    static function void split_schema_path(string path, ref string toks[$],
                                            output bit ok);
        string cur;
        int i, j;
        byte ch;
        toks = {};
        cur = "";
        ok = 1;
        if (path == "") return;
        i = 0;
        while (i < path.len()) begin
            ch = path[i];
            if (ch == ".") begin
                if (cur == "") begin ok = 0; return; end
                toks.push_back(cur);
                cur = "";
                i++;
            end else if (ch == "[") begin
                if (cur != "") begin
                    toks.push_back(cur);
                    cur = "";
                end
                j = i + 1;
                while (j < path.len() && path[j] != "]") j++;
                if (j >= path.len() || j == i + 1) begin ok = 0; return; end
                toks.push_back(path.substr(i, j));
                i = j + 1;
                // Eat the dot after a selector, else the dot branch rejects nested[0].base as an empty token.
                if (i < path.len() && path[i] == ".") begin
                    i++;
                    if (i >= path.len() || path[i] == "." ||
                        path[i] == "[" || path[i] == "]") begin
                        ok = 0;
                        return;
                    end
                end else if (i < path.len() && path[i] != "[") begin
                    ok = 0;
                    return;
                end
            end else if (ch == "]") begin
                ok = 0;
                return;
            end else begin
                cur = {cur, ch};
                i++;
            end
        end
        if (cur != "") toks.push_back(cur);
        else if (path.len() > 0 && path[path.len()-1] == ".") ok = 0;
    endfunction

    static function bit schema_looks_index(string tok);
        return (tok.len() >= 2 && tok[0] == "[" && tok[tok.len()-1] == "]");
    endfunction

    // Canonical decimal only, without the value parser, so a malformed unrelated key cannot cause a fatal.
    static function bit schema_index_token(string tok, output int idx);
        int v, d;
        idx = -1;
        if (!schema_looks_index(tok)) return 0;
        if (tok.len() == 3 && tok[1] == "0") begin idx = 0; return 1; end
        if (tok.len() < 3 || tok[1] < "1" || tok[1] > "9") return 0;
        v = 0;
        for (int i = 1; i < tok.len()-1; i++) begin
            if (tok[i] < "0" || tok[i] > "9") return 0;
            d = tok[i] - "0";
            if (v > 100000000 || (v == 100000000 && d > 0)) return 0;
            v = v * 10 + d;
        end
        idx = v;
        return 1;
    endfunction

    // key has '+' and '=value' already stripped. All selector branches are checked so inherited .each paths get
    // the same strict index check; a matching prefix without one canonical [decimal] is malformed, not ignored.
    static function bit schema_array_index_from_key(string root, string field,
                                                     string key,
                                                     string source_text,
                                                     output int idx);
        string paths[$];
        idx = -1;
        recursive_selector_paths(root, paths);
        foreach (paths[p]) begin
            string prefix;
            int close;
            prefix = {paths[p], ".", field, "["};
            if (aip_str::str_find(key, prefix) != 0) continue;
            close = aip_str::str_find(key, "]", prefix.len());
            if (close < prefix.len() || close != key.len()-1)
                fail($sformatf("malformed index in %s%s", source_text, key));
            if (!schema_index_token(key.substr(prefix.len()-1, close), idx))
                fail($sformatf("noncanonical index in %s%s", source_text, key));
            return 1;
        end
        return 0;
    endfunction

    // Separate from container_index_extent() so schema arrays never feed partially parsed text to the legacy int parser.
    static function int schema_array_index_extent(string root, string field);
        string keys[$], args[$];
        string key, arg;
        int eq, idx, max_idx;
        max_idx = -1;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (schema_array_index_from_key(root, field, key,
                                            "runtime key ", idx) &&
                idx > max_idx)
                max_idx = idx;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (schema_array_index_from_key(root, field, key, "+", idx) &&
                idx > max_idx)
                max_idx = idx;
        end
        return max_idx + 1;
    endfunction

    static function bit schema_control(string tok);
        return (tok == "size" || tok == "each" || tok == "unique" || tok == "sort");
    endfunction

    static function bit schema_path_has_selector(ref string toks[$]);
        foreach (toks[i]) begin
            if (toks[i] == "each" || schema_looks_index(toks[i])) return 1;
        end
        return 0;
    endfunction

    // Returns a schema_match_kind_t. META_BARE_ARRAY = known path crossing an array field without a selector:
    // callers report it, while unrelated keys (META_UNKNOWN) are ignored.
    static function int schema_match_path(input string schema_id, ref string toks[$],
                                          input int pos, input bit allow_array_direct);
        int kind, sub;
        string child_id;
        string tok;
        if (pos >= toks.size()) return META_UNKNOWN;
        tok = toks[pos];
        if (tok == "each" || schema_looks_index(tok)) return META_UNKNOWN;
        if (!schema_field(schema_id, tok, kind, child_id)) return META_UNKNOWN;

        if (kind == META_SCALAR) begin
            if (pos + 1 >= toks.size()) return META_SCALAR;
            if (pos + 2 == toks.size() &&
                (toks[pos+1] == "unique" || toks[pos+1] == "sort"))
                return META_CONTROL;
            return META_UNKNOWN;
        end

        if (kind == META_PRIMITIVE_ARRAY) begin
            if (!allow_array_direct) begin
                // Known operation on this array, but the enclosing record has no selector.
                if (pos + 1 >= toks.size()) return META_BARE_ARRAY;
                if (schema_control(toks[pos+1]) || schema_looks_index(toks[pos+1]))
                    return META_BARE_ARRAY;
                return META_UNKNOWN;
            end
            if (pos + 1 >= toks.size()) return META_PRIMITIVE_ARRAY;
            if (pos + 2 == toks.size() && schema_control(toks[pos+1]))
                return META_CONTROL;
            if (schema_looks_index(toks[pos+1])) begin
                if (pos + 2 >= toks.size()) return META_SCALAR_ELEMENT;
                return META_UNKNOWN;
            end
            return META_UNKNOWN;
        end

        if (kind == META_STRUCT) begin
            if (pos + 1 >= toks.size()) return META_STRUCT;
            return schema_match_path(child_id, toks, pos + 1, allow_array_direct);
        end

        if (kind == META_STRUCT_ARRAY) begin
            if (!allow_array_direct) begin
                // Enclosing record not selected yet: a selector right after the field picks the nested array, not
                // the outer one. Probe the child tree only to tell known paths (still bare) from unrelated keys.
                if (pos + 1 >= toks.size()) return META_BARE_ARRAY;
                if (pos + 2 == toks.size() && schema_control(toks[pos+1]))
                    return META_BARE_ARRAY;
                if (toks[pos+1] == "each" || schema_looks_index(toks[pos+1])) begin
                    if (pos + 2 >= toks.size()) return META_BARE_ARRAY;
                    sub = schema_match_path(child_id, toks, pos + 2, 1);
                end else begin
                    sub = schema_match_path(child_id, toks, pos + 1, 0);
                end
                if (sub != META_UNKNOWN) return META_BARE_ARRAY;
                return META_UNKNOWN;
            end
            if (pos + 1 >= toks.size()) begin
                return META_STRUCT_ARRAY;
            end
            if (pos + 2 == toks.size() && schema_control(toks[pos+1])) begin
                return META_CONTROL;
            end
            if (toks[pos+1] == "each" || schema_looks_index(toks[pos+1])) begin
                if (pos + 2 >= toks.size()) return META_STRUCT;
                return schema_match_path(child_id, toks, pos + 2, 1);
            end
            // Child without an each/[index] selector: probe only to tell it from an unrelated key; still bare.
            sub = schema_match_path(child_id, toks, pos + 1, 0);
            if (sub != META_UNKNOWN) return META_BARE_ARRAY;
            return META_UNKNOWN;
        end
        return META_UNKNOWN;
    endfunction

    static function int schema_classify_suffix(input string schema_id, input string suffix,
                                                input bit allow_array_direct);
        string toks[$];
        bit ok;
        split_schema_path(suffix, toks, ok);
        if (!ok) return META_UNKNOWN;
        if (toks.size() == 0) return META_STRUCT;
        return schema_match_path(schema_id, toks, 0, allow_array_direct);
    endfunction

    // 只有 schema 认得的 .each 后代才算数，无关参数忽略。
    // 返回真时诊断已选中该 key/raw，调用方据此定位 size unknown 等错误。
    static function bit has_container_each_schema(string root, string schema_id);
        string keys[$];
        string args[$];
        string key, arg, suffix, index_text;
        string toks[$];
        bit has_index, ok;
        int kind, eq;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || has_index)
                continue;
            split_schema_path(suffix, toks, ok);
            if (!ok || toks.size() == 0 || toks[0] != "each") continue;
            aip_cmdline_diagnostic::select_value(key, aip_cmdline_override::get_val(key));
            if (toks.size() == 1) return 1;
            kind = schema_match_path(schema_id, toks, 1, 1);
            if (kind == META_BARE_ARRAY) begin
                if (toks[toks.size()-1] == "unique" ||
                    toks[toks.size()-1] == "sort")
                    fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
                return 1;
            end
            if (kind != META_UNKNOWN) return 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || has_index)
                continue;
            split_schema_path(suffix, toks, ok);
            if (!ok || toks.size() == 0 || toks[0] != "each") continue;
            aip_cmdline_diagnostic::select_value(key,
                (eq >= 0 && eq+1 < arg.len()) ? arg.substr(eq+1, arg.len()-1) : "");
            if (toks.size() == 1) return 1;
            kind = schema_match_path(schema_id, toks, 1, 1);
            if (kind == META_BARE_ARRAY) begin
                if (toks[toks.size()-1] == "unique" ||
                    toks[toks.size()-1] == "sort")
                    fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
                return 1;
            end
            if (kind != META_UNKNOWN) return 1;
        end
        return 0;
    endfunction

    static function void validate_compact(string compact, string fields[$]);
        string body, segs[$];
        if (compact == "") return;
        if (compact.len() < 2 || compact[0] != "{" || compact[compact.len()-1] != "}")
            fail($sformatf("compact value must be wrapped in {}: %s", compact));
        body = compact.substr(1, compact.len()-2);
        if (aip_str::strip(body) == "") return;
        split_top(body, ",", segs);
        foreach (segs[i]) begin
            int eq = aip_str::str_find(segs[i], "=");
            string k;
            bit known = 0;
            if (eq <= 0)
                fail($sformatf("malformed compact member '%s'", segs[i]));
            k = aip_str::strip(segs[i].substr(0, eq-1));
            foreach (fields[j]) if (fields[j] == k) known = 1;
            if (!known) fail($sformatf("unknown compact field '%s'", k));
            for (int j = 0; j < i; j++) begin
                int peq = aip_str::str_find(segs[j], "=");
                if (peq > 0 && aip_str::strip(segs[j].substr(0, peq-1)) == k)
                    fail($sformatf("duplicate compact field '%s'", k));
            end
        end
    endfunction

    static function void check_field_name(string field);
        if (field == "size" || field == "each" || field == "unique" || field == "sort")
            fail($sformatf("reserved schema field '%s'", field));
    endfunction

    static function void check_width(int width, string field);
        if (width < 1 || width > 1024)
            fail($sformatf("field '%s' has unsupported width %0d (1..1024)", field, width));
    endfunction

    // 默认值和求值结果共用此检查；错误文本沿用旧版，供脚本检索。
    static function void check_real(real value, string field);
        bit [63:0] encoding;
        encoding = $realtobits(value);
        if (encoding[62:52] == 11'h7ff && encoding[51:0] != 0)
            fail($sformatf("field '%s' default is NaN", field));
        if (!aip_cmdline_real::is_finite(value))
            fail($sformatf("field '%s' default is not finite", field));
    endfunction

    static function void check_nonempty(string value, string field);
        if (aip_str::strip(value) == "")
            fail($sformatf("empty value for non-string field '%s'", field));
    endfunction

    static function void check_integral_default(bit has_unknown, string field);
        if (has_unknown)
            fail($sformatf("integral default for field '%s' contains X/Z", field));
    endfunction

    static function void check_enum_default(bit valid, string field);
        if (!valid)
            fail($sformatf("enum default for field '%s' is not a declared item", field));
    endfunction

    // An explicit .size rule, when present, stays authoritative over this inferred extent.
    static function int container_index_extent(string root);
        int max_idx = -1;
        string keys[$]; string args[$];
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            string a = keys[k]; int q, idx, width;
            if (aip_str::str_find(a, {root, "["}) != 0) continue;
            q = aip_str::str_find(a, "]", root.len()+1);
            if (q <= root.len()+1) continue;
            idx = aip_str::str_to_num(a.substr(root.len()+1, q-1), width);
            if (width > 0 && idx >= 0 && idx > max_idx) max_idx = idx;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            string a = args[k]; int q, idx, width;
            if (a == "" || a[0] != "+") continue;
            a = a.substr(1, a.len()-1);
            if (aip_str::str_find(a, {root, "["}) != 0) continue;
            q = aip_str::str_find(a, "]", root.len()+1);
            if (q <= root.len()+1) continue;
            idx = aip_str::str_to_num(a.substr(root.len()+1, q-1), width);
            if (width > 0 && idx >= 0 && idx > max_idx) max_idx = idx;
        end
        return max_idx + 1;
    endfunction

    // A generator gives the complete length; a plain list gives one slot per top-level item. Never draws RNG:
    // lengths are normalized before any record is materialized.
    static function int overall_length(string raw, output bit is_generator);
        string s, p[$];
        aip_svec_t a, b, step, count;
        is_generator = 0;
        s = aip_str::strip(raw);
        if (s == "") return 0;
        if (s.len() >= 4 && s.substr(0,3) == "seq:") begin
            is_generator = 1;
            split_top(s, ":", p);
            if (p.size() < 3 || p.size() > 4)
                fail($sformatf("invalid seq generator '%s'", raw));
            if (!finite_int_literal(p[1], a) || !finite_int_literal(p[2], b) ||
                (p.size() == 4 && !finite_int_literal(p[3], step)))
                fail($sformatf("invalid seq generator '%s'", raw));
            if (p.size() != 4) step = 1;
            if (step <= 0 || a > b)
                fail($sformatf("invalid seq generator '%s'", raw));
            count = ((b - a) / step) + 1;
            if (count <= 0 || count > 1000000)
                fail($sformatf("seq generator expands outside 1..1000000 elements: '%s'", raw));
            return int'(count);
        end
        if (s.len() >= 5 && s.substr(0,4) == "perm:") begin
            is_generator = 1;
            split_top(s, ":", p);
            if (p.size() != 3)
                fail($sformatf("invalid perm generator '%s'", raw));
            if (!finite_int_literal(p[1], a) || !finite_int_literal(p[2], b))
                fail($sformatf("invalid perm generator '%s'", raw));
            if (a > b) fail($sformatf("invalid perm generator '%s'", raw));
            count = (b - a) + 1;
            if (count <= 0 || count > 1000000)
                fail($sformatf("perm generator expands outside 1..1000000 elements: '%s'", raw));
            return int'(count);
        end
        // [..] is a list wrapper unless it holds a single range (same rule as the typed resolver).
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]" &&
            aip_str::str_find(s, ":") == -1)
            s = s.substr(1, s.len()-2);
        split_top(s, ",", p);
        return p.size();
    endfunction

    static function bit is_container_overall_key(string root, string key);
        string suffix;
        if (key.len() <= root.len() ||
            key.substr(0, root.len()-1) != root || key[root.len()] != ".")
            return 0;
        suffix = key.substr(root.len()+1, key.len()-1);
        if (suffix == "size" || suffix == "each" || suffix == "unique" ||
            suffix == "sort" || aip_str::str_find(suffix, "each.") == 0 ||
            aip_str::str_find(suffix, "[") != -1 ||
            aip_str::str_find(suffix, ".each") != -1 ||
            aip_str::str_find(suffix, ".size") != -1 ||
            aip_str::str_find(suffix, ".unique") != -1 ||
            aip_str::str_find(suffix, ".sort") != -1)
            return 0;
        return 1;
    endfunction

    // has_index only for ROOT[index]...; the strict ROOT boundary keeps cfgs from owning cfgs_extra.* keys.
    static function bit schema_descendant_suffix(string root, string key,
                                                 output string suffix,
                                                 output bit has_index,
                                                 output string index_text);
        int q, start;
        suffix = "";
        index_text = "";
        has_index = 0;
        if (key == root) return 1;
        if (key.len() > root.len() &&
            key.substr(0, root.len()-1) == root && key[root.len()] == ".") begin
            suffix = key.substr(root.len()+1, key.len()-1);
            return 1;
        end
        if (key.len() <= root.len()+2 ||
            key.substr(0, root.len()-1) != root || key[root.len()] != "[")
            return 0;
        q = aip_str::str_find(key, "]", root.len()+1);
        if (q <= root.len()+1) return 0;
        index_text = key.substr(root.len()+1, q-1);
        has_index = 1;
        start = q + 1;
        if (start < key.len()) begin
            if (key[start] != ".") return 0;
            if (start + 1 >= key.len()) return 0;
            suffix = key.substr(start+1, key.len()-1);
        end
        return 1;
    endfunction

    // 兼容旧版只收集 value 的接口；结果追加到 values，不清空。
    static function void collect_container_overalls_schema(string root,
                                                            string schema_id,
                                                            ref string values[$]);
        string source_keys[$];
        collect_container_overalls_schema_with_sources(root, schema_id, values, source_keys);
    endfunction

    // 只收集已注册标量字段的 overall 及来源 key；数组子项缺 selector 即 fatal，无关路径忽略。
    static function void collect_container_overalls_schema_with_sources(string root,
                                                            string schema_id,
                                                            ref string values[$],
                                                            ref string source_keys[$]);
        string keys[$];
        string args[$];
        string normalized[string];
        bit runtime_key[string];
        string suffix, index_text, arg, key, value;
        bit has_index;
        int kind, eq;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text)) continue;
            if (has_index || suffix == "") continue;
            kind = schema_classify_suffix(schema_id, suffix, 0);
            aip_cmdline_diagnostic::select_value(key, aip_cmdline_override::get_val(key));
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select outer record with each or [index]", root, suffix));
            if (kind != META_SCALAR) continue;
            normalized[key] = aip_cmdline_override::get_val(key);
            runtime_key[key] = 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text)) continue;
            if (has_index || suffix == "") continue;
            kind = schema_classify_suffix(schema_id, suffix, 0);
            aip_cmdline_diagnostic::select_value(key,
                (eq >= 0 && eq+1 < arg.len()) ? arg.substr(eq+1, arg.len()-1) : "");
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select outer record with each or [index]", root, suffix));
            if (kind != META_SCALAR || runtime_key.exists(key)) continue;
            value = (eq >= 0) ? arg.substr(eq+1, arg.len()-1) : "";
            normalized[key] = value;
        end
        // Nested containers inherit field baselines from outer-each keys; resolve them with the materialization
        // fallback so an inherited seq/perm can be the only dynamic-length source.
        begin
            string scalar_suffixes[$];
            collect_schema_scalar_suffixes(schema_id, "", scalar_suffixes);
            foreach (scalar_suffixes[i]) begin
                lookup_t inherited;
                string concrete_key;
                inherited = lookup_container_rule(
                    root, {".", scalar_suffixes[i]}, concrete_key);
                if (inherited.found) normalized[concrete_key] = inherited.value;
            end
        end
        foreach (normalized[key]) begin
            values.push_back(normalized[key]);
            source_keys.push_back(key);
        end
    endfunction

    // 只按已注册的 indexed 后代推导长度，非规范索引留给后续 bounds 校验；
    // 返回前选中最大索引项，供容量冲突定位。
    static function int container_index_extent_schema(string root,
                                                       string schema_id);
        string keys[$];
        string args[$];
        string key, suffix, index_text, arg, max_key, max_raw;
        string toks[$];
        bit has_index, ok;
        int max_idx, idx, kind, eq;
        max_idx = -1;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || !has_index)
                continue;
            kind = schema_classify_suffix(schema_id, suffix, 1);
            if (kind == META_UNKNOWN) continue;
            aip_cmdline_diagnostic::select_value(key, aip_cmdline_override::get_val(key));
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
            if (!schema_index_token({"[", index_text, "]"}, idx)) continue;
            if (idx > max_idx) begin
                max_idx = idx;
                max_key = key;
                max_raw = aip_cmdline_override::get_val(key);
            end
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || !has_index)
                continue;
            kind = schema_classify_suffix(schema_id, suffix, 1);
            if (kind == META_UNKNOWN) continue;
            aip_cmdline_diagnostic::select_value(key,
                (eq >= 0 && eq+1 < arg.len()) ? arg.substr(eq+1, arg.len()-1) : "");
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
            if (!schema_index_token({"[", index_text, "]"}, idx)) continue;
            if (idx > max_idx) begin
                max_idx = idx;
                max_key = key;
                max_raw = (eq >= 0 && eq+1 < arg.len()) ? arg.substr(eq+1, arg.len()-1) : "";
            end
        end
        if (max_idx >= 0) aip_cmdline_diagnostic::select_value(max_key, max_raw);
        return max_idx + 1;
    endfunction

    // 兼容旧版只收集 value 的接口。
    static function void collect_container_overalls(string root, ref string values[$]);
        string source_keys[$];
        collect_container_overalls_with_sources(root, values, source_keys);
    endfunction

    // override 优先于同 key 的 plusarg，重复 plusarg 取最后一个；不消费 RNG。
    static function void collect_container_overalls_with_sources(string root,
                                                                 ref string values[$],
                                                                 ref string source_keys[$]);
        string keys[$]; string args[$];
        string normalized[string];
        bit runtime_key[string];
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            string key = keys[k];
            if (!is_container_overall_key(root, key)) continue;
            normalized[key] = aip_cmdline_override::get_val(key);
            runtime_key[key] = 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            string arg = args[k]; string key; string value; int eq;
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!is_container_overall_key(root, key) || runtime_key.exists(key))
                continue;
            value = (eq >= 0) ? arg.substr(eq+1, arg.len()-1) : "";
            normalized[key] = value;
        end
        foreach (normalized[key]) begin
            values.push_back(normalized[key]);
            source_keys.push_back(key);
        end
    endfunction

    static function aip_svec_t size_literal(string token, string path);
        aip_svec_t value;
        if (!finite_int_literal(token, value))
            fail($sformatf("%s invalid .size expression '%s'", path, token));
        return value;
    endfunction

    static function void check_size_candidate(string path, aip_svec_t value,
                                              int max_size = -1);
        if (value < 0 || value > 1000000 ||
            (max_size >= 0 && value > max_size))
            fail($sformatf("%s invalid candidate %0d (expected 0..%0d)",
                           path, value,
                           (max_size >= 0 && max_size < 1000000) ? max_size : 1000000));
    endfunction

    static function void check_size_range(string token, string path,
                                          int max_size = -1);
        string s, p[$];
        aip_svec_t lo, hi;
        s = aip_str::strip(token);
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]")
            s = s.substr(1, s.len()-2);
        split_top(s, ":", p);
        if (p.size() != 2)
            fail($sformatf("%s invalid .size expression '%s'", path, token));
        lo = size_literal(p[0], path);
        hi = size_literal(p[1], path);
        if (lo > hi)
            fail($sformatf("%s invalid .size expression '%s'", path, token));
        check_size_candidate(path, lo, max_size);
        check_size_candidate(path, hi, max_size);
    endfunction

    // 先校验全部候选再抽样一次，校验不消费 RNG。零权重项同样校验范围，以免禁用项掩盖越界配置；
    // 负权重或全零权重组直接报错，避免进入抽样的模零路径。
    static function int normalize_size(string raw, string path,
                                       int max_size = -1);
        string s, body, parts[$], item, left, right, seqparts[$];
        int op, n;
        bit is_inc, has_positive_weight;
        aip_svec_t start_value, end_value, step_value, weight_value;
        aip_svec_t span_value, last_value;
        aip_cmdline_diagnostic::push_value(path, raw);
        s = aip_str::remove_all_spaces(aip_str::strip(raw));
        if (s == "" || aip_str::lower(s) == "rand" ||
            aip_str::lower(s) == "each" ||
            aip_str::str_find(aip_str::lower(s), "seq:") == 0 ||
            aip_str::str_find(aip_str::lower(s), "perm:") == 0)
            fail($sformatf("%s invalid .size expression '%s'", path, raw));

        if (s.len() >= 2 &&
            ((s[0] == "{" && s[s.len()-1] == "}") ||
             (s[0] == "(" && s[s.len()-1] == ")"))) begin
            body = s.substr(1, s.len()-2);
            split_top(body, ",", parts);
            if (parts.size() == 0)
                fail($sformatf("%s invalid .size expression '%s'", path, raw));
            has_positive_weight = 0;
            foreach (parts[i]) begin
                item = parts[i];
                op = aip_str::str_find(item, ":=");
                if (op < 0) op = aip_str::str_find(item, ":/");
                if (op <= 0 || op + 2 >= item.len())
                    fail($sformatf("%s invalid .size expression '%s'", path, raw));
                left = item.substr(0, op-1);
                right = item.substr(op+2, item.len()-1);
                if (aip_str::lower(left) == "rand")
                    fail($sformatf("%s invalid .size expression '%s'", path, raw));
                weight_value = size_literal(right, path);
                if (weight_value < 0)
                    fail($sformatf("%s weight must be >= 0 in .size item[%0d] '%s'", path, i, item));
                if (weight_value > 0) has_positive_weight = 1;
                if (aip_str::str_find(left, ":") >= 0)
                    check_size_range(left, path, max_size);
                else
                    check_size_candidate(path, size_literal(left, path), max_size);
            end
            if (!has_positive_weight)
                fail($sformatf("%s weighted group total must be > 0; all weights are zero in '%s'", path, raw));
        end else if (s.len() >= 4 &&
                     (s.substr(0,3) == "inc:" || s.substr(0,3) == "dec:")) begin
            is_inc = (s.substr(0,3) == "inc:");
            split_top(s.substr(4), ":", seqparts);
            if (seqparts.size() < 2 || seqparts.size() > 3)
                fail($sformatf("%s invalid .size expression '%s'", path, raw));
            start_value = size_literal(seqparts[0], path);
            end_value = size_literal(seqparts[1], path);
            step_value = (seqparts.size() == 3) ? size_literal(seqparts[2], path) : 1;
            if (step_value <= 0 || (is_inc && start_value > end_value) ||
                (!is_inc && start_value < end_value))
                fail($sformatf("%s invalid .size expression '%s'", path, raw));
            span_value = is_inc ? (end_value - start_value) :
                                  (start_value - end_value);
            last_value = is_inc ?
                         (start_value + (span_value / step_value) * step_value) :
                         (start_value - (span_value / step_value) * step_value);
            check_size_candidate(path, start_value, max_size);
            check_size_candidate(path, last_value, max_size);
        end else if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]" &&
                     aip_str::str_find(s, ",") >= 0) begin
            split_top(s.substr(1, s.len()-2), ",", parts);
            foreach (parts[i])
                check_size_candidate(path, size_literal(parts[i], path), max_size);
        end else begin
            split_top(s, ",", parts);
            if (parts.size() > 1) begin
                foreach (parts[i])
                    check_size_candidate(path, size_literal(parts[i], path), max_size);
            end else if (aip_str::str_find(s, ":") >= 0) begin
                check_size_range(s, path, max_size);
            end else begin
                check_size_candidate(path, size_literal(s, path), max_size);
            end
        end
        n = aip_cmdline#(int)::parse_value(s);
        // Redundant after the checks above; kept as a postcondition in case the sampler grammar changes.
        if (n < 0 || n > 1000000 || (max_size >= 0 && n > max_size))
            fail($sformatf("%s invalid sampled size %0d", path, n));
        aip_cmdline_diagnostic::pop();
        return n;
    endfunction

    static function int container_size(string root, int defsz);
        return container_size_schema(root, defsz, "");
    endfunction

    // 各候选来源保留 key/raw，长度冲突或容量错误时定位到实际来源。
    static function int container_size_schema(string root, int defsz,
                                               string schema_id,
                                               int max_size = -1);
        lookup_t l; int n; string s; string q[$];
        string overalls[$], overall_keys[$], size_key;
        int ordinary_len = 0; int generator_len = -1;
        int ordinary_source = -1; int generator_source = -1;
        bit schema_has_each = 0;
        if (metadata_mode) return 0;
        if (defsz < 0 || defsz > 1000000)
            fail($sformatf("invalid DEFAULT_SIZE %0d", defsz));

        // Root overall (incl. a compact record list) and field overall/generator rules infer the length; .each never does.
        l = lookup(root);
        if (l.found && l.value != "") begin
            overalls.push_back(l.value);
            overall_keys.push_back(root);
        end
        if (schema_id == "") collect_container_overalls_with_sources(root, overalls, overall_keys);
        else begin
            // Validates outer-each descendants even when another rule already fixes the length.
            schema_has_each = has_container_each_schema(root, schema_id);
            collect_container_overalls_schema_with_sources(root, schema_id, overalls, overall_keys);
        end
        foreach (overalls[i]) begin
            bit gen;
            int len;
            aip_cmdline_diagnostic::select_value(overall_keys[i], overalls[i]);
            len = overall_length(overalls[i], gen);
            if (gen) begin
                if (generator_len < 0) begin
                    generator_len = len;
                    generator_source = i;
                end
                else if (generator_len != len)
                    fail($sformatf("%s conflicting field generator lengths %0d and %0d", root, generator_len, len));
            end else if (len > ordinary_len) begin
                ordinary_len = len;
                ordinary_source = i;
            end
        end

        l = lookup_container_rule(root, ".size", size_key);
        if (!l.found) begin
            int ie;
            if (schema_id == "") ie = container_index_extent(root);
            else ie = container_index_extent_schema(root, schema_id);
            if (generator_len < 0 && ordinary_len == 0 && ie == 0 &&
                defsz == 0 && ((schema_id == "") ? has_container_each(root) :
                                schema_has_each)) begin
                if (schema_id != "") void'(has_container_each_schema(root, schema_id));
                fail($sformatf("%s size unknown: each rule requires a positive size source", root));
            end
            if (generator_len >= 0) n = generator_len;
            else if (ordinary_len > 0) n = ordinary_len;
            else n = (ie > defsz) ? ie : defsz;
            if (generator_len >= 0 && ordinary_len > generator_len) begin
                aip_cmdline_diagnostic::select_value(overall_keys[ordinary_source], overalls[ordinary_source]);
                fail($sformatf("%s overall list has %0d elements, generator length is %0d", root, ordinary_len, generator_len));
            end
            if (generator_len >= 0)
                aip_cmdline_diagnostic::select_value(overall_keys[generator_source], overalls[generator_source]);
            else if (ordinary_len > 0)
                aip_cmdline_diagnostic::select_value(overall_keys[ordinary_source], overalls[ordinary_source]);
            if (n < 0 || n > 1000000)
                fail($sformatf("%s inferred size %0d is outside 0..1000000", root, n));
            if (max_size >= 0 && n > max_size)
                fail($sformatf("%s size %0d exceeds MAX_SIZE %0d", root, n, max_size));
            return n;
        end
        aip_cmdline_diagnostic::select_value(size_key, l.value);
        n = normalize_size(l.value, {root, ".size"}, max_size);
        if (generator_len >= 0 && generator_len != n)
            fail($sformatf("%s.size conflicts with generator length %0d", root, generator_len));
        if (ordinary_len > n) begin
            aip_cmdline_diagnostic::select_value(overall_keys[ordinary_source], overalls[ordinary_source]);
            fail($sformatf("%s overall list has %0d elements, .size is %0d", root, ordinary_len, n));
        end
        return n;
    endfunction

    // Static arrays are copied through zero-based temporaries, so require [0:N-1] before any select or write;
    // $size alone cannot tell it from offset or descending ranges of the same length.
    static function void validate_static_array_range(string path,
                                                     int unpacked_dimensions,
                                                     int left_index,
                                                     int right_index,
                                                     int low_index,
                                                     int high_index,
                                                     int element_count);
        int expected_right;
        if (unpacked_dimensions != 1)
            fail($sformatf(
                "%s static array must have exactly one unpacked dimension (got %0d)",
                path, unpacked_dimensions));
        expected_right = element_count - 1;
        if (left_index != 0 || right_index != expected_right ||
            low_index != 0 || high_index != expected_right)
            fail($sformatf(
                "%s static array range [%0d:%0d] must be [0:%0d]",
                path, left_index, right_index, expected_right));
    endfunction

    static function void validate_static_container_length(string root,
                                                           string schema_id,
                                                           int fixed_size,
                                                           string root_overall);
        string overalls[$], overall_keys[$], size_key;
        int generator_len;
        lookup_t size_rule;
        generator_len = -1;
        size_rule = lookup_container_rule(root, ".size", size_key);
        if (size_rule.found) begin
            aip_cmdline_diagnostic::select_value(size_key, size_rule.value);
            fail($sformatf("%s.size not allowed for static array", root));
        end
        // Result unused: called so known .each descendants are still checked for nested-array selectors.
        void'(has_container_each_schema(root, schema_id));
        if (root_overall != "") begin
            overalls.push_back(root_overall);
            overall_keys.push_back(root);
        end
        collect_container_overalls_schema_with_sources(root, schema_id, overalls, overall_keys);
        foreach (overalls[i]) begin
            bit gen;
            int len;
            aip_cmdline_diagnostic::select_value(overall_keys[i], overalls[i]);
            len = overall_length(overalls[i], gen);
            if (gen) begin
                if (len != fixed_size)
                    fail($sformatf("%s generator length %0d does not match static size %0d",
                                   root, len, fixed_size));
                if (generator_len < 0) generator_len = len;
                else if (generator_len != len)
                    fail($sformatf("%s conflicting field generator lengths %0d and %0d",
                                   root, generator_len, len));
            end else if (len > fixed_size) begin
                fail($sformatf("%s overall list has %0d elements, static size is %0d",
                               root, len, fixed_size));
            end
        end
    endfunction

    static function void validate_default_size(real d);
        if (d != d || d < 0.0 || d > 1000000.0 || d != $floor(d))
            fail($sformatf("invalid DEFAULT_SIZE %0f", d));
    endfunction

    static function void validate_max_size(real d);
        if (d != d || d < -1.0 || d > 1000000.0 || d != $floor(d))
            fail($sformatf("invalid MAX_SIZE %0f (expected -1 or non-negative integer)", d));
    endfunction

    static function void check_container_capacity(string root, int n, real max_size);
        validate_max_size(max_size);
        if (max_size >= 0.0 && n > int'(max_size))
            fail($sformatf("%s size %0d exceeds MAX_SIZE %0d", root, n, int'(max_size)));
    endfunction

    // 写入前校验，失败即终止；先选中 key 原文，使底层索引转换失败也能定位。
    static function void validate_indexed_bounds(string root, int n);
        string keys[$]; string args[$];
        uvm_cmdline_processor clp;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            string a = keys[k]; int p, q, idx; string is;
            p = aip_str::str_find(a, {root, "["});
            if (p != 0) continue;
            aip_cmdline_diagnostic::select_value(a, aip_cmdline_override::get_val(a));
            q = aip_str::str_find(a, "]", root.len()+1);
            if (q <= root.len()+1) continue;
            is = a.substr(root.len()+1, q-1);
            if (is.len() > 1 && is[0] == "0")
                fail($sformatf("noncanonical index in runtime key %s", a));
            idx = aip_cmdline#(int)::parse_value(is);
            if (idx < 0 || idx >= n)
                fail($sformatf("index %0d out of range for %s[%0d] (runtime key)", idx, root, n));
        end
        clp = aip_cmdline_source::get();
        clp.get_args(args);
        foreach (args[k]) begin
            string a = args[k]; int p, q, idx, eq; string is, key, raw;
            if (a.len() < 2 || a[0] != "+") continue;
            a = a.substr(1, a.len()-1);
            p = aip_str::str_find(a, {root, "["});
            if (p != 0) continue;
            eq = aip_str::str_find(a, "=");
            key = (eq >= 0) ? a.substr(0, eq-1) : a;
            raw = (eq >= 0 && eq+1 < a.len()) ? a.substr(eq+1, a.len()-1) : "";
            aip_cmdline_diagnostic::select_value(key, raw);
            q = aip_str::str_find(a, "]");
            if (q <= root.len()+1) continue;
            is = a.substr(root.len()+1, q-1);
            if (is.len() > 1 && is[0] == "0") fail($sformatf("noncanonical index in +%s", a));
            idx = aip_cmdline#(int)::parse_value(is);
            if (idx < 0 || idx >= n) fail($sformatf("index %0d out of range for %s[%0d]", idx, root, n));
        end
    endfunction

    // 只校验已注册字段的 indexed 后代，其他子系统的同前缀参数不参与边界检查。
    static function void validate_indexed_bounds_schema(string root, int n,
                                                         string schema_id);
        string keys[$];
        string args[$];
        string key, arg, suffix, index_text;
        bit has_index;
        int idx, kind, eq;
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            key = keys[k];
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || !has_index)
                continue;
            kind = schema_classify_suffix(schema_id, suffix, 1);
            if (kind == META_UNKNOWN) continue;
            aip_cmdline_diagnostic::select_value(key, aip_cmdline_override::get_val(key));
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
            if (!schema_index_token({"[", index_text, "]"}, idx))
                fail($sformatf("noncanonical index in runtime key %s", key));
            if (idx < 0 || idx >= n)
                fail($sformatf("index %0d out of range for %s[%0d] (runtime key)", idx, root, n));
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            eq = aip_str::str_find(arg, "=");
            key = (eq >= 0) ? arg.substr(0, eq-1) : arg;
            if (!schema_descendant_suffix(root, key, suffix, has_index, index_text) || !has_index)
                continue;
            kind = schema_classify_suffix(schema_id, suffix, 1);
            if (kind == META_UNKNOWN) continue;
            aip_cmdline_diagnostic::select_value(key,
                (eq >= 0 && eq+1 < arg.len()) ? arg.substr(eq+1, arg.len()-1) : "");
            if (kind == META_BARE_ARRAY)
                fail($sformatf("%s.%s is an array-valued child; select nested record with each or [index]", root, suffix));
            if (!schema_index_token({"[", index_text, "]"}, idx))
                fail($sformatf("noncanonical index in +%s", arg));
            if (idx < 0 || idx >= n)
                fail($sformatf("index %0d out of range for %s[%0d]", idx, root, n));
        end
    endfunction

    static function bit has_container_each(string root);
        string keys[$]; string args[$];
        aip_cmdline_override::get_keys(keys);
        foreach (keys[k]) begin
            string key = keys[k];
            if (key == {root, ".each"} ||
                aip_str::str_find(key, {root, ".each."}) == 0)
                return 1;
        end
        aip_cmdline_source::get().get_args(args);
        foreach (args[k]) begin
            string arg = args[k];
            if (arg.len() < 2 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            if (arg == {root, ".each"} ||
                aip_str::str_find(arg, {root, ".each."}) == 0)
                return 1;
        end
        return 0;
    endfunction

    static function string container_slot(string root, int idx, string overall);
        string slot; lookup_t l; bit found;
        l = lookup($sformatf("%s[%0d]", root, idx));
        if (l.found) return l.value;
        if (overall != "") begin
            slot = overall_slot(overall, idx, root, found);
            if (found) return slot;
        end
        return "";
    endfunction

    static function void prepare_container_generator(string root,
                                                     string overall);
        string s, ignored;
        bit found;
        s = aip_str::strip(overall);
        if (s.len() >= 5 && s.substr(0,4) == "perm:")
            ignored = overall_slot(s, 0, root, found);
    endfunction

    // Picks the winning rule without parsing it (indexed > overall slot > .each), so shadowed rules are never
    // validated or drawn. perm: overalls must be prewarmed first: the full shuffle is the one eager-RNG exception.
    static function lookup_t queue_slot_rule(string full_root,
                                             string leaf_root,
                                             lookup_t overall_rule,
                                             lookup_t each_rule,
                                             int idx,
                                             bit string_empty_overall = 0);
        lookup_t r;
        string slot;
        bit found;
        r = lookup_queue_rule(full_root, leaf_root,
                              $sformatf("[%0d]", idx));
        if (r.found) begin
            r.from_each = 0;
            return r;
        end
        if (overall_rule.found) begin
            if (string_empty_overall && overall_rule.value == "" && idx == 0) begin
                r = overall_rule;
                r.value = "";
                r.from_each = 0;
                return r;
            end
            slot = overall_slot(overall_rule.value, idx, full_root, found);
            if (found) begin
                r = overall_rule;
                r.value = slot;
                r.from_each = 0;
                return r;
            end
        end
        if (each_rule.found) begin
            r = each_rule;
            r.from_each = 1;
            return r;
        end
        return '{found:0, value:"", source:0, from_each:0};
    endfunction

    // Same winner order as queue_slot_rule, but looked up from the typed field (incl. inherited outer selectors);
    // an integral perm: overall must likewise be prewarmed first.
    static function lookup_t schema_array_slot_rule(string root,
                                                    string field,
                                                    lookup_t overall_rule,
                                                    lookup_t each_rule,
                                                    int idx,
                                                    bit string_empty_overall = 0);
        lookup_t r;
        string slot;
        bit found;
        r = lookup_array_index_rule(root, field, idx);
        if (r.found) begin
            r.from_each = 0;
            return r;
        end
        if (overall_rule.found) begin
            if (string_empty_overall && overall_rule.value == "" && idx == 0) begin
                r = overall_rule;
                r.value = "";
                r.from_each = 0;
                return r;
            end
            slot = overall_slot(overall_rule.value, idx,
                                {root, ".", field}, found);
            if (found) begin
                r = overall_rule;
                r.value = slot;
                r.from_each = 0;
                return r;
            end
        end
        if (each_rule.found) begin
            r = each_rule;
            r.from_each = 1;
            return r;
        end
        return '{found:0, value:"", source:0, from_each:0};
    endfunction

    static function void validate_generator_target(string raw, string path,
                                                   int width);
        string s, p[$];
        aip_vec_t value;
        int explicit_width;
        bit negative;
        s = aip_str::strip(raw);
        if (!((s.len() >= 4 && s.substr(0,3) == "seq:") ||
              (s.len() >= 5 && s.substr(0,4) == "perm:"))) return;
        split_top(s, ":", p);
        if (p.size() < 3 || p.size() > 4)
            fail($sformatf("invalid integral generator for %s: '%s'", path, raw));
        for (int i = 1; i < p.size(); i++) begin
            if (!aip_str::str_to_vec(aip_str::strip(p[i]), value,
                                     explicit_width, negative) ||
                (width > 0 && explicit_width > width) ||
                (width > 0 && width < 1024 && (value >> width) != 0))
                fail($sformatf("%s generator token '%s' exceeds %0d-bit target",
                               path, p[i], width));
        end
    endfunction

    // 预热 perm 洗牌并校验整数生成器位宽；先选中各字段原文，失败不会归因于上一个字段。
    static function void prepare_field_generators(string root,
                                                  string schema_id);
        string names[$];
        string tmp, key, ignored;
        lookup_t rule;
        bit found;
        collect_schema_scalar_suffixes(schema_id, "", names);
        // Lexical order keeps draw order independent of how the metadata map was populated.
        for (int i = 1; i < names.size(); i++) begin
            int j;
            tmp = names[i];
            j = i;
            while (j > 0 && tmp < names[j-1]) begin
                names[j] = names[j-1];
                j--;
            end
            names[j] = tmp;
        end
        foreach (names[i]) begin
            rule = lookup_container_rule(root, {".", names[i]}, key);
            aip_cmdline_diagnostic::select_value(key, rule.value);
            tmp = aip_str::strip(rule.value);
            begin
                int kind, width;
                bit is_signed;
                if (rule.found && schema_typed_field(schema_id, names[i],
                                                     kind, width, is_signed) &&
                    kind == 1)
                    validate_generator_target(tmp, key, width);
            end
            if (rule.found && tmp.len() >= 5 && tmp.substr(0,4) == "perm:")
                ignored = overall_slot(tmp, 0, key, found);
        end
    endfunction

    // Keyed by the innermost field like prepare_field_generators(), so a nested suffix is not parsed as one index.
    static function string scalar_generator_slot(string full_root,
                                                  string field,
                                                  string raw,
                                                  output bit found);
        string base, suffix, cache_key, desc_key;
        int idx;
        found = 0;
        if (!field_location(full_root, field, base, idx, suffix, desc_key))
            return "";
        cache_key = {base, ".", suffix};
        return overall_slot(raw, idx, cache_key, found);
    endfunction

    static function void begin_container(string root, string schema_id = "",
                                         int extent = -1);
        string prefix;
        string stale[$];
        // Only the fixed/normal pass resets: PHASE_EACH keeps the fixed descriptors, and nested applies call this once per pass.
        if (materialization_phase != PHASE_EACH)
            field_names[root].delete();
        if (schema_id != "") container_schema[root] = schema_id;
        if (extent >= 0) container_sizes[root] = extent;
        prefix = {root, "|"};
        // A repeated apply must not see descriptors from a previous extent; collect keys, then purge every parallel map.
        if (materialization_phase != PHASE_EACH)
            foreach (field_typed_kinds[k])
                if (aip_str::str_find(k, prefix) == 0) stale.push_back(k);
        foreach (stale[i]) begin
            field_typed_kinds.delete(stale[i]);
            field_bits.delete(stale[i]);
            field_width.delete(stale[i]);
            field_signed.delete(stale[i]);
            field_real_values.delete(stale[i]);
            field_string_values.delete(stale[i]);
            field_from_each.delete(stale[i]);
            field_each_raw.delete(stale[i]);
            field_values.delete(stale[i]);
            field_kinds.delete(stale[i]);
        end
        if (materialization_phase != PHASE_EACH) begin
            foreach (redraw_attempts[k])
                if (aip_str::str_find(k, prefix) == 0) redraw_attempts.delete(k);
        end
    endfunction

    // ROOT[i] (or a nested indexed root) -> base/idx/suffix key; scalar roots return 0 and are deliberately not recorded.
    static function bit field_location(string full_root, string field,
                                       output string base, output int idx,
                                       output string suffix, output string key);
        int b, e;
        string tail;
        base = "";
        idx = -1;
        suffix = "";
        key = "";
        // Innermost index: ROOT[0].kids[1] is keyed by its own container ROOT[0].kids, not the outer ROOT.
        b = -1;
        for (int p = 0; p < full_root.len(); p++)
            if (full_root[p] == "[") b = p;
        if (b <= 0) return 0;
        e = aip_str::str_find(full_root, "]", b+1);
        if (e <= b+1) return 0;
        base = full_root.substr(0, b-1);
        idx = aip_cmdline#(int)::parse_value(full_root.substr(b+1, e-1));
        tail = (e+1 < full_root.len()) ? full_root.substr(e+1) : "";
        if (tail != "" && tail[0] == ".") tail = tail.substr(1);
        suffix = (tail != "") ? {tail, ".", field} : field;
        key = $sformatf("%s|%0d|%s", base, idx, suffix);
        return 1;
    endfunction

    // 同时选中该字段原文，使空值、字符串转换等前置失败也能定位到它。
    // Provenance is kept apart from the typed descriptor so redraw can replace only the colliding field.
    static function void mark_typed_source(string full_root, string field,
                                            input bit from_each,
                                            input string each_raw);
        string base, suffix, key;
        int idx;
        aip_cmdline_diagnostic::select_value({full_root, ".", field}, each_raw);
        if (!field_location(full_root, field, base, idx, suffix, key)) return;
        field_from_each[key] = from_each;
        field_each_raw[key] = from_each ? each_raw : "";
    endfunction

    static function bit typed_source_is_each(string root, int idx,
                                             string suffix,
                                             output string each_raw);
        string key;
        key = $sformatf("%s|%0d|%s", root, idx, suffix);
        each_raw = field_each_raw.exists(key) ? field_each_raw[key] : "";
        return field_from_each.exists(key) && field_from_each[key];
    endfunction

    static function bit typed_descriptor_equal(string ka, string kb);
        int kind_a, kind_b;
        kind_a = field_typed_kinds.exists(ka) ? field_typed_kinds[ka] : 0;
        kind_b = field_typed_kinds.exists(kb) ? field_typed_kinds[kb] : 0;
        if (kind_a == 0 || kind_a != kind_b) return 0;
        case (kind_a)
            1, 4: return field_bits[ka] === field_bits[kb];
            2:   return field_string_values[ka] == field_string_values[kb];
            3:   return field_real_values[ka] == field_real_values[kb];
            default: return 0;
        endcase
    endfunction

    // The extent is recorded before either pass, so conflict checks also see fixed values at later indices.
    static function int typed_container_extent(string full_root);
        string base, suffix, key;
        int idx;
        if (field_location(full_root, "__aip_dummy", base, idx, suffix, key)) begin
            if (container_sizes.exists(base)) return container_sizes[base];
            return idx + 1;
        end
        return 0;
    endfunction

    // Later .each slots still hold fixed-pass placeholders and are skipped; earlier .each values and fixed
    // values on either side still conflict, so a redraw can avoid a later fixed value.
    static function bit typed_current_conflicts(string full_root, string field,
                                                input int extent = -1);
        string base, suffix, key, prior;
        int idx;
        if (!field_location(full_root, field, base, idx, suffix, key)) return 0;
        if (!field_typed_kinds.exists(key)) return 0;
        if (extent < 0) extent = typed_container_extent(full_root);
        if (extent <= 0) extent = idx + 1;
        for (int j = 0; j < extent; j++) begin
            if (j == idx) continue;
            prior = $sformatf("%s|%0d|%s", base, j, suffix);
            if (!field_typed_kinds.exists(prior)) continue;
            if (j > idx && field_from_each.exists(prior) && field_from_each[prior])
                continue;
            if (typed_descriptor_equal(key, prior)) return 1;
        end
        return 0;
    endfunction

    static function bit typed_unique_enabled(string full_root, string field);
        string base, suffix, key;
        string selected_key;
        int idx;
        lookup_t rule;
        string normalized;
        if (!field_location(full_root, field, base, idx, suffix, key)) return 0;
        rule = lookup_container_rule(base, {".each.", suffix, ".unique"},
                                     selected_key);
        if (!rule.found) return 0;
        aip_cmdline_diagnostic::push_value({base, ".each.", suffix, ".unique"}, rule.value);
        normalized = aip_str::lower(aip_str::strip(rule.value));
        if (normalized != "0" && normalized != "1")
            fail($sformatf("%s.each.%s.unique must be 0 or 1", base, suffix));
        aip_cmdline_diagnostic::pop();
        return normalized == "1";
    endfunction

    static function int typed_redraw_limit(string full_root);
        string base, suffix, key;
        int idx;
        int b;
        int p;
        b = -1;
        if (!field_location(full_root, "__aip_dummy", base, idx, suffix, key)) begin
            for (p = 0; p < full_root.len(); p++)
                if (full_root[p] == "[") b = p;
            if (b <= 0) return 100;
            base = full_root.substr(0, b-1);
        end
        if (container_sizes.exists(base) && container_sizes[base] > 0)
            return 100 * container_sizes[base];
        return 100 * ((idx >= 0) ? (idx + 1) : 1);
    endfunction

    static function string typed_rule_name(string full_root, string field);
        string base, suffix, key;
        int idx;
        if (field_location(full_root, field, base, idx, suffix, key))
            return {base, ".each.", suffix, ".unique"};
        return {full_root, ".each.", field, ".unique"};
    endfunction

    // The redraw budget is shared by the whole container/suffix, not reset per record; the caller reports exhaustion.
    static function bit consume_typed_redraw(string full_root, string field);
        string base, suffix, key;
        int idx, limit;
        if (!field_location(full_root, field, base, idx, suffix, key)) begin
            base = full_root;
            suffix = field;
        end
        key = {base, "|", suffix};
        limit = typed_redraw_limit(full_root);
        if (!redraw_attempts.exists(key)) redraw_attempts[key] = 0;
        if (redraw_attempts[key] >= limit) return 0;
        redraw_attempts[key]++;
        return 1;
    endfunction

    // Non-random literal parse for finite-candidate analysis; same 1026-bit signed width as the integer
    // resolver so ranges stay analyzable for every 1..1024-bit target.
    static function bit finite_int_literal(string token,
                                            output aip_svec_t value);
        aip_vec_t v;
        int explicit_width;
        bit negative;
        value = 0;
        if (!aip_str::str_to_vec(aip_str::strip(token), v, explicit_width,
                                 negative)) return 0;
        value = aip_svec_t'({2'b00, v});
        if (negative) value = -value;
        return 1;
    endfunction

    // 预检用非随机 real 转换：须完整消费 token，不用 str_to_real 的前缀转换，以免把 1.0:2.0 当成 1.0。
    static function bit finite_real_literal(string token,
                                             output real value);
        string cleaned, trailing;
        int matched;
        value = 0.0;
        cleaned = aip_str::remove_all_spaces(aip_str::strip(token));
        trailing = "";
        if (cleaned == "") return 0;
        matched = $sscanf(cleaned, "%g%s", value, trailing);
        if (matched != 1) return 0;
        if (!aip_cmdline_real::is_finite(value) || aip_cmdline_real::decimal_overflow(token)) return 0;
        return 1;
    endfunction

    // 枚举常见 .each 表达式的有限候选，不消费 RNG，也不做语法检查（归严格解析）。
    // 返回负值表示无法有界枚举，调用方回退到有限次重抽样。
    static function int finite_candidate_tokens(string raw,
                                                output string values[$],
                                                input int target_kind = 1);
        string s, parts[$], token;
        string inner, wparts[$], range_parts[$];
        aip_svec_t lo, hi, count, st, rlo, rhi, arm_weight;
        real rstart, rend, rstep, rvalue, rratio;
        int colon, n, ri, wp, wi, real_count;
        bit is_inc;
        values = {};
        s = aip_str::strip(raw);
        if (s == "" || s == "rand" || s == "RAND") return -1;
        if (aip_str::str_find(s, "seq:") == 0 ||
            aip_str::str_find(s, "perm:") == 0) return -1;
        if (target_kind == 2) begin
            s = normalize_string_list_wrapper(s);
            if (s == "") begin
                values.push_back("");
                return 1;
            end
        end

        // Real ranges/weighted groups are continuous, not finite sets (treating 1.0:2.0 as a singleton would
        // fake a unique shortage); only real inc/dec is discrete and is enumerated when small enough.
        if (target_kind == 3) begin
            if (aip_str::str_find(s, "inc:") == 0 ||
                aip_str::str_find(s, "dec:") == 0) begin
                is_inc = (s.substr(0, 3) == "inc:");
                split_top(s.substr(4), ":", parts);
                if (parts.size() < 2 || parts.size() > 3) return -1;
                if (!finite_real_literal(parts[0], rstart) ||
                    !finite_real_literal(parts[1], rend)) return -1;
                rstep = 1.0;
                if (parts.size() == 3 &&
                    !finite_real_literal(parts[2], rstep)) return -1;
                if (!(rstep > 0.0) || (is_inc && rstart > rend) ||
                    (!is_inc && rstart < rend)) return -1;
                rratio = is_inc ? ((rend - rstart) / rstep) :
                                   ((rstart - rend) / rstep);
                if (!(rratio >= 0.0) || rratio > 65535.0) return -1;
                real_count = int'(rratio) + 1;
                if (real_count <= 0 || real_count > 65536) return -1;
                for (ri = 0; ri < real_count; ri++) begin
                    rvalue = is_inc ? (rstart + ri * rstep) :
                                      (rstart - ri * rstep);
                    // %0.17g round-trips an IEEE-754 double; plain %g (6 digits) would merge close values.
                    values.push_back($sformatf("%0.17g", rvalue));
                end
                return values.size();
            end

            if (aip_str::str_find(s, ":") >= 0 ||
                (s.len() > 0 && (s[0] == "{" || s[0] == "(" || s[0] == "[")))
                return -1;

            split_top(s, ",", parts);
            if (parts.size() == 0) return 0;
            foreach (parts[ri]) begin
                token = aip_str::strip(parts[ri]);
                if (!finite_real_literal(token, rvalue)) return -1;
                values.push_back(token);
                if (values.size() > 65536) return -1;
            end
            return values.size();
        end

        if (target_kind == 1 &&
            (aip_str::str_find(s, "inc:") == 0 ||
             aip_str::str_find(s, "dec:") == 0)) begin
            is_inc = (s.substr(0, 3) == "inc:");
            split_top(s.substr(4), ":", parts);
            if (parts.size() < 2 || parts.size() > 3) return -1;
            if (!finite_int_literal(parts[0], lo) ||
                !finite_int_literal(parts[1], hi)) return -1;
            st = 1;
            if (parts.size() == 3) begin
                if (!finite_int_literal(parts[2], st) || st <= 0)
                    return -1;
            end
            if ((is_inc && hi < lo) || (!is_inc && lo < hi)) return -1;
            count = is_inc ? ((hi - lo) / st + 1) : ((lo - hi) / st + 1);
            if (count <= 0 || count > 65536) return -1;
            for (ri = 0; ri < count; ri++)
                values.push_back($sformatf("%0d", is_inc ? (lo + ri*st) : (lo - ri*st)));
            return values.size();
        end

        // Integer lo:hi (bracketed or not) is a unit-step range; for string/enum a colon is an ordinary character.
        if (target_kind == 1 && s.len() >= 3 &&
            s[0] == "[" && s[s.len()-1] == "]") begin
            colon = aip_str::str_find(s, ":");
            if (colon >= 0) begin
                if (aip_str::str_find(s, ",") >= 0) return -1;
                if (!finite_int_literal(s.substr(1, colon-1), lo) ||
                    !finite_int_literal(s.substr(colon+1, s.len()-2), hi) ||
                    hi < lo) return -1;
                count = hi - lo + 1;
                if (count <= 0 || count > 65536) return -1;
                for (ri = 0; ri < count; ri++)
                    values.push_back($sformatf("%0d", lo + ri));
                return values.size();
            end
            s = s.substr(1, s.len()-2);
        end else if (target_kind == 1) begin
            colon = aip_str::str_find(s, ":");
            if (colon >= 0) begin
                if (!finite_int_literal(s.substr(0, colon-1), lo) ||
                    !finite_int_literal(s.substr(colon+1, s.len()-1), hi) ||
                    hi < lo) return -1;
                count = hi - lo + 1;
                if (count <= 0 || count > 65536) return -1;
                for (ri = 0; ri < count; ri++)
                    values.push_back($sformatf("%0d", lo + ri));
                return values.size();
            end
        end

        // 权重组：只枚举可达的左侧值；正权重只影响概率，零权重禁用整项。
        if (s.len() >= 2 &&
            ((s[0] == "{" && s[s.len()-1] == "}") ||
             (s[0] == "(" && s[s.len()-1] == ")"))) begin
            inner = s.substr(1, s.len()-2);
            split_top(inner, ",", wparts);
            values = {};
            foreach (wparts[wi]) begin
                wp = aip_str::str_find(wparts[wi], ":=");
                if (wp < 0) wp = aip_str::str_find(wparts[wi], ":/");
                if (wp <= 0) return -1;
                if (!finite_int_literal(wparts[wi].substr(wp+2), arm_weight) || arm_weight < 0)
                    return -1;
                if (arm_weight == 0) continue;
                token = aip_str::strip(wparts[wi].substr(0, wp-1));
                if (token == "rand" || token == "RAND") return -1;
                if (target_kind == 1 && token.len() >= 3 &&
                    token[0] == "[" && token[token.len()-1] == "]" &&
                    aip_str::str_find(token, ":") >= 0) begin
                    split_top(token.substr(1, token.len()-2), ":", range_parts);
                    if (range_parts.size() != 2 ||
                        !finite_int_literal(range_parts[0], rlo) ||
                        !finite_int_literal(range_parts[1], rhi) || rhi < rlo)
                        return -1;
                    if (rhi-rlo+1 > 65536) return -1;
                    for (ri = 0; ri <= rhi-rlo; ri++) begin
                        values.push_back($sformatf("%0d", rlo + ri));
                        if (values.size() > 65536) return -1;
                    end
                    range_parts = {};
                end else begin
                    values.push_back(token);
                    if (values.size() > 65536) return -1;
                end
            end
            return values.size();
        end

        split_top(s, ",", parts);
        if (parts.size() == 0) return 0;
        foreach (parts[wi]) begin
            token = aip_str::strip(parts[wi]);
            if (token == "") return -1;
            // Keep duplicates: the 65,536 cutoff counts raw candidates; callers dedup only after
            // the target-type cast (e.g. -1 and 8'hff in an 8-bit container).
            values.push_back(token);
            if (values.size() > 65536) return -1;
        end
        n = values.size();
        return n;
    endfunction

    // Finite candidate token -> lossless descriptor; 0 = not exactly representable (caller falls back to bounded redraw).
    static function bit typed_literal_descriptor(string token, int kind,
                                                 int width,
                                                 output logic [1023:0] bits,
                                                 output string text,
                                                 output real real_value,
                                                 input string schema_id = "",
                                                 input string suffix = "");
        aip_vec_t v;
        int explicit_width;
        bit negative;
        bits = '0;
        text = "";
        real_value = 0.0;
        case (kind)
            1: begin
                if (!aip_str::str_to_vec(aip_str::strip(token), v,
                                         explicit_width, negative)) return 0;
                // Same rules as aip_cmdline#(T)::parse_single_num: explicit width and magnitude must fit the
                // target, so an oversized token never becomes a valid truncated candidate.
                if (width > 0 && explicit_width > width) return 0;
                if (width > 0 && width < 1024 && (v >> width) != 0) return 0;
                if (negative) v = -v;
                bits = v;
                if (width > 0 && width < 1024)
                    for (int q = width; q < 1024; q++) bits[q] = 1'b0;
                return 1;
            end
            2: begin
                text = decode_string(token);
                return 1;
            end
            3: return finite_real_literal(token, real_value);
            4: begin
                return schema_enum_literal(schema_id, suffix, token, bits);
            end
            default: return 0;
        endcase
    endfunction

    static function bit typed_candidate_equal(int kind,
                                              logic [1023:0] bits_a,
                                              string text_a, real real_a,
                                              logic [1023:0] bits_b,
                                              string text_b, real real_b);
        case (kind)
            1, 4: return bits_a === bits_b;
            2:   return text_a == text_b;
            3:   return real_a == real_b;
            default: return 0;
        endcase
    endfunction

    static function bit typed_candidate_matches_key(string key, int kind,
                                                     logic [1023:0] bits,
                                                     string text, real rv);
        int kk;
        kk = field_typed_kinds.exists(key) ? field_typed_kinds[key] : 0;
        if (kk != kind) return 0;
        case (kind)
            1, 4: return field_bits[key] === bits;
            2:   return field_string_values[key] == text;
            3:   return field_real_values[key] == rv;
            default: return 0;
        endcase
    endfunction

    static function void check_fixed_unique(string root, string suffix,
                                            int extent);
        string key, prior;
        bit from_each, prior_each;
        int i, j;
        for (i = 0; i < extent; i++) begin
            key = $sformatf("%s|%0d|%s", root, i, suffix);
            from_each = field_from_each.exists(key) && field_from_each[key];
            if (from_each || !field_typed_kinds.exists(key)) continue;
            for (j = 0; j < i; j++) begin
                prior = $sformatf("%s|%0d|%s", root, j, suffix);
                prior_each = field_from_each.exists(prior) && field_from_each[prior];
                if (!prior_each && field_typed_kinds.exists(prior) &&
                    typed_descriptor_equal(key, prior))
                    fail($sformatf("%s.each.%s.unique: duplicate fixed value at indices %0d and %0d",
                                  root, suffix, j, i));
            end
        end
    endfunction

    // Checks finite .each candidate capacity once all fixed slots are materialized; descriptor-only,
    // no RNG-consuming parser call. Fields without a finite candidate set are left to bounded redraw.
    static function void preflight_unique(string root, int extent,
                                           string schema_id);
        string names[$];
        string raw, tokens[$];
        string suffix, key;
        lookup_t ul;
        int status, kind, width, each_slots, available;
        bit is_signed, from_each;
        int idx, ni, ci, fi, fj;
        logic [1023:0] cbits[$];
        string ctext[$];
        real creal[$];
        logic [1023:0] tb;
        string ts;
        real tr;
        string prior;
        bit prior_each;
        bit matched, fixed_seen;
        lookup_t each_rule;
        bit schema_ok;

        names = field_names[root];
        if (schema_id != "") begin
            collect_schema_scalar_suffixes(schema_id, "", names);
        end
        foreach (names[ni]) begin
            suffix = names[ni];
            begin
                string selected_key;
                ul = lookup_container_rule(
                    root, {".each.", suffix, ".unique"}, selected_key);
            end
            if (!ul.found) continue;
            if (aip_str::lower(aip_str::strip(ul.value)) != "1") continue;
            aip_cmdline_diagnostic::select_value({root, ".each.", suffix, ".unique"}, ul.value);
            check_fixed_unique(root, suffix, extent);
            begin
                string selected_key;
                each_rule = lookup_container_rule(
                    root, {".each.", suffix}, selected_key);
            end
            if (!each_rule.found) continue;
            raw = each_rule.value;
            aip_cmdline_diagnostic::select_value({root, ".each.", suffix}, raw);
            schema_ok = schema_typed_field(schema_id, suffix, kind, width, is_signed);
            if (!schema_ok) continue;
            status = finite_candidate_tokens(raw, tokens, kind);
            if (status < 0) continue;
            cbits = {};
            ctext = {};
            creal = {};
            foreach (tokens[ci]) begin
                if (!typed_literal_descriptor(tokens[ci], kind, width,
                                              tb, ts, tr, schema_id, suffix)) begin
                    cbits = {};
                    ctext = {};
                    creal = {};
                    status = -1;
                    break;
                end
                matched = 0;
                foreach (cbits[fi]) begin
                    if (typed_candidate_equal(kind, cbits[fi], ctext[fi], creal[fi],
                                              tb, ts, tr)) begin
                        matched = 1;
                        break;
                    end
                end
                if (!matched) begin
                    cbits.push_back(tb);
                    ctext.push_back(ts);
                    creal.push_back(tr);
                end
            end
            if (status < 0 || cbits.size() == 0 && tokens.size() != 0) continue;

            each_slots = 0;
            for (fi = 0; fi < extent; fi++) begin
                key = $sformatf("%s|%0d|%s", root, fi, suffix);
                if (field_from_each.exists(key) && field_from_each[key]) each_slots++;
            end
            available = cbits.size();
            foreach (cbits[ci]) begin
                fixed_seen = 0;
                for (fi = 0; fi < extent; fi++) begin
                    key = $sformatf("%s|%0d|%s", root, fi, suffix);
                    if (field_from_each.exists(key) && field_from_each[key]) continue;
                    if (typed_candidate_matches_key(key, kind, cbits[ci], ctext[ci], creal[ci])) begin
                        fixed_seen = 1;
                        break;
                    end
                end
                if (fixed_seen) available--;
            end
            if (available < each_slots)
                fail($sformatf("%s.each.%s.unique: only %0d candidates for %0d elements",
                              root, suffix, available, each_slots));
        end
    endfunction

    static function void remember_field_name(string base, string suffix);
        bit seen;
        seen = 0;
        foreach (field_names[base][i])
            if (field_names[base][i] == suffix) seen = 1;
        if (!seen) field_names[base].push_back(suffix);
    endfunction

    // kind: 1 = integral, 4 = enum.
    static function void record_typed_bits(string full_root, string field,
                                            input logic [1023:0] bits,
                                            input int width,
                                            input bit is_signed,
                                            input int kind);
        string base, suffix, key;
        int idx;
        if (!field_location(full_root, field, base, idx, suffix, key)) return;
        field_bits[key] = bits;
        field_width[key] = width;
        field_signed[key] = is_signed;
        field_typed_kinds[key] = kind;
        // Presence marker in the legacy map: old diagnostic tools enumerate field keys from it.
        field_values[key] = "";
        field_kinds[key] = kind;
        remember_field_name(base, suffix);
    endfunction

    static function void record_typed_string(string full_root, string field,
                                              input string value);
        string base, suffix, key;
        int idx;
        if (!field_location(full_root, field, base, idx, suffix, key)) return;
        field_string_values[key] = value;
        field_typed_kinds[key] = 2;
        field_values[key] = value;
        field_kinds[key] = 2;
        remember_field_name(base, suffix);
    endfunction

    static function void record_typed_real(string full_root, string field,
                                            input real value);
        string base, suffix, key;
        int idx;
        if (!field_location(full_root, field, base, idx, suffix, key)) return;
        field_real_values[key] = value;
        field_typed_kinds[key] = 3;
        field_values[key] = "";
        field_kinds[key] = 3;
        remember_field_name(base, suffix);
    endfunction

    static function void record_field(string full_root, string field,
                                      string value, int kind);
        int b, e, idx;
        string base, suffix, key, tail;
        bit seen;
        b = aip_str::str_find(full_root, "[");
        if (b <= 0) return;
        e = aip_str::str_find(full_root, "]", b+1);
        if (e <= b+1) return;
        base = full_root.substr(0, b-1);
        idx = aip_cmdline#(int)::parse_value(full_root.substr(b+1, e-1));
        tail = (e+1 < full_root.len()) ? full_root.substr(e+1) : "";
        if (tail != "" && tail[0] == ".") tail = tail.substr(1);
        suffix = (tail != "") ? {tail, ".", field} : field;
        key = $sformatf("%s|%0d|%s", base, idx, suffix);
        field_values[key] = value;
        field_kinds[key] = kind;
        seen = 0;
        foreach (field_names[base][i]) if (field_names[base][i] == suffix) seen = 1;
        if (!seen) field_names[base].push_back(suffix);
    endfunction

    static function bit get_field(string root, int idx, string suffix,
                                  output string value, output int kind);
        string key = $sformatf("%s|%0d|%s", root, idx, suffix);
        if (!field_values.exists(key)) begin value = ""; kind = 0; return 0; end
        value = field_values[key]; kind = field_kinds[key]; return 1;
    endfunction

    static function bit get_typed_field(string root, int idx, string suffix,
                                        output int kind,
                                        output logic [1023:0] bits,
                                        output int width,
                                        output bit is_signed,
                                        output real real_value,
                                        output string string_value);
        string key;
        key = $sformatf("%s|%0d|%s", root, idx, suffix);
        if (!field_typed_kinds.exists(key)) begin
            kind = 0;
            bits = '0;
            width = 0;
            is_signed = 0;
            real_value = 0.0;
            string_value = "";
            return 0;
        end
        kind = field_typed_kinds[key];
        bits = field_bits[key];
        width = field_width.exists(key) ? field_width[key] : 0;
        is_signed = field_signed.exists(key) ? field_signed[key] : 0;
        real_value = field_real_values.exists(key) ? field_real_values[key] : 0.0;
        string_value = field_string_values.exists(key) ? field_string_values[key] : "";
        return 1;
    endfunction
endclass
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
