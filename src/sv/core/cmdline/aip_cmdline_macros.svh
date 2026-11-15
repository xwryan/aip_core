//===========================================================
// 所属层次：src/sv/core/cmdline（内部 include 片段，不是独立 compilation unit）。
// 基础公共宏：标量、旧版 struct、列表及 primitive queue 的用户入口。
// 仅定义文本宏；展开依赖公共解析类，聚合入口结束前所有依赖都已完成定义。
// 宏保留调用点 __FILE__/__LINE__；赋值、打印和诊断栈的原有先后次序不变。
// 只允许 aip_cmdline.sv 在其 include 窗口加载；拒绝直接包含，避免创建第二份 $unit/package 类型。
// 聚合入口持有唯一的 AIP_CMDLINE_SV 防重入 guard，本文件不声明新的 package。
// 本次仅按职责迁移定义，原有函数实现和宏展开语句保持不变。
//===========================================================
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
//===========================================================
// aip_cmdline - 命令行参数解析器
// 所属层次：src/sv/core；由 aip_core_pkg 或兼容入口包含，依赖 aip_log/aip_str/uvm_pkg。
// 参数覆盖表与 schema 元数据由库持有；目标变量/容器由调用者持有。
// 诊断上下文只在无时间推进的解析 function 调用期间存在，嵌套返回即恢复，
// 不跨 task 等待保存调用位置，不改变随机种子或抽样次数。
// 支持类型：int, string, real, byte, shortint, longint, bit[N:0], enum, struct
// 依赖：aip_str, uvm_pkg
//
// ===================== 使用说明 =====================
//
// 一、基础类型宏
//
//   1) aip_int(path, rtype, name, default_val)
//      - 解析整数参数，支持 int/byte/shortint/longint/bit[N:0] (最大 1024 bit, 超位宽报错)
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
//      - 控制键 (int/str 动态与固定数组通用, aip_real_list 不支持):
//          +path.name.size=8 / [4:16]     数组长度 (可随机); 静态数组不接受
//          +path.name.each=[1:10] / rand  每元素独立随机; 只有 .each 无长度来源报错
//          +path.name.unique=1            元素互不相同; 固定值重复/候选不足报错
//          +path.name.sort=asc|desc       升降序, 索引覆盖值一起排; 其他值报错
//          +path.name=seq:a:b[:s]         展开整个序列 (仅整数数组; 标量使用报错)
//          +path.name=perm:a:b            a..b 随机排列 (仅整数数组; 标量使用报错)
//          seq/perm 最多展开 1000000 个元素, 超出报错
//      - 优先级: name[i]= > name= 整体列表/seq/perm > name.each > default
//      - 静态数组: 不接受 .size; 列表长于声明长度报错; seq/perm 展开长度必须等于声明长度;
//        未覆盖元素填 default
//      - 注册日志: array 'name' (scope='p') [N] each=... unique sort=... = 值
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
// 五、类型安全 schema API（schema 紧跟用户 typedef 定义）
//
//   aip_struct_type_begin(STYPE) / aip_field_* / aip_struct_type_end(STYPE)
//   aip_struct_apply(ROOT, STYPE, TARGET)
//   aip_struct_sarray_apply(ROOT, STYPE, TARGET)
//   aip_struct_darray_apply(ROOT, STYPE, TARGET, DEFAULT_SIZE=0)
//   aip_struct_queue_apply(ROOT, STYPE, TARGET, DEFAULT_SIZE=0, MAX_SIZE=-1)
//   aip_int/str/real/enum_queue(..., MAX_SIZE=-1)
//
//   - schema 定义在用户 package/module/class scope，不写进本库文件；对象成员可作 TARGET。
//   - package 推荐 wildcard import；selective import 必须同时导入 TYPE 与
//     aip_struct_schema__TYPE。使用本地 TYPE alias 时 companion 也必须成对 alias。
//   - bounded queue 必须显式传入声明的元素容量（[$:7] 对应 MAX_SIZE=8）。
//   - 结构体容器控制使用 canonical ROOT.each.<scalar>.unique/sort；字段数组控制
//     归属于数组路径本身。unique=0 与 sort=none 表示显式关闭。
//   - API 没有内建 schema hook 或跨字段 solver；用户在 apply 后调用自己的约束
//     function/task 或 randomize() with。
//
// 六、优先级规则（所有类型统一）
//   path.name > name（无路径） > compact format > default
//
//===========================================================
//-------------------------------------------------------------------------
// aip_cmdline 参数解析器类
//
`define aip_int(path,rtype=int,name,default_val=0) \
    begin \
        aip_cmdline#(rtype)::get_single_value(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        if (aip_cmdline_print_control::should_print(`"name`", path)) \
            `aip_info(("[aip_cmdline] param '%s' (scope='%s') = %0d (0x%0h)", `"name`", path, name, name)); \
    end

// 无符号参数：先拒绝负数字面量再按 aip_int 读取（aip_int 会把 -1 读成全 1，适合位掩码，
// 不适合计数/地址/ID 这类参数）。
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

`define aip_real_list(path,name,default_val=0.0) \
    begin \
        aip_cmdline_real::get_dynamic_array(`"name`", path, default_val, name, `__FILE__, `__LINE__); \
        begin string __aip_ps=""; foreach(name[__i]) __aip_ps={__aip_ps,$sformatf("%g ",name[__i])}; \
            if (aip_cmdline_print_control::should_print(`"name`", path)) \
                `aip_info(("[aip_cmdline] array '%s' (scope='%s') [%0d] = %s", `"name`", path, name.size(), __aip_ps)); end \
    end

// 枚举宏在查询参数前建立用户来源，缺失必填值与枚举转换失败共用此上下文。
// 宏可能展开在静态过程作用域，依赖配置的赋值和候选队列重置必须在每次执行时发生。
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

// ---- 旧版结构体宏 ----
// begin/end 之间允许用户执行任意代码，因此仅在同步查询/解析期间保留诊断栈。
// 字段宏各自记录调用行，紧凑值保留整条原文并由底层解析器补充字段子表达式。
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

// primitive string queue 与整数入口一致，校验和拷贝期间保存用户调用位置。
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

// primitive enum queue 在构建映射前建立来源，默认值和候选错误均定位到此宏调用行。
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
