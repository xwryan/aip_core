// cmdline 公共上下文：各类型共享的参数来源、运行时 override 表、诊断栈及类前向声明，须先于标量与 schema 实现加载。
// 内部 include 片段：只允许 aip_cmdline.sv 在其 include 窗口加载，拒绝直接包含以免创建第二份 $unit/package 类型。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
typedef class aip_cmdline;
typedef class aip_strict_int_queue_runtime;
typedef class aip_strict_enum_queue_runtime;

// 快照恢复后的 CLI 刷新握手，两位均随快照保存：Tcl 恢复后、推进仿真前把 request 置为 ack 的反值，
// ack 只由下方同步 getter 写；不用进程本地计数器，以免恢复旧/已刷新快照时序号碰撞。
reg __aip_cmdline_refresh_request = 0;
reg __aip_cmdline_refresh_ack = 0;

// AIP 专用参数来源：普通仿真返回 UVM singleton；快照恢复后首次查询新建处理器，后续查询共享。
// 恢复只让 AIP 参数来源失效，不改 UVM 私有 singleton、override、用户持有的句柄及已赋值配置。
class aip_cmdline_source;
    protected static uvm_cmdline_processor current;

    // 失效后先完整构造新处理器（UVM 构造器经 DPI 重枚举当前进程 CLI）再发布并 ACK，保证全部读取看到同一份参数；
    // 构造前后保存/恢复调用进程 RNG，避免刷新改变业务随机流。空列表 fatal，不静默回退到快照中的旧 CLI。
    static function uvm_cmdline_processor get();
        uvm_cmdline_processor replacement;
        process owner;
        string randstate;
        string args[$];

        if (__aip_cmdline_refresh_request != __aip_cmdline_refresh_ack) begin
            owner = process::self();
            if (owner != null) randstate = owner.get_randstate();
            replacement = new("aip_cmdline_current_process");
            if (owner != null) owner.set_randstate(randstate);
            replacement.get_args(args);
            if (args.size() == 0)
                $fatal(1, "AIP_CMDLINE_REFRESH: current process argument enumeration is empty");
            current = replacement;
            __aip_cmdline_refresh_ack = __aip_cmdline_refresh_request;
        end
        if (current != null) return current;
        return uvm_cmdline_processor::get_inst();
    endfunction
endclass

// 运行时参数 override 表（所有 aip_cmdline#(T) 共享）；优先级 override > plusargs(path.name) > plusargs(name) > default。
// Tcl 经 set_param/clear_param 写入，$stop/run 握手保证读写互斥；表存表达式原文，类型化宏每次读取时再求值。
class aip_cmdline_override;
    static string table[string];

    static function void set_val(string key, string value);
        table[key] = value;
    endfunction

    // 区分"未设置"与"设为空串"（get_val 对两者都返回 ""）。
    static function bit has(string key);
        return table.exists(key);
    endfunction

    static function string get_val(string key);
        if (table.exists(key)) return table[key];
        return "";
    endfunction

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

// 路径别名：push(path, alias_path) 后，查询 <path>[.子路径].<name> 时在完整路径与叶名之间多查 <alias_path>[.子路径].<name>，
// 来源顺序为 override(完整、别名、叶名) 再 plusarg(完整、别名、叶名)。作用于标量、旧版数组与 aip_cmdline_query 入口；
// schema 与严格 queue 入口不查别名。可嵌套，最近一次 push 优先；须在同一段零时间代码内 pop，不跨 task 等待保留。
class aip_cmdline_alias;
    local static string paths[$];
    local static string aliases[$];

    // alias_path 为空表示本层不提供别名（便于调用方无条件成对 push/pop）。
    static function void push(string path, string alias_path);
        paths.push_back(path);
        aliases.push_back(alias_path);
    endfunction

    static function void pop();
        if (paths.size() == 0) return;
        void'(paths.pop_back());
        void'(aliases.pop_back());
    endfunction

    // path 等于或位于某个已 push 的路径之下时返回映射后的别名路径；无别名或映射结果与 path 相同时返回空串。
    static function string resolve(string path);
        for (int i = paths.size() - 1; i >= 0; i--) begin
            int		n;
            string	mapped;
            n = paths[i].len();
            if (path == paths[i])
                mapped = aliases[i];
            else if (n != 0 && path.len() > n && path.substr(0, n-1) == paths[i] && path[n] == ".")
                mapped = (aliases[i] == "") ? "" : {aliases[i], path.substr(n, path.len()-1)};
            else
                continue;
            return (mapped == path) ? "" : mapped;
        end
        return "";
    endfunction
endclass

// 键使用记录：record_begin() 之后，标量、旧版数组与 aip_cmdline_query 入口把查询过的候选键（完整、别名、叶名）记为
// 已使用，容器按根记录（根、根.控制键、根[i] 均算）。record_end(prefix, unused) 列出 prefix 子树下由 override 或
// plusarg 给出、但记录期间未被查询的键（按字典序），并结束本层记录。可嵌套，最外层 begin 时清空；schema 与严格
// queue 入口不参与记录。只读键名，不求值、不消耗随机数。
class aip_cmdline_usage;
    local static int	depth;
    local static bit	keys[string];
    local static bit	roots[string];

    static function void record_begin();
        if (depth == 0) begin
            keys.delete();
            roots.delete();
        end
        depth++;
    endfunction

    static function bit recording();
        return depth != 0;
    endfunction

    static function void note(string key);
        if (depth != 0) keys[key] = 1;
    endfunction

    static function void note_root(string root);
        if (depth != 0) roots[root] = 1;
    endfunction

    static function void record_end(string prefix, ref string unused[$]);
        string					given[string];
        string					override_keys[$];
        string					args[$];
        uvm_cmdline_processor	clp;
        unused.delete();
        if (depth == 0) return;
        aip_cmdline_override::get_keys(override_keys);
        foreach (override_keys[i]) given[override_keys[i]] = "";
        clp = aip_cmdline_source::get();
        clp.get_plusargs(args);
        foreach (args[i]) begin
            int	eq;
            eq = aip_str::str_find(args[i], "=");
            if (eq > 1) given[args[i].substr(1, eq - 1)] = "";
        end
        foreach (given[key]) begin
            if (key.len() <= prefix.len() || key.substr(0, prefix.len()-1) != prefix ||
                key[prefix.len()] != ".")
                continue;
            if (!used(key)) unused.push_back(key);
        end
        depth--;
    endfunction

    // 精确命中，或某个前缀（截到 "." / "[" 之前）是已记录的容器根。
    local static function bit used(string key);
        if (keys.exists(key) || roots.exists(key)) return 1;
        for (int i = 1; i < key.len(); i++)
            if ((key[i] == "." || key[i] == "[") && roots.exists(key.substr(0, i-1))) return 1;
        return 0;
    endfunction
endclass

// 整数字面量的取值规则（标量与严格 queue/schema 共用）：无符号目标不接受负号；有符号目标的纯十进制（可带负号）须在
// [-2^(N-1), 2^(N-1)-1] 内，带基数/位宽的写法（N'h、'h、'b、'o、'd、0x、0b 等）是位模式，放进 N 位后按补码解释，
// 带负号时取其无符号值的相反数且不得小于 -2^(N-1)。调用方先完成位宽/显式位宽检查。
class aip_cmdline_literal;
    // 去掉 '_' 与首尾空白后，只有可选正负号加十进制数字。
    static function bit is_plain_decimal(string s);
        int		start;
        bit		digit;
        start = 0;
        digit = 0;
        for (int i = 0; i < s.len(); i++) begin
            if (s[i] == "_" || s[i] == " " || s[i] == "\t") continue;
            if (!digit && start == 0 && (s[i] == "+" || s[i] == "-")) begin start = 1; continue; end
            if (s[i] < "0" || s[i] > "9") return 0;
            digit = 1;
            start = 1;
        end
        return digit;
    endfunction

    static function string unsigned_range(int nbits);
        aip_vec_t	max_v;
        if (nbits > 64) return $sformatf("0..2^%0d-1", nbits);
        max_v = (aip_vec_t'(1) << nbits) - 1;
        return $sformatf("0..%0d", max_v[63:0]);
    endfunction

    static function string signed_range(int nbits);
        aip_svec_t	half;
        if (nbits > 64) return $sformatf("-2^%0d..2^%0d-1", nbits - 1, nbits - 1);
        half = aip_svec_t'(1) <<< (nbits - 1);
        return $sformatf("%0d..%0d", -half, half - 1);
    endfunction

    // 有符号目标：v 为绝对值（已确认放得进 nbits），返回是否在范围内，value 为按上述规则得到的有符号值。
    static function bit signed_value(aip_vec_t v, bit negative, bit plain, int nbits, output aip_svec_t value);
        aip_svec_t	mag;
        aip_svec_t	half;
        mag = aip_svec_t'({2'b00, v});
        half = aip_svec_t'(1) <<< (nbits - 1);
        if (negative) begin
            value = -mag;
            return mag <= half;
        end
        if (plain) begin
            value = mag;
            return mag < half;
        end
        value = (mag >= half) ? mag - (half <<< 1) : mag;
        return 1;
    endfunction
endclass

// 解析器公共诊断层，跨 T 特化共享：底层（含 byte 数组的 int .size）报错时仍能定位用户宏调用位置及正在消费的配置。
// 入口均为不推进时间的 function，嵌套用栈保存，正常返回必须 pop。
class aip_cmdline_diagnostic;
    typedef struct {
        string key_name;
        string raw;
        string expression;
        string file;
        int line;
    } context_t;
    local static context_t contexts[$];

    static function string full_name(string name, string path);
        return (path == "") ? name : {path, ".", name};
    endfunction

    // 继承上层用户位置（显式 file/line 优先）；raw 留空，由 select_value 填入实际选中的输入。
    static function void push(string key_name, string file = "", int line = 0);
        context_t c;
        c.key_name = key_name;
        c.raw = "";
        c.expression = "";
        c.file = "";
        c.line = 0;
        if (contexts.size() != 0) begin
            c.file = contexts[$].file;
            c.line = contexts[$].line;
        end
        if (file != "") begin c.file = file; c.line = line; end
        contexts.push_back(c);
    endfunction

    static function void push_value(string key_name, string raw);
        push(key_name);
        select_value(key_name, raw);
    endfunction

    // parse_value 的子上下文：保留完整输入并记录当前子表达式；无上层时用空上下文，不冒用前一次宏的位置。
    static function void push_expression(string expression);
        context_t c;
        c.key_name = "";
        c.raw = expression;
        c.expression = expression;
        c.file = "";
        c.line = 0;
        if (contexts.size() != 0) begin
            c = contexts[$];
            c.expression = expression;
            if (c.raw == "") c.raw = expression;
        end
        contexts.push_back(c);
    endfunction

    // 不在受保护入口内时无副作用，避免产生持久的全局来源。
    static function void select_value(string key_name, string raw);
        if (contexts.size() == 0) return;
        contexts[$].key_name = key_name;
        contexts[$].raw = raw;
        contexts[$].expression = "";
    endfunction

    // 同一字段递归校验列表项时保留整条原文，仅更新子表达式；新字段则切换完整输入。
    static function void select_expression(string key_name, string expression);
        if (contexts.size() == 0) return;
        if (contexts[$].key_name == key_name && contexts[$].raw != "")
            contexts[$].expression = expression;
        else
            select_value(key_name, expression);
    endfunction

    // 提前返回都放在内部实现里，由外层包装保证 pop 必定执行。
    static function void pop();
        context_t unused;
        if (contexts.size() != 0) unused = contexts.pop_back();
    endfunction

    // 补充配置名、完整输入及用户位置后 hard fatal：沿用 AIP FATAL 格式与统计，但不让 UVM catcher/动作设置降级后继续。
    // 无用户位置时显示底层 fallback，不把库文件行号冒充用户调用位置。
    static function void report(string domain, string msg, string fallback_file, int fallback_line);
        string detail, file;
        int line;
        // 前缀与原因保持连续以兼容既有日志检索，定位信息追加在后。
        detail = {domain, (domain == "[AIP_STRUCT]") ? " " : ": ", msg};
        file = fallback_file;
        line = fallback_line;
        if (contexts.size() != 0) begin
            if (contexts[$].file != "") begin
                file = contexts[$].file;
                line = contexts[$].line;
            end
            if (contexts[$].key_name != "")
                detail = {detail, $sformatf(" parameter='+%s'", contexts[$].key_name)};
            detail = {detail, $sformatf(" value='%s'", contexts[$].raw)};
            if (contexts[$].expression != "" && contexts[$].expression != contexts[$].raw)
                detail = {detail, $sformatf(" expression='%s'", contexts[$].expression)};
        end
        aip_log::log(aip_log::FATAL, file, line, "", detail, 1);
    endfunction
endclass
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
