// 基础解析：整数/字符串、枚举、real、旧版 compact 辅助及注册日志限流。
// 内部 include 片段：只允许 aip_cmdline.sv 在其 include 窗口加载，拒绝直接包含以免创建第二份 $unit/package 类型。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else

class aip_cmdline #(type T = int);

    static bit global_required = 0; // 全局必填开关：置 1 时缺失参数报错
    static string last_array_ctrl = ""; // 最近一次 resolve_array 的控制键摘要，供注册日志打印

    typedef enum { RANGE, WEIGHT_EACH, WEIGHT_TOTAL, INCREMENT, DECREMENT, LIST, SINGLE, RAND } rand_mode_t;

    typedef enum { NOT_WRAPPER, VALID_WRAPPER, MALFORMED_WRAPPER } outer_list_wrapper_state_t;

    // 数值统一用 aip_svec_t（有符号 1026 bit）保存，最后才 T'() 转换，使 T=string 特化也能编译。
    typedef struct {
        rand_mode_t mode;
        aip_svec_t  min, max, step, start, weight;
        bit         full;        // 权重组里的 "rand"
        aip_svec_t  list_vals[];
    } rand_desc_t;

    typedef struct {
        int index;
        string value_str;
    } index_assign_t;


    // 候选键依次为完整 path.name、别名（aip_cmdline_alias）、叶名 name（path 非空时）；记录使用时全部记为已查询，
    // as_root=1 时按容器根记录。
    static function void candidate_keys(string name, string path, ref string keys[$], input bit as_root = 0);
        string	alias_path;
        keys.delete();
        keys.push_back((path != "") ? {path, ".", name} : name);
        if (path != "") begin
            alias_path = aip_cmdline_alias::resolve(path);
            if (alias_path != "") keys.push_back({alias_path, ".", name});
            keys.push_back(name);
        end
        if (aip_cmdline_usage::recording())
            foreach (keys[i]) begin
                if (as_root) aip_cmdline_usage::note_root(keys[i]);
                else aip_cmdline_usage::note(keys[i]);
            end
    endfunction

    // 按 override(完整、别名、叶名) > plusarg(完整、别名、叶名) 选中第一个来源，空串也算命中并屏蔽其后来源；
    // 返回 0=未给出、1=override、2=plusarg，key 为命中的键（未命中为完整键）。只读，不求值、不消耗随机数。
    static function int select_source(string name, string path, output string key, output string val);
        string					keys[$];
        string					vals[$];
        uvm_cmdline_processor	clp;
        candidate_keys(name, path, keys);
        foreach (keys[i]) begin
            if (aip_cmdline_override::has(keys[i])) begin
                key = keys[i];
                val = aip_cmdline_override::get_val(keys[i]);
                return 1;
            end
        end
        clp = aip_cmdline_source::get();
        foreach (keys[i]) begin
            vals.delete();
            clp.get_arg_values({"+", keys[i], "="}, vals);
            if (vals.size() != 0) begin
                key = keys[i];
                val = vals[vals.size()-1];
                return 2;
            end
        end
        key = keys[0];
        val = "";
        return 0;
    endfunction

    // 只查 override：完整、别名、叶名依次查找；空串也算命中。
    static function bit lookup_override(string name, string path, output string val);
        string	keys[$];
        candidate_keys(name, path, keys);
        foreach (keys[i]) begin
            if (aip_cmdline_override::has(keys[i])) begin
                val = aip_cmdline_override::get_val(keys[i]);
                return 1;
            end
        end
        val = "";
        return 0;
    endfunction

    // 按 select_source 顺序取原文，不消费 RNG。
    static function string get_cmdline_string(string name, string path = "");
        string	key;
        string	val;
        check_required(select_source(name, path, key, val), name, path);
        return val;
    endfunction

    // 必填开关打开且没有任何来源时，单独建上下文报出实际缺失的键，而非上一字段。
    protected static function void check_required(int src, string name, string path);
        if (src != 0 || !global_required) return;
        aip_cmdline_diagnostic::push_value(aip_cmdline_diagnostic::full_name(name, path), "<missing>");
        error($sformatf("Required parameter +%s (path: %s) not provided", name, path));
    endfunction

    // 解析失败即 hard fatal；VCS 需 -exitstatus 才会把失败传给 shell。
    protected static function void error(string msg);
        aip_cmdline_diagnostic::report("AIP_CORE[cmdline] parser Error", msg, `__FILE__, `__LINE__);
    endfunction

    // VCS 的 $typename 会把 packed typedef 展开成底层类型，故也要识别 logic/reg/integer，不只 bit。
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

    // 对变量而非类型名取 $bits，使 T=string 特化也能编译（返回 0）。
    protected static function int t_bits();
        T tmp;
        return $bits(tmp);
    endfunction

    protected static function aip_svec_t urand_svec(int nbits);
        aip_vec_t v = '0;
        for (int i = 0; i < nbits; i += 32) v = (v << 32) | $urandom();
        if (nbits < AIP_VEC_MAX_BITS) v = v & ((aip_vec_t'(1) << nbits) - 1);
        return aip_svec_t'({2'b00, v});
    endfunction

    // [lo, hi] 闭区间均匀随机，任意宽度；取模偏差约 2^-N，忽略。
    protected static function aip_svec_t rand_in_range(aip_svec_t lo, aip_svec_t hi);
        aip_svec_t span = hi - lo + 1;
        return lo + (urand_svec(AIP_VEC_MAX_BITS) % span);
    endfunction

    // 按 $typename 判断有符号性（T=string 特化也能编译）：带 unsigned 的为无符号，byte/shortint/int/longint/integer
    // 与显式 signed 位向量为有符号，其余 bit/logic/reg 位向量为无符号。
    static function bit t_signed();
        string tn = $typename(T);
        if (aip_str::str_find(tn, "unsigned") != -1) return 0;
        if (aip_str::str_find(tn, "signed") != -1) return 1;
        return tn == "byte" || tn == "shortint" || tn == "int" || tn == "longint" || tn == "integer";
    endfunction

    // 无符号目标的取值范围文字：64 位及以下给十进制上界，更宽给 2^N-1。
    protected static function string unsigned_range();
        int nbits = t_bits();
        aip_vec_t max_v;
        if (nbits > 64) return $sformatf("0..2^%0d-1", nbits);
        max_v = (aip_vec_t'(1) << nbits) - 1;
        return $sformatf("0..%0d", max_v[63:0]);
    endfunction

    // value_token=0 用于权重、步长等计数位置：它们沿用目标位宽检查，负数由各自规则报错。
    // 无符号目标的取值位置拒绝负号（含 -0），不回绕；超出位宽同样报错，均为 hard fatal。
    protected static function aip_svec_t parse_single_num(string s, bit value_token = 1);
        aip_vec_t  v;
        aip_svec_t r;
        int width;
        bit neg;
        int nbits = t_bits();
        bit check_unsigned = value_token && is_integer_type() && !t_signed();
        if (!aip_str::str_to_vec(s, v, width, neg))
            error($sformatf("Invalid integer format: %s", s));
        if (nbits > 0 && nbits < AIP_VEC_MAX_BITS && (v >> nbits) != 0)
            error($sformatf("value %s exceeds %0d-bit %s%s", s, nbits, $typename(T),
                            check_unsigned ? {" (allowed ", unsigned_range(), ")"} : ""));
        if (nbits > 0 && width > nbits)
            error($sformatf("explicit width in %s exceeds %0d-bit %s", s, nbits, $typename(T)));
        if (check_unsigned && neg)
            error($sformatf("negative value %s for unsigned %0d-bit %s (allowed %s)", s, nbits, $typename(T),
                            unsigned_range()));
        r = aip_svec_t'({2'b00, v});
        return neg ? -r : r;
    endfunction

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

    // 固定 override 的快路径分流：只排除表达式标记，不代替正式字面量校验。
    // 数字含空白时交公共路径规范化，以免与 plusarg 语义不同；字符串只排除分割用的逗号/括号。
    // real 入口复用本方法，避免维护第二套判别规则。
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

    protected static function void parse_int_list(string s, output aip_svec_t list[]);
        string parts[] = aip_str::split(aip_str::remove_all_spaces(s), ",");
        list = new[parts.size()];
        foreach (parts[i]) begin
            string p = aip_str::strip(parts[i]);
            if (p == "") error($sformatf("Empty element in list: %s", s));
            list[i] = parse_single_num(p);
        end
    endfunction

    // 零权重只禁用抽样，不跳过左侧语法/位宽检查；rand 只允许 :/，避免无限候选集的逐值权重。
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
        desc.weight = parse_single_num(right, 0);
        if (desc.weight < 0)
            error($sformatf("Weight must be >= 0 in item[%0d] '%s'", item_index, s));

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

    // 所有项（含零权重项）都须完整解析，空项属于语法错误。
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
        if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
            string inner = s.substr(1, s.len()-2);
            parse_weight_items(inner, desc_list);
        end else begin
            error($sformatf("Invalid weight group format: %s", s));
        end
    endfunction

    // := 给每个离散值分配权重，:/ 给整项分配；全零与累计溢出在消费 RNG 前检查。
    // 抽样调用顺序保持不变，相同 seed 结果可复现。
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

    // 格式 inc|dec:start:end[:step]。
    protected static function void parse_inc_dec(string s, bit is_inc, output rand_desc_t desc);
        string cleaned = aip_str::remove_all_spaces(s);
        string remain = cleaned.substr(4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        if (tokens.size() < 2 || tokens.size() > 3) error($sformatf("Invalid inc/dec format: %s", s));

        desc.mode = is_inc ? INCREMENT : DECREMENT;
        desc.start = parse_single_num(tokens[0]);
        desc.max = parse_single_num(tokens[1]);
        desc.step = (tokens.size() >= 3) ? parse_single_num(tokens[2], 0) : 1;
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
        step = (tokens.size() == 3) ? parse_single_num(tokens[2], 0) : 1;
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
        if (!is_integer_type()) return -1;  // string .each 列表交给 unique 重抽循环处理
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

    // An outer [] is a list wrapper only with a top-level comma: [1:3] is not, [1,[2:3],4] is.
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

    // 按顶层逗号分割，{} 与 () 内的逗号不拆。
    static function void split_array_elements(string s, ref string elems[]);
        int len = s.len();
        int brace_depth = 0;
        int paren_depth = 0;
        string current = "";
        elems = new[0];
        for (int i = 0; i < len; i++) begin
            byte ch = s[i];
            if (ch == "{") brace_depth++;
            else if (ch == "}") brace_depth--;
            else if (ch == "(") paren_depth++;
            else if (ch == ")") paren_depth--;
            else if (ch == "," && brace_depth == 0 && paren_depth == 0) begin
                elems = new[elems.size()+1](elems);
                elems[elems.size()-1] = current;
                current = "";
                continue;
            end
            current = {current, ch};
        end
        if (current != "") begin
            elems = new[elems.size()+1](elems);
            elems[elems.size()-1] = current;
        end
        if (brace_depth != 0 || paren_depth != 0)
            error($sformatf("Mismatched braces/parentheses in array string: %s", s));
    endfunction

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

    static function T parse_value(string s);
        T result;
        aip_cmdline_diagnostic::push_expression(s);
        result = parse_value_impl(s);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    protected static function T parse_value_impl(string s);
        if (is_integer_type()) begin
            if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
                rand_desc_t group[];
                parse_weight_group(s, group);
                return get_weighted_group_value(group);
            end else if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
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

    protected static function void get_all_cmdline_args(ref string args[$]);
        uvm_cmdline_processor clp = aip_cmdline_source::get();
        clp.get_args(args);
    endfunction

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
            pos = prefix.len();
            if (pos >= arg.len() || arg[pos] != "[") continue;
            end_bracket = aip_str::str_find(arg, "]", pos+1);
            if (end_bracket == -1) continue;
            idx_str = aip_str::remove_all_spaces(arg.substr(pos+1, end_bracket-1));
            idx = aip_str::str_to_num(idx_str, width);
            if (idx == -1 && width == 0) continue;  // 非法索引
            if (end_bracket+1 >= arg.len() || arg[end_bracket+1] != "=") continue;
            val_str = arg.substr(end_bracket+2, arg.len()-1);
            // 同一索引以后出现的 plusarg 为准
            index_vals[idx] = idx;
            value_strs[idx] = val_str;
        end
    endfunction

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

    // 尾部来源参数可选以兼容原四参数 API，用户宏自动传入 __FILE__/__LINE__。
    static function void get_single_value(string name, string path, T default_val, ref T val,
                                           input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_single_value_impl(name, path, default_val, val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 非空随机 override 与 plusarg 走同一抽样路径（每次读取重新抽）；固定 override 走字面量快路径，不消费 RNG。
    protected static function void get_single_value_impl(string name, string path, T default_val, ref T val);
        string	s;
        string	key;
        int		src;

        src = select_source(name, path, key, s);   // 命中 override 时 s 可能为空串
        check_required(src, name, path);

        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), s);

        if (src == 1 && s == "") begin
            T	zero; // 空 override 取类型初值（含 string 空串与四态类型），不回退宏默认值
            val = zero;
            return;
        end
        val = default_val;
        if (s != "") eval_selected(s, src == 1, val);
    endfunction

    // 对已选中的非空原文求值：固定 override 走字面量快路径；否则按顶层逗号拆分、抽一个候选再解析。
    // 拆分结果为空（如全空白）时保持 val。
    protected static function void eval_selected(string s, bit is_ov, ref T val);
        string	parts[];
        if (is_ov && is_literal_candidate(s, $typename(T) == "string")) begin
            val = parse_single_value(s);
            return;
        end
        split_overall_string(s, parts);
        if (parts.size() != 0) begin
            int	idx;
            idx = $urandom_range(0, parts.size()-1);
            val = parse_value(parts[idx]);
        end
    endfunction

    // 可选参数：按 select_source 选中一个来源（含别名），缺失或空值（含空 override）保持 val 并返回 0；
    // 否则按 get_single_value 的同一规则求值写入 val 并返回 1。必填开关 global_required 不作用于可选参数。
    static function bit get_optional(string name, string path, ref T val,
                                     input string source_file = "", input int source_line = 0);
        string	s;
        string	key;
        int		src;
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        src = select_source(name, path, key, s);
        if (src != 0 && s != "") begin
            aip_cmdline_diagnostic::select_value(key, s);
            eval_selected(s, src == 1, val);
        end
        aip_cmdline_diagnostic::pop();
        return src != 0 && s != "";
    endfunction

    // fixed_size=-1：动态数组，长度由 .size/整体列表/最大索引决定；>=0：静态数组，.size 与超长列表报错。
    static function void resolve_array(
        string name, string path, T default_val, int fixed_size, ref T arr[],
        input string source_file = "", input int source_line = 0
    );
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        resolve_array_impl(name, path, default_val, fixed_size, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

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

        begin
            int    ov_p_v[int]; string ov_p_s[int];
            int    ov_a_v[int]; string ov_a_s[int];
            int    ov_l_v[int]; string ov_l_s[int];
            int    pa_p_v[int]; string pa_p_s[int];
            int    pa_a_v[int]; string pa_a_s[int];
            string alias_path;
            string roots[$];

            alias_path = (path != "") ? aip_cmdline_alias::resolve(path) : "";
            candidate_keys(name, path, roots, 1);   // 记录使用：根、控制键与索引都归入容器根
            collect_indexed_overrides(name, path, ov_p_v, ov_p_s);
            if (alias_path != "")
                collect_indexed_overrides(name, alias_path, ov_a_v, ov_a_s);
            collect_indexed_overrides(name, "",   ov_l_v, ov_l_s);
            if (path != "")
                collect_indexed_assignments(name, path, pa_p_v, pa_p_s);
            if (alias_path != "")
                collect_indexed_assignments(name, alias_path, pa_a_v, pa_a_s);
            collect_indexed_assignments(name, "", no_path_vals, no_path_strs);

            foreach (ov_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_p_s[i];       end
            foreach (ov_a_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_a_s[i];       end
            foreach (ov_l_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_l_s[i];       end
            foreach (pa_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=pa_p_s[i];       end
            foreach (pa_a_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=pa_a_s[i];       end
            foreach (no_path_vals[i]) if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=no_path_strs[i]; end
        end
        foreach (index_vals[i]) begin
            if (i > max_idx) max_idx = i;
        end

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

        arr = new[size];
        fixed = new[size];
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name({name, ".each"}, path), each_str);
        for (int i = 0; i < size; i++) begin
            arr[i] = (each_str != "") ? parse_value(each_str) : default_val;
            fixed[i] = (each_str == "");
        end

        for (int i = 0; i < overall_vals.size(); i++) begin
            arr[i] = overall_vals[i];
            fixed[i] = 1;
        end

        // 越界索引静默忽略（保持既有行为）。
        foreach (index_vals[i]) begin
            if (i < size) begin
                aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", aip_cmdline_diagnostic::full_name(name, path), i), index_strs[i]);
                arr[i] = parse_value(index_strs[i]);
                fixed[i] = 1;
            end
        end

        // .unique：固定值（默认/整体/索引赋值）互不重复；.each 生成的元素与已有值冲突则重抽，上限 100×size 次。
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

        // 索引覆盖值一起排序；用内建方法，1000000 元素的 seq 也不卡。
        if (sort_str == "asc")       arr.sort();
        else if (sort_str == "desc") arr.rsort();
    endfunction

    static function void get_dynamic_array(
        string name, string path,
        T default_val,
        ref T arr[],
        input string source_file = "", input int source_line = 0
    );
        resolve_array(name, path, default_val, -1, arr, source_file, source_line);
    endfunction

    // 键等于容器根，或是根的控制子键/元素索引（根后紧跟 "." 或 "["）；相似前缀如 options_extra 不算。
    static function bit key_under_root(string key, string root);
        if (key == root) return 1;
        return key.len() > root.len() && key.substr(0, root.len()-1) == root &&
               (key[root.len()] == "." || key[root.len()] == "[");
    endfunction

    // 可选容器：先选根再解析，避免同一容器的整体值、控制键与索引分散在不同路径下被合并。候选根依次为完整
    // path.name、别名、叶名；所有 override 键先于 plusarg 匹配，第一个有键落在其下的根胜出。选中后按 resolve_array
    // 解析该根（显式配置替换整个容器，未覆盖元素取 default_val）；三个根下都没有键时保持 arr 并返回 0。
    static function bit resolve_array_opt(
        string name, string path, T default_val, int fixed_size, ref T arr[],
        input string source_file = "", input int source_line = 0
    );
        string					roots[$];
        string					keys[$];
        string					args[$];
        uvm_cmdline_processor	clp;
        candidate_keys(name, path, roots, 1);
        aip_cmdline_override::get_keys(keys);
        foreach (roots[i]) foreach (keys[j])
            if (key_under_root(keys[j], roots[i])) begin
                resolve_array(roots[i], "", default_val, fixed_size, arr, source_file, source_line);
                return 1;
            end
        clp = aip_cmdline_source::get();
        clp.get_args(args);
        foreach (roots[i]) foreach (args[j]) begin
            int	eq;
            if (args[j].len() < 2 || args[j][0] != "+") continue;
            eq = aip_str::str_find(args[j], "=");
            if (eq < 0) continue;
            if (key_under_root(args[j].substr(1, eq - 1), roots[i])) begin
                resolve_array(roots[i], "", default_val, fixed_size, arr, source_file, source_line);
                return 1;
            end
        end
        return 0;
    endfunction

endclass

// 枚举解析：先校验全部候选再抽样，避免非法候选因本次未被抽中而隐藏。
class aip_cmdline_enum;
    // 校验整条表达式并按出现顺序返回全部候选值，不消耗随机数。逗号候选可写成员名（不区分大小写）或等于某成员值的
    // 整数字面量（如 0x0A，负值按二进制补码比较）；整串为 rand 时取全部成员，但同名成员优先。范围、权重等数值随机
    // 语法不适用于枚举；空候选、未知名称或不对应成员的数值都 hard fatal。
    static function void candidates(string s, string names[$], logic [1023:0] values[$],
                                    ref logic [1023:0] out[$]);
        string cleaned, candidate;
        int start, stop;
        bit matched;

        out.delete();
        aip_cmdline_diagnostic::push_expression(s);
        cleaned = aip_str::strip(s);
        if (cleaned == "")
            aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                "empty enum string", `__FILE__, `__LINE__);
        if (names.size() == 0 || names.size() != values.size())
            aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                "enum names/values mapping is empty or has mismatched lengths",
                `__FILE__, `__LINE__);

        if (aip_str::lower(cleaned) == "rand" && !has_name(names, "rand")) begin
            foreach (values[i]) out.push_back(values[i]);
            aip_cmdline_diagnostic::pop();
            return;
        end

        start = 0;
        while (start <= cleaned.len()) begin
            stop = aip_str::str_find(cleaned, ",", start);
            if (stop < 0) stop = cleaned.len();
            candidate = (stop == start) ? "" :
                        aip_str::strip(cleaned.substr(start, stop-1));
            matched = 0;
            foreach (names[i]) begin
                if (aip_str::lower(names[i]) == aip_str::lower(candidate)) begin
                    out.push_back(values[i]);
                    matched = 1;
                    break;
                end
            end
            if (!matched && aip_cmdline#(int)::is_literal_candidate(candidate)) begin
                aip_vec_t		magnitude;
                logic [1023:0]	number;
                int				width;
                bit				negative;
                if (aip_str::str_to_vec(candidate, magnitude, width, negative)) begin
                    number = negative ? ~magnitude + 1'b1 : magnitude;
                    foreach (values[i]) begin
                        if (number === values[i]) begin
                            out.push_back(values[i]);
                            matched = 1;
                            break;
                        end
                    end
                end
            end
            if (!matched)
                aip_cmdline_diagnostic::report("AIP_CORE[cmdline_enum] Error",
                    $sformatf("candidate[%0d] '%s' not found in enum",
                              out.size(), candidate), `__FILE__, `__LINE__);
            if (stop == cleaned.len()) break;
            start = stop + 1;
        end
        aip_cmdline_diagnostic::pop();
    endfunction

    // 全部候选校验通过后等概率抽一个（固定消耗一次随机数）。
    static function logic [1023:0] resolve_bits(string s, string names[$], logic [1023:0] values[$]);
        logic [1023:0] all[$], result;
        aip_cmdline_diagnostic::push_expression(s);
        candidates(s, names, values, all);
        result = all[$urandom_range(all.size()-1)];
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    protected static function bit has_name(string names[$], string name);
        foreach (names[i]) if (aip_str::lower(names[i]) == name) return 1;
        return 0;
    endfunction

    // 兼容 int 枚举接口：经 resolve_bits 解析后取低 32 位。
    static function int resolve(string s, string names[$], int values[$]);
        logic [1023:0] wide_values[$];
        foreach (values[i]) wide_values.push_back(values[i]);
        return int'(resolve_bits(s, names, wide_values));
    endfunction

endclass

// real 解析独立于参数化 aip_cmdline#(T)，以兼容 VCS。
class aip_cmdline_real;

    // VCS sscanf 对溢出返回 DBL_MAX 而非 Inf，只查转换结果发现不了，故按十进制原文与 binary64 最大有限值比较。
    // 只判上界（允许零及下溢到零），语法完整性由调用方检查。
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
        // The equal-exponent comparison needs normalized digits; otherwise 0.18e309 would
        // compare its leading zero against DBL_MAX's leading one and be accepted.
        digits = digits.substr(lead, digits.len()-1);
        // Exact decimal expansion of IEEE-754 binary64's largest finite value (DBL_MAX).
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

    // 查指数字段全 1（Inf/NaN），不依赖工具浮点比较；被饱和成 DBL_MAX 的溢出需配合 decimal_overflow 检查。
    static function bit is_finite(real value);
        bit [63:0] encoding;
        encoding = $realtobits(value);
        return encoding[62:52] != 11'h7ff;
    endfunction

    protected static function void error(string msg);
        aip_cmdline_diagnostic::report("AIP_CORE[cmdline_real] parser Error", msg, `__FILE__, `__LINE__);
    endfunction

    // 须完整消费有限数字，不沿用 aip_str 通用转换对非法输入的零值回退（单独实现以免影响其他调用者）。
    protected static function real parse_real_literal(string token);
        real value;
        string trailing;
        int matched;
        matched = $sscanf(aip_str::remove_all_spaces(token), "%g%s", value, trailing);
        if (matched != 1 || !is_finite(value) || decimal_overflow(token))
            error($sformatf("Invalid real literal '%s'", token));
        return value;
    endfunction

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

    // 格式 inc|dec:start:end[:step]，如 inc:0.1:1.0:0.1。
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
    protected static function real parse_real_weight_literal(string token, string item, int item_index);
        real value;
        string trailing;
        int matched;
        matched = $sscanf(aip_str::remove_all_spaces(token), "%g%s", value, trailing);
        if (matched != 1 || !is_finite(value) || decimal_overflow(token))
            error($sformatf("Invalid real literal '%s' in weight item[%0d] '%s'", token, item_index, item));
        return value;
    endfunction

    // 权重须为 0..INT_MAX 整数，范围项连续均匀抽样；零权重项仍查语法，溢出与全零组在 RNG 前报错。
    // 不增加随机调用次数，保持相同 seed 下的既有抽样顺序。
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

    static function real parse_value(string s);
        real result;
        aip_cmdline_diagnostic::push_expression(s);
        result = parse_value_impl(s);
        aip_cmdline_diagnostic::pop();
        return result;
    endfunction

    protected static function real parse_value_impl(string s);
        s = aip_str::remove_all_spaces(s);
        if ((s[0] == "{" && s[s.len()-1] == "}") || (s[0] == "(" && s[s.len()-1] == ")")) begin
            return parse_real_weight_group(s);
        end
        else if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
            return parse_real_weight_group($sformatf("{%s}", s));
        end
        else if (s.len() >= 3 && s[0] == "[" && s[s.len()-1] == "]") begin
            real rmin, rmax;
            parse_real_range(s, rmin, rmax);
            return rmin + (rmax - rmin) * ($urandom() / 4294967296.0);
        end
        else if (aip_str::str_find(s, "inc:") != -1) begin
            return parse_real_inc_dec(s, 1);
        end
        else if (aip_str::str_find(s, "dec:") != -1) begin
            return parse_real_inc_dec(s, 0);
        end
        else if (aip_str::str_find(s, ",") != -1) begin
            string rparts[] = aip_str::split(s, ",");
            int idx = $urandom_range(rparts.size()-1);
            return parse_real_literal(rparts[idx]);
        end
        else if (aip_str::str_find(s, ":") != -1) begin
            real rmin, rmax;
            parse_real_range(s, rmin, rmax);
            return rmin + (rmax - rmin) * ($urandom() / 4294967296.0);
        end
        else begin
            return parse_real_literal(s);
        end
    endfunction

    // 尾部来源参数可选以兼容旧调用方，用户宏自动传入 __FILE__/__LINE__。
    static function void get_single_value(string name, string path, real default_val, ref real val,
                                           input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_single_value_impl(name, path, default_val, val);
        aip_cmdline_diagnostic::pop();
    endfunction

    // 与整数入口一致：非空 override 每次读取时按 plusarg 语法求值，字面量直接转换以省去完整解析的扫描开销。
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

    static function void get_dynamic_array(string name, string path, real default_val, ref real arr[],
                                            input string source_file = "", input int source_line = 0);
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        get_dynamic_array_impl(name, path, default_val, arr);
        aip_cmdline_diagnostic::pop();
    endfunction

    // .size 只接受确定的整数字面量，校验非负且不超过 int 上限后才分配，不截断、不回退。
    protected static function void get_dynamic_array_impl(string name, string path, real default_val, ref real arr[]);
        string size_str;
        int size;
        string overall_str;
        real overall_vals[];
        string parts[];

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

        overall_str = aip_cmdline#(int)::get_cmdline_string(name, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), overall_str);
        if (overall_str != "") begin
            string cleaned = aip_str::remove_all_spaces(overall_str);
            aip_cmdline#(int)::split_array_elements(cleaned, parts);
            foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
            overall_vals = new[parts.size()];
            foreach (parts[i]) begin
                aip_cmdline_diagnostic::select_value($sformatf("%s[%0d]", aip_cmdline_diagnostic::full_name(name, path), i), overall_str);
                if (parts[i] == "") begin error("Empty element in real array"); return; end
                overall_vals[i] = parse_value(parts[i]);
            end
        end

        if (size == -1) begin
            if (overall_vals.size() > 0)
                size = overall_vals.size();
            else begin
                arr = new[0];
                return;
            end
        end

        arr = new[size];
        for (int i = 0; i < size; i++) arr[i] = default_val;

        if (overall_vals.size() > 0) begin
            int copy_len = (overall_vals.size() < size) ? overall_vals.size() : size;
            for (int i = 0; i < copy_len; i++) arr[i] = overall_vals[i];
        end
    endfunction

endclass

class aip_cmdline_struct;

    // 解析旧版紧凑格式 {key=val,...}，不支持值内逗号；缺括号/等号、空键值或空分段立即 fatal，
    // 防止拼写错误被静默丢弃而沿用默认值。空对象 {} 合法。
    static function void parse_compact(string s, ref string keys[$], ref string vals[$]);
        string inner;
        int eq_pos;

        aip_cmdline_diagnostic::push_expression(s);
        keys = {};
        vals = {};

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

        // 手工逐段扫描而非 split，避开 split 的动态数组 resize 问题。
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

    static function string find_key(string keys[$], string vals[$], string key);
        foreach (keys[i]) begin
            if (keys[i] == key) return vals[i];
        end
        return "";
    endfunction

endclass

// Registration log throttling shared by all macros.
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
