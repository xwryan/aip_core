//===========================================================
// 所属层次：src/sv/core/cmdline（内部 include 片段，不是独立 compilation unit）。
// 公共上下文：保存跨类型共享的参数来源、运行时 override 表、诊断栈及必要的类前向声明。
// 依赖聚合入口加载的 aip_str/aip_log/uvm_pkg；必须先于标量与 schema 实现。
// override 随仿真存在；诊断帧仅在同步解析调用期间有效，正常返回必须成对恢复。
// 只允许 aip_cmdline.sv 在其 include 窗口加载；拒绝直接包含，避免创建第二份 $unit/package 类型。
// 聚合入口持有唯一的 AIP_CMDLINE_SV 防重入 guard，本文件不声明新的 package。
// 恢复时仅使 AIP 参数来源失效；UVM singleton、override 和用户已经赋值的配置均不重写。
//===========================================================
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
typedef class aip_cmdline;
typedef class aip_strict_int_queue_runtime;
typedef class aip_strict_enum_queue_runtime;

// 两位均属于当前 SV 命名空间并参与快照。Tcl 恢复后在推进仿真前读取实际
// acknowledged，强制 request 为其反值；不用进程本地计数器，避免恢复旧快照
// 或已刷新快照时序号碰撞。Tcl 不写 acknowledged，唯一写入者是下方同步 getter。
reg __aip_cmdline_refresh_request = 0;
reg __aip_cmdline_refresh_ack = 0;

// AIP 独占恢复后的处理器，避免改动 UVM 私有 singleton 及用户直接持有的句柄。
// 普通仿真仍返回原 singleton；仅第一次恢复后查询创建对象，后续查询共享该对象。
class aip_cmdline_source;
    protected static uvm_cmdline_processor current;

    // 返回本轮 AIP 查询应使用的完整参数来源。失效后先完整构造临时对象，再发布
    // 句柄并 ACK，保证标量与枚举全部参数的数组/schema 读取同一顺序和空值语义。
    // UVM 构造器通过 DPI 重枚举当前进程 CLI；保留调用进程 RNG，避免刷新改变业务随机流。
    // 枚举异常/空列表必须 fatal，不允许静默回退到快照中的旧 CLI。此函数不推进时间。
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

//-------------------------------------------------------------------------
// 运行时参数 override 表（非参数化，所有 aip_cmdline#(T) 共享）
// 优先级：override > plusargs(path.name) > plusargs(name) > default
// TCL 通过 set_param/clear_param 命令设置，$stop/run 握手保证读写互斥
// 表中保存表达式原文，写入本身不抽样；类型化宏在每次读取时按同类 plusarg 规则求值。
// get_val/get_cmdline_string 仍返回原文，供模板名和其它自定义字符串消费者使用。
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

// 解析器的公共诊断层：底层报错时仍能找到用户宏调用位置及正在消费的配置。
// 所有受保护入口均为不推进仿真时间的 function；用栈保存嵌套调用，正常返回
// 必须 pop。该层跨 T 特化共享，因而 byte 数组的 int .size 解析也保留来源。
class aip_cmdline_diagnostic;
    typedef struct {
        string key_name;
        string raw;
        string expression;
        string file;
        int line;
    } context_t;
    local static context_t contexts[$];

    // 拼接请求的完整配置名；空 scope 不生成多余的点，不执行参数查询。
    static function string full_name(string name, string path);
        return (path == "") ? name : {path, ".", name};
    endfunction

    // 新建一次入口上下文；继承上层用户位置，显式 file/line 可由直接 API 调用者提供。
    // raw 初始为空，实际选中的输入由 select_value 设置；不保留上一次已完成调用的状态。
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

    // 为 schema/queue 的单个字段建立临时上下文；path 是具体字段/索引，raw 是完整表达式。
    static function void push_value(string key_name, string raw);
        push(key_name);
        select_value(key_name, raw);
    endfunction

    // 为底层 parse_value 建立子上下文，保留完整输入，同时记录当前被抽中的子表达式。
    // 直接调用 parse_value 时没有用户位置，故使用空上下文而不冒用前一次宏的位置。
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

    // 记录当前实际解析的配置项；未处于受保护入口时无副作用，避免产生持久的全局来源。
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

    // 恢复上层上下文；入口的提前返回位于内部实现中，由外层包装保证此处一定执行。
    static function void pop();
        context_t unused;
        if (contexts.size() != 0) unused = contexts.pop_back();
    endfunction

    // 统一补充配置名、完整输入及用户位置，并以 hard fatal 终止仿真；调用后不会继续解析。
    // 使用 AIP 的 FATAL 格式和统计，但不允许 UVM catcher/动作设置把配置错误降级后继续。
    // 无用户位置时显示底层 fallback，绝不把库文件行号伪装成用户调用位置。
    static function void report(string domain, string msg, string fallback_file, int fallback_line);
        string detail, file;
        int line;
        // 保留原错误前缀与原因的连续文本，兼容既有日志检索；定位元数据追加在后。
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
