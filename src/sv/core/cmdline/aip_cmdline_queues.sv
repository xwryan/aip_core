//===========================================================
// 所属层次：src/sv/core/cmdline（内部 include 片段，不是独立 compilation unit）。
// 严格 primitive queue 解析：整数、字符串、real 与 enum 的槽位选择和类型化求值。
// 依赖公共上下文、基础解析及 schema/数组适配器；外部宏负责把临时数组写回用户队列。
// 临时数组、预检和抽样按既有流程运行；源优先级、分配预算及失败终止方式均不改变。
// 只允许 aip_cmdline.sv 在其 include 窗口加载；拒绝直接包含，避免创建第二份 $unit/package 类型。
// 聚合入口持有唯一的 AIP_CMDLINE_SV 防重入 guard，本文件不声明新的 package。
// 本次仅按职责迁移定义，原有函数实现和宏展开语句保持不变。
//===========================================================
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
// Strict primitive queue adapters.  These intentionally do not call the
// legacy list resolver: queue APIs retain its PATH/leaf source order while
// using the accepted schema normalization, typed parsing, and allocation
// budget.  TARGET itself never crosses a helper ref boundary; only the
// temporary dynamic representation does.
class aip_strict_int_queue_runtime #(type T = int);
    static function aip_svec_t strict_literal(string token, string path);
        aip_vec_t value;
        aip_svec_t result;
        int explicit_width;
        bit negative;
        string cleaned;
        cleaned = aip_str::strip(token);
        if (!aip_str::str_to_vec(cleaned, value, explicit_width, negative))
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral literal '%s'", path, token));
        if (explicit_width > $bits(T) ||
            ($bits(T) < 1024 && (value >> $bits(T)) != 0))
            aip_struct_runtime::fail($sformatf(
                "%s integral token '%s' exceeds %0d-bit target",
                path, token, $bits(T)));
        result = aip_svec_t'({2'b00, value});
        return negative ? -result : result;
    endfunction

    static function void validate_range(string expr, string path);
        string s, parts[$];
        aip_svec_t lo, hi;
        s = aip_str::strip(expr);
        if (s.len() >= 2 && s[0] == "[" && s[s.len()-1] == "]")
            s = s.substr(1, s.len()-2);
        aip_struct_runtime::split_top(s, ":", parts);
        if (parts.size() != 2)
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral range '%s'", path, expr));
        lo = strict_literal(parts[0], path);
        hi = strict_literal(parts[1], path);
        if (lo > hi)
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral range '%s'", path, expr));
    endfunction

    // 验证一个整数权重项并返回其权重是否为正；path 标识配置位置。
    // 零权重允许禁用该项，但左值/范围仍须合法；负权重或格式错误终止解析。
    static function bit validate_weight_item(string item, string path);
        int eq_pos, slash_pos, op_pos;
        string left, right;
        aip_svec_t weight;
        eq_pos = aip_str::str_find(item, ":=");
        slash_pos = aip_str::str_find(item, ":/");
        if ((eq_pos >= 0) == (slash_pos >= 0))
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral weight item '%s'", path, item));
        op_pos = (eq_pos >= 0) ? eq_pos : slash_pos;
        if (op_pos <= 0 || op_pos + 2 >= item.len())
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral weight item '%s'", path, item));
        left = aip_str::strip(item.substr(0, op_pos-1));
        right = aip_str::strip(item.substr(op_pos+2, item.len()-1));
        if (left == "rand") begin
            if (eq_pos >= 0)
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral weight item '%s'", path, item));
        end else if (left.len() >= 2 && left[0] == "[" &&
                     left[left.len()-1] == "]") begin
            validate_range(left, path);
        end else begin
            void'(strict_literal(left, path));
        end
        weight = strict_literal(right, path);
        if (weight < 0)
            aip_struct_runtime::fail($sformatf(
                "%s integral weight must be >= 0 in item '%s'", path, item));
        return weight > 0;
    endfunction

    // 在整数严格解析入口完整检查所有候选，保留 expr/path 供上层来源诊断。
    // 全组至少一个正权重，零权重不绕过逐项校验；此函数不消费 RNG。
    static function void validate_expr(string expr, string path);
        string s, parts[$];
        aip_svec_t start_value, end_value, step_value;
        bit is_inc, has_positive_weight;
        aip_cmdline_diagnostic::select_expression(path, expr);
        s = aip_str::strip(expr);
        if (s == "")
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral literal '%s'", path, expr));
        if (s == "rand") return;
        if ((s.len() >= 4 && s.substr(0,3) == "seq:") ||
            (s.len() >= 5 && s.substr(0,4) == "perm:"))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for scalar queue slot", path));
        if ((s[0] == "{" || s[0] == "(") && s.len() >= 2 &&
            ((s[0] == "{" && s[s.len()-1] == "}") ||
             (s[0] == "(" && s[s.len()-1] == ")"))) begin
            aip_struct_runtime::split_top(s.substr(1, s.len()-2), ",", parts);
            if (parts.size() == 0)
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral weight group '%s'", path, expr));
            has_positive_weight = 0;
            foreach (parts[i]) begin
                if (validate_weight_item(parts[i], $sformatf("%s item[%0d]", path, i)))
                    has_positive_weight = 1;
            end
            if (!has_positive_weight)
                aip_struct_runtime::fail($sformatf(
                    "%s weighted group total must be > 0; all weights are zero in '%s'", path, expr));
            return;
        end
        if (s[0] == "{" || s[0] == "(" ||
            s[s.len()-1] == "}" || s[s.len()-1] == ")")
            aip_struct_runtime::fail($sformatf(
                "%s invalid integral expression '%s'", path, expr));
        if (s.len() >= 4 &&
            (s.substr(0,3) == "inc:" || s.substr(0,3) == "dec:")) begin
            is_inc = (s.substr(0,3) == "inc:");
            aip_struct_runtime::split_top(s.substr(4), ":", parts);
            if (parts.size() < 2 || parts.size() > 3)
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral %s expression '%s'",
                    path, is_inc ? "inc" : "dec", expr));
            start_value = strict_literal(parts[0], path);
            end_value = strict_literal(parts[1], path);
            step_value = (parts.size() == 3) ?
                         strict_literal(parts[2], path) : 1;
            if (step_value <= 0 ||
                (is_inc && start_value > end_value) ||
                (!is_inc && start_value < end_value))
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral %s expression '%s'",
                    path, is_inc ? "inc" : "dec", expr));
            return;
        end
        if (aip_str::str_find(s, ":=") >= 0 ||
            aip_str::str_find(s, ":/") >= 0) begin
            if (!validate_weight_item(s, path))
                aip_struct_runtime::fail($sformatf(
                    "%s weighted group total must be > 0; all weights are zero in '%s'", path, expr));
            return;
        end
        if (s[0] == "[") begin
            if (s.len() < 3 || s[s.len()-1] != "]")
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral range '%s'", path, expr));
            aip_struct_runtime::split_top(s.substr(1, s.len()-2), ",", parts);
            if (parts.size() > 1) begin
                foreach (parts[i]) validate_expr(parts[i], path);
                return;
            end
            validate_range(s, path);
            return;
        end
        if (aip_str::str_find(s, ":") >= 0) begin
            validate_range(s, path);
            return;
        end
        if (aip_str::str_find(s, ",") >= 0) begin
            aip_struct_runtime::split_top(s, ",", parts);
            if (parts.size() == 0)
                aip_struct_runtime::fail($sformatf(
                    "%s invalid integral expression '%s'", path, expr));
            foreach (parts[i]) void'(strict_literal(parts[i], path));
            return;
        end
        void'(strict_literal(s, path));
    endfunction

    // 对整数表达式先完整校验再抽样，返回目标 T；错误保留完整原文与失败子项。
    // 临时诊断帧在正常返回时弹出，不遗留上次字段位置，也不额外消费 RNG。
    static function T draw_strict(string expr, string path);
        T result;
        aip_cmdline_diagnostic::push_value(path, expr);
        validate_expr(expr, path);
        aip_cmdline_diagnostic::select_value(path, expr);
        result = aip_cmdline#(T)::parse_value(expr);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // Return a winner's single final typed value without invoking a random
    // resolver.  Multiple raw spellings that cast to the same T value are
    // still deterministic; genuinely multi-valued or non-enumerable rules
    // stay on the normal materialize-and-check path.
    // 为本次解析单独保存诊断帧，提前返回也由包装层恢复上层来源。
    static function bit deterministic_value(
        aip_struct_runtime::lookup_t winner,
        T default_val,
        string path,
        output T value);
        bit result;
        aip_cmdline_diagnostic::push_value(path, winner.value);
        result = deterministic_value_impl(winner, default_val, path, value);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 无随机抽样地判断 winner 经 T 类型转换后是否只有一个候选值；缺失时使用默认值。
    // 不确定表达式返回 0，非法候选在外层绑定的具体索引上下文中 fatal。
    protected static function bit deterministic_value_impl(
        aip_struct_runtime::lookup_t winner,
        T default_val,
        string path,
        output T value);
        string tokens[$];
        T values[$];
        T candidate;
        int status;
        bit seen;
        if (!winner.found) begin
            value = default_val;
            return 1;
        end
        status = aip_struct_runtime::finite_candidate_tokens(
            winner.value, tokens, 1);
        if (status < 0) return 0;
        foreach (tokens[i]) begin
            candidate = T'(strict_literal(tokens[i], path));
            seen = 0;
            foreach (values[j])
                if (values[j] === candidate) seen = 1;
            if (!seen) values.push_back(candidate);
        end
        if (values.size() != 1) return 0;
        value = values[0];
        return 1;
    endfunction

    // Prove finite unique capacity before any `.each` draw.  Raw candidates
    // are bounded by finite_candidate_tokens(); only after that cutoff are
    // they cast to T and deduplicated.  Unknown randomized fixed winners make
    // this check conservative, while deterministic fixed winners are checked
    // for collisions and removed from the available each set.
    // 为本次解析单独保存诊断帧，提前返回也由包装层恢复上层来源。
    static function void preflight_unique(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        T default_val);
        aip_cmdline_diagnostic::push_value({path, ".unique"}, "1");
        preflight_unique_impl(path, each_expr, winners, from_each, default_val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 预检固定整数值冲突及 each 可用候选数，先按 T 转换去重且不消费随机数。
    // 无法有限枚举的表达式留给后续有界重抽，正常返回由包装层恢复诊断上下文。
    protected static function void preflight_unique_impl(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        T default_val);
        string tokens[$];
        T candidates[$];
        T fixed_values[];
        bit fixed_known[];
        T candidate;
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
                if (fixed_known[j] && fixed_values[i] === fixed_values[j])
                    aip_struct_runtime::fail($sformatf(
                        "%s.unique: duplicate fixed value at indices %0d and %0d",
                        path, j, i));
        end

        if (each_slots == 0) return;
        aip_cmdline_diagnostic::select_value({path, ".each"}, each_expr);
        status = aip_struct_runtime::finite_candidate_tokens(
            each_expr, tokens, 1);
        if (status < 0) return;
        foreach (tokens[i]) begin
            candidate = T'(strict_literal(tokens[i], {path, ".each"}));
            seen = 0;
            foreach (candidates[j])
                if (candidates[j] === candidate) seen = 1;
            if (!seen) candidates.push_back(candidate);
        end
        available = candidates.size();
        foreach (candidates[i]) begin
            occupied = 0;
            foreach (fixed_values[j])
                if (fixed_known[j] && fixed_values[j] === candidates[i]) begin
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

    // 为本次解析单独保存诊断帧，提前返回也由包装层恢复上层来源。
    static function void resolve(string full_root, string leaf_root,
                                 T default_val, int max_size,
                                 ref T arr[]);
        aip_cmdline_diagnostic::push(full_root);
        resolve_impl(full_root, leaf_root, default_val, max_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按队列既有 PATH/leaf 来源优先级确定大小及各槽位，先检查容量再生成 T 数组。
    // unique 模式先物化固定值再抽 each；控制与候选分别记录原文，失败立即 fatal。
    protected static function void resolve_impl(string full_root, string leaf_root,
                                 T default_val, int max_size,
                                 ref T arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, ul, sol;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str, unique_str, sort_str;
        int n, extent, glen;
        bit gen, unique_on, each_used;
        bit from_each[];

        ol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root);
        sl = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".size");
        el = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".each");
        ul = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".unique");
        sol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".sort");
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        unique_str = ul.found ? aip_str::lower(aip_str::strip(ul.value)) : "0";
        sort_str = sol.found ? aip_str::lower(aip_str::strip(sol.value)) : "none";
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (ol.found && aip_str::strip(overall) == "")
            aip_struct_runtime::fail($sformatf("empty value for %s", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.value);
        if (ul.found && unique_str != "0" && unique_str != "1")
            aip_struct_runtime::fail($sformatf("%s.unique must be 0 or 1", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".sort"}, sol.value);
        if (sol.found && sort_str != "asc" && sort_str != "desc" &&
            sort_str != "none")
            aip_struct_runtime::fail($sformatf("%s.sort must be asc, desc, or none", full_root));
        unique_on = (unique_str == "1");

        if (sl.found)
            n = aip_struct_runtime::normalize_size(sl.value,
                                                   {full_root, ".size"},
                                                   max_size);
        else
            n = -1;
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value(full_root, overall);
            aip_struct_runtime::validate_generator_target(overall, full_root,
                                                           $bits(T));
            glen = aip_struct_runtime::overall_length(overall, gen);
            if (n >= 0 && gen && glen != n)
                aip_struct_runtime::fail($sformatf(
                    "%s.size conflicts with generator length %0d",
                    full_root, glen));
            if (n >= 0 && !gen && glen > n)
                aip_struct_runtime::fail($sformatf(
                    "%s overall list exceeds size", full_root));
            if (n < 0) n = glen;
        end
        extent = aip_struct_runtime::queue_index_extent(full_root, leaf_root);
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (n < 0) begin
            if (extent > 0) n = extent;
            else if (el.found)
                aip_struct_runtime::fail($sformatf(
                    "%s.each given but size unknown", full_root));
            else n = 0;
        end
        if (extent > n) begin
            aip_struct_runtime::lookup_t index_rule;
            index_rule = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, $sformatf("[%0d]", extent-1));
            aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", full_root, extent-1), index_rule.value);
            aip_struct_runtime::fail($sformatf(
                "%s indexed value out of range", full_root));
        end
        aip_cmdline_diagnostic::select_value(sl.found ? {full_root, ".size"} : full_root,
            sl.found ? sl.value : overall);
        aip_struct_runtime::check_container_capacity(full_root, n, max_size);
        aip_struct_runtime::charge_allocation(full_root, n);
        arr = new[n];
        from_each = new[n];
        winners = new[n];
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value(full_root, overall);
            aip_struct_runtime::prepare_container_generator(full_root, overall);
        end
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::queue_slot_rule(
                full_root, leaf_root, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (each_used && aip_str::strip(each_str) == "")
            aip_struct_runtime::fail($sformatf(
                "empty value for %s.each", full_root));
        if (unique_on)
            preflight_unique(full_root, each_str, winners, from_each,
                             default_val);
        if (unique_on) begin
            aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.value);
            // Materialize every fixed winner first so an earlier `.each`
            // slot can reject a collision with a later indexed/overall slot.
            for (int i = 0; i < n; i++) begin
                if (from_each[i]) continue;
                if (!winners[i].found) arr[i] = default_val;
                else begin
                    if (aip_str::strip(winners[i].value) == "") begin
                        aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", full_root, i), winners[i].value);
                        aip_struct_runtime::fail($sformatf(
                            "empty value for %s[%0d]", full_root, i));
                    end
                    arr[i] = draw_strict(winners[i].value,
                                         $sformatf("%s[%0d]", full_root, i));
                end
            end
            for (int i = 0; i < n; i++) if (!from_each[i])
                for (int j = 0; j < i; j++)
                    if (!from_each[j] && arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
            for (int i = 0; i < n; i++) begin
                int attempts;
                bit duplicate;
                attempts = 0;
                if (from_each[i]) begin
                    arr[i] = draw_strict(winners[i].value,
                                         {full_root, ".each"});
                    do begin
                        duplicate = 0;
                        for (int j = 0; j < n; j++)
                            if (j != i && (!from_each[j] || j < i) &&
                                arr[i] === arr[j]) duplicate = 1;
                        if (!duplicate) break;
                        attempts++;
                        if (attempts > 100)
                            aip_struct_runtime::fail($sformatf(
                                "%s.unique: candidate shortage", full_root));
                        arr[i] = draw_strict(winners[i].value,
                                             {full_root, ".each"});
                    end while (duplicate);
                end
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
        end else begin
            // With uniqueness disabled, retain index-order draw semantics
            // while evaluating only the already-selected winner.
            for (int i = 0; i < n; i++) begin
                if (!winners[i].found) arr[i] = default_val;
                else begin
                    if (aip_str::strip(winners[i].value) == "") begin
                        aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", full_root, i), winners[i].value);
                        aip_struct_runtime::fail($sformatf(
                            "empty value for %s[%0d]", full_root, i));
                    end
                    arr[i] = draw_strict(winners[i].value,
                                         winners[i].from_each ?
                                         {full_root, ".each"} :
                                         $sformatf("%s[%0d]", full_root, i));
                end
            end
        end
        if (sort_str == "asc" || sort_str == "desc") begin
            for (int i = 1; i < n; i++) begin
                T value;
                int j;
                value = arr[i];
                j = i;
                while (j > 0 &&
                       ((sort_str == "asc" && value < arr[j-1]) ||
                        (sort_str == "desc" && value > arr[j-1]))) begin
                    arr[j] = arr[j-1];
                    j--;
                end
                arr[j] = value;
            end
        end
    endfunction
endclass

// 字符串队列将控制键与实际 winner 分开记录，避免后查询的 .sort 掩盖前一项错误；
// 入口和逐元素抽样使用同步栈，直接调用 runtime 也不会沿用此前宏的来源。
class aip_strict_string_queue_runtime;
    // 判断文本是否声明了字符串队列不支持的 seq/perm 生成器；不解析和消费随机数。
    static function bit unsupported_generator(string text);
        string s;
        s = aip_str::lower(aip_str::strip(text));
        return ((s.len() >= 4 && s.substr(0,3) == "seq:") ||
                (s.len() >= 5 && s.substr(0,4) == "perm:"));
    endfunction

    // 为整个队列解析建立临时上下文，输出动态数组；所有失败由公共 fatal 处理。
    // 调用者未提供宏来源时只继承当前有效上下文，不保存跨调用的全局状态。
    static function void resolve(string full_root, string leaf_root,
                                 string default_val, int max_size,
                                 ref string arr[]);
        aip_cmdline_diagnostic::push(full_root);
        resolve_impl(full_root, leaf_root, default_val, max_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 对单个 winner 保留完整表达式和逻辑槽位，再执行字符串随机/转义解析。
    // 正常返回恢复队列控制项上下文，非法引号或转义在当前用户调用位置 fatal。
    static function string draw(string expr, string path);
        string result;
        aip_cmdline_diagnostic::push_value(path, expr);
        result = aip_struct_runtime::resolve_string(expr);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 按 overall/each/index 优先级解析字符串队列；每个校验前选择对应原始值，
    // 保持既有大小推导、唯一性和排序语义，错误不返回半构造数组。
    static function void resolve_impl(string full_root, string leaf_root,
                                 string default_val, int max_size,
                                 ref string arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, ul, sol, gr;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str, unique_str, sort_str, generator_suffix;
        int n, extent, olen;
        bit gen, unique_on, each_used;
        bit from_each[];

        ol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root);
        sl = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".size");
        el = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".each");
        ul = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".unique");
        sol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".sort");
        generator_suffix = ".seq";
        gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".seq");
        if (!gr.found) begin
            generator_suffix = ".perm";
            gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".perm");
        end
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (gr.found)
            aip_cmdline_diagnostic::select_value({full_root, generator_suffix}, gr.value);
        if (gr.found || (ol.found && unsupported_generator(overall)))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for string primitive queue",
                full_root));
        unique_str = ul.found ? aip_str::lower(aip_str::strip(ul.value)) : "0";
        sort_str = sol.found ? aip_str::lower(aip_str::strip(sol.value)) : "none";
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.found ? ul.value : "0");
        if (ul.found && unique_str != "0" && unique_str != "1")
            aip_struct_runtime::fail($sformatf("%s.unique must be 0 or 1", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".sort"}, sol.found ? sol.value : "none");
        if (sol.found && sort_str != "asc" && sort_str != "desc" &&
            sort_str != "none")
            aip_struct_runtime::fail($sformatf("%s.sort must be asc, desc, or none", full_root));
        unique_on = (unique_str == "1");

        aip_cmdline_diagnostic::select_value({full_root, ".size"}, sl.found ? sl.value : "");
        if (sl.found)
            n = aip_struct_runtime::normalize_size(sl.value,
                                                   {full_root, ".size"},
                                                   max_size);
        else n = -1;
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value(full_root, overall);
            olen = (overall == "") ? 1 :
                   aip_struct_runtime::overall_length(overall, gen);
            if (n >= 0 && olen > n)
                aip_struct_runtime::fail($sformatf(
                    "%s overall list exceeds size", full_root));
            if (n < 0) n = olen;
        end
        extent = aip_struct_runtime::queue_index_extent(full_root, leaf_root);
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (n < 0) begin
            if (extent > 0) n = extent;
            else if (el.found)
                aip_struct_runtime::fail($sformatf(
                    "%s.each given but size unknown", full_root));
            else n = 0;
        end
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (extent > n)
            aip_struct_runtime::fail($sformatf(
                "%s indexed value out of range", full_root));
        aip_struct_runtime::check_container_capacity(full_root, n, max_size);
        aip_struct_runtime::charge_allocation(full_root, n);
        arr = new[n];
        from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::queue_slot_rule(
                full_root, leaf_root, ol, el, i, 1);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (each_used && unsupported_generator(each_str))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for string primitive queue",
                full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, unique_str);
        if (unique_on)
            aip_struct_string_array_runtime::preflight_unique(
                full_root, each_str, winners, from_each, default_val);
        if (unique_on) begin
            for (int i = 0; i < n; i++) begin
                if (from_each[i]) continue;
                if (winners[i].found)
                    arr[i] = draw(winners[i].value,
                                  $sformatf("%s[%0d]", full_root, i));
                else
                    arr[i] = default_val;
            end
            aip_cmdline_diagnostic::select_value({full_root, ".unique"}, unique_str);
            for (int i = 0; i < n; i++) if (!from_each[i])
                for (int j = 0; j < i; j++)
                    if (!from_each[j] && arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
            for (int i = 0; i < n; i++) begin
                int attempts;
                bit duplicate;
                attempts = 0;
                if (from_each[i]) begin
                    arr[i] = draw(winners[i].value, {full_root, ".each"});
                    do begin
                        duplicate = 0;
                        for (int j = 0; j < n; j++)
                            if (j != i && (!from_each[j] || j < i) &&
                                arr[i] == arr[j]) duplicate = 1;
                        if (!duplicate) break;
                        attempts++;
                        if (attempts > 100)
                            aip_struct_runtime::fail($sformatf(
                                "%s.unique: candidate shortage", full_root));
                        arr[i] = draw(winners[i].value, {full_root, ".each"});
                    end while (duplicate);
                end
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
        end else begin
            for (int i = 0; i < n; i++) begin
                if (winners[i].found)
                    arr[i] = draw(winners[i].value, winners[i].from_each ?
                                  {full_root, ".each"} :
                                  $sformatf("%s[%0d]", full_root, i));
                else
                    arr[i] = default_val;
            end
        end
        if (sort_str == "asc" || sort_str == "desc") begin
            for (int i = 1; i < n; i++) begin
                string value;
                int j;
                value = arr[i];
                j = i;
                while (j > 0 &&
                       ((sort_str == "asc" && value < arr[j-1]) ||
                        (sort_str == "desc" && value > arr[j-1]))) begin
                    arr[j] = arr[j-1];
                    j--;
                end
                arr[j] = value;
            end
        end
    endfunction
endclass

class aip_strict_real_queue_runtime;
    static function bit unsupported_generator(string text);
        string s;
        s = aip_str::lower(aip_str::strip(text));
        return ((s.len() >= 4 && s.substr(0,3) == "seq:") ||
                (s.len() >= 5 && s.substr(0,4) == "perm:"));
    endfunction

    // 为本次解析单独保存诊断帧，提前返回也由包装层恢复上层来源。
    static function void resolve(string full_root, string leaf_root,
                                 real default_val, int max_size,
                                 ref real arr[]);
        aip_cmdline_diagnostic::push(full_root);
        resolve_impl(full_root, leaf_root, default_val, max_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按队列既有 PATH/leaf 来源优先级生成 real 临时数组，检查容量、表达式及唯一性。
    // 拒绝 seq/perm，校验或抽样前选择对应控制/槽位原文，外层统一恢复诊断帧。
    protected static function void resolve_impl(string full_root, string leaf_root,
                                 real default_val, int max_size,
                                 ref real arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, ul, sol, gr;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str, unique_str, sort_str;
        int n, extent, olen;
        bit gen, unique_on, each_used;
        bit from_each[];

        ol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root);
        sl = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".size");
        el = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".each");
        ul = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".unique");
        sol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".sort");
        gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".seq");
        aip_cmdline_diagnostic::select_value({full_root, ".seq"}, gr.value);
        if (!gr.found) begin
            gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".perm");
            aip_cmdline_diagnostic::select_value({full_root, ".perm"}, gr.value);
        end
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        if (gr.found)
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for real primitive queue", full_root));
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (ol.found && unsupported_generator(overall))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for real primitive queue",
                full_root));
        if (ol.found && aip_str::strip(overall) == "")
            aip_struct_runtime::fail($sformatf("empty value for %s", full_root));
        unique_str = ul.found ? aip_str::lower(aip_str::strip(ul.value)) : "0";
        sort_str = sol.found ? aip_str::lower(aip_str::strip(sol.value)) : "none";
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.value);
        if (ul.found && unique_str != "0" && unique_str != "1")
            aip_struct_runtime::fail($sformatf("%s.unique must be 0 or 1", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".sort"}, sol.value);
        if (sol.found && sort_str != "asc" && sort_str != "desc" &&
            sort_str != "none")
            aip_struct_runtime::fail($sformatf("%s.sort must be asc, desc, or none", full_root));
        unique_on = (unique_str == "1");

        if (sl.found)
            n = aip_struct_runtime::normalize_size(sl.value,
                                                   {full_root, ".size"},
                                                   max_size);
        else n = -1;
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value(full_root, overall);
            olen = aip_struct_runtime::overall_length(overall, gen);
            if (n >= 0 && olen > n)
                aip_struct_runtime::fail($sformatf(
                    "%s overall list exceeds size", full_root));
            if (n < 0) n = olen;
        end
        extent = aip_struct_runtime::queue_index_extent(full_root, leaf_root);
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (n < 0) begin
            if (extent > 0) n = extent;
            else if (el.found)
                aip_struct_runtime::fail($sformatf(
                    "%s.each given but size unknown", full_root));
            else n = 0;
        end
        if (extent > n) begin
            aip_struct_runtime::lookup_t index_rule;
            index_rule = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, $sformatf("[%0d]", extent-1));
            aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", full_root, extent-1), index_rule.value);
            aip_struct_runtime::fail($sformatf(
                "%s indexed value out of range", full_root));
        end
        aip_cmdline_diagnostic::select_value(sl.found ? {full_root, ".size"} : full_root,
            sl.found ? sl.value : overall);
        aip_struct_runtime::check_container_capacity(full_root, n, max_size);
        aip_struct_runtime::charge_allocation(full_root, n);
        arr = new[n];
        from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::queue_slot_rule(
                full_root, leaf_root, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (each_used && unsupported_generator(each_str))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for real primitive queue",
                full_root));
        if (each_used && aip_str::strip(each_str) == "")
            aip_struct_runtime::fail($sformatf(
                "empty value for %s.each", full_root));
        if (unique_on)
            aip_struct_real_array_runtime::preflight_unique(
                full_root, each_str, winners, from_each, default_val);
        if (unique_on) begin
            aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.value);
            for (int i = 0; i < n; i++) begin
                if (from_each[i]) continue;
                if (winners[i].found)
                    arr[i] = aip_struct_real_array_runtime::draw_strict(
                        winners[i].value,
                        $sformatf("%s[%0d]", full_root, i));
                else
                    arr[i] = default_val;
            end
            for (int i = 0; i < n; i++) if (!from_each[i])
                for (int j = 0; j < i; j++)
                    if (!from_each[j] && arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
            for (int i = 0; i < n; i++) begin
                int attempts;
                bit duplicate;
                attempts = 0;
                if (from_each[i]) begin
                    arr[i] = aip_struct_real_array_runtime::draw_strict(
                        winners[i].value, {full_root, ".each"});
                    do begin
                        duplicate = 0;
                        for (int j = 0; j < n; j++)
                            if (j != i && (!from_each[j] || j < i) &&
                                arr[i] == arr[j]) duplicate = 1;
                        if (!duplicate) break;
                        attempts++;
                        if (attempts > 100)
                            aip_struct_runtime::fail($sformatf(
                                "%s.unique: candidate shortage", full_root));
                        arr[i] = aip_struct_real_array_runtime::draw_strict(
                            winners[i].value, {full_root, ".each"});
                    end while (duplicate);
                end
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] == arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
        end else begin
            for (int i = 0; i < n; i++) begin
                if (!winners[i].found) arr[i] = default_val;
                else arr[i] = aip_struct_real_array_runtime::draw_strict(
                    winners[i].value, winners[i].from_each ?
                    {full_root, ".each"} :
                    $sformatf("%s[%0d]", full_root, i));
            end
        end
        if (sort_str == "asc" || sort_str == "desc") begin
            for (int i = 1; i < n; i++) begin
                real value;
                int j;
                value = arr[i];
                j = i;
                while (j > 0 &&
                       ((sort_str == "asc" && value < arr[j-1]) ||
                        (sort_str == "desc" && value > arr[j-1]))) begin
                    arr[j] = arr[j-1];
                    j--;
                end
                arr[j] = value;
            end
        end
    endfunction
endclass

// 枚举队列保留字段/槽位和原始候选串，预检与抽样共享诊断来源，非法候选立即终止。
class aip_strict_enum_queue_runtime #(type E = int);
    // 将一个候选名称映射到 E；完整原文由上层保留，本层仅补充当前子表达式。
    // 名称忽略大小写，未知名称通过公共 fatal 报出逻辑路径而不返回伪造默认值。
    static function bit parse_name(
        string token,
        string path,
        input string names[$],
        input logic [1023:0] bits[$],
        output E value);
        string normalized;
        aip_cmdline_diagnostic::select_expression(path, token);
        normalized = aip_str::lower(aip_str::strip(token));
        foreach (names[i]) begin
            if (aip_str::lower(names[i]) == normalized) begin
                value = E'(bits[i]);
                return 1;
            end
        end
        aip_struct_runtime::fail($sformatf(
            "%s invalid enum value '%s'", path, token));
        return 0;
    endfunction

    // 在同步子上下文内校验并抽样枚举表达式，直接 API 调用也保留完整原文；
    // 所有候选都先校验，故无论随机种子为何均可发现非法名称。
    static function E draw(string expr, string path,
                           input string names[$],
                           input logic [1023:0] bits[$]);
        E result;
        aip_cmdline_diagnostic::push_value(path, expr);
        result = draw_impl(expr, path, names, bits);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 执行已建立来源的候选解析，返回一个合法 E；空串、坏分隔符和非法名称 fatal。
    static function E draw_impl(string expr, string path,
                           input string names[$],
                           input logic [1023:0] bits[$]);
        string parts[$];
        E candidates[$];
        string token;
        bit matched;
        aip_struct_runtime::split_top(expr, ",", parts);
        if (parts.size() == 0)
            aip_struct_runtime::fail($sformatf(
                "%s invalid enum value '%s'", path, expr));
        foreach (parts[p]) begin
            token = aip_str::lower(aip_str::strip(parts[p]));
            matched = 0;
            foreach (names[i]) begin
                if (aip_str::lower(names[i]) == token) begin
                    candidates.push_back(E'(bits[i]));
                    matched = 1;
                    break;
                end
            end
            if (!matched)
                aip_struct_runtime::fail($sformatf(
                    "%s invalid enum value '%s'", path, parts[p]));
        end
        return candidates[$urandom_range(candidates.size()-1)];
    endfunction

    // 预检固定 winner 是否只有一个不同的枚举值；缺失 winner 使用默认值，
    // 非确定性表达式返回 0；解析错误先选择该 winner 原文以定位具体索引。
    static function bit deterministic_value(
        aip_struct_runtime::lookup_t winner,
        E default_val,
        string path,
        input string names[$],
        input logic [1023:0] bits[$],
        output E value);
        string tokens[$];
        E values[$];
        E candidate;
        int status;
        bit seen;
        if (!winner.found) begin
            value = default_val;
            return 1;
        end
        aip_cmdline_diagnostic::select_value(path, winner.value);
        if (aip_str::str_find(winner.value, ":") >= 0 ||
            aip_str::str_find(winner.value, "{") >= 0 ||
            aip_str::str_find(winner.value, "(") >= 0)
            return 0;
        status = aip_struct_runtime::finite_candidate_tokens(
            winner.value, tokens, 4);
        if (status < 0) return 0;
        foreach (tokens[i]) begin
            void'(parse_name(tokens[i], path, names, bits, candidate));
            seen = 0;
            foreach (values[j])
                if (values[j] === candidate) seen = 1;
            if (!seen) values.push_back(candidate);
        end
        if (values.size() != 1) return 0;
        value = values[0];
        return 1;
    endfunction

    // 预检唯一性：固定值冲突或 .each 可用候选不足直接 fatal，预检不消费随机数。
    // 固定 winner 与 each 分别记录原始输入，避免报错落到此前处理的其他槽位。
    static function void preflight_unique(
        string path,
        string each_expr,
        input aip_struct_runtime::lookup_t winners[],
        input bit from_each[],
        E default_val,
        input string names[$],
        input logic [1023:0] bits[$]);
        string tokens[$];
        E candidates[$];
        E fixed_values[];
        bit fixed_known[];
        E candidate;
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
                names, bits, fixed_values[i]);
        end
        aip_cmdline_diagnostic::select_value({path, ".unique"}, "1");
        foreach (fixed_values[i]) begin
            if (!fixed_known[i]) continue;
            for (int j = 0; j < i; j++)
                if (fixed_known[j] && fixed_values[i] === fixed_values[j])
                    aip_struct_runtime::fail($sformatf(
                        "%s.unique: duplicate fixed value at indices %0d and %0d",
                        path, j, i));
        end

        if (each_slots == 0 || aip_str::str_find(each_expr, ":") >= 0 ||
            aip_str::str_find(each_expr, "{") >= 0 ||
            aip_str::str_find(each_expr, "(") >= 0)
            return;
        aip_cmdline_diagnostic::select_value({path, ".each"}, each_expr);
        status = aip_struct_runtime::finite_candidate_tokens(
            each_expr, tokens, 4);
        if (status < 0) return;
        foreach (tokens[i]) begin
            void'(parse_name(tokens[i], {path, ".each"}, names, bits,
                             candidate));
            seen = 0;
            foreach (candidates[j])
                if (candidates[j] === candidate) seen = 1;
            if (!seen) candidates.push_back(candidate);
        end
        available = candidates.size();
        foreach (candidates[i]) begin
            occupied = 0;
            foreach (fixed_values[j])
                if (fixed_known[j] && fixed_values[j] === candidates[i]) begin
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

    // 只识别枚举队列不支持的 seq/perm 前缀，不改变表达式或随机状态。
    static function bit unsupported_generator(string text);
        string s;
        s = aip_str::lower(aip_str::strip(text));
        return ((s.len() >= 4 && s.substr(0,3) == "seq:") ||
                (s.len() >= 5 && s.substr(0,4) == "perm:"));
    endfunction

    // 给整个枚举队列解析建立同步诊断上下文，正常返回时恢复调用方来源。
    // 输出数组仅在全部控制键、默认枚举和候选合法时才交给宏拷贝。
    static function void resolve(string full_root, string leaf_root,
                                 E default_val, int max_size,
                                 input string names[$],
                                 input logic [1023:0] bits[$],
                                 ref E arr[]);
        aip_cmdline_diagnostic::push(full_root);
        resolve_impl(full_root, leaf_root, default_val, max_size, names, bits, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按既有规则推导大小、选择 winner、执行唯一性和排序；各失败点先切换到对应
    // 控制键或候选原文，fatal 不允许调用方继续使用部分解析结果。
    static function void resolve_impl(string full_root, string leaf_root,
                                 E default_val, int max_size,
                                 input string names[$],
                                 input logic [1023:0] bits[$],
                                 ref E arr[]);
        aip_struct_runtime::lookup_t ol, sl, el, ul, sol, gr;
        aip_struct_runtime::lookup_t winners[];
        string overall, each_str, unique_str, sort_str, generator_suffix;
        int n, extent, olen;
        bit gen, unique_on, default_valid, each_used;
        bit from_each[];

        aip_cmdline_diagnostic::select_value(full_root, $sformatf("DEFAULT_VAL=%0d", default_val));
        default_valid = 0;
        foreach (bits[i])
            if (default_val === E'(bits[i])) default_valid = 1;
        if (!default_valid)
            aip_struct_runtime::fail($sformatf(
                "%s invalid enum DEFAULT_VAL", full_root));
        ol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root);
        sl = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".size");
        el = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".each");
        ul = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".unique");
        sol = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".sort");
        generator_suffix = ".seq";
        gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".seq");
        if (!gr.found) begin
            generator_suffix = ".perm";
            gr = aip_struct_runtime::lookup_queue_rule(full_root, leaf_root, ".perm");
        end
        overall = ol.found ? ol.value : "";
        each_str = el.found ? el.value : "";
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (gr.found)
            aip_cmdline_diagnostic::select_value({full_root, generator_suffix}, gr.value);
        if (gr.found || (ol.found && unsupported_generator(overall)))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for enum primitive queue",
                full_root));
        if (ol.found && aip_str::strip(overall) == "")
            aip_struct_runtime::fail($sformatf("empty value for %s", full_root));
        unique_str = ul.found ? aip_str::lower(aip_str::strip(ul.value)) : "0";
        sort_str = sol.found ? aip_str::lower(aip_str::strip(sol.value)) : "none";
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, ul.found ? ul.value : "0");
        if (ul.found && unique_str != "0" && unique_str != "1")
            aip_struct_runtime::fail($sformatf("%s.unique must be 0 or 1", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".sort"}, sol.found ? sol.value : "none");
        if (sol.found && sort_str != "asc" && sort_str != "desc" &&
            sort_str != "none")
            aip_struct_runtime::fail($sformatf("%s.sort must be asc, desc, or none", full_root));
        unique_on = (unique_str == "1");

        aip_cmdline_diagnostic::select_value({full_root, ".size"}, sl.found ? sl.value : "");
        if (sl.found)
            n = aip_struct_runtime::normalize_size(sl.value,
                                                   {full_root, ".size"},
                                                   max_size);
        else n = -1;
        if (ol.found) begin
            aip_cmdline_diagnostic::select_value(full_root, overall);
            olen = aip_struct_runtime::overall_length(overall, gen);
            if (n >= 0 && olen > n)
                aip_struct_runtime::fail($sformatf(
                    "%s overall list exceeds size", full_root));
            if (n < 0) n = olen;
        end
        extent = aip_struct_runtime::queue_index_extent(full_root, leaf_root);
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (n < 0) begin
            if (extent > 0) n = extent;
            else if (el.found)
                aip_struct_runtime::fail($sformatf(
                    "%s.each given but size unknown", full_root));
            else n = 0;
        end
        aip_cmdline_diagnostic::select_value(full_root, overall);
        if (extent > n)
            aip_struct_runtime::fail($sformatf(
                "%s indexed value out of range", full_root));
        aip_struct_runtime::check_container_capacity(full_root, n, max_size);
        aip_struct_runtime::charge_allocation(full_root, n);
        arr = new[n];
        from_each = new[n];
        winners = new[n];
        each_used = 0;
        for (int i = 0; i < n; i++) begin
            winners[i] = aip_struct_runtime::queue_slot_rule(
                full_root, leaf_root, ol, el, i);
            from_each[i] = winners[i].found && winners[i].from_each;
            if (from_each[i]) each_used = 1;
        end
        aip_cmdline_diagnostic::select_value({full_root, ".each"}, each_str);
        if (each_used && unsupported_generator(each_str))
            aip_struct_runtime::fail($sformatf(
                "%s seq/perm unsupported for enum primitive queue",
                full_root));
        if (each_used && aip_str::strip(each_str) == "")
            aip_struct_runtime::fail($sformatf(
                "empty value for %s.each", full_root));
        aip_cmdline_diagnostic::select_value({full_root, ".unique"}, unique_str);
        if (unique_on)
            preflight_unique(full_root, each_str, winners, from_each,
                             default_val, names, bits);
        if (unique_on) begin
            for (int i = 0; i < n; i++) begin
                if (from_each[i]) continue;
                if (winners[i].found)
                    arr[i] = draw(winners[i].value,
                                  $sformatf("%s[%0d]", full_root, i),
                                  names, bits);
                else
                    arr[i] = default_val;
            end
            aip_cmdline_diagnostic::select_value({full_root, ".unique"}, unique_str);
            for (int i = 0; i < n; i++) if (!from_each[i])
                for (int j = 0; j < i; j++)
                    if (!from_each[j] && arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
            for (int i = 0; i < n; i++) begin
                int attempts;
                bit duplicate;
                attempts = 0;
                if (from_each[i]) begin
                    arr[i] = draw(winners[i].value, {full_root, ".each"},
                                  names, bits);
                    do begin
                        duplicate = 0;
                        for (int j = 0; j < n; j++)
                            if (j != i && (!from_each[j] || j < i) &&
                                arr[i] === arr[j]) duplicate = 1;
                        if (!duplicate) break;
                        attempts++;
                        if (attempts > 100)
                            aip_struct_runtime::fail($sformatf(
                                "%s.unique: candidate shortage", full_root));
                        arr[i] = draw(winners[i].value,
                                      {full_root, ".each"}, names, bits);
                    end while (duplicate);
                end
            end
            for (int i = 0; i < n; i++)
                for (int j = 0; j < i; j++)
                    if (arr[i] === arr[j])
                        aip_struct_runtime::fail($sformatf(
                            "%s.unique: duplicate final value", full_root));
        end else begin
            for (int i = 0; i < n; i++) begin
                if (winners[i].found)
                    arr[i] = draw(winners[i].value,
                                  winners[i].from_each ?
                                  {full_root, ".each"} :
                                  $sformatf("%s[%0d]", full_root, i),
                                  names, bits);
                else
                    arr[i] = default_val;
            end
        end
        if (sort_str == "asc" || sort_str == "desc") begin
            for (int i = 1; i < n; i++) begin
                E value;
                int j;
                value = arr[i];
                j = i;
                while (j > 0 &&
                       ((sort_str == "asc" && value < arr[j-1]) ||
                        (sort_str == "desc" && value > arr[j-1]))) begin
                    arr[j] = arr[j-1];
                    j--;
                end
                arr[j] = value;
            end
        end
    endfunction
endclass
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
