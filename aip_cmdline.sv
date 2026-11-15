//===========================================================
// aip_cmdline - 命令行参数解析器
// 支持类型：int, string, real, byte, shortint, longint, bit[N:0], enum, struct
// 依赖：aip_str, uvm_pkg
//
// ===================== 使用说明 =====================
//
// 一、基础类型宏
//
//   1) aip_int(path, rtype, name, default_val)
//      - 解析整数参数，支持 int/byte/shortint/longint/bit[N:0]
//      - 命令行：+path.name=100  +path.name=0xFF  +path.name=[1:10]
//      - 随机模式：范围[min:max], 列表val1,val2, 权重{0:=40,[1:3]:=60}
//      - 递增递减：inc:start:end:step, dec:start:end:step
//      - 示例：
//          int count;
//          `aip_int("dut", int, count, 1)       // +dut.count=10
//          byte reg_val;
//          `aip_int("dut", byte, reg_val, 0)    // +dut.reg_val=8'hAB
//
//   2) aip_string(path, name, default_val)
//      - 解析字符串参数
//      - 命令行：+path.name=hello  +path.name=a,b,c（逗号随机）
//
//   3) aip_real(path, name, default_val)
//      - 解析浮点参数，支持科学计数法
//      - 命令行：+path.name=1.5e6  +path.name=[0.8:1.0]  +path.name=0.8,0.9,1.0
//      - 支持范围/列表/权重/递增递减，与 int 语法一致
//      - 示例：
//          real freq;
//          `aip_real("clk", freq, 100.0e6)      // +clk.freq=156.25e6
//
// 二、数组类型宏
//
//   4) aip_int_list(path, rtype, name, default_val)  - 整数动态数组
//   5) aip_str_list(path, name, default_val)         - 字符串动态数组
//   6) aip_real_list(path, name, default_val)        - 浮点动态数组
//   7) aip_int_slist(path, rtype, name, default_val) - 整数固定数组
//   8) aip_str_slist(path, name, default_val)        - 字符串固定数组
//
// 三、枚举类型宏
//
//   9) aip_enum(path, enum_type, name, default_val)
//      - 自动遍历枚举成员，按名称匹配（大小写不敏感）
//      - 命令行：+path.name=MEMBER（直接指定）
//                +path.name=A,B,C（逗号随机）
//      - 示例：
//          typedef enum { FAST, SLOW, NORMAL } speed_e;
//          speed_e spd;
//          `aip_enum("dut", speed_e, spd, NORMAL)  // +dut.spd=FAST
//
// 四、结构体宏
//
//   10) aip_struct_begin/end + aip_struct_int/string/real/enum
//       - 逐字段声明结构体参数
//       - 紧凑格式：+path.name={field1=val1,field2=val2}
//       - 点号格式：+path.name.field=val（优先级高于紧凑格式）
//       - 示例：
//           typedef struct { int addr; int len; string name; } cfg_t;
//           cfg_t cfg;
//           `aip_struct_begin("dut", cfg)
//               `aip_struct_int(cfg, addr, 0)
//               `aip_struct_int(cfg, len, 64)
//               `aip_struct_string(cfg, name, "x")
//           `aip_struct_end(cfg)
//           // 紧凑：+dut.cfg={addr=0x100,len=64,name=hello}
//           // 点号：+dut.cfg.addr=0xFF
//
// 五、优先级规则（所有类型统一）
//   path.name > name（无路径） > compact format > default
//
//===========================================================
`ifndef AIP_CMDLINE_SV
`define AIP_CMDLINE_SV
import uvm_pkg::*;
`include "uvm_macros.svh"
`include "aip_str.sv"

typedef class aip_cmdline;

//-------------------------------------------------------------------------
// 运行时参数 override 表（非参数化，所有 aip_cmdline#(T) 共享）
// 优先级：override > plusargs(path.name) > plusargs(name) > default
// TCL 通过 set_param/clear_param 命令设置，$stop/run 握手保证读写互斥
//-------------------------------------------------------------------------
class aip_cmdline_override;
    static string table[string];

    static function void set_val(string key, string value);
        table[key] = value;
    endfunction

    // 是否存在该 key —— 区分 "未设置" 与 "设置为空串"（get_val 返回 "" 无法区分）
    static function bit has(string key);
        return table.exists(key);
    endfunction

    static function string get_val(string key);
        if (table.exists(key)) return table[key];
        return "";
    endfunction

    // 导出所有 key —— 供索引数组 override 扫描用（Bug B）
    static function void get_keys(ref string keys[$]);
        keys = {};
        foreach (table[k]) keys.push_back(k);
    endfunction

    static function void clear(string key);
        if (table.exists(key)) table.delete(key);
    endfunction

    static function void clear_all();
        table.delete();
    endfunction
endclass

//-------------------------------------------------------------------------
// aip_cmdline 参数解析器类
//
`define aip_int(path,rtype=int,name,default_val=0) \
    begin \
        aip_cmdline#(rtype)::get_single_value(`"name`", path, default_val, name); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %0d (0x%0h)", `"name`", path, name, name)); \
    end

`define aip_string(path,name,default_val="") \
    begin \
        aip_cmdline#(string)::get_single_value(`"name`", path, default_val, name); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = '%s'", `"name`", path, name)); \
    end

`define aip_int_list(path,rtype=int,name,default_val=0) \
    begin \
        aip_cmdline#(rtype)::get_dynamic_array(`"name`", path,default_val,name); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%0d ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, name.size(), __aip_ps)); end \
    end


`define aip_str_list(path,name,default_val="") \
    begin \
        aip_cmdline#(string)::get_dynamic_array(`"name`", path,default_val,name); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("'%s' ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, name.size(), __aip_ps)); end \
    end

`define aip_int_slist(path,rtype=int,name,default_val=0) \
    begin \
        rtype __val[]; \
        aip_cmdline#(rtype)::parse_value_list(`"name`",path,__val); \
        foreach(name[i]) begin \
            if(i>=__val.size) break; \
            name[i] = __val[i]; \
        end \
        foreach(name[i]) begin \
            if(aip_cmdline#(rtype)::get_cmdline_string($sformatf("%s[%0d]",`"name`",i),path)!="") \
                aip_cmdline#(rtype)::get_single_value($sformatf("%s[%0d]",`"name`",i), path, default_val, name[i]); \
        end \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%0d ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, $size(name), __aip_ps)); end \
    end

`define aip_str_slist(path,name,default_val="") \
    begin \
        string __val[]; \
        aip_cmdline#(string)::parse_value_list(`"name`",path,__val); \
        foreach(name[i]) begin \
            if(i>=__val.size) break; \
            name[i] = __val[i]; \
        end \
        foreach(name[i]) begin \
            if(aip_cmdline#(string)::get_cmdline_string($sformatf("%s[%0d]",`"name`",i),path)!="") \
                aip_cmdline#(string)::get_single_value($sformatf("%s[%0d]",`"name`",i), path, default_val, name[i]); \
        end \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("'%s' ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, $size(name), __aip_ps)); end \
    end

`define aip_real(path,name,default_val=0.0) \
    begin \
        aip_cmdline_real::get_single_value(`"name`", path, default_val, name); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %g", `"name`", path, name)); \
    end

`define aip_real_list(path,name,default_val=0.0) \
    begin \
        aip_cmdline_real::get_dynamic_array(`"name`", path, default_val, name); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%g ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, name.size(), __aip_ps)); end \
    end

`define aip_enum(path, enum_type, _aip_v, default_val) \
    begin \
        string __enum_names[$]; \
        int    __enum_values[$]; \
        enum_type __e_iter = __e_iter.first(); \
        do begin \
            __enum_names.push_back(__e_iter.name()); \
            __enum_values.push_back(int'(__e_iter)); \
            if (__e_iter == __e_iter.last()) break; \
            __e_iter = __e_iter.next(); \
        end while (1); \
        begin \
            string __s = aip_cmdline#(int)::get_cmdline_string(`"_aip_v`", path); \
            if (__s == "") begin \
                _aip_v = default_val; \
            end else begin \
                _aip_v = enum_type'(aip_cmdline_enum::resolve(__s, __enum_names, __enum_values)); \
            end \
        end \
        if (aip_cmdline_print_control::should_print(`"_aip_v`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %s (%0d)", `"_aip_v`", path, _aip_v.name(), _aip_v)); \
    end

// ---- 结构体宏 ----
`define aip_struct_begin(path, name) \
    begin \
        string __struct_path = (path != "") ? {path, ".", `"name`"} : `"name`"; \
        string __compact_str = aip_cmdline#(string)::get_cmdline_string(`"name`", path); \
        string __compact_keys[$]; \
        string __compact_vals[$]; \
        if (__compact_str != "") \
            aip_cmdline_struct::parse_compact(__compact_str, __compact_keys, __compact_vals);

`define aip_struct_int(svar, field, default_val) \
        begin \
            string __cv = ""; \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_cmdline#(int)::parse_value(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                if (__dv != "") \
                    svar.field = aip_cmdline#(int)::parse_value(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %0d (0x%0h)", `"field`", __struct_path, svar.field, svar.field)); \
        end

`define aip_struct_string(svar, field, default_val) \
        begin \
            string __cv = ""; \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_str::strip(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv = aip_cmdline#(string)::get_cmdline_string(`"field`", __struct_path); \
                if (__dv != "") \
                    svar.field = aip_str::strip(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = '%s'", `"field`", __struct_path, svar.field)); \
        end

`define aip_struct_real(svar, field, default_val) \
        begin \
            string __cv = ""; \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_cmdline_real::parse_value(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                if (__dv != "") \
                    svar.field = aip_cmdline_real::parse_value(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %g", `"field`", __struct_path, svar.field)); \
        end

`define aip_struct_enum(enum_type, svar, field, default_val) \
        begin \
            string __enum_names[$]; \
            int    __enum_values[$]; \
            enum_type __e_iter = __e_iter.first(); \
            do begin \
                __enum_names.push_back(__e_iter.name()); \
                __enum_values.push_back(int'(__e_iter)); \
                if (__e_iter == __e_iter.last()) break; \
                __e_iter = __e_iter.next(); \
            end while (1); \
            begin \
                string __cv = ""; \
                foreach (__compact_keys[__fi]) \
                    if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
                if (__cv != "") \
                    svar.field = enum_type'(aip_cmdline_enum::resolve(__cv, __enum_names, __enum_values)); \
                else \
                    svar.field = default_val; \
                begin \
                    string __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                    if (__dv != "") \
                        svar.field = enum_type'(aip_cmdline_enum::resolve(__dv, __enum_names, __enum_values)); \
                end \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %s (%0d)", `"field`", __struct_path, svar.field.name(), svar.field)); \
        end

`define aip_struct_end(name) \
    end


//-------------------------------------------------------------------------
class aip_cmdline #(type T = int);

    static bit global_required = 0; // 全局必填开关，默认非必填

    // 随机模式枚举
    typedef enum { RANGE, WEIGHT_EACH, WEIGHT_TOTAL, INCREMENT, DECREMENT, LIST, SINGLE } rand_mode_t;

    typedef enum { NOT_WRAPPER, VALID_WRAPPER, MALFORMED_WRAPPER } outer_list_wrapper_state_t;

    // 随机描述结构体
    typedef struct {
        rand_mode_t mode;
        int         min, max, step, start, weight;
        int         list_vals[];
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

    static function string get_cmdline_string(string name, string path = "");
        uvm_cmdline_processor clp = uvm_cmdline_processor::get_inst();
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
            $fatal(1, $sformatf("Required parameter +%s (path: %s) not provided", name, path));
        end

        return (vals.size() > 0) ? vals[vals.size()-1] : "";
    endfunction

    protected static function void error(string msg);
        `aip_error(("AIP_CORE[cmdline] parser Error: %s", msg));
        $finish;
    endfunction

    // 判断 T 是否为整数族类型（int, byte, shortint, longint, bit[N:0]）
    protected static function bit is_integer_type();
        string tn = $typename(T);
        return (tn == "int" || tn == "byte" || tn == "shortint" || tn == "longint" ||
                aip_str::str_find(tn, "bit") != -1);
    endfunction

    // 解析单值（根据类型）
    protected static function T parse_single_value(string s);
        if (is_integer_type()) begin
            int width,val;
            val = aip_str::str_to_num(s, width);
            if (val == -1 && width == 0) error($sformatf("Invalid integer format: %s", s));
            return T'(val);
        end else if ($typename(T) == "string") begin
            return aip_str::strip(s);
        end else begin
            error($sformatf("Unsupported type: %s", $typename(T)));
            return T'(0);
        end
    endfunction

    // 解析范围 [min:max]
    protected static function void parse_range(string s, output int min, output int max);
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
        min = parse_single_value(min_str);
        max = parse_single_value(max_str);
        if (min > max) error($sformatf("Range min > max: %s", s));
    endfunction

    // 解析整数列表（逗号分隔）
    protected static function void parse_int_list(string s, output int list[]);
        string parts[] = aip_str::split(aip_str::remove_all_spaces(s), ",");
        list = new[parts.size()];
        foreach (parts[i]) begin
            string p = aip_str::strip(parts[i]);
            if (p == "") error($sformatf("Empty element in list: %s", s));
            list[i] = parse_single_value(p);
        end
    endfunction

    // ---------- 权重解析相关 ----------
    // 解析单个权重项（如 "0:=40" 或 "[1:3]:=60" 或 "[1:5]:/10"）
    protected static function rand_desc_t parse_weight_item(string s);
        rand_desc_t desc;
        int pos_eq,pos_sl,weight_pos,weight_len;
        string left,right;
        pos_eq = aip_str::str_find(s, ":=");
        pos_sl = aip_str::str_find(s, ":/");
        if (pos_eq == -1 && pos_sl == -1)
            error($sformatf("Invalid weight format (missing := or :/): %s", s));

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
        desc.weight = parse_single_value(right);

        // 解析左侧（可能是范围或单个值）
        if (left.len() >= 3 && left[0] == "[" && left[left.len()-1] == "]") begin
            parse_range(left, desc.min, desc.max);
        end else begin
            desc.min = parse_single_value(left);
            desc.max = desc.min;
        end
        return desc;
    endfunction

    // 解析多个权重项（逗号分隔），返回描述数组
    protected static function void parse_weight_items(string s, output rand_desc_t desc_list[]);
        string parts[] = aip_str::split(aip_str::remove_all_spaces(s), ",");
        desc_list = new[parts.size()];
        foreach (parts[i]) begin
            string part = aip_str::strip(parts[i]);
            if (part == "") error($sformatf("Empty weight item in group: %s", s));
            desc_list[i] = parse_weight_item(part);
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

    // 从权重组中随机选择一个值
    protected static function T get_weighted_group_value(rand_desc_t desc_list[]);
        int r,accum;
        int total_weight = 0;
        
        foreach (desc_list[i]) begin
            if (desc_list[i].mode == WEIGHT_EACH)
                total_weight += (desc_list[i].max - desc_list[i].min + 1) * desc_list[i].weight;
            else
                total_weight += desc_list[i].weight;
        end

        r = $urandom_range(total_weight-1);
        accum = 0;
        foreach (desc_list[i]) begin
            if (desc_list[i].mode == WEIGHT_EACH) begin
                int block_weight = (desc_list[i].max - desc_list[i].min + 1) * desc_list[i].weight;
                if (r < accum + block_weight) begin
                    int idx = (r - accum) / desc_list[i].weight;
                    return T'(desc_list[i].min + idx);
                end
                accum += block_weight;
            end else begin
                if (r < accum + desc_list[i].weight) begin
                    return T'(desc_list[i].min + $urandom_range(desc_list[i].max - desc_list[i].min));
                end
                accum += desc_list[i].weight;
            end
        end
        error("Weighted group selection failed");
        return T'(0);
    endfunction

    // 解析 inc/dec
    protected static function void parse_inc_dec(string s, bit is_inc, output rand_desc_t desc);
        string cleaned = aip_str::remove_all_spaces(s);
        string remain = cleaned.substr(4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        if (tokens.size() < 2) error($sformatf("Invalid inc/dec format: %s", s));

        desc.mode = is_inc ? INCREMENT : DECREMENT;
        desc.start = parse_single_value(tokens[0]);
        desc.max = parse_single_value(tokens[1]);
        desc.step = (tokens.size() >= 3) ? parse_single_value(tokens[2]) : 1;

        if (is_inc && desc.start > desc.max) error("Increment start > end");
        if (!is_inc && desc.start < desc.max) error("Decrement start < end");
    endfunction

    // 解析随机描述（非权重组）
    protected static function rand_desc_t parse_rand_desc(string s);
        rand_desc_t desc;
        s = strip_outer_list_wrapper(s);

        if (aip_str::str_find(s, ":=") != -1 || aip_str::str_find(s, ":/") != -1) begin
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
        int val;
        if (!is_integer_type()) begin
            error("Random mode only supported for int type");
        end

        case (desc.mode)
            SINGLE:   val = desc.min;
            RANGE:    val = desc.min + $urandom_range(desc.max - desc.min);
            LIST:     val = desc.list_vals[$urandom_range(desc.list_vals.size()-1)];
            INCREMENT: begin
                int cnt = ((desc.max - desc.start) / desc.step) + 1;
                val = desc.start + $urandom_range(cnt-1) * desc.step;
            end
            DECREMENT: begin
                int cnt = ((desc.start - desc.max) / desc.step) + 1;
                val = desc.start - $urandom_range(cnt-1) * desc.step;
            end
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

    // ---------- 解析单个值（支持随机/权重/权重组）----------
    static function T parse_value(string s);
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

    // ---------- 解析 size 字符串（仅单值/范围/列表）----------
    static function void parse_value_list(string name,string path,output T val_list[]);
        string parts[];
        string s = get_cmdline_string(name, path);
        if (s == "") begin
            return;
        end
        split_overall_string(s, parts);
        if(parts.size == 0) begin
            return;
        end
        else begin
            val_list = new[parts.size];
            foreach(parts[i]) begin
                val_list[i] = parse_value(parts[i]);
            end
        end

    endfunction

    // ---------- 获取所有命令行参数 ----------
    protected static function void get_all_cmdline_args(ref string args[$]);
        uvm_cmdline_processor clp = uvm_cmdline_processor::get_inst();
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

    // ---------- 公共接口：获取单值 ----------
    static function void get_single_value(string name, string path, T default_val, ref T val);
        string parts[];
        string s;
        bit    is_ov;

        is_ov = lookup_override(name, path, s);   // 命中则 s=override 值(可能空串)
        if (!is_ov)
            s = get_cmdline_string(name, path);   // 未命中 override -> plusargs

        if (is_ov) begin
            // override = 强制确定值: 空 -> 空/零(Bug A); 非空 -> 字面解析, 不 split/不随机(Bug C)
            if (s == "") begin
                T zero;                           // int->0, string->"" (默认初始化, 免 T' cast)
                val = zero;
                return;
            end
            val = parse_single_value(s);
            return;
        end
        if (s == "") begin
            val = default_val;
            return;
        end
        split_overall_string(s, parts);
        if(parts.size == 0) begin
            val = default_val;
            return;
        end
        else begin
            int idx=$urandom_range(0,parts.size-1);
            val = parse_value(parts[idx]);
        end

    endfunction

    // ---------- 获取动态数组（支持 .size 和索引赋值）----------
    static function void get_dynamic_array(
        string name, string path,
        T default_val,
        ref T arr[]
    );
        string size_str;
        int size;
        string overall_str;
        T overall_vals[];
        int index_vals[int];
        string index_strs[int];
        int no_path_vals[int];
        string no_path_strs[int];
        int max_idx = -1;

        // 1. 获取 .size 参数
        size_str = get_cmdline_string({name , ".size"}, path);
        if (size_str != "") begin
            size = parse_value(size_str);
        end else begin
            size = -1;  // 待定
        end

        // 2. 获取整体赋值
        overall_str = get_cmdline_string(name, path);
        if (overall_str != "") begin
            string parts[];
            split_overall_string(overall_str, parts);
            overall_vals = new[parts.size()];
            foreach (parts[i]) begin
                if (parts[i] == "") error("Empty element in overall array assignment");
                overall_vals[i] = parse_value(parts[i]);
            end
        end

        // 3. 收集索引赋值, 优先级 override(full) > override(leaf) > plusarg(path) > plusarg(leaf) — Bug B
        begin
            int    ov_p_v[int]; string ov_p_s[int];
            int    ov_l_v[int]; string ov_l_s[int];
            int    pa_p_v[int]; string pa_p_s[int];

            collect_indexed_overrides(name, path, ov_p_v, ov_p_s);     // override 全名 prefix
            collect_indexed_overrides(name, "",   ov_l_v, ov_l_s);     // override leaf prefix
            if (path != "")
                collect_indexed_assignments(name, path, pa_p_v, pa_p_s); // plusarg 全名 prefix
            collect_indexed_assignments(name, "", no_path_vals, no_path_strs); // plusarg leaf prefix

            // 高优先级先填, 已存在不覆盖
            foreach (ov_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_p_s[i];       end
            foreach (ov_l_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=ov_l_s[i];       end
            foreach (pa_p_v[i])       if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=pa_p_s[i];       end
            foreach (no_path_vals[i]) if (!index_vals.exists(i)) begin index_vals[i]=i; index_strs[i]=no_path_strs[i]; end
        end
        foreach (index_vals[i]) begin
            if (i > max_idx) max_idx = i;
        end

        // 4. 确定数组大小
        if (size == -1) begin
            if (overall_vals.size() > 0) begin
                size = overall_vals.size();
            end else if (max_idx >= 0) begin
                size = max_idx + 1;
            end else begin
                arr = new[0];
                return;
            end
        end else begin
        end

        // 5. 分配并初始化
        arr = new[size];
        for (int i = 0; i < size; i++) begin
            if (is_integer_type()) begin
                arr[i] = default_val;
            end else if ($typename(T) == "string") begin
                arr[i] = default_val;
            end else begin
                error($sformatf("Unsupported type: %s", $typename(T)));
            end
        end

        // 6. 应用整体赋值
        if (overall_vals.size() > 0) begin
            int copy_len = (overall_vals.size() < size) ? overall_vals.size() : size;
            for (int i = 0; i < copy_len; i++) arr[i] = overall_vals[i];
        end

        // 7. 应用索引赋值（覆盖）
        foreach (index_vals[i]) begin
            if (i >= size) begin
                continue;
            end
            else begin
                arr[i] = parse_value(index_strs[i]);
            end
        end
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_enum - 枚举命令行解析辅助类
//-------------------------------------------------------------------------
class aip_cmdline_enum;

    // 解析枚举字符串，返回匹配的 int 值
    // 支持直接指定（FAST_MODE）或逗号分隔随机（FAST_MODE,SLOW_MODE）
    // 大小写不敏感
    static function int resolve(string s, string names[$], int values[$]);
        string cleaned = aip_str::strip(s);
        string parts[];

        if (cleaned == "") begin
            `aip_error(("AIP_CORE[cmdline_enum] Error: empty enum string"));
            $finish;
        end

        // 检查是否包含逗号（随机模式）
        if (aip_str::str_find(cleaned, ",") != -1) begin
            parts = aip_str::split(cleaned, ",");
        end else begin
            parts = new[1];
            parts[0] = cleaned;
        end

        // 随机选一个候选
        begin
            int idx = $urandom_range(parts.size()-1);
            string candidate = aip_str::lower(aip_str::strip(parts[idx]));

            foreach (names[i]) begin
                if (aip_str::lower(names[i]) == candidate) begin
                    return values[i];
                end
            end

            // 匹配失败
            `aip_error(("AIP_CORE[cmdline_enum] Error: '%s' not found in enum", parts[idx]));
            foreach (names[i]) $display("  - %s", names[i]);
            $finish;
            return 0;
        end
    endfunction

endclass

//-------------------------------------------------------------------------
// aip_cmdline_real - real 类型命令行解析类（独立于参数化类，兼容 VCS）
//-------------------------------------------------------------------------
class aip_cmdline_real;

    protected static function void error(string msg);
        `aip_error(("AIP_CORE[cmdline_real] parser Error: %s", msg));
        $finish;
    endfunction

    // 解析 real 范围 [min:max] 或 min:max
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

        rmin = aip_str::str_to_real(min_str);
        rmax = aip_str::str_to_real(max_str);
        if (rmin > rmax) error($sformatf("Real range min > max: %s", s));
    endfunction

    // 解析 real inc/dec（如 inc:0.1:1.0:0.1）
    protected static function real parse_real_inc_dec(string s, bit is_inc);
        string cleaned = aip_str::remove_all_spaces(s);
        string remain = cleaned.substr(4, cleaned.len()-1);
        string tokens[] = aip_str::split(remain, ":");
        real start_val, end_val, step_val;
        int cnt;

        if (tokens.size() < 2) error($sformatf("Invalid real inc/dec format: %s", s));

        start_val = aip_str::str_to_real(tokens[0]);
        end_val   = aip_str::str_to_real(tokens[1]);
        step_val  = (tokens.size() >= 3) ? aip_str::str_to_real(tokens[2]) : 1.0;

        if (step_val <= 0.0) error("Real inc/dec step must be > 0");
        if (is_inc && start_val > end_val) error("Real increment start > end");
        if (!is_inc && start_val < end_val) error("Real decrement start < end");

        if (is_inc)
            cnt = int'((end_val - start_val) / step_val) + 1;
        else
            cnt = int'((start_val - end_val) / step_val) + 1;

        if (is_inc)
            return start_val + $urandom_range(cnt-1) * step_val;
        else
            return start_val - $urandom_range(cnt-1) * step_val;
    endfunction

    // 解析 real 权重组 {val:=w, [min:max]:/w, ...}
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

            if (wpos == -1) error($sformatf("Invalid real weight format: %s", p));

            left  = aip_str::strip(p.substr(0, wpos-1));
            right = aip_str::strip(p.substr(wpos+2, p.len()-1));
            weights[i] = int'(aip_str::str_to_real(right));

            if (left.len() >= 3 && left[0] == "[" && left[left.len()-1] == "]") begin
                parse_real_range(left, mins[i], maxs[i]);
            end else begin
                mins[i] = aip_str::str_to_real(left);
                maxs[i] = mins[i];
            end
        end

        foreach (weights[i]) total_weight += weights[i];

        r = $urandom_range(total_weight - 1);
        accum = 0;
        foreach (weights[i]) begin
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

    // 解析 real 值（支持范围/列表/权重/inc-dec/单值）
    static function real parse_value(string s);
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
            return aip_str::str_to_real(aip_str::strip(rparts[idx]));
        end
        // 无括号范围 min:max
        else if (aip_str::str_find(s, ":") != -1) begin
            real rmin, rmax;
            parse_real_range(s, rmin, rmax);
            return rmin + (rmax - rmin) * ($urandom() / 4294967296.0);
        end
        // 单值
        else begin
            return aip_str::str_to_real(s);
        end
    endfunction

    // 获取单个 real 值
    static function void get_single_value(string name, string path, real default_val, ref real val);
        string s;
        bit    is_ov;
        is_ov = aip_cmdline#(int)::lookup_override(name, path, s);
        if (!is_ov)
            s = aip_cmdline#(int)::get_cmdline_string(name, path);
        if (is_ov) begin
            // override = 强制确定值: 空 -> 0.0(Bug A); 非空 -> 字面 real, 不随机(Bug C)
            val = (s == "") ? 0.0 : aip_str::str_to_real(aip_str::remove_all_spaces(s));
            return;
        end
        if (s == "") begin
            val = default_val;
            return;
        end
        s = aip_str::remove_all_spaces(s);
        val = parse_value(s);
    endfunction

    // 获取 real 动态数组
    static function void get_dynamic_array(string name, string path, real default_val, ref real arr[]);
        string size_str;
        int size;
        string overall_str;
        real overall_vals[];
        string parts[];

        // 1. 获取 .size
        size_str = aip_cmdline#(int)::get_cmdline_string({name, ".size"}, path);
        if (size_str != "") begin
            int width;
            size = aip_str::str_to_num(aip_str::remove_all_spaces(size_str), width);
        end else begin
            size = -1;
        end

        // 2. 获取整体赋值
        overall_str = aip_cmdline#(int)::get_cmdline_string(name, path);
        if (overall_str != "") begin
            string cleaned = aip_str::remove_all_spaces(overall_str);
            // 使用 aip_cmdline 的智能分割
            aip_cmdline#(int)::split_array_elements(cleaned, parts);
            foreach (parts[i]) parts[i] = aip_str::strip(parts[i]);
            overall_vals = new[parts.size()];
            foreach (parts[i]) begin
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

    // 解析紧凑格式 {key=val,key=val,...}
    // 返回 keys 和 vals 队列
    static function void parse_compact(string s, ref string keys[$], ref string vals[$]);
        string inner;
        int eq_pos;

        keys = {};
        vals = {};

        // 去除外层 { }
        s = aip_str::strip(s);
        if (s.len() < 2 || s[0] != "{" || s[s.len()-1] != "}") begin
            `aip_error(("AIP_CORE[cmdline_struct] Error: compact format must be wrapped in {}: %s", s));
            $finish;
        end
        inner = s.substr(1, s.len()-2);
        if (inner == "") return;

        // 逐段解析 key=val,key=val,...（避免 split 动态数组 resize 问题）
        begin
            int start = 0;
            int comma_pos, inner_len;
            inner_len = inner.len();
            while (start < inner_len) begin
                string segment;
                comma_pos = aip_str::str_find(inner, ",", start);
                if (comma_pos == -1)
                    segment = inner.substr(start, inner_len - 1);
                else
                    segment = inner.substr(start, comma_pos - 1);
                segment = aip_str::strip(segment);
                eq_pos = aip_str::str_find(segment, "=");
                if (eq_pos > 0 && eq_pos < segment.len()-1) begin
                    keys.push_back(segment.substr(0, eq_pos-1));
                    vals.push_back(segment.substr(eq_pos+1, segment.len()-1));
                end
                if (comma_pos == -1) break;
                start = comma_pos + 1;
            end
        end
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

//-------------------------------------------------------------------------
// 测试模块（包含新权重语法）
//-------------------------------------------------------------------------
`ifdef AIP_CMDLINE_TEST
module test_param_parser_full;

    typedef enum { FAST_MODE, SLOW_MODE, NORMAL_MODE } test_mode_e;
    typedef struct {
        int    addr;
        int    len;
        string name;
        real   freq;
        test_mode_e mode;
    } test_cfg_t;

    initial begin
        real real_plain;
        real real_range;
        real real_list;
        real real_sci;
        real real_arr[];
        byte byte_val;
        bit [7:0] bit8_val;
        int int_plain;
        int int_hex;
        int int_bin;
        int int_range;
        int int_list;
        int int_weight;
        int int_inc;
        int int_dec;
        int val_int;
        string str_list;
        string str_plain;
        string str_with_spaces;
        int val_enum;
        int int_array[];
        string str_array[];
        int dyn_arr2[];
        int dyn_arr[];
        int sarray[10];
        string colors[] = {"RED","GREEN","BLUE"};
        int cvals[] = '{0,1,2};

        $display("=====================================");
        $display("========== 测试1：单个int参数 ==========");
        $display("=====================================");
        `aip_int("int_plain",int, int_plain,2);
        $display("int_plain (100) → %0d", int_plain);
        `aip_int("int_hex", int, int_hex,0);
        $display("int_hex (0x7F) → %0d", int_hex);
        `aip_int("int_bin", int, int_bin);
        $display("int_bin (0b1010) → %0d", int_bin);
        `aip_int("int_range", int, int_range);
        $display("int_range ([1:10]) → %0d", int_range);
        `aip_int("int_list", int, int_list);
        $display("int_list (10,20,30) → %0d", int_list);
        `aip_int("int_weight", int, int_weight);   // 单个权重项
        $display("int_weight (0:=40) → %0d", int_weight);
        `aip_int("int_inc", int, int_inc);
        $display("int_inc (inc:0:10:2) → %0d", int_inc);
        `aip_int("int_dec", int, int_dec);
        $display("int_dec (dec:10:0:2) → %0d", int_dec);

        $display("\n=====================================");
        $display("========== 测试2：单个string参数 =========");
        $display("=====================================");
        `aip_string("str_plain", str_plain ,"default");
        $display("str_plain (hello_world) → '%s'", str_plain);
        `aip_string("str_list", str_list, "default");
        $display("str_list (apple,banana,orange) → '%s'", str_list);
        `aip_string("str_with_spaces",str_with_spaces, "default");
        $display("str_with_spaces ('hello world') → '%s'", str_with_spaces);

        $display("\n=====================================");
        $display("========== 测试4：int数组（包含复合权重）======");
        $display("=====================================");
        `aip_int_list("int_array", int, int_array);
        $write("int_array (1,2,[8:9],10:20,{0:=40,[1:3]:=60},([1:5]:/10),100) → ");
        foreach (int_array[i]) $write("%0d ", int_array[i]);
        $display("");
        $display("数组长度（预期7）→ %0d", int_array.size());

        $display("\n=====================================");
        $display("========== 测试5：string数组 ==========");
        $display("=====================================");
        `aip_str_list("str_array", str_array);
        $write("str_array (aaa,bbb,ccc,hello world) → ");
        foreach (str_array[i]) $write("'%s' ", str_array[i]);
        $display("");
        $display("数组长度（预期4）→ %0d", str_array.size());

        $display("\n=====================================");
        $display("========== 测试6：路径优先 ==========");
        $display("=====================================");
        `aip_int("path_param", int, val_int);
        $display("path_param (无路径) → %0d", val_int);
        `aip_int("path_param", int, val_int);
        $display("path_param (path=top) → %0d", val_int);

        $display("\n=====================================");
        $display("========== 测试7：后定义覆盖 ==========");
        $display("=====================================");
        `aip_int("cover_param", int, val_int);
        $display("cover_param (后定义200覆盖100) → %0d", val_int);

        $display("\n=====================================");
        $display("========== 测试8：全局必填开关 =========");
        $display("=====================================");
        `aip_int("non_exist", int, val_int,999);
        $display("non_exist (关闭必填，返回默认值999) → %0d", val_int);
        aip_cmdline#(int)::global_required = 1;
        $display("开启全局必填，访问不存在的参数会触发Fatal（以下是预期报错）");
        // `aip_int("non_exist", "", 0, val_int); // 取消注释验证报错
        aip_cmdline#(int)::global_required = 0;

        $display("\n=====================================");
        $display("========== 测试9：动态数组 with .size =========");
        $display("=====================================");
        `aip_int_list("dyn_array", int, dyn_arr);
        $write("dyn_array (size=[3:5], overall=1,2,3, index[1]=[10:20]) → ");
        foreach (dyn_arr[i]) $write("%0d ", dyn_arr[i]);
        $display("");

        $display("\n=====================================");
        $display("========== 测试10：动态数组 without .size =========");
        $display("=====================================");
        `aip_int_slist("",int, sarray,1)
        $write("sarray (overall=1,2,3,4,5) → ");
        foreach (sarray[i]) $write("%0d ", sarray[i]);
        $display("");

        // ========== 测试11：real 类型 ==========
        $display("\n=====================================");
        $display("========== 测试11：real参数 ==========");
        $display("=====================================");
        `aip_real("", real_plain, 0.0)
        $display("real_plain → %g", real_plain);
        `aip_real("", real_sci, 100.0e6)
        $display("real_sci → %g", real_sci);
        `aip_real("", real_range, 0.0)
        $display("real_range ([0.8:1.0]) → %g", real_range);
        `aip_real("", real_list, 0.0)
        $display("real_list (0.8,0.9,1.0) → %g", real_list);

        // ========== 测试12：real 数组 ==========
        $display("\n=====================================");
        $display("========== 测试12：real数组 ==========");
        $display("=====================================");
        `aip_real_list("", real_arr, 0.0)
        $write("real_arr → ");
        foreach (real_arr[i]) $write("%g ", real_arr[i]);
        $display("");

        // ========== 测试13：byte 类型 ==========
        $display("\n=====================================");
        $display("========== 测试13：byte参数 ==========");
        $display("=====================================");
        `aip_int("", byte, byte_val, 0)
        $display("byte_val → %0d", byte_val);
        `aip_int("", bit[7:0], bit8_val, 0)
        $display("bit8_val → %0d", bit8_val);

        // ========== 测试14：enum 类型 ==========
        $display("\n=====================================");
        $display("========== 测试14：enum参数 ==========");
        $display("=====================================");
        begin
            test_mode_e test_mode;
            `aip_enum("", test_mode_e, test_mode, NORMAL_MODE)
            $display("test_mode → %s (%0d)", test_mode.name(), test_mode);
        end

        // ========== 测试15：struct 类型 ==========
        $display("\n=====================================");
        $display("========== 测试15：struct参数 ==========");
        $display("=====================================");
        begin
            test_cfg_t test_cfg;
            `aip_struct_begin("", test_cfg)
                `aip_struct_int(test_cfg, addr, 0)
                `aip_struct_int(test_cfg, len, 64)
                `aip_struct_string(test_cfg, name, "default")
                `aip_struct_real(test_cfg, freq, 100.0e6)
                `aip_struct_enum(test_mode_e, test_cfg, mode, NORMAL_MODE)
            `aip_struct_end(test_cfg)
            $display("test_cfg.addr → 0x%0h", test_cfg.addr);
            $display("test_cfg.len  → %0d", test_cfg.len);
            $display("test_cfg.name → '%s'", test_cfg.name);
            $display("test_cfg.freq → %g", test_cfg.freq);
            $display("test_cfg.mode → %s", test_cfg.mode.name());
        end

        $display("\n=====================================");
        $display("========== 所有测试完成 ==========");
        $display("=====================================");
        $finish;
    end
endmodule
`endif // AIP_CMDLINE_TEST

`endif // AIP_CMDLINE_SV
