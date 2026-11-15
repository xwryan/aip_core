//===========================================================
// 所属层次：src/sv/core/cmdline（内部 include 片段，不是独立 compilation unit）。
// 基础解析：整数/字符串、枚举、real、旧版 compact 辅助及注册日志限流。
// 依赖公共上下文与 aip_str/aip_log/uvm_pkg；日志限流在标量解析类之后定义。
// 目标变量由用户持有；解析过程不推进仿真时间，override 与 plusarg 的非空表达式共用求值路径。
// set_param 只保存原文，随机抽样发生在每次读取时；空 override 仍返回类型初值，不回退宏默认值。
// 只允许 aip_cmdline.sv 在其 include 窗口加载；拒绝直接包含，避免创建第二份 $unit/package 类型。
// 聚合入口持有唯一的 AIP_CMDLINE_SV 防重入 guard，本文件不声明新的 package。
// 所有 CLI 查询均经过共享参数源；恢复后重取当前进程参数，保持既有解析/优先级规则。
//===========================================================
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else

//-------------------------------------------------------------------------
class aip_cmdline #(type T = int);

    static bit global_required = 0; // 全局必填开关，默认非必填
    static string last_array_ctrl = ""; // 最近一次 resolve_array 的控制键摘要 (each=/unique/sort=), 供注册日志打印

    // 随机模式枚举
    typedef enum { RANGE, WEIGHT_EACH, WEIGHT_TOTAL, INCREMENT, DECREMENT, LIST, SINGLE, RAND } rand_mode_t;

    typedef enum { NOT_WRAPPER, VALID_WRAPPER, MALFORMED_WRAPPER } outer_list_wrapper_state_t;

    // 随机描述结构体. 所有数值用 aip_svec_t (有符号 1026 bit) 保存,
    // 最后一步才 T'() 转换 — 这样同一份代码在 T=string 特化下也能编译.
    typedef struct {
        rand_mode_t mode;
        aip_svec_t  min, max, step, start, weight;
        bit         full;        // 权重组里的 "rand" (Task 4)
        aip_svec_t  list_vals[];
    } rand_desc_t;

    // 索引赋值结构
    typedef struct {
        int index;
        string value_str;
    } index_assign_t;


    // ---------- 私有辅助函数 ----------
    // 解析 override: 先全名 path.name, 再退 leaf name（对齐 plusargs 两级回退）— Bug E
    // 返回 1=命中（空串也算命中，靠 has() 判定）; 命中时 val 为 override 值 — Bug A
    static function bit lookup_override(string name, string path, output string val);
        string full = (path != "") ? {path, ".", name} : name;
        if (aip_cmdline_override::has(full)) begin
            val = aip_cmdline_override::get_val(full);
            return 1;
        end
        if (path != "" && aip_cmdline_override::has(name)) begin  // leaf 回退 — Bug E
            val = aip_cmdline_override::get_val(name);
            return 1;
        end
        val = "";
        return 0;
    endfunction

    // 按 override/完整 plusarg/leaf plusarg 顺序查询，不消费 RNG；缺失必填项建立
    // 独立错误上下文，确保数组控制键查询失败也能显示实际缺失键，不沿用上一字段。
    static function string get_cmdline_string(string name, string path = "");
        uvm_cmdline_processor clp = aip_cmdline_source::get();
        string vals[$];
        string full_name;
        string override_val;

        // 1. 先查 override 表（优先级最高，TCL set_param 设置）
        //    用 has() 判命中(空串也返回), full->leaf 回退 — Bug A + Bug E
        if (lookup_override(name, path, override_val))
            return override_val;

        // 2. 再查 plusargs（原有逻辑）
        if (path != "") begin
            full_name = $sformatf("+%s.%s=", path, name);
            clp.get_arg_values(full_name, vals);
        end
        if (vals.size() == 0) begin
            full_name = $sformatf("+%s=", name);
            clp.get_arg_values(full_name, vals);
        end

        if (vals.size() == 0 && global_required) begin
            aip_cmdline_diagnostic::push_value(aip_cmdline_diagnostic::full_name(name, path), "<missing>");
            error($sformatf("Required parameter +%s (path: %s) not provided", name, path));
        end

        return (vals.size() > 0) ? vals[vals.size()-1] : "";
    endfunction

    // 所有整数/字符串公共解析失败均打印来源并 hard fatal；VCS 需 -exitstatus 将失败传给 shell。
    protected static function void error(string msg);
        aip_cmdline_diagnostic::report("AIP_CORE[cmdline] parser Error", msg, `__FILE__, `__LINE__);
    endfunction

    // 判断 T 是否为整数族类型。VCS 的 $typename 会把 packed typedef 展开
    // 成其底层类型，因此也要识别 logic/reg/integer，而不只识别 bit。
    protected static function bit is_integer_type();
        string tn = $typename(T);
        return (tn == "int" || tn == "byte" || tn == "shortint" || tn == "longint" ||
                tn == "longint unsigned" || tn == "int unsigned" ||
                tn == "shortint unsigned" || tn == "byte unsigned" ||
                tn == "integer" || tn == "integer unsigned" ||
                aip_str::str_find(tn, "bit") != -1 ||
                aip_str::str_find(tn, "logic") != -1 ||
                aip_str::str_find(tn, "reg") != -1);
    endfunction

    // T 的位宽. 用变量而不是类型名取 $bits, 让 T=string 特化也能编译 (返回 0).
    protected static function int t_bits();
        T tmp;
        return $bits(tmp);
    endfunction

    // nbits 位均匀随机, 非负
    protected static function aip_svec_t urand_svec(int nbits);
        aip_vec_t v = '0;
        for (int i = 0; i < nbits; i += 32) v = (v << 32) | $urandom();
        if (nbits < AIP_VEC_MAX_BITS) v = v & ((aip_vec_t'(1) << nbits) - 1);
        return aip_svec_t'({2'b00, v});
    endfunction

    // [lo, hi] 闭区间均匀随机 (任意宽度; 偏差 2^-N 忽略)
    protected static function aip_svec_t rand_in_range(aip_svec_t lo, aip_svec_t hi);
        aip_svec_t span = hi - lo + 1;
        return lo + (urand_svec(AIP_VEC_MAX_BITS) % span);
    endfunction

    // 解析单个整数字面量为有符号宽值, 并按 T 的位宽做 fail-closed 检查
    protected static function aip_svec_t parse_single_num(string s);
        aip_vec_t  v;
        aip_svec_t r;
        int width;
        bit neg;
        int nbits = t_bits();
        if (!aip_str::str_to_vec(s, v, width, neg))
            error($sformatf("Invalid integer format: %s", s));
        if (nbits > 0 && nbits < AIP_VEC_MAX_BITS && (v >> nbits) != 0)
            error($sformatf("value %s exceeds %0d-bit %s", s, nbits, $typename(T)));
        if (nbits > 0 && width > nbits)
            error($sformatf("explicit width in %s exceeds %0d-bit %s", s, nbits, $typename(T)));
        r = aip_svec_t'({2'b00, v});
        return neg ? -r : r;
    endfunction

    // 解析单值（根据类型）
    protected static function T parse_single_value(string s);
        if (is_integer_type()) begin
            return T'(parse_single_num(s));
        end else if ($typename(T) == "string") begin
            return aip_str::strip(s);
        end else begin
            error($sformatf("Unsupported type: %s", $typename(T)));
            return T'(0);
        end
    endfunction

    // 固定 override 的轻量分流：只排除表达式标记，不代替正式字面量校验。
    // 数字仅放行无空白的字面量候选字符；含空白时由公共路径规范化，
    // 避免直接整数转换不去空白而造成两种来源语义不同。
    // rand、范围、权重、列表、步长等仍交给原解析器，错误也由它带来源报告。
    // 字符串只需排除智能分割涉及的逗号/括号，冒号和方括号本来就是普通文本。
    // 无分配、无 RNG、无缓存；real 入口复用该方法以避免维护第二套判别规则。
    static function bit is_literal_candidate(string	s, bit	string_value = 0);
        for (int	i = 0; i < s.len(); i++) begin
            if (string_value) begin
                if (s[i] inside {",", "{", "}", "(", ")"}) return 0;
            end else if (!(s[i] inside {
                ["0":"9"],
                "a", "b", "c", "d", "e", "f", "A", "B", "C", "D", "E", "F",
                "h", "H", "o", "O", "s", "S", "x", "X", "z", "Z",
                "'", "_", "+", "-", "."
            })) return 0;
        end
        return s.len() != 0;
    endfunction

    // 解析范围 [min:max]
    protected static function void parse_range(string s, output aip_svec_t min, output aip_svec_t max);
        int pos;
        string min_str,max_str;
        string inner = aip_str::remove_all_spaces(s);

        if (inner.len() >= 3 && inner[0] == "[" && inner[inner.len()-1] == "]") begin
            inner = inner.substr(1, inner.len() - 2);
            inner = aip_str::strip(inner);
        end

        pos = aip_str::str_find(inner, ":");
        if (pos == -1) error($sformatf("Missing ':' in range: %s", s));
        if (pos == 0) error($sformatf("Invalid range format (no min value): %s", s));
        if (pos == inner.len()-1) error($sformatf("Invalid range format (no max value): %s", s));

        min_str = aip_str::strip(inner.substr(0, pos-1));
        max_str = aip_str::strip(inner.substr(pos+1, inner.len()-1));

        if (min_str == "" || max_str == "") error($sformatf("Empty value in range: %s", s));
        min = parse_single_num(min_str);
        max = parse_single_num(max_str);
        if (min > max) error($sformatf("Range min > max: %s", s));
    endfunction

    // 解析整数列表（逗号分隔）
    protected static function void parse_int_list(string s, output aip_svec_t list[]);
        string parts[] = aip_str::split(aip_str::remove_all_spaces(s), ",");
        list = new[parts.size()];
        foreach (parts[i]) begin
            string p = aip_str::strip(parts[i]);
            if (p == "") error($sformatf("Empty element in list: %s", s));
            list[i] = parse_single_num(p);
        end
    endfunction

    // ---------- 权重解析相关 ----------
    // 将单个 := / :/ 权重项转成描述符；item_index 是原组中的零基序号，
    // 用于定位非法权重。零权重只禁用抽样，不跳过左侧语法/位宽检查；
    // 负权重立即报错，rand 仅允许 :/，避免无限候选集的逐值权重语义。
    protected static function rand_desc_t parse_weight_item(string s, int item_index = 0);
        rand_desc_t desc;
        int pos_eq,pos_sl,weight_pos,weight_len;
        string left,right;
        pos_eq = aip_str::str_find(s, ":=");
        pos_sl = aip_str::str_find(s, ":/");
        if ((pos_eq >= 0) == (pos_sl >= 0))
            error($sformatf("Invalid weight item[%0d] '%s' (expected one := or :/)", item_index, s));

        weight_pos = (pos_eq != -1) ? pos_eq : pos_sl;
        weight_len = 2;

        if (weight_pos == 0) error($sformatf("Missing left value before weight in: %s", s));
        if (weight_pos + weight_len >= s.len())
            error($sformatf("Missing right value after weight in: %s", s));

        left = aip_str::strip(s.substr(0, weight_pos-1));
        right = aip_str::strip(s.substr(weight_pos+weight_len, s.len()-1));

        if (left == "") error($sformatf("Empty left value after stripping in part: %s", s));
        if (right == "") error($sformatf("Empty weight value after stripping in part: %s", s));

        desc.mode = (pos_eq != -1) ? WEIGHT_EACH : WEIGHT_TOTAL;
        desc.weight = parse_single_num(right);
        if (desc.weight < 0)
            error($sformatf("Weight must be >= 0 in item[%0d] '%s'", item_index, s));

        // 解析左侧（可能是范围、单个值，或 rand）
        desc.full = 0;
        if (left == "rand") begin
            if (desc.mode == WEIGHT_EACH) error("rand:=w not allowed; use rand:/w");
            desc.full = 1;
            desc.min = 0;
            desc.max = 0;
        end else if (left.len() >= 3 && left[0] == "[" && left[left.len()-1] == "]") begin
            parse_range(left, desc.min, desc.max);
        end else begin
            desc.min = parse_single_num(left);
            desc.max = desc.min;
        end
        return desc;
    endfunction

    // 解析逗号分隔的完整权重组，输出描述数组；保留原项序号用于诊断。
    // 所有项（包括权重为零的项）都必须完成解析，空项属于语法错误。
    protected static function void parse_weight_items(string s, output rand_desc_t desc_list[]);
        string parts[] = aip_str::split(aip_str::remove_all_spaces(s), ",");
        desc_list = new[parts.size()];
        foreach (parts[i]) begin
            string part = aip_str::strip(parts[i]);
            if (part == "") error($sformatf("Empty weight item[%0d] in group: %s", i, s));
            desc_list[i] = parse_weight_item(part, i);
        end
    endfunction

    // 解析带括号的权重组（如 "{0:=40, [1:3]:=60}" 或 "([1:5]:/10)"）
    protected static function void parse_weight_group(string s, output rand_desc_t desc_list[]);
        // 去除外层括号
        if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
            string inner = s.substr(1, s.len()-2);
            parse_weight_items(inner, desc_list);
        end else begin
            error($sformatf("Invalid weight group format: %s", s));
        end
    endfunction

    // 按描述数组抽取一个 T 值：:= 为每个离散值分配权重，:/ 为整项分配权重。
    // 零权重项不参与累计或抽样，先检查全零和有符号累计溢出，再消费 RNG；
    // 正权重组沿用原抽样调用顺序，以保持原有 seed 的可复现性。
    protected static function T get_weighted_group_value(rand_desc_t desc_list[]);
        aip_svec_t r, accum, total_weight;
        aip_svec_t block_weight, candidate_count;
        aip_svec_t max_weight = aip_svec_t'({1'b0, {(AIP_VEC_MAX_BITS+1){1'b1}}});
        total_weight = 0;
        foreach (desc_list[i]) begin
            if (desc_list[i].weight < 0)
                error($sformatf("Weight must be >= 0 in item[%0d]", i));
            if (desc_list[i].weight == 0) continue;
            block_weight = desc_list[i].weight;
            if (desc_list[i].mode == WEIGHT_EACH) begin
                candidate_count = desc_list[i].max - desc_list[i].min + 1;
                if (candidate_count <= 0 || candidate_count > max_weight / block_weight)
                    error($sformatf("Weighted item[%0d] exceeds supported cumulative weight width", i));
                block_weight *= candidate_count;
            end
            if (total_weight > max_weight - block_weight)
                error($sformatf("Weighted group total overflows at item[%0d]", i));
            total_weight += block_weight;
        end
        if (total_weight == 0)
            error("Weighted group total must be > 0; all weights are zero");

        r = urand_svec(AIP_VEC_MAX_BITS) % total_weight;
        accum = 0;
        foreach (desc_list[i]) begin
            // 显式跳过禁用项，防止 := 分支执行零除法。
            if (desc_list[i].weight == 0) continue;
            if (desc_list[i].mode == WEIGHT_EACH) begin
                aip_svec_t block_weight = (desc_list[i].max - desc_list[i].min + 1) * desc_list[i].weight;
                if (r < accum + block_weight) begin
                    aip_svec_t idx = (r - accum) / desc_list[i].weight;
                    return T'(desc_list[i].min + idx);
                end
                accum += block_weight;
            end else begin
                if (r < accum + desc_list[i].weight) begin
                    return desc_list[i].full ? T'(urand_svec(t_bits()))
                                             : T'(rand_in_range(desc_list[i].min, desc_list[i].max));
                end
                accum += desc_list[i].weight;
            end
        end
        error("Weighted group selection failed");
        return T'(0);
    endfunction

    // 解析 inc/dec 的起点、终点和可选正步长；多余字段同样属于语法错误。
    protected static function void parse_inc_dec(string s, bit is_inc, output rand_desc_t desc);
        string cleaned = aip_str::remove_all_spaces(s);
        string remain = cleaned.substr(4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        if (tokens.size() < 2 || tokens.size() > 3) error($sformatf("Invalid inc/dec format: %s", s));

        desc.mode = is_inc ? INCREMENT : DECREMENT;
        desc.start = parse_single_num(tokens[0]);
        desc.max = parse_single_num(tokens[1]);
        desc.step = (tokens.size() >= 3) ? parse_single_num(tokens[2]) : 1;
        if (desc.step <= 0) error($sformatf("inc/dec step must be > 0: %s", s));

        if (is_inc && desc.start > desc.max) error("Increment start > end");
        if (!is_inc && desc.start < desc.max) error("Decrement start < end");
    endfunction

    protected static function bit is_generator(string s);
        string c = aip_str::remove_all_spaces(s);
        return (c.len() >= 4 && c.substr(0, 3) == "seq:") ||
               (c.len() >= 5 && c.substr(0, 4) == "perm:");
    endfunction

    // 数组生成式: seq:a:b[:s] 展开完整序列; perm:a:b 为 a..b 的随机排列
    protected static function void expand_generator(string s, ref T vals[]);
        string cleaned = aip_str::remove_all_spaces(s);
        bit is_perm = (cleaned.len() >= 5 && cleaned.substr(0, 4) == "perm:");
        string remain = cleaned.substr(is_perm ? 5 : 4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        aip_svec_t a, b, step, cnt;
        if (!is_integer_type()) error($sformatf("seq:/perm: only for integer arrays: %s", s));
        if (tokens.size() < 2 || tokens.size() > 3 || (is_perm && tokens.size() != 2))
            error($sformatf("Invalid seq:/perm: format: %s", s));
        a = parse_single_num(tokens[0]);
        b = parse_single_num(tokens[1]);
        step = (tokens.size() == 3) ? parse_single_num(tokens[2]) : 1;
        if (step <= 0) error($sformatf("seq: step must be > 0: %s", s));
        if (a > b) error($sformatf("seq:/perm: start > end: %s", s));
        cnt = (b - a) / step + 1;
        if (cnt > 1000000) error($sformatf("seq:/perm: expands to more than 1000000 elements: %s", s));
        vals = new[int'(cnt)];
        foreach (vals[i]) vals[i] = T'(a + i * step);
        if (is_perm) begin
            for (int i = vals.size()-1; i > 0; i--) begin
                int j = $urandom_range(i);
                T tmp = vals[i];
                vals[i] = vals[j];
                vals[j] = tmp;
            end
        end
    endfunction

    // .each 的候选个数; 不可枚举 (rand / 权重组 / 空) 返回 -1
    protected static function aip_svec_t each_candidate_count(string s);
        rand_desc_t d;
        string c = aip_str::remove_all_spaces(s);
        if (!is_integer_type()) return -1;  // string .each 列表由第 8 步重抽循环处理
        if (c == "" || c == "rand") return -1;
        if (c[0] == "{" || c[0] == "(" ||
            aip_str::str_find(c, ":=") != -1 || aip_str::str_find(c, ":/") != -1) return -1;
        d = parse_rand_desc(c);
        case (d.mode)
            SINGLE:    return 1;
            RANGE:     return d.max - d.min + 1;
            LIST:      return d.list_vals.size();
            INCREMENT: return (d.max - d.start) / d.step + 1;
            DECREMENT: return (d.start - d.max) / d.step + 1;
            default:   return -1;
        endcase
    endfunction

    // 解析随机描述（非权重组）
    protected static function rand_desc_t parse_rand_desc(string s);
        rand_desc_t desc;
        s = strip_outer_list_wrapper(s);

        if (is_generator(s)) error($sformatf("seq:/perm: are array-only: %s", s));
        if (s == "rand") begin
            desc.mode = RAND;
        end
        else if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
            error("Weight mode not supported for single value (use {} or () group)");
        end
        else if (s.len() >= 3 && s[0] == "[" && s[s.len()-1] == "]") begin
            int colon_pos = aip_str::str_find(s, ":");
            if (colon_pos == -1 || colon_pos == 1 || colon_pos == s.len()-2)
                error($sformatf("Invalid range format: %s", s));
            parse_range(s, desc.min, desc.max);
            desc.mode = RANGE;
        end
        else if (aip_str::str_find(s, "inc:") != -1) begin
            parse_inc_dec(s, 1, desc);
        end
        else if (aip_str::str_find(s, "dec:") != -1) begin
            parse_inc_dec(s, 0, desc);
        end
        else if (aip_str::str_find(s, ",") != -1) begin
            parse_int_list(s, desc.list_vals);
            desc.mode = LIST;
        end
        else if (aip_str::str_find(s, ":") != -1) begin
            int colon_pos = aip_str::str_find(s, ":");
            if (colon_pos == 0 || colon_pos == s.len()-1)
                error($sformatf("Invalid range format (colon at edge): %s", s));
            parse_range(s, desc.min, desc.max);
            desc.mode = RANGE;
        end
        else begin
            desc.mode = SINGLE;
            desc.min = parse_single_value(s);
            desc.max = desc.min;
        end
        return desc;
    endfunction

    protected static function T get_rand_value(rand_desc_t desc);
        aip_svec_t val;
        if (!is_integer_type()) begin
            error("Random mode only supported for int type");
        end

        case (desc.mode)
            SINGLE:    val = desc.min;
            RANGE:     val = rand_in_range(desc.min, desc.max);
            LIST:      val = desc.list_vals[$urandom_range(desc.list_vals.size()-1)];
            INCREMENT: begin
                aip_svec_t cnt = ((desc.max - desc.start) / desc.step) + 1;
                val = desc.start + (urand_svec(AIP_VEC_MAX_BITS) % cnt) * desc.step;
            end
            DECREMENT: begin
                aip_svec_t cnt = ((desc.start - desc.max) / desc.step) + 1;
                val = desc.start - (urand_svec(AIP_VEC_MAX_BITS) % cnt) * desc.step;
            end
            RAND:      val = urand_svec(t_bits());
            default: error($sformatf("Unsupported rand mode: %s", desc.mode.name()));
        endcase
        return T'(val);
    endfunction

    // Classify a complete outer [] containing a comma at the outer list level.
    // [1:3] is therefore not a wrapper, while [1,[2:3],4] is a valid wrapper.
    protected static function outer_list_wrapper_state_t classify_outer_list_wrapper(string s);
        string cleaned = aip_str::remove_all_spaces(s);
        int bracket_depth = 0;
        int brace_depth = 0;
        int paren_depth = 0;
        byte delimiter_stack[$];
        bit has_top_level_comma = 0;
        bit has_element_content = 0;
        bit outer_closed_before_end = 0;

        for (int i = 0; i < cleaned.len(); i++) begin
            byte ch = cleaned[i];
            if (ch == "[") begin
                if (bracket_depth >= 1) has_element_content = 1;
                delimiter_stack.push_back(ch);
                bracket_depth++;
            end else if (ch == "]") begin
                if (delimiter_stack.size() == 0 || delimiter_stack[$] != "[")
                    return MALFORMED_WRAPPER;
                void'(delimiter_stack.pop_back());
                bracket_depth--;
                if (bracket_depth < 0) return MALFORMED_WRAPPER;
                if (cleaned[0] == "[" && bracket_depth == 0 &&
                    i != cleaned.len()-1)
                    outer_closed_before_end = 1;
            end else if (ch == "{") begin
                delimiter_stack.push_back(ch);
                brace_depth++;
                if (bracket_depth >= 1) has_element_content = 1;
            end else if (ch == "}") begin
                if (delimiter_stack.size() == 0 || delimiter_stack[$] != "{")
                    return MALFORMED_WRAPPER;
                void'(delimiter_stack.pop_back());
                brace_depth--;
                if (brace_depth < 0) return MALFORMED_WRAPPER;
            end else if (ch == "(") begin
                delimiter_stack.push_back(ch);
                paren_depth++;
                if (bracket_depth >= 1) has_element_content = 1;
            end else if (ch == ")") begin
                if (delimiter_stack.size() == 0 || delimiter_stack[$] != "(")
                    return MALFORMED_WRAPPER;
                void'(delimiter_stack.pop_back());
                paren_depth--;
                if (paren_depth < 0) return MALFORMED_WRAPPER;
            end else if (ch == "," && bracket_depth == 1 &&
                         brace_depth == 0 && paren_depth == 0) begin
                if (!has_element_content) return MALFORMED_WRAPPER;
                has_top_level_comma = 1;
                has_element_content = 0;
            end else if (bracket_depth >= 1) begin
                has_element_content = 1;
            end
        end
        if (bracket_depth != 0 || brace_depth != 0 || paren_depth != 0 ||
            delimiter_stack.size() != 0)
            return MALFORMED_WRAPPER;
        if (cleaned.len() < 2 || cleaned[0] != "[" ||
            cleaned[cleaned.len()-1] != "]")
            return NOT_WRAPPER;
        if (outer_closed_before_end)
            return NOT_WRAPPER;
        if (!has_top_level_comma)
            return NOT_WRAPPER;
        if (!has_element_content)
            return MALFORMED_WRAPPER;
        return VALID_WRAPPER;
    endfunction

    protected static function bit has_outer_list_wrapper(string s);
        return classify_outer_list_wrapper(s) == VALID_WRAPPER;
    endfunction

    protected static function string strip_outer_list_wrapper(string s);
        string cleaned = aip_str::remove_all_spaces(s);
        case (classify_outer_list_wrapper(cleaned))
            VALID_WRAPPER:
                return cleaned.substr(1, cleaned.len()-2);
            MALFORMED_WRAPPER:
                error($sformatf("Invalid outer list wrapper: %s", cleaned));
            default:
                return cleaned;
        endcase
        return cleaned;
    endfunction

    // ---------- 智能分割数组元素（识别括号嵌套）----------
    static function void split_array_elements(string s, ref string elems[]);
        int len = s.len();
        int brace_depth = 0;
        int paren_depth = 0;
        string current = "";
        elems = new[0];  // 初始化为空
        for (int i = 0; i < len; i++) begin
            byte ch = s[i];
            if (ch == "{") brace_depth++;
            else if (ch == "}") brace_depth--;
            else if (ch == "(") paren_depth++;
            else if (ch == ")") paren_depth--;
            else if (ch == "," && brace_depth == 0 && paren_depth == 0) begin
                // 顶层逗号，结束当前元素
                elems = new[elems.size()+1](elems);
                elems[elems.size()-1] = current;
                current = "";
                continue;
            end
            current = {current, ch};
        end
        // 添加最后一个元素
        if (current != "") begin
            elems = new[elems.size()+1](elems);
            elems[elems.size()-1] = current;
        end
        // 检查括号是否匹配
        if (brace_depth != 0 || paren_depth != 0)
            error($sformatf("Mismatched braces/parentheses in array string: %s", s));
    endfunction

    // ---------- 根据类型安全分割整体赋值字符串（使用智能分割）----------
    protected static function void split_overall_string(string s, ref string parts[]);
        if (is_integer_type()) begin
            string cleaned = strip_outer_list_wrapper(s);
            split_array_elements(cleaned, parts);
            foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
        end else begin  // string type
            split_array_elements(s, parts);
            foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
        end
    endfunction

    // 公共表达式入口：上下文随此次 function 进入/退出，直接调用也能打印原始表达式。
    static function T parse_value(string s);
        T result;
        aip_cmdline_diagnostic::push_expression(s);
        result = parse_value_impl(s);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 单个值的实际解析；调用者负责诊断栈，保留原抽样顺序和各分支提前返回。
    protected static function T parse_value_impl(string s);
        if (is_integer_type()) begin
            // 检查是否为权重组（以 { 或 ( 开头，且匹配结束）
            if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
                rand_desc_t group[];
                parse_weight_group(s, group);
                return get_weighted_group_value(group);
            end else if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
                // 单个权重项（无括号）视为组
                rand_desc_t items[];
                parse_weight_items(s, items);
                if (items.size() != 1)
                    error($sformatf("Multiple weight items without grouping braces: %s", s));
                return get_weighted_group_value(items);
            end else begin
                rand_desc_t desc = parse_rand_desc(s);
                return get_rand_value(desc);
            end
        end else if ($typename(T) == "string") begin
            string trimmed = aip_str::strip(s);
            if (aip_str::str_find(trimmed, ",") != -1) begin
                string parts[] = aip_str::split(trimmed, ",");
                foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
                return parts[$urandom_range(parts.size()-1)];
            end else begin
                return trimmed;
            end
        end else begin
            error($sformatf("Unsupported type: %s", $typename(T)));
            return T'(0);
        end
    endfunction

    // ---------- 获取所有命令行参数 ----------
    protected static function void get_all_cmdline_args(ref string args[$]);
        uvm_cmdline_processor clp = aip_cmdline_source::get();
        clp.get_args(args);
    endfunction

    // ---------- 收集指定数组的所有索引赋值 ----------
    protected static function void collect_indexed_assignments(
        string name, string path,
        ref int index_vals[int],
        ref string value_strs[int]
    );
        string args[$];
        string prefix;

        if (path != "") prefix = {path , "." , name};
        else prefix = name;

        get_all_cmdline_args(args);
        foreach (args[i]) begin
            int pos,end_bracket,idx,width;
            string idx_str,val_str;

            string arg = args[i];
            if (arg.len() == 0 || arg[0] != "+") continue;
            arg = arg.substr(1, arg.len()-1);
            if (arg.len() < prefix.len()) continue;
            if (arg.substr(0, prefix.len()-1) != prefix) continue;
            // 必须是 [index]= 格式
            pos = prefix.len();
            if (pos >= arg.len() || arg[pos] != "[") continue;
            end_bracket = aip_str::str_find(arg, "]", pos+1);
            if (end_bracket == -1) continue;
            idx_str = aip_str::remove_all_spaces(arg.substr(pos+1, end_bracket-1));
            idx = aip_str::str_to_num(idx_str, width);
            if (idx == -1 && width == 0) continue;  // 非法索引
            if (end_bracket+1 >= arg.len() || arg[end_bracket+1] != "=") continue;
            val_str = arg.substr(end_bracket+2, arg.len()-1);
            // 后定义覆盖
            index_vals[idx] = idx;
            value_strs[idx] = val_str;
        end
    endfunction

    // ---------- 扫描 override 表的索引赋值 prefix[idx]（Bug B）----------
    // override key 形如 "path.name[3]" 或 "name[3]"（无 "=" 后缀）
    protected static function void collect_indexed_overrides(
        string name, string path,
        ref int index_vals[int],
        ref string value_strs[int]
    );
        string keys[$];
        string prefix;

        if (path != "") prefix = {path , "." , name};
        else prefix = name;

        aip_cmdline_override::get_keys(keys);
        foreach (keys[i]) begin
            int pos,end_bracket,idx,width;
            string idx_str;
            string k = keys[i];

            if (k.len() < prefix.len()) continue;
            if (k.substr(0, prefix.len()-1) != prefix) continue;
            pos = prefix.len();
            if (pos >= k.len() || k[pos] != "[") continue;
            end_bracket = aip_str::str_find(k, "]", pos+1);
            if (end_bracket == -1) continue;
            idx_str = aip_str::remove_all_spaces(k.substr(pos+1, end_bracket-1));
            idx = aip_str::str_to_num(idx_str, width);
            if (idx == -1 && width == 0) continue;  // 非法索引
            if (end_bracket+1 != k.len()) continue; // prefix[idx] 后必须正好结束
            index_vals[idx] = idx;
            value_strs[idx] = aip_cmdline_override::get_val(k);
        end
    endfunction

    // 公共单值入口：附加可选的调用位置，兼容原四参数 API；包装层保证所有正常返回都恢复上下文。
    static function void get_single_value(string name, string path, T default_val, ref T val,
                                           input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_single_value_impl(name, path, default_val, val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 按原优先级选择参数来源，再统一执行范围/列表/权重/步长候选解析。
    // 非空随机 override 与 plusarg 使用相同抽样路径，字符串列表也每次重新选择；
    // 固定 override 保留原字面量快路径和不消费 RNG 的行为，不创建候选数组。
    // 空 override 保留类型默认初始化语义，缺失/空 plusarg 仍使用调用方默认值。
    // 表达式错误由现有解析器带参数来源终止；本函数不缓存结果或改变 override 原文。
    protected static function void get_single_value_impl(string name, string path, T default_val, ref T val);
        string	parts[];
        string	s;
        bit	is_ov;

        is_ov = lookup_override(name, path, s);   // 命中则 s=override 值(可能空串)
        if (!is_ov)
            s = get_cmdline_string(name, path);   // 未命中 override -> plusargs

        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), s);

        if (is_ov && s == "") begin
            T	zero; // 保持原类型默认初始化语义，包括 string 空串与四态类型。
            val = zero;
            return;
        end
        if (s == "") begin
            val = default_val;
            return;
        end
        if (is_ov && is_literal_candidate(s, $typename(T) == "string")) begin
            val = parse_single_value(s);
            return;
        end
        split_overall_string(s, parts);
        if(parts.size == 0) begin
            val = default_val;
            return;
        end
        else begin
            int	idx;
            idx = $urandom_range(0,parts.size-1);
            val = parse_value(parts[idx]);
        end

    endfunction

    // 动/静态数组公共入口：建立跨元素类型共享的诊断来源；附加参数不影响原 API。
    static function void resolve_array(
        string name, string path, T default_val, int fixed_size, ref T arr[],
        input string source_file = "", input int source_line = 0
    );
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        resolve_array_impl(name, path, default_val, fixed_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 动/静态数组内部解析；调用者保证入口上下文存在，当前键在每个表达式求值前切换。
    // fixed_size = -1: 动态数组 (size 由 .size / 整体列表 / 索引决定)
    // fixed_size >= 0: 静态数组, 长度固定, .size 与超长列表报错
    protected static function void resolve_array_impl(
        string name, string path,
        T default_val,
        int fixed_size,
        ref T arr[]
    );
        string size_str;
        string each_str;
        string unique_str;
        bit do_unique;
        string sort_str;
        bit fixed[];
        int size;
        string overall_str;
        T overall_vals[];
        int index_vals[int];
        string index_strs[int];
        int no_path_vals[int];
        string no_path_strs[int];
        int max_idx = -1;

        // 1. .size
        size_str = get_cmdline_string({name , ".size"}, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".size"}, path), size_str);
        if (fixed_size >= 0) begin
            if (size_str != "")
                error($sformatf("%s.size not allowed for static array (declared size %0d)", name, fixed_size));
            size = fixed_size;
        end else if (size_str != "") begin
            size = aip_cmdline#(int)::parse_value(size_str);
            if (size < 0) error($sformatf("%s.size must be >= 0, got %0d", name, size));
        end else begin
            size = -1;
        end
        each_str = get_cmdline_string({name , ".each"}, path);
        unique_str = get_cmdline_string({name , ".unique"}, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".unique"}, path), unique_str);
        if (unique_str != "" && unique_str != "0" && unique_str != "1")
            error($sformatf("%s.unique must be 0 or 1", name));
        do_unique = (unique_str == "1");
        sort_str = get_cmdline_string({name , ".sort"}, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".sort"}, path), sort_str);
        if (sort_str != "" && sort_str != "asc" && sort_str != "desc")
            error($sformatf("%s.sort must be asc or desc", name));
        last_array_ctrl = "";
        if (each_str != "")  last_array_ctrl = {last_array_ctrl, "each=", each_str, " "};
        if (do_unique)       last_array_ctrl = {last_array_ctrl, "unique "};
        if (sort_str != "")  last_array_ctrl = {last_array_ctrl, "sort=", sort_str, " "};

        // 2. 整体赋值
        overall_str = get_cmdline_string(name, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), overall_str);
        if (overall_str != "" && is_integer_type() && is_generator(overall_str)) begin
            string kind = (aip_str::remove_all_spaces(overall_str).substr(0, 3) == "seq:") ? "seq:" : "perm:";
            expand_generator(overall_str, overall_vals);
            if (fixed_size >= 0 && overall_vals.size() != fixed_size)
                error($sformatf("%s %s expands to %0d elements, static array holds %0d",
                                name, kind, overall_vals.size(), fixed_size));
        end else if (overall_str != "") begin
            string parts[];
            split_overall_string(overall_str, parts);
            overall_vals = new[parts.size()];
            foreach (parts[i]) begin
                aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", aip_cmdline_diagnostic::full_name(name, path), i), overall_str);
                if (parts[i] == "") error("Empty element in overall array assignment");
                overall_vals[i] = parse_value(parts[i]);
            end
        end
        if (fixed_size >= 0 && overall_vals.size() > fixed_size)
            error($sformatf("%s overall list has %0d elements, static array holds %0d",
                            name, overall_vals.size(), fixed_size));
        if (fixed_size < 0 && size >= 0 && overall_vals.size() > size)
            error($sformatf("%s overall list has %0d elements, .size is %0d",
                            name, overall_vals.size(), size));

        // 3. 索引赋值 (原 get_dynamic_array 第 3 步, 原样保留)
        begin
            int    ov_p_v[int]; string ov_p_s[int];
            int    ov_l_v[int]; string ov_l_s[int];
            int    pa_p_v[int]; string pa_p_s[int];

            collect_indexed_overrides(name, path, ov_p_v, ov_p_s);
            collect_indexed_overrides(name, "",   ov_l_v, ov_l_s);
            if (path != "")
                collect_indexed_assignments(name, path, pa_p_v, pa_p_s);
            collect_indexed_assignments(name, "", no_path_vals, no_path_strs);

            foreach (ov_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_p_s[i];       end
            foreach (ov_l_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_l_s[i];       end
            foreach (pa_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=pa_p_s[i];       end
            foreach (no_path_vals[i]) if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=no_path_strs[i]; end
        end
        foreach (index_vals[i]) begin
            if (i > max_idx) max_idx = i;
        end

        // 4. 动态数组长度
        if (size == -1) begin
            if (overall_vals.size() > 0) begin
                size = overall_vals.size();
            end else if (max_idx >= 0) begin
                size = max_idx + 1;
            end else if (each_str != "") begin
                aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".each"}, path), each_str);
                error($sformatf("%s.each given but size unknown", name));
            end else begin
                arr = new[0];
                return;
            end
        end

        // 5. 分配; 每元素独立按 .each 抽, 无 .each 填 default
        arr = new[size];
        fixed = new[size];
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".each"}, path), each_str);
        for (int i = 0; i < size; i++) begin
            arr[i] = (each_str != "") ? parse_value(each_str) : default_val;
            fixed[i] = (each_str == "");
        end

        // 6. 整体赋值
        for (int i = 0; i < overall_vals.size(); i++) begin
            arr[i] = overall_vals[i];
            fixed[i] = 1;
        end

        // 7. 索引覆盖 (越界索引忽略, 与旧行为一致)
        foreach (index_vals[i]) begin
            if (i < size) begin
                aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", aip_cmdline_diagnostic::full_name(name, path), i), index_strs[i]);
                arr[i] = parse_value(index_strs[i]);
                fixed[i] = 1;
            end
        end

        // 8. .unique: 固定值互不重复; .each 生成的元素与已有值冲突则重抽
        if (do_unique) begin
            int to_fill = 0;
            int draws = 0;
            aip_svec_t cand;
            // 固定值冲突属于 unique 控制，不应错误归因于不存在的 each 表达式。
            aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".unique"}, path), unique_str);
            for (int i = 0; i < size; i++) begin
                if (!fixed[i]) begin to_fill++; continue; end
                for (int j = 0; j < i; j++)
                    if (fixed[j] && arr[i] == arr[j])
                        error($sformatf("%s.unique: duplicate fixed value %p", name, arr[i]));
            end
            aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".each"}, path), each_str);
            cand = each_candidate_count(each_str);
            if (cand >= 0 && cand < to_fill)
                error($sformatf("%s.unique: only %0d candidates for %0d elements", name, cand, to_fill));
            for (int i = 0; i < size; i++) begin
                if (fixed[i]) continue;
                forever begin
                    bit clash = 0;
                    for (int j = 0; j < size; j++)
                        if (j != i && (fixed[j] || j < i) && arr[j] == arr[i]) clash = 1;
                    if (!clash) break;
                    draws++;
                    if (draws > 100 * size)
                        error($sformatf("%s.unique: could not find %0d distinct values", name, to_fill));
                    arr[i] = parse_value(each_str);
                end
            end
        end

        // 9. .sort: 对最终数组排序 (索引覆盖值一起排); 内建方法, seq: 上限 1000000 元素也不卡
        if (sort_str == "asc")       arr.sort();
        else if (sort_str == "desc") arr.rsort();
    endfunction

    // 动态数组转接到统一入口，传递可选用户位置；生命周期由 resolve_array 包装层管理。
    static function void get_dynamic_array(
        string name, string path,
        T default_val,
        ref T arr[],
        input string source_file = "", input int source_line = 0
    );
        resolve_array(name, path, default_val, -1, arr, source_file, source_line);
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_enum - 枚举命令行解析辅助类；统一校验全部候选后再抽样，
// 避免非法候选因本次随机未选中而隐藏。直接 API 调用也有独立表达式上下文。
//-------------------------------------------------------------------------
class aip_cmdline_enum;
    // 输入名称/位值映射及逗号候选，返回随机候选的无损位值；空项、未知名称或
    // 映射长度不一致均交给公共 fatal，正常返回前恢复上层宏或 schema 的来源。
    static function logic [1023:0] resolve_bits(string s, string names[$], logic [1023:0] values[$]);
        string cleaned, candidate;
        logic [1023:0] candidates[$], result;
        int start, stop;
        bit matched;

        aip_cmdline_diagnostic::push_expression(s);
        cleaned = aip_str::strip(s);
        if (cleaned == "")
            aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                "empty enum string", `__FILE__, `__LINE__);
        if (names.size() == 0 || names.size() != values.size())
            aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                "enum names/values mapping is empty or has mismatched lengths",
                `__FILE__, `__LINE__);

        start = 0;
        while (start <= cleaned.len()) begin
            stop = aip_str::str_find(cleaned, ",", start);
            if (stop < 0) stop = cleaned.len();
            candidate = (stop == start) ? "" :
                        aip_str::strip(cleaned.substr(start, stop-1));
            matched = 0;
            foreach (names[i]) begin
                if (aip_str::lower(names[i]) == aip_str::lower(candidate)) begin
                    candidates.push_back(values[i]);
                    matched = 1;
                    break;
                end
            end
            if (!matched)
                aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                    $sformatf("candidate[%0d] '%s' not found in enum",
                              candidates.size(), candidate), `__FILE__, `__LINE__);
            if (stop == cleaned.len()) break;
            start = stop + 1;
        end
        result = candidates[$urandom_range(candidates.size()-1)];
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // 兼容 int 枚举接口；位值统一交由 resolve_bits 解析，保留有符号 int 的低 32 位。
    // 直接名称和逗号随机列表均忽略大小写，非法候选由公共诊断立即终止仿真。
    static function int resolve(string s, string names[$], int values[$]);
        logic [1023:0] wide_values[$];
        foreach (values[i]) wide_values.push_back(values[i]);
        return int'(resolve_bits(s, names, wide_values));
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_real - real 类型命令行解析类（独立于参数化类，兼容 VCS）
//-------------------------------------------------------------------------
class aip_cmdline_real;

    // 将十进制原文与 binary64 最大有限值比较；VCS sscanf 对溢出返回 DBL_MAX，
    // 仅检查转换结果无法发现错误。保留既有 schema 算法，普通/权重/预检共同复用。
    // 此函数只判数值上界，语法完整性仍由调用方检查；允许零及下溢到零。
    static function bit decimal_overflow(string token);
        string s, mant, exp_text, digits, max_dec;
        int ep, dot, digits_before, lead, exp_sign, exp_value, sci, i, d;
        byte ch;
        s = aip_str::remove_all_spaces(aip_str::strip(token));
        if (s == "") return 0;
        if (s[0] == "+" || s[0] == "-") s = s.substr(1, s.len()-1);
        ep = aip_str::str_find(s, "e");
        if (ep < 0) ep = aip_str::str_find(s, "E");
        if (ep < 0) begin
            mant = s;
            exp_value = 0;
        end else begin
            if (ep <= 0 || ep >= s.len()-1) return 0;
            mant = s.substr(0, ep-1);
            exp_text = s.substr(ep+1, s.len()-1);
            exp_sign = 1;
            if (exp_text[0] == "+" || exp_text[0] == "-") begin
                if (exp_text[0] == "-") exp_sign = -1;
                if (exp_text.len() == 1) return 0;
                exp_text = exp_text.substr(1, exp_text.len()-1);
            end
            exp_value = 0;
            for (i = 0; i < exp_text.len(); i++) begin
                ch = exp_text[i];
                if (ch < "0" || ch > "9") return 0;
                d = ch - "0";
                if (exp_value > 1000000 ||
                    (exp_value == 1000000 && d != 0)) exp_value = 1000000;
                else exp_value = exp_value * 10 + d;
            end
            exp_value *= exp_sign;
        end
        dot = aip_str::str_find(mant, ".");
        digits_before = (dot >= 0) ? dot : mant.len();
        digits = "";
        for (i = 0; i < mant.len(); i++) begin
            ch = mant[i];
            if (ch == ".") continue;
            if (ch < "0" || ch > "9") return 0;
            digits = {digits, ch};
        end
        if (digits == "") return 0;
        lead = 0;
        while (lead < digits.len() && digits[lead] == "0") lead++;
        if (lead == digits.len()) return 0;
        sci = exp_value + digits_before - lead - 1;
        if (sci > 308) return 1;
        if (sci < 308) return 0;
        // The exponent calculation accounts for leading zeroes, but the
        // equal-exponent magnitude comparison must compare normalized digits.
        // Otherwise a token such as 0.18e309 compares its leading zero against
        // DBL_MAX's leading one and is incorrectly accepted.
        digits = digits.substr(lead, digits.len()-1);
        // Exact decimal expansion of IEEE-754 binary64's largest finite
        // value.  Comparing at the same decimal exponent catches values
        // that VCS saturates to DBL_MAX instead of returning Inf.
        max_dec = "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368";
        for (i = 0; i < max_dec.len() || i < digits.len(); i++) begin
            ch = (i < digits.len()) ? digits[i] : "0";
            if (i < max_dec.len()) d = max_dec[i] - "0";
            else d = 0;
            if ((ch - "0") > d) return 1;
            if ((ch - "0") < d) return 0;
        end
        return 0;
    endfunction

    // IEEE-754 指数字段全 1 表示 Inf/NaN；位模式检查不依赖工具的浮点比较行为。
    // 文本溢出可能已被工具饱和为有限 DBL_MAX，因此还需配合 decimal_overflow 使用。
    static function bit is_finite(real value);
        bit [63:0] encoding;
        encoding = $realtobits(value);
        return encoding[62:52] != 11'h7ff;
    endfunction

    // real 解析错误统一补用户位置与完整表达式，并以 hard fatal 终止。
    protected static function void error(string msg);
        aip_cmdline_diagnostic::report("AIP_CORE[cmdline_real] parser Error", msg, `__FILE__, `__LINE__);
    endfunction

    // 参数专用 real 转换：必须完整消费有限数字，非法输入不能沿用通用工具的零值回退。
    // 保留现有去空格语义；来源由公共入口持有，不改变 aip_str 的其他调用者。
    protected static function real parse_real_literal(string token);
        real value;
        string trailing;
        int matched;
        matched = $sscanf(aip_str::remove_all_spaces(token), "%g%s", value, trailing);
        if (matched != 1 || !is_finite(value) || decimal_overflow(token))
            error($sformatf("Invalid real literal '%s'", token));
        return value;
    endfunction

    // 解析 real 范围 [min:max] 或 min:max；两端必须为完整有限数字且 min <= max。
    protected static function void parse_real_range(string s, output real rmin, output real rmax);
        string inner = aip_str::remove_all_spaces(s);
        int pos;
        string min_str, max_str;

        if (inner.len() >= 3 && inner[0] == "[" && inner[inner.len()-1] == "]") begin
            inner = inner.substr(1, inner.len() - 2);
        end

        pos = aip_str::str_find(inner, ":");
        if (pos == -1) error($sformatf("Missing ':' in real range: %s", s));
        if (pos == 0) error($sformatf("Invalid real range format (no min value): %s", s));
        if (pos == inner.len()-1) error($sformatf("Invalid real range format (no max value): %s", s));

        min_str = aip_str::strip(inner.substr(0, pos-1));
        max_str = aip_str::strip(inner.substr(pos+1, inner.len()-1));

        rmin = parse_real_literal(min_str);
        rmax = parse_real_literal(max_str);
        if (rmin > rmax) error($sformatf("Real range min > max: %s", s));
    endfunction

    // 解析 real inc/dec（如 inc:0.1:1.0:0.1）；拒绝多余字段、非法数字和不可抽样的步数。
    protected static function real parse_real_inc_dec(string s, bit is_inc);
        string cleaned = aip_str::remove_all_spaces(s);
        string remain = cleaned.substr(4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        real start_val, end_val, step_val;
        int cnt;

        if (tokens.size() < 2 || tokens.size() > 3) error($sformatf("Invalid real inc/dec format: %s", s));

        start_val = parse_real_literal(tokens[0]);
        end_val   = parse_real_literal(tokens[1]);
        step_val  = (tokens.size() >= 3) ? parse_real_literal(tokens[2]) : 1.0;

        if (step_val <= 0.0) error("Real inc/dec step must be > 0");
        if (is_inc && start_val > end_val) error("Real increment start > end");
        if (!is_inc && start_val < end_val) error("Real decrement start < end");
        if ((is_inc ? start_val - end_val : end_val - start_val) / step_val < -2147483646.0)
            error("Real inc/dec candidate count exceeds 2147483647");

        if (is_inc)
            cnt = int'((end_val - start_val) / step_val) + 1;
        else
            cnt = int'((start_val - end_val) / step_val) + 1;

        if (is_inc)
            return start_val + $urandom_range(cnt-1) * step_val;
        else
            return start_val - $urandom_range(cnt-1) * step_val;
    endfunction

    // 权重组内的实数字面量必须完整消费，防止被禁用项中的拼写错误静默变成 0。
    // 输入 token 及所属项用于诊断，返回有限 real；格式错误/非有限值立即报错。
    protected static function real parse_real_weight_literal(string token, string item, int item_index);
        real value;
        string trailing;
        int matched;
        matched = $sscanf(aip_str::remove_all_spaces(token), "%g%s", value, trailing);
        if (matched != 1 || !is_finite(value) || decimal_overflow(token))
            error($sformatf("Invalid real literal '%s' in weight item[%0d] '%s'", token, item_index, item));
        return value;
    endfunction

    // 解析并抽样 real 权重组；real 范围保持现有连续均匀抽样语义，权重必须
    // 为 0..INT_MAX 的整数。零权重项仍检查语法，累计溢出和全零组在 RNG 前报错；
    // 正权重输入不增加随机调用，保持旧版相同 seed 下的抽样顺序。
    protected static function real parse_real_weight_group(string s);
        string inner;
        string parts[];
        real   mins[], maxs[];
        int    weights[];
        int    total_weight = 0;
        int    r, accum;

        if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")"))
            inner = s.substr(1, s.len()-2);
        else
            inner = s;

        parts = aip_str::split(inner, ",");
        mins    = new[parts.size()];
        maxs    = new[parts.size()];
        weights = new[parts.size()];

        foreach (parts[i]) begin
            string p = aip_str::strip(parts[i]);
            int pos_eq = aip_str::str_find(p, ":=");
            int pos_sl = aip_str::str_find(p, ":/");
            int wpos = (pos_eq != -1) ? pos_eq : pos_sl;
            string left, right;
            string range_body, endpoints[];
            real weight_value;

            if ((pos_eq >= 0) == (pos_sl >= 0) || wpos <= 0 || wpos + 2 >= p.len())
                error($sformatf("Invalid real weight item[%0d] '%s'", i, p));

            left  = aip_str::strip(p.substr(0, wpos-1));
            right = aip_str::strip(p.substr(wpos+2, p.len()-1));
            weight_value = parse_real_weight_literal(right, p, i);
            if (weight_value < 0.0 || weight_value > 2147483647.0 || int'(weight_value) != weight_value)
                error($sformatf("Real weight must be an integer >= 0 and <= 2147483647 in item[%0d] '%s'", i, p));
            weights[i] = int'(weight_value);

            if (left.len() >= 3 && left[0] == "[" && left[left.len()-1] == "]") begin
                range_body = left.substr(1, left.len()-2);
                endpoints = aip_str::split(range_body, ":");
                if (endpoints.size() != 2)
                    error($sformatf("Invalid real range in weight item[%0d] '%s'", i, p));
                mins[i] = parse_real_weight_literal(endpoints[0], p, i);
                maxs[i] = parse_real_weight_literal(endpoints[1], p, i);
                if (mins[i] > maxs[i])
                    error($sformatf("Real range min > max in weight item[%0d] '%s'", i, p));
            end else begin
                mins[i] = parse_real_weight_literal(left, p, i);
                maxs[i] = mins[i];
            end
        end

        foreach (weights[i]) begin
            if (total_weight > 2147483647 - weights[i])
                error($sformatf("Real weighted group total exceeds 2147483647 at item[%0d] '%s'", i, parts[i]));
            total_weight += weights[i];
        end
        if (total_weight == 0)
            error("Real weighted group total must be > 0; all weights are zero");

        r = $urandom_range(total_weight - 1);
        accum = 0;
        foreach (weights[i]) begin
            if (weights[i] == 0) continue;
            if (r < accum + weights[i]) begin
                if (mins[i] == maxs[i])
                    return mins[i];
                else
                    return mins[i] + (maxs[i] - mins[i]) * ($urandom() / 4294967296.0);
            end
            accum += weights[i];
        end
        error("Real weighted selection failed");
        return 0.0;
    endfunction

    // real 表达式公共入口：保留原文及调用来源，在实际求值后恢复上层诊断上下文。
    static function real parse_value(string s);
        real result;
        aip_cmdline_diagnostic::push_expression(s);
        result = parse_value_impl(s);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    // real 内部求值：由公共入口持有诊断上下文，维持已有随机抽样顺序。
    protected static function real parse_value_impl(string s);
        s = aip_str::remove_all_spaces(s);
        // 权重组 {...} 或 (...)
        if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
            return parse_real_weight_group(s);
        end
        // 单权重项
        else if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
            return parse_real_weight_group($sformatf("{%s}", s));
        end
        // 范围 [min:max]
        else if (s.len() >= 3 && s[0] == "[" && s[s.len()-1] == "]") begin
            real rmin, rmax;
            parse_real_range(s, rmin, rmax);
            return rmin + (rmax - rmin) * ($urandom() / 4294967296.0);
        end
        // inc/dec
        else if (aip_str::str_find(s, "inc:") != -1) begin
            return parse_real_inc_dec(s, 1);
        end
        else if (aip_str::str_find(s, "dec:") != -1) begin
            return parse_real_inc_dec(s, 0);
        end
        // 列表随机
        else if (aip_str::str_find(s, ",") != -1) begin
            string rparts[] = aip_str::split(s, ",");
            int idx = $urandom_range(rparts.size()-1);
            return parse_real_literal(rparts[idx]);
        end
        // 无括号范围 min:max
        else if (aip_str::str_find(s, ":") != -1) begin
            real rmin, rmax;
            parse_real_range(s, rmin, rmax);
            return rmin + (rmax - rmin) * ($urandom() / 4294967296.0);
        end
        // 单值
        else begin
            return parse_real_literal(s);
        end
    endfunction

    // real 单值公共入口，尾部可选参数向后兼容；用户宏自动传递文件名和行号。
    static function void get_single_value(string name, string path, real default_val, ref real val,
                                           input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_single_value_impl(name, path, default_val, val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // real 与整数入口一致：非空 override 复用 plusarg 的范围/列表/权重/步长求值。
    // 每次读取才抽样；固定 override 直接校验/转换，避免完整表达式解析的扫描开销。
    // 空 override 返回 0.0，缺失参数使用 default_val。
    // 原参数来源一直保留在诊断栈中，非法表达式沿现有 hard fatal 路径结束。
    protected static function void get_single_value_impl(string name, string path, real default_val, ref real val);
        string	s;
        bit	is_ov;
        is_ov = aip_cmdline#(int)::lookup_override(name, path, s);
        if (!is_ov)
            s = aip_cmdline#(int)::get_cmdline_string(name, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), s);
        if (is_ov && s == "") begin
            val = 0.0;
            return;
        end
        if (s == "") begin
            val = default_val;
            return;
        end
        if (is_ov && aip_cmdline#(int)::is_literal_candidate(s)) begin
            val = parse_real_literal(s);
            return;
        end
        s = aip_str::remove_all_spaces(s);
        val = parse_value(s);
    endfunction

    // real 动态数组公共入口：一次无时序调用持有来源，内部提前返回不泄漏上下文。
    static function void get_dynamic_array(string name, string path, real default_val, ref real arr[],
                                            input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_dynamic_array_impl(name, path, default_val, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // real 动态数组内部实现；每个元素解析前记录其键和完整输入。
    // .size 保持确定整数字面量语义，并检查语法/非负/int 上限后才分配，禁止截断或负数回退。
    protected static function void get_dynamic_array_impl(string name, string path, real default_val, ref real arr[]);
        string size_str;
        int size;
        string overall_str;
        real overall_vals[];
        string parts[];

        // 1. 获取 .size
        size_str = aip_cmdline#(int)::get_cmdline_string({name, ".size"}, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".size"}, path), size_str);
        if (size_str != "") begin
            int width;
            aip_vec_t size_bits;
            bit negative;
            string cleaned_size;
            cleaned_size = aip_str::remove_all_spaces(size_str);
            if (!aip_str::str_to_vec(cleaned_size, size_bits, width, negative) ||
                negative || size_bits > 2147483647)
                error($sformatf("Invalid real array size '%s': expected integer >= 0 and <= 2147483647", size_str));
            size = int'(size_bits);
        end else begin
            size = -1;
        end

        // 2. 获取整体赋值
        overall_str = aip_cmdline#(int)::get_cmdline_string(name, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), overall_str);
        if (overall_str != "") begin
            string cleaned = aip_str::remove_all_spaces(overall_str);
            // 使用 aip_cmdline 的智能分割
            aip_cmdline#(int)::split_array_elements(cleaned, parts);
            foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
            overall_vals = new[parts.size()];
            foreach (parts[i]) begin
                aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", aip_cmdline_diagnostic::full_name(name, path), i), overall_str);
                if (parts[i] == "") begin error("Empty element in real array"); return; end
                overall_vals[i] = parse_value(parts[i]);
            end
        end

        // 3. 确定大小
        if (size == -1) begin
            if (overall_vals.size() > 0)
                size = overall_vals.size();
            else begin
                arr = new[0];
                return;
            end
        end

        // 4. 初始化
        arr = new[size];
        for (int i = 0; i < size; i++) arr[i] = default_val;

        // 5. 应用整体赋值
        if (overall_vals.size() > 0) begin
            int copy_len = (overall_vals.size() < size) ? overall_vals.size() : size;
            for (int i = 0; i < copy_len; i++) arr[i] = overall_vals[i];
        end
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_struct - 结构体紧凑格式解析辅助类
//-------------------------------------------------------------------------
class aip_cmdline_struct;

    // 解析旧版紧凑格式 {key=val,key=val,...}，覆盖输出队列；不支持字段值内的逗号。
    // 原文保留在同步上下文中；缺括号、缺等号、空字段/值、空分段立即 fatal，
    // 防止拼写错误被静默丢弃后继续使用默认值。空对象 {} 仍然合法。
    static function void parse_compact(string s, ref string keys[$], ref string vals[$]);
        string inner;
        int eq_pos;

        aip_cmdline_diagnostic::push_expression(s);
        keys = {};
        vals = {};

        // 去除外层 { }
        s = aip_str::strip(s);
        if (s.len() < 2 || s[0] != "{" || s[s.len()-1] != "}") begin
            aip_cmdline_diagnostic::report("AIP_CORE[cmdline_struct] Error",
                $sformatf("compact format must be wrapped in {}: %s", s),
                `__FILE__, `__LINE__);
        end
        inner = (s.len() == 2) ? "" : s.substr(1, s.len()-2);
        if (aip_str::strip(inner) == "") begin
            aip_cmdline_diagnostic::pop();
            return;
        end

        // 逐段解析 key=val,key=val,...（避免 split 动态数组 resize 问题）
        begin
            int start = 0;
            int comma_pos, inner_len;
            inner_len = inner.len();
            while (start <= inner_len) begin
                string segment, field, value;
                comma_pos = aip_str::str_find(inner, ",", start);
                if (start == inner_len || comma_pos == start)
                    segment = "";
                else if (comma_pos == -1)
                    segment = inner.substr(start, inner_len - 1);
                else
                    segment = inner.substr(start, comma_pos - 1);
                segment = aip_str::strip(segment);
                eq_pos = aip_str::str_find(segment, "=");
                if (eq_pos <= 0 || eq_pos >= segment.len()-1)
                    aip_cmdline_diagnostic::report("AIP_CORE[cmdline_struct] Error",
                        $sformatf("malformed compact member[%0d] '%s'; expected key=value",
                                  keys.size(), segment), `__FILE__, `__LINE__);
                field = aip_str::strip(segment.substr(0, eq_pos-1));
                value = aip_str::strip(segment.substr(eq_pos+1, segment.len()-1));
                if (field == "" || value == "")
                    aip_cmdline_diagnostic::report("AIP_CORE[cmdline_struct] Error",
                        $sformatf("empty key/value in compact member[%0d] '%s'",
                                  keys.size(), segment), `__FILE__, `__LINE__);
                keys.push_back(field);
                vals.push_back(value);
                if (comma_pos == -1) break;
                start = comma_pos + 1;
            end
        end
        aip_cmdline_diagnostic::pop();
    endfunction

    // 在 keys 中查找指定 key，返回对应 val，未找到返回 ""
    static function string find_key(string keys[$], string vals[$], string key);
        foreach (keys[i]) begin
            if (keys[i] == key) return vals[i];
        end
        return "";
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_print_control - registration log throttling shared by all macros
//-------------------------------------------------------------------------
class aip_cmdline_print_control;
    static bit print_enable = 1;
    static int max_prints = 10;

    protected static int print_counts[string];
    protected static bit initialized = 0;

    protected static function void apply_config(int enable, int requested_max);
        if (requested_max < -1)
            `aip_warning(("[aip_cmdline] max_prints %0d normalized to -1",
                          requested_max));
        print_enable = (enable != 0);
        max_prints = (requested_max < -1) ? -1 : requested_max;
        initialized = 1;
    endfunction

    protected static function void lazy_initialize();
        int enable;
        int requested_max;

        if (initialized) return;

        aip_cmdline#(int)::get_single_value(
            "print_enable", "aip_cmdline", 1, enable);
        aip_cmdline#(int)::get_single_value(
            "max_prints", "aip_cmdline", 10, requested_max);
        apply_config(enable, requested_max);
    endfunction

    static function bit should_print(string name, string path = "");
        string key;

        lazy_initialize();
        if (!print_enable || max_prints == 0) return 0;

        key = (path == "") ? name : {path, ".", name};
        if (!print_counts.exists(key)) print_counts[key] = 0;

        if (max_prints == -1) begin
            print_counts[key]++;
            return 1;
        end

        if (print_counts[key] < max_prints) begin
            print_counts[key]++;
            return 1;
        end
        return 0;
    endfunction

    static task configure(int enable, int requested_max_prints);
        apply_config(enable, requested_max_prints);
        print_counts.delete();
    endtask
endclass
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
