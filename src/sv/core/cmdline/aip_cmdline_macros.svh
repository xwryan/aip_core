// aip_cmdline 用户宏：基础类型、列表、旧版 struct 及 primitive queue 入口；用法与随机化语法见 README §4。
// 内部 include 片段：只允许 aip_cmdline.sv 在其 include 窗口加载，拒绝直接包含以免创建第二份 $unit/package 类型。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
// 例：`aip_int("dut", int, count, 1) 把 +dut.count=10 读入 count（变量名即参数名），未给出时取 1。
`define aip_int(path,rtype=int,name,default_val=0) \
    begin \
        aip_cmdline#(rtype)::get_single_value(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %0d (0x%0h)", `"name`", path, name, name)); \
    end

// 无符号参数：先拒绝负数字面量再按 aip_int 读取（aip_int 把 -1 读成全 1，适合位掩码，不适合计数/地址/ID）。
`define aip_uint(path,rtype,name,default_val=0) \
    begin \
        string _aip_raw; \
        _aip_raw = aip_cmdline#(rtype)::get_cmdline_string(`"name`", path); \
        if (aip_str::str_find(_aip_raw, "-") >= 0) \
            aip_cmdline_diagnostic::report("[AIP_CMDLINE]", \
                $sformatf("%s.%s requires an unsigned value: %s", path, `"name`", _aip_raw), \
                `__FILE__, `__LINE__); \
        `aip_int(path, rtype, name, default_val) \
    end

`define aip_string(path,name,default_val="") \
    begin \
        aip_cmdline#(string)::get_single_value(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = '%s'", `"name`", path, name)); \
    end

`define aip_int_list(path,rtype=int,name,default_val=0) \
    begin \
        aip_cmdline#(rtype)::get_dynamic_array(`"name`", path,default_val,name, `__FILE__, `__LINE__); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%0d ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] %s= %s", `"name`", path, name.size(), aip_cmdline#(rtype)::last_array_ctrl, __aip_ps)); end \
    end


`define aip_str_list(path,name,default_val="") \
    begin \
        aip_cmdline#(string)::get_dynamic_array(`"name`", path,default_val,name, `__FILE__, `__LINE__); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("'%s' ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] %s= %s", `"name`", path, name.size(), aip_cmdline#(string)::last_array_ctrl, __aip_ps)); end \
    end

`define aip_int_slist(path,rtype=int,name,default_val=0) \
    begin \
        rtype __aip_sv[]; \
        aip_cmdline#(rtype)::resolve_array(`"name`", path, default_val, $size(name), __aip_sv, `__FILE__, `__LINE__); \
        foreach (name[__i]) name[__i] = __aip_sv[__i]; \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%0d ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] %s= %s", `"name`", path, $size(name), aip_cmdline#(rtype)::last_array_ctrl, __aip_ps)); end \
    end

`define aip_str_slist(path,name,default_val="") \
    begin \
        string __aip_sv[]; \
        aip_cmdline#(string)::resolve_array(`"name`", path, default_val, $size(name), __aip_sv, `__FILE__, `__LINE__); \
        foreach (name[__i]) name[__i] = __aip_sv[__i]; \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("'%s' ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] %s= %s", `"name`", path, $size(name), aip_cmdline#(string)::last_array_ctrl, __aip_ps)); end \
    end

`define aip_real(path,name,default_val=0.0) \
    begin \
        aip_cmdline_real::get_single_value(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %g", `"name`", path, name)); \
    end

// real 列表只读 .size 与整体列表，不支持 .each/.unique/.sort、seq/perm 及索引覆盖。
`define aip_real_list(path,name,default_val=0.0) \
    begin \
        aip_cmdline_real::get_dynamic_array(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%g ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, name.size(), __aip_ps)); end \
    end

// 查询参数前先建立用户来源，缺失必填值与枚举转换失败共用此上下文。
// 宏可能展开在静态过程作用域，候选队列重置与赋值必须在每次执行时进行。
`define aip_enum(path, enum_type, _aip_v, default_val) \
    begin \
        string __enum_names[$]; \
        int    __enum_values[$]; \
        enum_type __e_iter; \
        __enum_names.delete(); \
        __enum_values.delete(); \
        __e_iter = __e_iter.first(); \
        do begin \
            __enum_names.push_back(__e_iter.name()); \
            __enum_values.push_back(int'(__e_iter)); \
            if (__e_iter == __e_iter.last()) break; \
            __e_iter = __e_iter.next(); \
        end while (1); \
        begin \
            string __s; \
            aip_cmdline_diagnostic::push(aip_cmdline_diagnostic::full_name(`"_aip_v`", path), `__FILE__, `__LINE__); \
            __s = aip_cmdline#(int)::get_cmdline_string(`"_aip_v`", path); \
            aip_cmdline_diagnostic::select_value(aip_cmdline_diagnostic::full_name(`"_aip_v`", path), __s); \
            if (__s == "") begin \
                _aip_v = default_val; \
            end else begin \
                _aip_v = enum_type'(aip_cmdline_enum::resolve(__s, __enum_names, __enum_values)); \
            end \
            aip_cmdline_diagnostic::pop(); \
        end \
        if (aip_cmdline_print_control::should_print(`"_aip_v`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %s (%0d)", `"_aip_v`", path, _aip_v.name(), _aip_v)); \
    end

// 旧版逐字段结构体宏（新代码推荐 schema API）：紧凑值 +path.name={field=v,...} 先赋，点号 +path.name.field=v 再覆盖。
// begin/end 之间可执行任意用户代码，故诊断栈只在同步查询/解析期间保留。
// 配置查询不能放入声明初始化式：module initial 内的静态初始化可能早于用户 set_val。
`define aip_struct_begin(path, name) \
    begin \
        string __struct_path; \
        string __compact_str; \
        string __compact_keys[$]; \
        string __compact_vals[$]; \
        __struct_path = (path != "") ? {path, ".", `"name`"} : `"name`"; \
        __compact_keys.delete(); \
        __compact_vals.delete(); \
        aip_cmdline_diagnostic::push(__struct_path, `__FILE__, `__LINE__); \
        __compact_str = aip_cmdline#(string)::get_cmdline_string(`"name`", path); \
        aip_cmdline_diagnostic::select_value(__struct_path, __compact_str); \
        if (__compact_str != "") \
            aip_cmdline_struct::parse_compact(__compact_str, __compact_keys, __compact_vals); \
        aip_cmdline_diagnostic::pop();

`define aip_struct_int(svar, field, default_val) \
        begin \
            string __cv; \
            __cv = ""; \
            aip_cmdline_diagnostic::push({__struct_path, ".", `"field`"}, `__FILE__, `__LINE__); \
            aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __compact_str); \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_cmdline#(int)::parse_value(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv; \
                __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __dv); \
                if (__dv != "") \
                    svar.field = aip_cmdline#(int)::parse_value(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %0d (0x%0h)", `"field`", __struct_path, svar.field, svar.field)); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_struct_string(svar, field, default_val) \
        begin \
            string __cv; \
            __cv = ""; \
            aip_cmdline_diagnostic::push({__struct_path, ".", `"field`"}, `__FILE__, `__LINE__); \
            aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __compact_str); \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_str::strip(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv; \
                __dv = aip_cmdline#(string)::get_cmdline_string(`"field`", __struct_path); \
                if (__dv != "") \
                    svar.field = aip_str::strip(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = '%s'", `"field`", __struct_path, svar.field)); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_struct_real(svar, field, default_val) \
        begin \
            string __cv; \
            __cv = ""; \
            aip_cmdline_diagnostic::push({__struct_path, ".", `"field`"}, `__FILE__, `__LINE__); \
            aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __compact_str); \
            foreach (__compact_keys[__fi]) \
                if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
            if (__cv != "") \
                svar.field = aip_cmdline_real::parse_value(__cv); \
            else \
                svar.field = default_val; \
            begin \
                string __dv; \
                __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __dv); \
                if (__dv != "") \
                    svar.field = aip_cmdline_real::parse_value(__dv); \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %g", `"field`", __struct_path, svar.field)); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_struct_enum(enum_type, svar, field, default_val) \
        begin \
            string __enum_names[$]; \
            int    __enum_values[$]; \
            enum_type __e_iter; \
            __enum_names.delete(); \
            __enum_values.delete(); \
            __e_iter = __e_iter.first(); \
            aip_cmdline_diagnostic::push({__struct_path, ".", `"field`"}, `__FILE__, `__LINE__); \
            aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __compact_str); \
            do begin \
                __enum_names.push_back(__e_iter.name()); \
                __enum_values.push_back(int'(__e_iter)); \
                if (__e_iter == __e_iter.last()) break; \
                __e_iter = __e_iter.next(); \
            end while (1); \
            begin \
                string __cv; \
                __cv = ""; \
                foreach (__compact_keys[__fi]) \
                    if (__compact_keys[__fi] == `"field`") begin __cv = __compact_vals[__fi]; break; end \
                if (__cv != "") \
                    svar.field = enum_type'(aip_cmdline_enum::resolve(__cv, __enum_names, __enum_values)); \
                else \
                    svar.field = default_val; \
                begin \
                    string __dv; \
                    __dv = aip_cmdline#(int)::get_cmdline_string(`"field`", __struct_path); \
                    aip_cmdline_diagnostic::select_value({__struct_path, ".", `"field`"}, __dv); \
                    if (__dv != "") \
                        svar.field = enum_type'(aip_cmdline_enum::resolve(__dv, __enum_names, __enum_values)); \
                end \
            end \
            if (aip_cmdline_print_control::should_print(`"field`", __struct_path)) \
                `aip_info(("[aip_cmdline] struct member '%s' (scope='%s') = %s (%0d)", `"field`", __struct_path, svar.field.name(), svar.field)); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_struct_end(name) \
    end

// bounded queue 须显式传入声明的元素容量（[$:7] 对应 MAX_SIZE=8），声明容量无法可移植地反射。
`define aip_int_queue(PATH, RTYPE=int, NAME, DEFAULT_VAL=0, MAX_SIZE=-1) \
        begin \
            bit [0:((1 / (($bits(RTYPE) >= 1 && $bits(RTYPE) <= 1024) ? 1 : 0)) - 1)] __aip_width_guard; RTYPE __aip_sv[]; RTYPE __aip_default; string __aip_path; string __aip_leaf; string __aip_full; real __aip_max_real; int __aip_max; int __aip_rules; int __aip_controls; string __aip_flags; \
            __aip_path = (PATH); __aip_leaf = `"NAME`"; __aip_default = (DEFAULT_VAL); __aip_max_real = real'(MAX_SIZE); \
            __aip_full = (__aip_path == "") ? __aip_leaf : {__aip_path, ".", __aip_leaf}; \
            aip_cmdline_diagnostic::push(__aip_full, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_full); \
            aip_struct_runtime::check_width($bits(RTYPE), __aip_full); \
            aip_struct_runtime::validate_max_size(__aip_max_real); __aip_max = int'(__aip_max_real); \
            aip_struct_runtime::check_integral_default($isunknown(__aip_default), __aip_full); \
            aip_strict_int_queue_runtime#(RTYPE)::resolve(__aip_full, __aip_leaf, __aip_default, __aip_max, __aip_sv); \
            NAME.delete(); foreach (__aip_sv[__aip_i]) NAME.push_back(__aip_sv[__aip_i]); \
            if (NAME.size() != __aip_sv.size()) \
                aip_struct_runtime::fail($sformatf("%s queue size mismatch after copy (expected %0d, got %0d)", __aip_full, __aip_sv.size(), NAME.size())); \
            aip_struct_runtime::queue_rule_stats(__aip_full, __aip_leaf, __aip_rules, __aip_controls, __aip_flags); \
            if (aip_cmdline_print_control::should_print(__aip_full, "")) \
                `aip_info(("[aip_cmdline] queue_summary root='%s' type='%s' kind='primitive_queue' size=%0d rules=%0d controls=%0d flags=%s", __aip_full, $typename(RTYPE), NAME.size(), __aip_rules, __aip_controls, __aip_flags)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_str_queue(PATH, NAME, DEFAULT_VAL="", MAX_SIZE=-1) \
        begin \
            string __aip_sv[]; string __aip_default; string __aip_path; string __aip_leaf; string __aip_full; real __aip_max_real; int __aip_max; int __aip_rules; int __aip_controls; string __aip_flags; \
            __aip_path = (PATH); __aip_leaf = `"NAME`"; __aip_default = (DEFAULT_VAL); __aip_max_real = real'(MAX_SIZE); \
            __aip_full = (__aip_path == "") ? __aip_leaf : {__aip_path, ".", __aip_leaf}; \
            aip_cmdline_diagnostic::push(__aip_full, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_full); \
            aip_struct_runtime::validate_max_size(__aip_max_real); __aip_max = int'(__aip_max_real); \
            aip_strict_string_queue_runtime::resolve(__aip_full, __aip_leaf, __aip_default, __aip_max, __aip_sv); \
            NAME.delete(); foreach (__aip_sv[__aip_i]) NAME.push_back(__aip_sv[__aip_i]); \
            if (NAME.size() != __aip_sv.size()) \
                aip_struct_runtime::fail($sformatf("%s queue size mismatch after copy (expected %0d, got %0d)", __aip_full, __aip_sv.size(), NAME.size())); \
            aip_struct_runtime::queue_rule_stats(__aip_full, __aip_leaf, __aip_rules, __aip_controls, __aip_flags); \
            if (aip_cmdline_print_control::should_print(__aip_full, "")) \
                `aip_info(("[aip_cmdline] queue_summary root='%s' type='string' kind='primitive_queue' size=%0d rules=%0d controls=%0d flags=%s", __aip_full, NAME.size(), __aip_rules, __aip_controls, __aip_flags)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_real_queue(PATH, NAME, DEFAULT_VAL=0.0, MAX_SIZE=-1) \
        begin \
            real __aip_sv[]; real __aip_default; string __aip_path; string __aip_leaf; string __aip_full; real __aip_max_real; int __aip_max; int __aip_rules; int __aip_controls; string __aip_flags; \
            __aip_path = (PATH); __aip_leaf = `"NAME`"; __aip_default = (DEFAULT_VAL); __aip_max_real = real'(MAX_SIZE); \
            __aip_full = (__aip_path == "") ? __aip_leaf : {__aip_path, ".", __aip_leaf}; \
            aip_cmdline_diagnostic::push(__aip_full, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_full); \
            aip_struct_runtime::validate_max_size(__aip_max_real); __aip_max = int'(__aip_max_real); \
            aip_struct_runtime::check_real(__aip_default, __aip_full); \
            aip_strict_real_queue_runtime::resolve(__aip_full, __aip_leaf, __aip_default, __aip_max, __aip_sv); \
            NAME.delete(); foreach (__aip_sv[__aip_i]) NAME.push_back(__aip_sv[__aip_i]); \
            if (NAME.size() != __aip_sv.size()) \
                aip_struct_runtime::fail($sformatf("%s queue size mismatch after copy (expected %0d, got %0d)", __aip_full, __aip_sv.size(), NAME.size())); \
            aip_struct_runtime::queue_rule_stats(__aip_full, __aip_leaf, __aip_rules, __aip_controls, __aip_flags); \
            if (aip_cmdline_print_control::should_print(__aip_full, "")) \
                `aip_info(("[aip_cmdline] queue_summary root='%s' type='real' kind='primitive_queue' size=%0d rules=%0d controls=%0d flags=%s", __aip_full, NAME.size(), __aip_rules, __aip_controls, __aip_flags)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

`define aip_enum_queue(PATH, ETYPE, NAME, DEFAULT_VAL, MAX_SIZE=-1) \
        begin \
            string __aip_names[$]; logic [1023:0] __aip_bits[$]; logic [1023:0] __aip_b; ETYPE __aip_sv[]; ETYPE __aip_iter; ETYPE __aip_default; string __aip_path; string __aip_leaf; string __aip_full; real __aip_max_real; int __aip_max; int __aip_rules; int __aip_controls; string __aip_flags; \
            __aip_path = (PATH); __aip_leaf = `"NAME`"; __aip_default = (DEFAULT_VAL); __aip_max_real = real'(MAX_SIZE); \
            __aip_full = (__aip_path == "") ? __aip_leaf : {__aip_path, ".", __aip_leaf}; \
            aip_cmdline_diagnostic::push(__aip_full, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_full); \
            aip_struct_runtime::validate_max_size(__aip_max_real); __aip_max = int'(__aip_max_real); \
            __aip_iter = __aip_iter.first(); \
            do begin __aip_b = '0; __aip_b[$bits(ETYPE)-1:0] = __aip_iter; __aip_names.push_back(__aip_iter.name()); __aip_bits.push_back(__aip_b); if (__aip_iter == __aip_iter.last()) break; __aip_iter = __aip_iter.next(); end while (1); \
            aip_strict_enum_queue_runtime#(ETYPE)::resolve(__aip_full, __aip_leaf, __aip_default, __aip_max, __aip_names, __aip_bits, __aip_sv); \
            NAME.delete(); foreach (__aip_sv[__aip_i]) NAME.push_back(__aip_sv[__aip_i]); \
            if (NAME.size() != __aip_sv.size()) \
                aip_struct_runtime::fail($sformatf("%s queue size mismatch after copy (expected %0d, got %0d)", __aip_full, __aip_sv.size(), NAME.size())); \
            aip_struct_runtime::queue_rule_stats(__aip_full, __aip_leaf, __aip_rules, __aip_controls, __aip_flags); \
            if (aip_cmdline_print_control::should_print(__aip_full, "")) \
                `aip_info(("[aip_cmdline] queue_summary root='%s' type='%s' kind='primitive_queue' size=%0d rules=%0d controls=%0d flags=%s", __aip_full, $typename(ETYPE), NAME.size(), __aip_rules, __aip_controls, __aip_flags)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
