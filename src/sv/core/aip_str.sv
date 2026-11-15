// 字符串与数值字面量工具：任意宽度整数解析、SV 风格格式化及 real 解析。
`ifndef AIP_STR_SV
`define AIP_STR_SV

typedef string string_darray_t[];

// 任意宽度整数字面量的工作类型 (aip_cmdline 宽位支持)
localparam int AIP_VEC_MAX_BITS = 1024;
typedef bit [AIP_VEC_MAX_BITS-1:0] aip_vec_t;
// 有符号工作类型, 比最宽 T 多 2 bit, 保证 max-min+1 不溢出
typedef bit signed [AIP_VEC_MAX_BITS+1:0] aip_svec_t;

class aip_str;

    // 自实现大小写转换（返回 string），避免 $tolower/$toupper 作用于 byte 时的类型问题。
    static function string char_to_lower(byte c);
        if (c >= "A" && c <= "Z") begin
            return string'(c + 32);
        end else begin
            return string'(c);
        end
    endfunction

    static function string char_to_upper(byte c);
        if (c >= "a" && c <= "z") begin
            return string'(c - 32);
        end else begin
            return string'(c);
        end
    endfunction

	static function string merge_all(string arg[]);
		string result;
		for(int i=0;i<arg.size;i++) begin
			result = {result,arg[i]};
		end
		return result;
    endfunction

	static function string remove_all_spaces(string s);
        string res = "";
        foreach (s[i]) begin
            if (s[i] != 8'd32 && s[i] != 8'd9 && s[i] != 8'd10 && s[i] != 8'd13) begin
                res = {res, s[i]};
            end
        end
        return res;
    endfunction

    static function int str_find(string s, string sub, int start = 0);
        int s_len = s.len();
        int sub_len = sub.len();
        
        if (sub_len == 0 || start < 0 || start >= s_len) return -1;
        if (sub_len > s_len - start) return -1;

        for (int i = start; i <= s_len - sub_len; i++) begin
            bit match = 1;
            for (int j = 0; j < sub_len; j++) begin
                if (s[i+j] != sub[j]) begin
                    match = 0;
                    break;
                end
            end
            if (match) return i;
        end
        return -1;
    endfunction

    static function string strip(string s, string chars = "");
        int start_idx = 0;
        int end_idx = s.len() - 1;
        bit is_whitespace;

        if (chars == "") begin
            while (start_idx <= end_idx) begin
                // VCS Q-2020 bug: s[i] == "\r" matches 'r' (byte 114).
                // Use byte value comparison: space=32, tab=9, LF=10, CR=13
                is_whitespace = (s[start_idx] == 8'd32)  || (s[start_idx] == 8'd9) ||
                                (s[start_idx] == 8'd10)  || (s[start_idx] == 8'd13);
                if (!is_whitespace) break;
                start_idx++;
            end
            while (end_idx >= start_idx) begin
                is_whitespace = (s[end_idx] == 8'd32)  || (s[end_idx] == 8'd9) ||
                                (s[end_idx] == 8'd10)  || (s[end_idx] == 8'd13);
                if (!is_whitespace) break;
                end_idx--;
            end
        end else begin
            while (start_idx <= end_idx) begin
                if (str_find(chars, s.substr(start_idx, start_idx)) == -1) break;
                start_idx++;
            end
            while (end_idx >= start_idx) begin
                if (str_find(chars, s.substr(end_idx, end_idx)) == -1) break;
                end_idx--;
            end
        end

        if (start_idx > end_idx) return "";
        return s.substr(start_idx, end_idx);
    endfunction

    static function string_darray_t split(string s, string sep = "");
        string_darray_t result;
        int start = 0;
        int idx;
        bit is_whitespace;

        if (sep == "") begin
            for (int i = 0; i <= s.len(); i++) begin
                // Byte literals: on VCS Q-2020 `s[i] == "\t"` matches the letter 't'.
                if (i == s.len() || (s[i] == 8'd32) || (s[i] == 8'd9) || (s[i] == 8'd10) || (s[i] == 8'd13)) begin
                    if (i > start) begin
                        result = new[result.size() + 1](result);
                        result[result.size()-1] = s.substr(start, i-1);
                    end
                    start = i + 1;
                end
            end
        end else begin
            while (1) begin
                idx = str_find(s, sep, start);
                if (idx == -1) break;
                result = new[result.size() + 1](result);
                result[result.size()-1] = s.substr(start, idx-1);
                start = idx + sep.len();
            end
            if (start <= s.len()-1) begin
                result = new[result.size() + 1](result);
                result[result.size()-1] = s.substr(start, s.len()-1);
            end
        end
        return result;
    endfunction

    static function string replace(string s, string old_str, string new_str, int count = -1);
        string res = "";
        int start = 0;
        int idx;
        int replace_cnt = 0;

        if (old_str.len() == 0) return s;

        while (1) begin
            idx = str_find(s, old_str, start);
            if (idx == -1 || (count != -1 && replace_cnt >= count)) break;
            
            res = {res, s.substr(start, idx-1), new_str};
            start = idx + old_str.len();
            replace_cnt++;
        end
        res = {res, s.substr(start, s.len()-1)};
        return res;
    endfunction

    static function string lower(string s);
        string res = "";
        foreach (s[i]) begin
            res = {res, char_to_lower(s[i])};
        end
        return res;
    endfunction

    static function string upper(string s);
        string res = "";
        foreach (s[i]) begin
            res = {res, char_to_upper(s[i])};
        end
        return res;
    endfunction

    static function int find(string s, string sub, int start = 0);
        return str_find(s, sub, start);
    endfunction

    static function int index(string s, string sub, int start = 0);
        int idx = find(s, sub, start);
        if (idx == -1) begin
            $fatal(1, "aip_str::index: Substring '%s' not found in '%s'", sub, s);
        end
        return idx;
    endfunction

    static function void print_string_array(string_darray_t arr);
        $write("[");
        foreach (arr[i]) begin
            $write("'%s'", arr[i]);
            if (i != arr.size()-1) $write(", ");
        end
        $write("]\n");
    endfunction


    static function string remove_underscore(string s);
        string res = "";
        foreach (s[i]) begin
            if (s[i] != "_") res = {res, s[i]};
        end
        return res;
    endfunction

    static function bit is_valid_digit(byte c, int radix);
        case (radix)
            2:  return (c == "0" || c == "1");
            8:  return (c >= "0" && c <= "7");
            10: return (c >= "0" && c <= "9");
            16: begin
                return (c >= "0" && c <= "9") || 
                       (c >= "a" && c <= "f") || 
                       (c >= "A" && c <= "F");
            end
            default: return 0;
        endcase
    endfunction

    // 拆分数值字面量（进制/数字串/显式位宽/负号），非法返回 0。
    // 接受：8'b1010、'h5A、100、b110、0x1A3F、0b1010、-10、-0x10、-8'd10。
    local static function bit split_num_literal(string s, output int radix,
                                                output string num_part,
                                                output int width_part,
                                                output bit is_negative);
        string s_clean;
        int idx = 0;
        radix = 10; num_part = ""; width_part = 0; is_negative = 0;
        if (s == "") return 0;

        foreach (s[i]) begin
            if (s[i] != "_") s_clean = {s_clean, char_to_lower(s[i])};
        end
        if (s_clean == "") return 0;
        if (s_clean[0] == "+" || s_clean[0] == "-") begin
            is_negative = (s_clean[0] == "-");
            if (s_clean.len() == 1) return 0;
            s_clean = s_clean.substr(1, s_clean.len()-1);
        end

        // C 风格前缀 0x / 0b / 0o / 0d
        if (s_clean.len() >= 2 && s_clean[0] == "0") begin
            case (s_clean[1])
                "b": begin radix = 2;  num_part = s_clean.substr(2, s_clean.len()-1); end
                "o": begin radix = 8;  num_part = s_clean.substr(2, s_clean.len()-1); end
                "d": begin radix = 10; num_part = s_clean.substr(2, s_clean.len()-1); end
                "x": begin radix = 16; num_part = s_clean.substr(2, s_clean.len()-1); end
                default: ;
            endcase
        end

        if (num_part == "") begin
            if (s_clean[idx] == "'") begin
                // 'b101 / 'h5A
                idx++;
                if (idx >= s_clean.len()) return 0;
                case (s_clean[idx])
                    "b": radix = 2;
                    "o": radix = 8;
                    "d": radix = 10;
                    "h": radix = 16;
                    default: return 0;
                endcase
                idx++;
                num_part = s_clean.substr(idx, s_clean.len()-1);
            end else if (s_clean[idx] inside {["0":"9"]}) begin
                // 8'b1010 / 8b1010 / 纯十进制
                while (idx < s_clean.len() && s_clean[idx] inside {["0":"9"]}) begin
                    width_part = width_part * 10 + (s_clean[idx] - "0");
                    idx++;
                end
                if (idx < s_clean.len() && s_clean[idx] == "'") begin
                    idx++;
                    if (idx >= s_clean.len()) return 0;
                    case (s_clean[idx])
                        "b": radix = 2;
                        "o": radix = 8;
                        "d": radix = 10;
                        "h": radix = 16;
                        default: return 0;
                    endcase
                    idx++;
                    num_part = s_clean.substr(idx, s_clean.len()-1);
                end else if (idx < s_clean.len() && s_clean[idx] inside {"b","o","d","h"}) begin
                    case (s_clean[idx])
                        "b": radix = 2;
                        "o": radix = 8;
                        "d": radix = 10;
                        "h": radix = 16;
                        default: return 0;
                    endcase
                    idx++;
                    num_part = s_clean.substr(idx, s_clean.len()-1);
                end else begin
                    num_part = s_clean;
                    radix = 10;
                    width_part = 0;
                end
            end else if (s_clean[idx] inside {"b","o","d","h"}) begin
                // b110 / h5a
                case (s_clean[idx])
                    "b": radix = 2;
                    "o": radix = 8;
                    "d": radix = 10;
                    "h": radix = 16;
                    default: return 0;
                endcase
                idx++;
                num_part = s_clean.substr(idx, s_clean.len()-1);
                width_part = 0;
            end else begin
                return 0;
            end
        end

        if (num_part == "") return 0;
        foreach (num_part[i]) begin
            if (!is_valid_digit(num_part[i], radix)) return 0;
        end
        return 1;
    endfunction

    // 任意宽度（<= AIP_VEC_MAX_BITS）数值解析：v = 绝对值，width = 显式位宽（无则 0），is_negative = 前导 '-'；
    // 非法字符/空串/显式位宽溢出/超过 1024 bit 返回 0。
    static function bit str_to_vec(string s, output aip_vec_t v, output int width,
                                   output bit is_negative);
        int radix, width_part;
        string num_part;
        aip_vec_t all_ones, limit;
        v = '0; width = 0; is_negative = 0;
        if (!split_num_literal(s, radix, num_part, width_part, is_negative)) return 0;
        all_ones = {AIP_VEC_MAX_BITS{1'b1}};
        limit = all_ones / radix;      // v <= limit 时 v*radix 不溢出
        foreach (num_part[i]) begin
            byte c = num_part[i];
            int digit = (c >= "0" && c <= "9") ? int'(c - "0") : int'(10 + (c - "a"));
            if (v > limit) return 0;
            v = v * radix;
            if (v > all_ones - digit) return 0;
            v = v + digit;
        end
        if (width_part > AIP_VEC_MAX_BITS) return 0;
        if (width_part > 0 && width_part < AIP_VEC_MAX_BITS && (v >> width_part) != 0) return 0;
        width = width_part;
        return 1;
    endfunction

    // 64 位兼容接口：非法返回全 1 且 width=0；无显式位宽时 width = 数字个数（调用方只用它判合法）。
    static function longint unsigned str_to_num(string s, ref int width);
        int radix, width_part, w;
        string num_part;
        bit neg;
        aip_vec_t v;
        width = 0;
        if (!split_num_literal(s, radix, num_part, width_part, neg)) return {64{1'b1}};
        if (!str_to_vec(s, v, w, neg)) return {64{1'b1}};
        if ((v >> 64) != 0) return {64{1'b1}};
        width = (width_part > 0) ? width_part : num_part.len();
        str_to_num = v[63:0];
        if (neg) str_to_num = -str_to_num;
    endfunction

    local static function string to_radix_string(longint unsigned val, int radix);
        string digits = "0123456789abcdef";
        string res = "";
        longint unsigned quotient = val;
        if (val == 0) return "0";
        while (quotient > 0) begin
            int digit = quotient % radix;
            res = {digits[digit], res};
            quotient = quotient / radix;
        end
        return res;
    endfunction

    // 从低位起每 4 位插入下划线。
    local static function string add_underscore(string s);
        string res = "";
        int len = s.len();
        for (int i = 0; i < len; i++) begin
            if (i > 0 && (len - i) % 4 == 0) res = {res, "_"};
            res = {res, s[i]};
        end
        return res;
    endfunction

    // 转为 SV 风格字面量（如 8'h7b）；width<=0 时返回纯十进制，add_score 每 4 位加下划线（十进制除外）。
    static function string num_to_str(longint unsigned value, int width, int radix = 16, bit add_score = 1);
        string radix_letter;
        longint unsigned masked_val;
        string val_str;

        case (radix)
            2:  radix_letter = "b";
            8:  radix_letter = "o";
            10: radix_letter = "d";
            16: radix_letter = "h";
            default: begin
                `aip_error(("Unsupported radix %0d in num_to_str, using hexadecimal", radix));
                radix = 16;
                radix_letter = "h";
            end
        endcase

        if (width <= 0) begin
            return $sformatf("%0d", value);
        end

        if (width >= 64) begin
            masked_val = value;
        end else begin
            masked_val = value & ((64'h1 << width) - 1);
        end

        val_str = to_radix_string(masked_val, radix);

        if (add_score && radix != 10 && val_str.len() > 4) begin
            val_str = add_underscore(val_str);
        end

        return $sformatf("%0d'%s%s", width, radix_letter, val_str);
    endfunction

    static function void help();
        $display("\n=== aip_str Class Help ===");
        $display("This class provides various string manipulation utilities for UVM testbenches.\n");

        $display("--- Basic Character Conversion ---");
        $display("  char_to_lower(byte c) -> string");
        $display("    Convert a single uppercase letter to lowercase; others unchanged.");
        $display("    Example: char_to_lower(\"A\") returns \"a\"\n");

        $display("  char_to_upper(byte c) -> string");
        $display("    Convert a single lowercase letter to uppercase; others unchanged.");
        $display("    Example: char_to_upper(\"b\") returns \"B\"\n");

        $display("--- String Case Conversion ---");
        $display("  lower(string s) -> string");
        $display("    Convert entire string to lowercase.");
        $display("    Example: lower(\"Hello World\") returns \"hello world\"\n");

        $display("  upper(string s) -> string");
        $display("    Convert entire string to uppercase.");
        $display("    Example: upper(\"Hello World\") returns \"HELLO WORLD\"\n");

        $display("--- Searching ---");
        $display("  find(string s, string sub, int start=0) -> int");
        $display("    Find first occurrence of 'sub' in 's' starting from 'start'. Returns index or -1.");
        $display("    Example: find(\"hello world\", \"world\") returns 6\n");

        $display("  index(string s, string sub, int start=0) -> int");
        $display("    Same as find, but fatal if not found.");
        $display("    Example: index(\"hello\", \"ll\") returns 2\n");

        $display("--- Stripping and Splitting ---");
        $display("  strip(string s, string chars=\"\") -> string");
        $display("    Remove leading/trailing whitespace (if chars=\"\") or specified characters.");
        $display("    Example: strip(\"  abc  \") returns \"abc\"\n");

        $display("  split(string s, string sep=\"\") -> string_darray_t");
        $display("    Split string by separator. If sep=\"\", split by whitespace.");
        $display("    Example: split(\"a,b,c\", \",\") returns [\"a\",\"b\",\"c\"]\n");

        $display("  print_string_array(string_darray_t arr)");
        $display("    Print a string array in a readable format.\n");

        $display("--- Replacement ---");
        $display("  replace(string s, string old_str, string new_str, int count=-1) -> string");
        $display("    Replace occurrences of old_str with new_str. count limits replacements.");
        $display("    Example: replace(\"aaabbb\", \"b\", \"c\", 2) returns \"aaaccc\"? Actually returns \"aaaccc\" if count>=3, but with count=2: \"aaaccb\"\n");

        $display("--- Numerical String Parsing (SV & C styles) ---");
        $display("  str_to_num(string s, ref int width) -> int");
        $display("    Parse SV-style or C-style numeric string. Returns value, width via ref.");
        $display("    Supports: 8'b1010, 'h5A, b110, 0x1A3F, 0b1010, 0o77, 0d123, 100, etc.");
        $display("    Returns -1 and width=0 if invalid.");
        $display("    Example: str_to_num(\"12'hABC\", width) returns 2748, width=12\n");

        $display("--- Numerical Value Formatting (SV style) ---");
        $display("  num_to_str(int value, int width, int radix=16, bit add_underscore=1) -> string");
        $display("    Convert integer to SV-style string with given width and radix (2/8/10/16).");
        $display("    width>0: output like <width>'<radix_letter><value> (e.g., 8'h7b)");
        $display("    add_underscore inserts '_' every 4 bits for readability (except decimal).");
        $display("    If width<=0, returns plain decimal string (e.g., \"123\").");
        $display("    Example: num_to_str(123, 8, 16) returns \"8'h7b\"");
        $display("    Example: num_to_str(123, 8, 2, 1) returns \"8'b0111_1011\"\n");

        $display("  str_to_real(string s) -> real");
        $display("    Parse real number from string. Supports integer, decimal, scientific notation.");
        $display("    Example: str_to_real(\"1.5e6\") returns 1500000.0");
        $display("    Example: str_to_real(\"0.85\") returns 0.85\n");

        $display("--- Internal Functions (not typically used) ---");
        $display("  str_find, remove_underscore, is_valid_digit, to_radix_string, add_underscore (local)");
        $display("==========================================\n");
    endfunction

    // 支持整数、小数、科学计数法与负数；非法输入返回 0.0。
    static function real str_to_real(string s);
        real val;
        string cleaned = remove_all_spaces(s);
        int matched;
        if (cleaned == "") begin
            `aip_error(("AIP_CORE[str] empty string for real conversion"));
            return 0.0;
        end
        matched = $sscanf(cleaned, "%g", val);
        if (matched != 1) begin
            `aip_error(("AIP_CORE[str] invalid real format: '%s'", s));
            return 0.0;
        end
        return val;
    endfunction

endclass

`endif // AIP_STR_SV
