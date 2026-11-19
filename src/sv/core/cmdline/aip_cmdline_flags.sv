// 内部 include 片段，只能由 aip_cmdline.sv 加载。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else

// 枚举位标志：E 的成员值是位号，掩码最多 64 位。值为单个整数字面量（即掩码），或逗号分隔的成员名
// （不区分大小写，结果为各位之或）；不支持随机语法，解析不消耗随机数。
class aip_cmdline_flags #(type E = int);

    // 来源优先级与 aip_int 相同：override > +path.name > +name；空 override 为 0，未给出取 default_val。
    static function bit [63:0] resolve(string name, string path, bit [63:0] default_val, int nbits,
                                       input string source_file = "", input int source_line = 0);
        string     s;
        bit        is_ov;
        bit [63:0] mask;
        aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(name, path), source_file, source_line);
        if (nbits < 1 || nbits > 64)
            error($sformatf("flags target must be 1..64 bits, got %0d", nbits));
        is_ov = aip_cmdline#(int)::lookup_override(name, path, s);
        if (!is_ov) s = aip_cmdline#(int)::get_cmdline_string(name, path);
        aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(name, path), s);
        if (s == "") mask = is_ov ? '0 : default_val;
        else         mask = parse(s, nbits);
        aip_cmdline_diagnostic::pop();
        return mask;
    endfunction

    // 成员名优先于数字，形如 D0/B1 的成员名不会被当成整数字面量；名称与数字不能混写。
    static function bit [63:0] parse(string s, int nbits);
        string     tokens[$];
        bit [63:0] mask;
        int        pos;
        int        start;
        int        stop;
        aip_cmdline_diagnostic::push_expression(s);
        start = 0;
        forever begin
            stop = aip_str::str_find(s, ",", start);
            if (stop < 0) stop = s.len();
            tokens.push_back((stop == start) ? "" : aip_str::strip(s.substr(start, stop-1)));
            if (stop == s.len()) break;
            start = stop + 1;
        end
        if (tokens.size() == 1 && !find_bit(tokens[0], pos) && literal_mask(tokens[0], nbits, mask)) begin
            aip_cmdline_diagnostic::pop();
            return mask;
        end
        mask = '0;
        foreach (tokens[i]) begin
            if (tokens[i] == "")
                error($sformatf("empty flag name at item[%0d]", i));
            if (!find_bit(tokens[i], pos))
                error($sformatf("unknown flag '%s' (expected one integer mask or names of %s: %s)",
                                tokens[i], $typename(E), all_names()));
            if (pos < 0 || pos >= nbits)
                error($sformatf("flag '%s' is bit %0d, outside the %0d-bit target", tokens[i], pos, nbits));
            mask |= 64'h1 << pos;
        end
        aip_cmdline_diagnostic::pop();
        return mask;
    endfunction

    // 置位的成员名按位号升序以 | 连接；没有成员名的置位位以十六进制余数追加在末尾。
    static function string names(bit [63:0] mask);
        string     s;
        string     by_bit[int];
        bit [63:0] rest;
        E          e;
        e = e.first();
        forever begin
            if (bit_of(e) >= 0) by_bit[bit_of(e)] = e.name();
            if (e == e.last()) break;
            e = e.next();
        end
        rest = mask;
        for (int b = 0; b < 64; b++) begin
            if (!mask[b] || !by_bit.exists(b)) continue;
            s = (s == "") ? by_bit[b] : {s, "|", by_bit[b]};
            rest[b] = 1'b0;
        end
        if (rest != 0) s = (s == "") ? $sformatf("0x%0h", rest) : {s, $sformatf("|0x%0h", rest)};
        return s;
    endfunction

    // 十六进制加成员名，如 0x13 (A|B|E)；零值为 0x0。
    static function string describe(bit [63:0] mask);
        if (mask == 0) return "0x0";
        return $sformatf("0x%0h (%s)", mask, names(mask));
    endfunction

    // 成员值不在 0..63 时返回 -1；按基类型扩展到宽向量再比较，宽基类型的大值不会被截断成合法位号。
    protected static function int bit_of(E e);
        logic [1023:0] v;
        v = e;
        return (v < 64) ? int'(v) : -1;
    endfunction

    protected static function bit find_bit(string token, output int pos);
        string key;
        E      e;
        key = aip_str::lower(token);
        pos = -1;
        e = e.first();
        forever begin
            if (aip_str::lower(e.name()) == key) begin
                pos = bit_of(e);
                return 1;
            end
            if (e == e.last()) break;
            e = e.next();
        end
        return 0;
    endfunction

    // 字面量形式与 aip_int 无符号固定值相同：掩码不接受负数，也不回绕；不是整数字面量返回 0，越界直接 fatal。
    protected static function bit literal_mask(string token, int nbits, output bit [63:0] mask);
        aip_vec_t v;
        int       width;
        bit       negative;
        mask = '0;
        if (!aip_str::str_to_vec(token, v, width, negative)) return 0;
        if ((v >> nbits) != 0)
            error($sformatf("value %s exceeds the %0d-bit target", token, nbits));
        if (width > nbits)
            error($sformatf("explicit width in %s exceeds the %0d-bit target", token, nbits));
        if (negative)
            error($sformatf("negative mask %s; flags are unsigned (allowed 0..%s)", token,
                            (nbits == 64) ? "0xffffffffffffffff" : $sformatf("0x%0h", (64'h1 << nbits) - 1)));
        mask = v[63:0];
        return 1;
    endfunction

    protected static function string all_names();
        string s;
        E      e;
        e = e.first();
        forever begin
            s = (s == "") ? e.name() : {s, ", ", e.name()};
            if (e == e.last()) break;
            e = e.next();
        end
        return s;
    endfunction

    protected static function void error(string msg);
        aip_cmdline_diagnostic::report("AIP_CORE[cmdline_flags] Error", msg, `__FILE__, `__LINE__);
    endfunction
endclass

`endif // AIP_CMDLINE_INTERNAL_INCLUDE
