// src/sv/core：命令注册、参数分发及用户 task/sequence 的执行生命周期。
// 依赖 aip_str、UVM sequence 和随后声明的 bridge；注册对象在仿真期常驻，
// 同名调用共享 handle，因此调度器必须先取得执行所有权再修改参数/结果。
// wait=0 仅改变当前调用的等待方式：后台 worker 拥有 handle，前台只返回
// STARTED 确认。每次调用新建结果上下文，避免已结束调用的子线程污染复用。
// 新 bridge 使用逐次输出接口；旧全局返回 task 仍可后台运行，但互相串行。
// 注入队列在公共派发入口登记资源预约，防止直接调用越过已排队请求；
// 完成事件驱动等待者，异常取消则由队列的低频回收器检查 process 状态。
// 寄存器入口支持 128 位数据和位置参数；错误表达式在业务结束后回传，不改变调度。
// execution/scope只携带通用身份和非阻塞终态通知，不依赖RAL；业务listener
// 的快照独立于会失效的result context，watchdog按请求scope而不是名字寻址。
`ifndef AIP_CMD_SV
`define AIP_CMD_SV

`include "core/aip_str.sv"

// Command source enum: determines error handling behavior
typedef enum int {
    SRC_TCL      = 0,  // Soft fail: set status=-1, no $fatal
    SRC_DPI      = 1,  // Hard fail: $fatal on unknown command
    SRC_INTERNAL = 2,  // Hard fail on unknown command
    SRC_SOCKET   = 3   // Soft fail: TCP clients receive ERROR, simulation continues
} cmd_source_e;

// Forward declaration for registry
typedef class aip_cmd;
typedef class aip_cmd_execution;
typedef class aip_cmd_execution_scope;

typedef enum {AIP_CMD_COMPLETED, AIP_CMD_CANCELLED, AIP_CMD_WATCHDOG} aip_cmd_end_e;

// 内部订阅与用户watchdog hook分离；function回调不得启动阻塞清理操作。
virtual class aip_cmd_liveness_listener;
    // 收到唯一终态身份；派生业务自行核对generation，不依赖result context。
    pure virtual function void on_terminal(aip_cmd_execution execution, aip_cmd_end_e reason);
endclass

// 一次真实worker的身份对象；调度器拥有，旧引用永远不能变成新调用身份。
class aip_cmd_execution;
    local static longint unsigned next_id;
    local longint unsigned identity;
    local process owner;
    local aip_cmd_liveness_listener listener;
    local bit terminal;
    local bit cancel_requested;
    local bit sequence_seen;
    local bit result_available;
    local string terminal_text;
    local aip_cmd_end_e terminal_reason;
    aip_cmd_execution_scope scope;

    // 只在真实worker bind时创建；不把外层dispatch占位process当owner。
    function new(process owner0, aip_cmd_execution_scope scope0);
        if (next_id == '1) $fatal(1, "AIP_CMD execution identity exhausted");
        identity = ++next_id;
        owner = owner0;
        scope = scope0;
    endfunction

    // 身份只读，数值用于诊断，授权仍以对象身份和owner共同判断。
    function longint unsigned get_id(); return identity; endfunction

    // 返回真实执行进程，不返回bridge等待进程。
    function process get_owner(); return owner; endfunction

    // 只允许执行者绑定一个内部订阅；不覆盖已有订阅或终态。
    function bit subscribe(aip_cmd_liveness_listener listener0);
        if (terminal || listener0 == null || owner != process::self() || listener != null) return 0;
        listener = listener0;
        return 1;
    endfunction

    // 协作取消仅记录意图；实际cleanup仍由活着的业务worker完成。
    function bit request_cancel();
        if (terminal || owner != process::self()) return 0;
        cancel_requested = 1;
        return 1;
    endfunction

    // sequence登记构成不可撤销的“曾进入外部动作”证据，注销不擦除此历史。
    function void note_sequence(); sequence_seen = 1; endfunction

    // 清洁kill判定不能用FINISHED推断子sequence已清空。
    function bit had_sequence(); return sequence_seen; endfunction

    // 当前终态只读；防止finish、惰性回收和watchdog重复结账。
    function bit is_terminal(); return terminal; endfunction

    // 终态原因只读，listener拒绝伪造的过早或不匹配回调。
    function aip_cmd_end_e get_end_reason(); return terminal_reason; endfunction

    // 正常worker尾声调用，回调先于result context失效且只能发生一次。
    function void complete();
        if (terminal || owner != process::self()) return;
        terminal = 1;
        terminal_reason = cancel_requested ? AIP_CMD_CANCELLED : AIP_CMD_COMPLETED;
        if (listener != null) listener.on_terminal(this, terminal_reason);
        listener = null;
        scope = null;
    endfunction

    // 外部只能通知确已死亡的owner；迟到事件不覆盖第一次终态。
    function void notify_dead(aip_cmd_end_e reason);
        if (!(reason inside {AIP_CMD_CANCELLED, AIP_CMD_WATCHDOG}) || terminal || owner == null ||
            !(owner.status() inside {process::KILLED, process::FINISHED})) return;
        terminal = 1;
        terminal_reason = reason;
        if (listener != null) listener.on_terminal(this, reason);
        listener = null;
        scope = null;
    endfunction

    // listener在终态回调内发布独立结果；不接触失效的command result context。
    function bit publish_terminal_result(aip_cmd_liveness_listener publisher, string text0);
        if (!terminal || listener == null || publisher != listener) return 0;
        terminal_text = text0;
        result_available = 1;
        return 1;
    endfunction

    // bridge仅消费watchdog生成的业务结果；其他命令保留原文字。
    function bit watchdog_result(output string text0);
        text0 = "";
        if (!result_available || terminal_reason != AIP_CMD_WATCHDOG) return 0;
        text0 = terminal_text;
        return 1;
    endfunction

    // 正常finish消费取消/清理失败快照，不把业务旧OK覆盖内部安全诊断。
    function bit completion_result(output string text0);
        text0 = "";
        if (!result_available || terminal_reason == AIP_CMD_WATCHDOG) return 0;
        text0 = terminal_text;
        return 1;
    endfunction
endclass

// 一次dispatch树持有启动过的真实执行身份；跨同步嵌套/fork传播，不全局扫名字。
class aip_cmd_execution_scope;
    local aip_cmd_execution executions[$];

    // 保存本请求启动的身份；每个身份只由其bind点加入一次。
    function void add(aip_cmd_execution execution); executions.push_back(execution); endfunction

    // kill后通知死亡后代，不通知仍活着的其他任务；选首个业务watchdog快照。
    function bit notify_dead(aip_cmd_end_e reason, output string result_text);
        bit found = 0;
        string candidate;
        result_text = "";
        foreach (executions[i]) begin
            executions[i].notify_dead(reason);
            if (executions[i].watchdog_result(candidate) && !found) begin
                result_text = candidate;
                found = 1;
            end
        end
        return found;
    endfunction
endclass

// 预约只表示 FIFO 准入资格，不持有业务参数或执行上下文。注入服务拥有
// token；核心持有队列引用直到准入/取消，过期 token 永远不能再次使用。
class aip_cmd_admission;
    aip_cmd command_handle;
    longint unsigned ticket;
    bit active;

    // 建立一次性资格；只有 reserve_injection 可将它放进实际资源队列。
    function new(aip_cmd handle, longint unsigned id);
        command_handle = handle;
        ticket = id;
        active = 1;
    endfunction
endclass

// package 级事件兼容旧 VCS 的静态类支持；只通知资源变化，不携带结果。
event __aip_cmd_admission_changed;

// 注入服务接受后递增、终态 release 后递减；普通 bridge/socket 均通过
// 此计数保护结束/插件卸载/全局参数修改，无需核心反向依赖注入桥接类。
int unsigned __aip_injection_live_tickets = 0;

// 独立于常驻命令 handle 的单次结果容器；调用结束即失效，不能跨调用复用。
// 普通 task 用 aip_cmd::set_result；fork 子线程必须在 fork 前捕获此对象，
// 再显式调用 ctx.set_result，因为标准 process API 不提供父进程查询能力。
class aip_cmd_result_context;
    int status;
    string result_text;
    bit assigned;
    bit active;
    process owner_process;
    // 同步派发链只用于识别“父命令暂停等待子命令”的重入；不代表 fork
    // 子进程可继承结果写权限，后台边界 parent_waits=0 会截断 legacy 重入。
    aip_cmd_result_context call_parent;
    bit parent_waits;
    // legacy 槽使用可恢复的上下文栈。子命令先保存父全局值，正常结束或
    // 被取消后再还原，避免同步嵌套和跨线程并行被错误地视作同一种情况。
    aip_cmd_result_context legacy_parent;
    int legacy_saved_status;
    string legacy_saved_result;

    // 创建尚未写入的结果，先由派发进程占位，worker 开始后再转移所有权。
    function new(process owner);
        status = 0;
        result_text = "";
        assigned = 0;
        active = 1;
        owner_process = owner;
        call_parent = null;
        parent_waits = 0;
        legacy_parent = null;
        legacy_saved_status = 0;
        legacy_saved_result = "";
    endfunction

    // 只允许调度器在 worker 启动时转移 owner；不改变已保存的业务结果。
    function void bind_owner(process owner);
        owner_process = owner;
    endfunction

    // 主动结束或 owner 已被取消/返回后均视为失效；不保留可复用的写入权限。
    function bit is_active();
        if (active && owner_process != null &&
            (owner_process.status() == process::FINISHED ||
             owner_process.status() == process::KILLED))
            active = 0;
        return active;
    endfunction

    // 原子写本次调用的状态/文本；错误上下文立即报错，绝不退回共享全局槽。
    // fork 子线程可持有同一对象，但必须在命令 owner 返回之前完成结果报告。
    function void set_result(int result_status, string text);
        if (!is_active()) begin
            $fatal(1, "AIP_CMD[result] Cannot write an inactive command result context");
            return;
        end
        status = result_status;
        result_text = text;
        assigned = 1;
    endfunction

    // 正常返回或惰性取消清理时永久失效；已捕获的旧对象不能影响下一次调用。
    function void invalidate();
        active = 0;
    endfunction
endclass

// Global command registry — declared outside class for VCS Q-2020 compatibility
// (static associative arrays of class type inside class may cause issues)
aip_cmd __aip_cmd_registry[string];

// 旧静态 facade 的直接 SV 调用没有注册 handle；仅在调用期间登记独立
// 上下文，使 set_result 能按当前 process 定位。正常退出或取消后回收入口。
aip_cmd_result_context __aip_compat_result_scopes[$];

// CPU command flag registry — 1 = route to aip_cpu_bridge
bit __aip_cmd_is_cpu[string];

// 活动 seq 登记表：launch 登记，正常返回注销；显式取消/watchdog 清理使用
// UVM kill() 终止 sequence，但不保证 driver 已发出的协议事务可以回滚或恢复。
// 类句柄关联数组放在类外，以兼容 VCS Q-2020（同命令注册表）。
uvm_sequence_base __aip_active_seqs[string];
// 记录登记 sequence 时的执行进程；watchdog 只清理已取消命令的 sequence，
// 不能因下一条同步命令超时而误杀之前已经 ACK 的后台 sequence。
process __aip_active_seq_owners[string];

// 将 sequence 句柄与执行进程关联，使取消操作可按所有权限定范围。
class aip_cmd_seq_registry;
    // seq 开跑前登记 (cmd_name -> seq 句柄)
    static function void register(string cmd_name, uvm_sequence_base seq);
        aip_cmd_execution execution = aip_cmd::get_current_execution();
        __aip_active_seqs[cmd_name] = seq;
        __aip_active_seq_owners[cmd_name] = process::self();
        if (execution != null) execution.note_sequence();
    endfunction
    // seq 正常跑完注销
    static function void unregister(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name)) __aip_active_seqs.delete(cmd_name);
        if (__aip_active_seq_owners.exists(cmd_name)) __aip_active_seq_owners.delete(cmd_name);
    endfunction
    // 显式清理所有活动 seq，返回 kill 数量；普通 watchdog 不使用此全局操作。
    static function int kill_active();
        int n = 0;
        foreach (__aip_active_seqs[nm]) begin
            if (__aip_active_seqs[nm] != null) begin
                __aip_active_seqs[nm].kill();
                n = n + 1;
            end
        end
        __aip_active_seqs.delete();
        __aip_active_seq_owners.delete();
        return n;
    endfunction
    // kill 指定命令的活动 seq, 返回 1=杀了 0=没找到 (供 TCL kill_seq)
    static function int kill_one(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name) && __aip_active_seqs[cmd_name] != null) begin
            __aip_active_seqs[cmd_name].kill();
            unregister(cmd_name);
            return 1;
        end
        return 0;
    endfunction
    // 只回收被 watchdog 杀死的 owner；FINISHED 不代表其子 sequence 已结束。
    // 先快照名称，避免 kill()/unregister() 修改正在遍历的关联数组。
    static function int kill_cancelled_owners();
        string cancelled[$];
        int n = 0;
        foreach (__aip_active_seq_owners[nm]) begin
            if (__aip_active_seq_owners[nm] != null &&
                __aip_active_seq_owners[nm].status() == process::KILLED)
                cancelled.push_back(nm);
        end
        foreach (cancelled[i]) n += kill_one(cancelled[i]);
        return n;
    endfunction

    // 返回当前登记数量；不把普通后台任务计入 sequence 数量。
    static function int count();
        return __aip_active_seqs.num();
    endfunction

    // 只读核对该owner仍有登记sequence；不从FINISHED推断资源已消失。
    static function bit has_owner(process owner);
        foreach (__aip_active_seq_owners[name])
            if (__aip_active_seq_owners[name] == owner) return 1;
        return 0;
    endfunction
endclass


// 注册对象与单次执行分离：对象常驻，process 句柄仅在一次 cmd_exec 期间有效。
// 不复制 handle 是为了兼容用户 sequence 通过 get_handle(get_name()) 取参数。
class aip_cmd;

    // Instance fields
    string cmd_name;
    string group;
    string description;
    string param_info;
    string args_in;
    string result_out;
    int    status;

    // 内置控制命令默认禁止后台；用户宏通过专用基类显式开放此能力。
    bit background_allowed;
    bit uses_legacy_result;
    local bit execution_busy;
    local process execution_process;
    local aip_cmd_result_context result_context;
    local aip_cmd_execution execution;
    local aip_cmd_execution_scope execution_scope;
    local bit macro_result_scope_active;
    // 老 string 宏默认仍接收全局静态变量返回结果，允许 wait=0；不同执行
    // 链只能有一条占槽，同一同步调用链允许压栈重入。局部结果不依赖此锁。
    local static process legacy_result_owner;
    local static aip_cmd_result_context legacy_result_context;

    // 局部命令按实际 handle 排队；旧全局返回命令共享唯一资源，因此所有
    // legacy 别名共用 FIFO。队列只存有限注入槽对应的 token，不存参数副本。
    local aip_cmd_admission injection_admissions[$];
    local static aip_cmd_admission legacy_injection_admissions[$];

    // Static fields for last execution result
    static int    __aip_cmd_last_status;
    static string __aip_cmd_last_result;

    // 子类实现实际操作；局部模式写 handle/context，legacy 模式写兼容全局槽
    // 时必须持有该槽所有权，不能让不同 legacy 命令交错写入。
    virtual task cmd_exec();
    endtask

    // 构造常驻注册对象；重名保留原对象并报告错误，所有执行能力默认为同步。
    function new(string name);
        this.cmd_name    = name;
        this.group       = "";
        this.description = "";
        this.param_info  = "";
        this.args_in     = "";
        this.result_out  = "";
        this.status      = 0;
        this.background_allowed = 0;
        this.uses_legacy_result = 0;
        this.execution_busy = 0;
        this.execution_process = null;
        this.result_context = null;
        this.macro_result_scope_active = 0;
        if (__aip_cmd_registry.exists(name)) begin
            `aip_error(("[AIP_CMD] Command '%s' already registered", name));
        end else begin
            __aip_cmd_registry[name] = this;
        end
    endfunction

    // 按注册名称获取常驻 handle；未注册返回 null，不创建临时命令实例。
    static function aip_cmd get_handle(string name);
        if (__aip_cmd_registry.exists(name))
            return __aip_cmd_registry[name];
        else
            return null;
    endfunction

    // 删除注册表入口，供插件卸载使用；调用方负责确保没有在途命令。
    static function void unregister(string name);
        if (__aip_cmd_registry.exists(name))
            __aip_cmd_registry.delete(name);
    endfunction

    // 生成逗号分隔的已注册名称列表，用于 help 和未知命令错误提示。
    static function string get_all_cmd_names();
        string result;
        string name;
        int first;
        result = "";
        first = 1;
        if (__aip_cmd_registry.first(name)) begin
            do begin
                if (first) begin
                    result = name;
                    first = 0;
                end else begin
                    result = {result, ", ", name};
                end
            end while (__aip_cmd_registry.next(name));
        end
        return result;
    endfunction

    // 按首个空白分离名称与原始参数；支持空格/Tab/换行，不解释用户参数内容。
    static function void parse_cmd_str(string cmd_str, output string cmd_name, output string args);
        string s;
        int space_pos;
        s = aip_str::strip(cmd_str);
        space_pos = -1;
        for (int i = 0; i < s.len(); i++) begin
            if (is_arg_space(s[i])) begin
                space_pos = i;
                break;
            end
        end
        if (space_pos == -1) begin
            cmd_name = s;
            args = "";
        end else begin
            cmd_name = s.substr(0, space_pos - 1);
            args = aip_str::strip(s.substr(space_pos + 1, s.len() - 1));
        end
    endfunction

    // 提取业务 key=value；沿用历史宽松解析，支持 brace 值并保留其括号。
    // 框架 wait 不使用此函数，避免把嵌套业务字符串误认成控制参数。
    static function string get_arg(string args, string key);
        string search_key;
        int pos;
        int val_start;
        int val_end;
        int brace_depth;
        byte prev_char;

        if (args == "" || key == "") return "";

        search_key = {key, "="};
        // Find "key=" at the start of the string or right after a delimiter
        // (space, comma, tab).  A hit inside a longer key ("xpath=" for key
        // "path") is skipped and the search continues.
        pos = aip_str::str_find(args, search_key);
        while (pos > 0) begin
            prev_char = args[pos - 1];
            if (prev_char == 8'd32 || prev_char == 8'd44 || prev_char == 8'd9) break;
            pos = aip_str::str_find(args, search_key, pos + 1);
        end
        if (pos == -1) return "";

        val_start = pos + search_key.len();
        if (val_start >= args.len()) return "";

        // Check for brace-enclosed value
        if (args[val_start] == "{") begin
            brace_depth = 0;
            for (int i = val_start; i < args.len(); i++) begin
                if (args[i] == "{") brace_depth = brace_depth + 1;
                else if (args[i] == "}") begin
                    brace_depth = brace_depth - 1;
                    if (brace_depth == 0) begin
                        return args.substr(val_start, i);
                    end
                end
            end
            // Unmatched brace: return from val_start to end
            return args.substr(val_start, args.len() - 1);
        end else begin
            // Non-brace value: read until space or comma or end
            val_end = val_start;
            while (val_end < args.len()) begin
                if (args[val_end] == 8'd32 || args[val_end] == 8'd44 || args[val_end] == 8'd9) break;
                val_end = val_end + 1;
            end
            if (val_end == val_start) return "";
            return args.substr(val_start, val_end - 1);
        end
    endfunction

    // 收集同名业务参数；与 get_arg 相同，按顶层空白/逗号分隔，保留
    // brace/bracket/quote 内的内容。重复参数按出现顺序返回。
    // 例如：get_arg_values("cmd=vio_stop cmd=vio_release", "cmd")
    // 返回 ["vio_stop", "vio_release"]。
    static function string_darray_t get_arg_values(string args, string key);
        string values[$];
        string_darray_t result;
        string token;
        int pos;

        result = new[0];
        if (args == "" || key == "") begin
            return result;
        end

        pos = 0;
        while (pos < args.len()) begin
            int token_start;
            int token_end;

            while (pos < args.len() &&
                   (is_arg_space(args[pos]) || args[pos] == ","))
                pos++;
            if (pos >= args.len()) break;

            token_start = pos;
            token_end = arg_token_end(args, token_start);
            token = args.substr(token_start, token_end - 1);
            if (token.len() > key.len() + 1 &&
                token.substr(0, key.len() - 1) == key &&
                token[key.len()] == "=") begin
                values.push_back(token.substr(key.len() + 1, token.len() - 1));
            end
            pos = token_end;
        end

        result = new[values.size()];
        foreach (values[index]) result[index] = values[index];
        return result;
    endfunction

    // 将业务整数字符串转为 int；空值或转换失败返回给定默认值。
    static function int parse_int_arg(string s, int default_val = 0);
        int width;
        longint unsigned result;
        if (s == "") return default_val;
        result = aip_str::str_to_num(s, width);
        // str_to_num returns -1 ({64{1'b1}}) with width=0 on error
        if (width == 0 && result == {64{1'b1}}) return default_val;
        return int'(result);
    endfunction

    // 将业务数字转为 64 位无符号数；空值/错误返回默认值，不做 32 位截断。
    static function longint unsigned parse_int64_arg(string s, longint unsigned dv = 0);
        int width;
        longint unsigned result;
        if (s == "") return dv;
        result = aip_str::str_to_num(s, width);
        // str_to_num returns -1 ({64{1'b1}}) with width=0 on error
        if (width == 0 && result == {64{1'b1}}) return dv;
        return result;
    endfunction

    // 去除字符串两端空白；空值返回默认字符串，不解释内部内容。
    static function string parse_string_arg(string s, string default_val = "");
        string stripped;
        if (s == "") return default_val;
        stripped = aip_str::strip(s);
        if (stripped == "") return default_val;
        return stripped;
    endfunction

    // 将 s/ms/us/ns/ps/fs 时间转换为 ns；非法数值返回 0，未知单位警告后按 ns。
    static function real parse_time_ns(string s);
        string stripped;
        int num_end;
        real value;
        string unit;
        int w;

        stripped = aip_str::strip(s);
        if (stripped == "") return 0.0;

        // Find where digits/decimal end and unit starts
        num_end = 0;
        while (num_end < stripped.len()) begin
            byte c = stripped[num_end];
            if ((c >= 8'd48 && c <= 8'd57) || c == 8'd46 || c == 8'd45)
                num_end = num_end + 1;
            else
                break;
        end

        if (num_end == 0) return 0.0;

        // Parse numeric part
        value = stripped.substr(0, num_end - 1).atoreal();

        // Parse unit
        if (num_end < stripped.len())
            unit = aip_str::lower(aip_str::strip(stripped.substr(num_end, stripped.len() - 1)));
        else
            unit = "ns";

        case (unit)
            "fs": return value / 1e6;
            "ps": return value / 1e3;
            "ns": return value;
            "us": return value * 1e3;
            "ms": return value * 1e6;
            "s":  return value * 1e9;
            default: begin
                `aip_warning(("[AIP_CMD] unknown time unit '%s', assuming ns", unit));
                return value;
            end
        endcase
    endfunction

    // 识别框架参数分隔符；逗号沿用已有 get_arg 的命令参数格式。
    static function bit is_arg_space(byte c);
        return c == 8'd32 || c == 8'd9 || c == 8'd10 || c == 8'd13;
    endfunction

    // 扫描一个完整顶层 token：保留嵌套 brace/bracket 和双引号内部的 wait。
    // 反斜线保护下一字符；不替用户解析业务表达式，也不改写其引用格式。
    static function int arg_token_end(string args, int start_pos);
        int braces = 0;
        int brackets = 0;
        bit quoted = 0;
        bit escaped = 0;
        for (int i = start_pos; i < args.len(); i++) begin
            byte c = args[i];
            if (escaped) begin
                escaped = 0;
                continue;
            end
            if (c == 8'd92) begin
                escaped = 1;
                continue;
            end
            if (braces == 0 && c == 8'd34) begin
                quoted = !quoted;
                continue;
            end
            if (quoted) continue;
            if (c == "{") braces++;
            else if (c == "}" && braces > 0) braces--;
            else if (braces == 0 && c == "[") brackets++;
            else if (braces == 0 && c == "]" && brackets > 0) brackets--;
            else if (braces == 0 && brackets == 0 && (is_arg_space(c) || c == ","))
                return i;
        end
        return args.len();
    endfunction

    // 查找最后一个顶层 token 的起点，供 fork 只消费末尾 join/取消选项。
    // 嵌套值里的同名词保持原样；空字符串返回 -1。
    static function int last_arg_start(string args);
        int pos = 0;
        int last = -1;
        while (pos < args.len()) begin
            if (is_arg_space(args[pos]) || args[pos] == ",") begin
                pos++;
            end else begin
                last = pos;
                pos = arg_token_end(args, pos);
            end
        end
        return last;
    endfunction

    // 仅按顶层逗号拆 fork 子命令；业务 brace/quote 内的逗号不能产生伪命令。
    static function string_darray_t split_fork_commands(string args);
        string items[$];
        string_darray_t result;
        int start_pos = 0;
        int pos = 0;
        while (pos < args.len()) begin
            if (args[pos] == ",") begin
                if (pos > start_pos) items.push_back(aip_str::strip(args.substr(start_pos, pos - 1)));
                else items.push_back("");
                pos++;
                start_pos = pos;
            end else if (is_arg_space(args[pos])) begin
                pos++;
            end else begin
                pos = arg_token_end(args, pos);
            end
        end
        if (start_pos < args.len()) items.push_back(aip_str::strip(args.substr(start_pos, args.len() - 1)));
        result = new[items.size()];
        foreach (items[i]) result[i] = items[i];
        return result;
    endfunction

    // 每次独立解析保留参数 wait=0/1；先验证完整输入，再按原始字符区间删除
    // 控制 token。没有 wait 时逐字保留 args，不能重组业务 token 或吞尾逗号。
    // 中间 wait 删除一侧分隔符；开头 wait 删除后分隔符；末尾 wait 只删前
    // 空白而保留业务尾逗号。重复、空值、孤立 wait 都失败，不修改注册 handle。
    static function bit extract_wait(string args, output string user_args,
                                     output bit wait_for_done, output bit explicit_wait,
                                     output string error_text);
        int pos = 0;
        int remove_start = -1;
        int remove_end = -1;
        int wait_token_start = -1;
        bit user_before_wait = 0;
        bit user_after_wait = 0;
        bit saw_user_token = 0;
        user_args = args;
        wait_for_done = 1;
        explicit_wait = 0;
        error_text = "";
        while (pos < args.len()) begin
            int separator_start = pos;
            int token_start;
            int token_end;
            string token;
            while (pos < args.len() && (is_arg_space(args[pos]) || args[pos] == ",")) pos++;
            if (pos == args.len()) break;
            token_start = pos;
            token_end = arg_token_end(args, token_start);
            token = args.substr(token_start, token_end - 1);
            pos = token_end;
            if (token == "wait" || (token.len() >= 5 && token.substr(0, 4) == "wait=")) begin
                if (explicit_wait) begin
                    error_text = "duplicate wait parameter";
                    return 0;
                end
                explicit_wait = 1;
                if (token != "wait=0" && token != "wait=1") begin
                    error_text = "wait must be exactly wait=0 or wait=1";
                    return 0;
                end
                wait_for_done = (token == "wait=1");
                user_before_wait = saw_user_token;
                wait_token_start = token_start;
                remove_start = saw_user_token ? separator_start : 0;
                remove_end = token_end;
            end else begin
                saw_user_token = 1;
                if (explicit_wait) user_after_wait = 1;
            end
        end
        if (explicit_wait) begin
            if (!user_before_wait) begin
                while (remove_end < args.len() &&
                       (is_arg_space(args[remove_end]) || args[remove_end] == ","))
                    remove_end++;
            end else if (!user_after_wait) begin
                remove_start = wait_token_start;
                while (remove_start > 0 && is_arg_space(args[remove_start - 1]))
                    remove_start--;
                remove_end = args.len();
            end
            user_args = (remove_start > 0) ? args.substr(0, remove_start - 1) : "";
            if (remove_end < args.len())
                user_args = {user_args, args.substr(remove_end, args.len() - 1)};
        end
        return 1;
    endfunction

    // 查询执行所有权；被 watchdog/kill_seq 杀死后没有机会执行正常尾声，
    // 因此下次调度按 process 状态惰性回收，防止永久 BUSY。
    function bit is_busy();
        if (execution_busy && execution_process != null &&
            (execution_process.status() == process::FINISHED ||
             execution_process.status() == process::KILLED)) begin
            if (execution != null) execution.notify_dead(AIP_CMD_CANCELLED);
            if (result_context != null) result_context.invalidate();
            void'(legacy_result_busy());
            execution_busy = 0;
            execution_process = null;
            execution_scope = null;
            macro_result_scope_active = 0;
            -> __aip_cmd_admission_changed;
        end
        return execution_busy;
    endfunction

    // 回收已结束/取消的 legacy 栈顶，并逐层恢复仍在等待的父调用全局快照。
    // 只查询 owner 状态，不杀进程；ctx 对象保留父链直到当前调用彻底释放。
    static function bit legacy_result_busy();
        aip_cmd_result_context retired;
        while (legacy_result_context != null && !legacy_result_context.is_active()) begin
            retired = legacy_result_context;
            legacy_result_context = retired.legacy_parent;
            if (legacy_result_context != null) begin
                __aip_cmd_last_status = retired.legacy_saved_status;
                __aip_cmd_last_result = retired.legacy_saved_result;
            end
            -> __aip_cmd_admission_changed;
        end
        legacy_result_owner = (legacy_result_context == null) ? null :
                              legacy_result_context.owner_process;
        return legacy_result_context != null;
    endfunction

    // 在提交时立即预约 FIFO，尚不改写常驻 handle 参数；原同步调用继续
    // 使用自己的上下文。调用方保证 ticket 唯一且槽位容量已检查。
    function aip_cmd_admission reserve_injection(longint unsigned ticket);
        aip_cmd_admission token;
        token = new(this, ticket);
        if (uses_legacy_result) legacy_injection_admissions.push_back(token);
        else injection_admissions.push_back(token);
        -> __aip_cmd_admission_changed;
        return token;
    endfunction

    // 取消/准入均移除同一个一次性预约；幂等处理迟到的超时/取消尾声。
    // 先作废再通知，等待者不会将已回收的 token 当作新一轮执行资格。
    function void retire_injection(aip_cmd_admission token);
        if (token == null || !token.active || token.command_handle != this) return;
        token.active = 0;
        if (uses_legacy_result) begin
            foreach (legacy_injection_admissions[i])
                if (legacy_injection_admissions[i] == token) begin
                    legacy_injection_admissions.delete(i);
                    break;
                end
        end else begin
            foreach (injection_admissions[i])
                if (injection_admissions[i] == token) begin
                    injection_admissions.delete(i);
                    break;
                end
        end
        -> __aip_cmd_admission_changed;
    endfunction

    // 检查 token 是否为资源队首；null 表示普通 exec_result，仅在无预约
    // 时放行。同步 legacy 后代由派发层单独处理，避免父命令持槽等待死锁。
    function bit injection_turn(aip_cmd_admission token = null);
        if (token != null && (!token.active || token.command_handle != this)) return 0;
        if (uses_legacy_result) begin
            if (legacy_injection_admissions.size() == 0) return token == null;
            return token != null && legacy_injection_admissions[0] == token;
        end
        if (injection_admissions.size() == 0) return token == null;
        return token != null && injection_admissions[0] == token;
    endfunction

    // 队列 worker 用于零阻塞准入检查；与随后 exec_result 在同一调度片内
    // 运行。busy 查询同时回收已被外部取消的 owner，不主动杀业务线程。
    function bit injection_ready(aip_cmd_admission token);
        return injection_turn(token) && !is_busy() &&
               (!uses_legacy_result || !legacy_result_busy());
    endfunction

    // 只有同步后代可重入被其父调用占用的 legacy 槽；普通 fork 子线程没有
    // 当前上下文，后台边界也不能穿透。允许 legacy -> local -> legacy 同步链。
    static function bit can_nest_legacy_result(bit wait_for_done);
        aip_cmd_result_context caller_context;
        if (!wait_for_done) return 0;
        caller_context = get_current_context();
        while (caller_context != null && caller_context.is_active()) begin
            if (caller_context == legacy_result_context) return 1;
            if (!caller_context.parent_waits) return 0;
            caller_context = caller_context.call_parent;
        end
        return 0;
    endfunction

    // 在任何 worker 派生或阻塞操作前压栈，保存父全局值；调用者已经完成
    // BUSY/同步血缘检查。实际 worker 开始后仅替换 ctx.owner，不再重新入栈。
    static function void acquire_legacy_result(aip_cmd_result_context ctx);
        void'(legacy_result_busy());
        ctx.legacy_parent = legacy_result_context;
        ctx.legacy_saved_status = __aip_cmd_last_status;
        ctx.legacy_saved_result = __aip_cmd_last_result;
        legacy_result_context = ctx;
        legacy_result_owner = ctx.owner_process;
    endfunction

    // 更新旧顺序接口的全局镜像；legacy 在途期间仅 owner 及其纯同步后代
    // 可发布。这样 legacy -> local helper -> exec(child) 仍能读到子返回值。
    // fork join_none 仍可能产生 legacy worker，因此 bridge ACK/其他命令完成
    // 不能覆盖该 worker 尚未读回的全局结果。此保护不拦截用户直接赋值。
    static function void publish_compat_result(int result_status, string result_text);
        if (legacy_result_busy() && legacy_result_owner != process::self() &&
            !can_nest_legacy_result(1'b1)) return;
        __aip_cmd_last_status = result_status;
        __aip_cmd_last_result = result_text;
    endfunction

    // 查找当前执行进程所属的单次上下文；直接调用的子 task/function 同属
    // 一个进程，但 fork 子线程必须事先显式捕获上下文，不能隐式猜测其父级。
    // 无命令上下文返回 null，调用方可据此识别直接 SV 调用和命令调用。
    static function aip_cmd_result_context get_current_context();
        process caller;
        caller = process::self();
        foreach (__aip_cmd_registry[name]) begin
            if (__aip_cmd_registry[name].execution_busy &&
                __aip_cmd_registry[name].execution_process == caller &&
                __aip_cmd_registry[name].result_context != null &&
                __aip_cmd_registry[name].result_context.is_active())
                return __aip_cmd_registry[name].result_context;
        end
        // 临时 facade 不在命令注册表中，倒序清理可避免队列删除使遍历漏项。
        for (int i = __aip_compat_result_scopes.size() - 1; i >= 0; i--) begin
            if (__aip_compat_result_scopes[i] == null ||
                !__aip_compat_result_scopes[i].is_active())
                __aip_compat_result_scopes.delete(i);
            else if (__aip_compat_result_scopes[i].owner_process == caller)
                return __aip_compat_result_scopes[i];
        end
        return null;
    endfunction

    // 查询当前真实worker身份；不按命令名、结果context或外层caller猜血缘。
    static function aip_cmd_execution get_current_execution();
        process caller = process::self();
        foreach (__aip_cmd_registry[name]) begin
            if (__aip_cmd_registry[name].execution_busy &&
                __aip_cmd_registry[name].execution_process == caller)
                return __aip_cmd_registry[name].execution;
        end
        return null;
    endfunction

    // 兼容旧静态 facade 直接 SV 调用：已有命令/外层 facade 上下文时返回
    // null 表示借用，外层负责收尾；否则创建临时上下文并在业务开始前独占
    // legacy 槽。无上下文的外部并行调用遇占槽立即 fatal，不能先操作后报错。
    // 此 API 为 function，允许同样保护 loader.check 等公开 function 入口。
    static function aip_cmd_result_context begin_compat_result_scope();
        aip_cmd_result_context ctx;
        if (get_current_context() != null) return null;
        if (legacy_result_busy()) begin
            $fatal(1, "AIP_CMD[result] Direct compatibility call cannot acquire the legacy result slot; use exec_result");
            return null;
        end
        ctx = new(process::self());
        acquire_legacy_result(ctx);
        __aip_compat_result_scopes.push_back(ctx);
        // 不清空旧镜像：例如 check() 成功只返回布尔值，不应额外改变最近结果。
        return ctx;
    endfunction

    // 只结束自己新建的 facade 上下文；借用的 null 不作处理。显式结果优先，
    // 未写结果时保留旧镜像（兼容纯检查 function），然后释放槽并发布最终值。
    // 调用方必须在每条正常/错误 return 前收尾；取消由 owner 状态惰性回收。
    static function void end_compat_result_scope(aip_cmd_result_context owned_scope);
        int completed_status;
        string completed_result;
        if (owned_scope == null) return;
        if (!owned_scope.is_active() || owned_scope.owner_process != process::self()) begin
            $fatal(1, "AIP_CMD[result] Cannot end an inactive or foreign compatibility result context");
            return;
        end
        completed_status = owned_scope.assigned ? owned_scope.status : __aip_cmd_last_status;
        completed_result = owned_scope.assigned ? owned_scope.result_text : __aip_cmd_last_result;
        owned_scope.invalidate();
        void'(legacy_result_busy());
        for (int i = __aip_compat_result_scopes.size() - 1; i >= 0; i--) begin
            if (__aip_compat_result_scopes[i] == owned_scope)
                __aip_compat_result_scopes.delete(i);
        end
        publish_compat_result(completed_status, completed_result);
    endfunction

    // 用户任务不增加参数即可报告本次调用结果；无上下文通常表示误在 fork
    // 子线程使用此快捷接口，或未经命令调度直接调用了面向命令的包装 task。
    // 此时必须显式传递已捕获的 context，不能静默回退到旧全局返回槽。
    static function void set_result(int result_status, string result_text);
        aip_cmd_result_context ctx;
        ctx = get_current_context();
        if (ctx == null) begin
            $fatal(1, "AIP_CMD[result] No current command context; capture get_current_context() before fork and use ctx.set_result() in the child");
            return;
        end
        ctx.set_result(result_status, result_text);
    endfunction

    // 内置旧 facade 专用返回适配：调用者必须已经建立或借用当前上下文，
    // 绝不把“找不到上下文”解释为可随意写全局。若当前 ctx 正拥有 legacy
    // 槽，就沿用旧立即写槽契约，让外层旧 task 能读结果、再改写最终结果；
    // 此路径不置 assigned，因此不会让 facade 压过外层后续的裸全局赋值。
    // 独立结果/typed 调用仍写 ctx；用户显式 set_result 的优先级保持不变。
    static function void set_compat_result(int result_status, string result_text);
        aip_cmd_result_context ctx;
        ctx = get_current_context();
        if (ctx == null) begin
            $fatal(1, "AIP_CMD[result] No current compatibility result context; enter begin_compat_result_scope before calling a legacy facade");
            return;
        end
        if (legacy_result_busy() && legacy_result_context == ctx &&
            legacy_result_owner == process::self()) begin
            __aip_cmd_last_status = result_status;
            __aip_cmd_last_result = result_text;
        end else begin
            ctx.set_result(result_status, result_text);
        end
    endfunction

    // worker 真正开始后接管已预占的执行/全局槽所有权；全局槽只由 legacy
    // 调用清零，局部结果命令与它并发时不会读写或争用这个兼容资源。
    function void bind_execution();
        execution_process = process::self();
        execution = new(execution_process, execution_scope);
        if (execution_scope != null) execution_scope.add(execution);
        result_context.bind_owner(execution_process);
        if (uses_legacy_result) begin
            legacy_result_owner = execution_process;
            __aip_cmd_last_status = 0;
            __aip_cmd_last_result = "";
        end
    endfunction

    // 统一同步/后台收尾：显式 context 结果优先，其次 legacy 全局槽，否则
    // 保留原 handle/typed output 结果；先快照再释放，避免下一次调用覆盖。
    // context 在释放前永久失效，命令已返回的遗留子线程会收到清晰诊断。
    function void finish_execution(output int result_status, output string result_text);
        string cancelled_text;
        if (execution != null) execution.complete();
        if (result_context != null && result_context.assigned) begin
            status = result_context.status;
            result_out = result_context.result_text;
        end else if (uses_legacy_result) begin
            status = __aip_cmd_last_status;
            result_out = __aip_cmd_last_result;
        end
        if (execution != null && execution.completion_result(cancelled_text)) begin
            status = 1;
            result_out = cancelled_text;
        end
        result_status = status;
        result_text = result_out;
        if (result_context != null) result_context.invalidate();
        void'(legacy_result_busy());
        execution_busy = 0;
        execution_process = null;
        execution_scope = null;
        macro_result_scope_active = 0;
        -> __aip_cmd_admission_changed;
    endfunction

    // 兼容旧代码顺序执行 get_handle()->args_in->cmd_exec()：有正常派发
    // 上下文时复用；否则建立临时上下文并返回 owns_scope=1，交给宏尾收尾。
    // 直接嵌套/重入不能表达独立派发所有权，因此明确拒绝并要求 exec_result。
    // 此检查无法撤销外部已写入 args_in 的操作；直接入口只保证顺序使用，
    // 并发调用必须通过 exec_result 在更新业务参数之前完成 BUSY 检查。
    function bit begin_macro_result_scope();
        process caller;
        caller = process::self();
        if (is_busy()) begin
            if (execution_process != caller || macro_result_scope_active) begin
                $fatal(1, "AIP_CMD[result] Direct cmd_exec for '%s' is busy or reentrant; use exec_result", cmd_name);
                return 0;
            end
            macro_result_scope_active = 1;
            return 0;
        end
        if (get_current_context() != null) begin
            $fatal(1, "AIP_CMD[result] Nested direct cmd_exec for '%s' is unsupported; use exec_result", cmd_name);
            return 0;
        end
        if (uses_legacy_result && legacy_result_busy()) begin
            $fatal(1, "AIP_CMD[result] Direct cmd_exec for '%s' cannot acquire the legacy result slot; use exec_result", cmd_name);
            return 0;
        end
        execution_busy = 1;
        execution_process = caller;
        execution_scope = null;
        result_context = new(caller);
        if (uses_legacy_result) acquire_legacy_result(result_context);
        status = 0;
        result_out = "";
        bind_execution();
        macro_result_scope_active = 1;
        return 1;
    endfunction

    // 只有直接入口创建的临时上下文在宏尾结束并更新旧顺序调用镜像；正常
    // 派发由统一收尾决定是否发布。镜像发布仍保护其他在途 legacy 调用。
    function void end_macro_result_scope(bit owns_scope);
        int completed_status;
        string completed_result;
        macro_result_scope_active = 0;
        if (owns_scope) begin
            finish_execution(completed_status, completed_result);
            publish_compat_result(completed_status, completed_result);
        end
    endfunction

    // 后台 worker 的唯一执行入口；结束结果只留在自身 handle 并写日志，
    // 不能覆盖已经发送的 STARTED 确认或后续命令的前台返回槽。
    // 不吞掉 UVM_FATAL/$fatal，业务 task/sequence 自身超时仍遵循用户定义。
    static task run_background(aip_cmd handle);
        int completed_status;
        string completed_result;
        handle.cmd_exec();
        handle.finish_execution(completed_status, completed_result);
        `aip_info(("[AIP_CMD_BACKGROUND] %s finished status=%0d result=%s",
                   handle.cmd_name, completed_status, completed_result));
    endtask

    // 逐次结果接口：输出由本次调用独占，支持前后台/不同 bridge 同时执行。
    // wait=0 只确认 worker 已派发，不宣称业务执行完成；同步仍等待 cmd_exec。
    // CPU 继续使用固件 async 协议，显式 wait 拒绝；fork 的 wait 留给子命令。
    // 可选 admission 只供独立队列使用；普通入口无 token，存在预约时返回
    // BUSY 而不抢先。已持 legacy 槽的同步后代保留重入资格以完成父调用。
    static task exec_result(string cmd_str, cmd_source_e src,
                            output int out_status, output string out_result,
                            input aip_cmd_admission admission = null,
                            input aip_cmd_execution_scope scope = null);
        string name;
        string args;
        string user_args;
        string wait_error;
        bit wait_for_done;
        bit explicit_wait;
        aip_cmd handle;
        aip_cmd_result_context caller_context;
        aip_cmd_execution caller_execution;

        caller_execution = get_current_execution();
        if (scope == null && caller_execution != null) scope = caller_execution.scope;
        if (scope == null) scope = new();

        out_status = 0;
        out_result = "";
        parse_cmd_str(cmd_str, name, args);

        // 生命周期操作会销毁执行环境或改变在途解析配置；任何传输入口
        // 都必须等待全部 ticket 显式回收。只读查询与用户显式 kill 不受限。
        if (__aip_injection_live_tickets != 0 &&
            (name == "end_test" || name == "so_load" || name == "so_reload" ||
             name == "so_unload" || name == "set_param" || name == "clear_param")) begin
            out_status = 1;
            out_result = {"BUSY: release all injection tickets before lifecycle command '", name, "'"};
            return;
        end

        // fork 参数包含多个完整子命令，不在父层消费它们的 wait。
        if (name == "fork") begin
            fork_exec_result(args, src, out_status, out_result, scope);
            return;
        end

        handle = get_handle(name);
        if (handle == null) begin
            if (src == SRC_TCL || src == SRC_SOCKET) begin
                out_status = -1;
                out_result = {"Unknown command: ", name};
                return;
            end else begin
                $fatal(1, "AIP_CMD[exec] Unknown command '%s'. Available commands: %s",
                       name, get_all_cmd_names());
            end
        end

        if (!extract_wait(args, user_args, wait_for_done, explicit_wait, wait_error)) begin
            out_status = 1;
            out_result = {"ERROR: ", name, ": ", wait_error};
            return;
        end

        if (!handle.injection_turn(admission) &&
            !(admission == null && handle.uses_legacy_result &&
              legacy_result_busy() && can_nest_legacy_result(wait_for_done))) begin
            out_status = 1;
            out_result = {"BUSY: command '", name, "' has pending queued requests"};
            return;
        end

        // 必须在写 args/status/result 前检查 BUSY，避免覆盖正在使用的参数。
        if (handle.is_busy()) begin
            out_status = 1;
            out_result = {"BUSY: command '", name, "' is still running"};
            return;
        end

        if (__aip_cmd_is_cpu.exists(name) && __aip_cmd_is_cpu[name]) begin
            bit is_async;
            string async_val;
            if (explicit_wait) begin
                out_status = 1;
                out_result = {"ERROR: ", name, ": wait is not supported for CPU commands; use async"};
                return;
            end
            async_val = get_arg(args, "async");
            is_async = (async_val == "1");
            aip_cpu_bridge::send_cmd(cmd_str, is_async, out_status, out_result);
            return;
        end

        if (!wait_for_done && !handle.background_allowed) begin
            out_status = 1;
            out_result = {"ERROR: ", name, ": wait=0 is not supported for this command"};
            return;
        end
        if (handle.uses_legacy_result && legacy_result_busy() &&
            !can_nest_legacy_result(wait_for_done)) begin
            out_status = 1;
            out_result = {"BUSY: legacy global-result command; cannot run '", name, "' concurrently"};
            return;
        end

        // 在占用新 handle 之前捕获父调用；仅同步边允许 legacy 槽重入，
        // 并不把 set_result 写权限隐式授予任意 fork 子进程。
        caller_context = get_current_context();
        if (admission != null) handle.retire_injection(admission);
        handle.execution_busy = 1;
        // child 尚未获得调度时先用调用进程占位；若 fork 的取消分支在启动窗口
        // 杀死 caller，下一次调度仍能观察 KILLED 并回收，而非留下 null owner。
        handle.execution_process = process::self();
        handle.execution = null;
        handle.execution_scope = scope;
        handle.result_context = new(handle.execution_process);
        handle.result_context.call_parent = caller_context;
        handle.result_context.parent_waits = wait_for_done;
        // 同步/后台均在派生前预占 legacy 槽，避免两个调用在 worker 尚未
        // 获得调度时同时通过检查；调用者若在此窗口被取消，锁可惰性回收。
        if (handle.uses_legacy_result) acquire_legacy_result(handle.result_context);
        handle.args_in = user_args;
        handle.status = 0;
        handle.result_out = "";
        if (wait_for_done) begin
            int completed_status;
            string completed_result;
            bit completed = 0;
            // 每次同步业务也有独立进程。用户 task 内的 disable/wait fork 只能
            // 影响本次子进程，不能触及同一 bridge/caller 先前已 ACK 的后台任务。
            fork
                begin
                    handle.bind_execution();
                    handle.cmd_exec();
                    handle.finish_execution(completed_status, completed_result);
                    completed = 1;
                end
            join
            // 只有 worker 被单独 kill、而派发父进程仍活着时才会走此分支。
            // 立刻触发惰性清理，先恢复父 legacy 快照，不能假报缺省成功。
            if (!completed) begin
                void'(handle.is_busy());
                out_status = 1;
                out_result = {"CANCELLED: command '", name, "' did not complete"};
                if (handle.execution != null) begin
                    string cancelled_text;
                    if (handle.execution.completion_result(cancelled_text)) out_result = cancelled_text;
                end
            end else begin
                out_status = completed_status;
                out_result = completed_result;
            end
        end else begin
            bit started = 0;
            // 等待 worker 登记 process 句柄后立即 ACK；不等 cmd_exec 返回。
            // 该 delta 握手也保证下一条同名调用看到确切的在途 owner。
            fork
                begin
                    handle.bind_execution();
                    started = 1;
                    run_background(handle);
                end
            join_none
            wait (started);
            out_status = 0;
            out_result = {"STARTED: ", name};
        end
    endtask

    // 兼容旧调用点：仅在本次 dispatch 返回时发布全局结果。并发调用方应改用
    // exec_result；直接并发读写 __aip_cmd_last_* 从来不是逐次结果安全接口。
    static task exec(string cmd_str, cmd_source_e src = SRC_INTERNAL);
        int result_status;
        string result_text;
        exec_result(cmd_str, src, result_status, result_text);
        publish_compat_result(result_status, result_text);
    endtask

    // Fork-execute multiple commands in parallel
    // Format: "cmd1 a=1, cmd2 b=2, cmd3 join|join_any|join_none [disable_remaining=1]"
    // Aggregates child statuses: first non-zero status wins; failure list collected
    // 子命令结果只聚合到本次局部变量；同名并发由 BUSY 拒绝，不再抢共享槽。
    // join_none 只回启动确认，迟到的子命令不能改写调用方结果。
    static task fork_exec_result(string cmd_str, cmd_source_e src,
                                 output int out_status, output string out_result,
                                 input aip_cmd_execution_scope scope = null);
        string s;
        string join_type;
        int disable_remaining;
        int total;
        int done_count;
        int worst_status;
        string fail_list;
        string_darray_t cmd_list;
        process child_process[];
        int started_count;
        int jn_pos;
        string tail_token;
        aip_cmd_execution parent_execution;

        parent_execution = get_current_execution();
        if (scope == null && parent_execution != null) scope = parent_execution.scope;
        if (scope == null) scope = new();

        out_status = 0;
        out_result = "";
        s = aip_str::strip(cmd_str);
        if (s == "") begin
            `aip_warning(("AIP_CMD[fork_exec] Empty fork command string"));
            out_status = 1;
            out_result = "ERROR: empty fork command";
            return;
        end

        // fork 自身只消费末尾选项；子命令参数/嵌套业务字符串保持不变。
        disable_remaining = 0;
        jn_pos = last_arg_start(s);
        if (jn_pos >= 0) begin
            tail_token = s.substr(jn_pos, s.len() - 1);
            if (tail_token == "disable_remaining=1" || tail_token == "disable_remaining=0") begin
                disable_remaining = (tail_token == "disable_remaining=1");
                s = (jn_pos > 0) ? aip_str::strip(s.substr(0, jn_pos - 1)) : "";
            end
        end

        // join 必须是独立顶层尾 token，不能把名称/字符串中的 join 当关键字。
        join_type = "join";
        jn_pos = last_arg_start(s);
        if (jn_pos >= 0) begin
            tail_token = s.substr(jn_pos, s.len() - 1);
            if (tail_token == "join" || tail_token == "join_any" || tail_token == "join_none") begin
                join_type = tail_token;
                s = (jn_pos > 0) ? aip_str::strip(s.substr(0, jn_pos - 1)) : "";
            end
        end

        // Remove trailing comma if present after stripping join keyword
        if (s.len() > 0 && s[s.len() - 1] == ",") begin
            if (s.len() > 1)
                s = aip_str::strip(s.substr(0, s.len() - 2));
            else
                s = "";
        end

        cmd_list = split_fork_commands(s);
        total = cmd_list.size();

        if (total == 0) begin
            `aip_warning(("AIP_CMD[fork_exec] No commands to fork"));
            out_status = 1;
            out_result = "ERROR: fork contains no commands";
            return;
        end

        child_process = new[total];
        started_count = 0;
        done_count = 0;
        worst_status = 0;
        fail_list = "";

        // Launch all commands with fork...join_none
        for (int i = 0; i < total; i++) begin
            automatic string cmd_i = aip_str::strip(cmd_list[i]);
            automatic int child_index = i;
            fork
                begin
                    automatic int child_status;
                    automatic string child_result;
                    child_process[child_index] = process::self();
                    started_count++;
                    exec_result(cmd_i, src, child_status, child_result, null, scope);
                    if (child_status != 0) begin
                        if (worst_status == 0) worst_status = child_status;
                        fail_list = {fail_list, $sformatf(" [%s:status=%0d,msg=%s]",
                                                          cmd_i, child_status, child_result)};
                    end
                    done_count = done_count + 1;
                end
            join_none
        end

        // 先让每个子进程登记句柄，避免零耗时子命令触发 join_any 时遗漏尚未运行者。
        wait (started_count == total);
        if (join_type == "join") begin
            wait (done_count == total);
        end else if (join_type == "join_any") begin
            wait (done_count > 0);
            if (disable_remaining) begin
                // 只取消当前 fork 的未完成分支，不使用会误杀历史后台的 disable fork。
                foreach (child_process[i]) begin
                    if (child_process[i] != null &&
                        child_process[i].status() != process::FINISHED &&
                        child_process[i].status() != process::KILLED)
                        child_process[i].kill();
                end
                void'(aip_cmd_seq_registry::kill_cancelled_owners());
                if (scope != null) begin
                    string ignored;
                    void'(scope.notify_dead(AIP_CMD_CANCELLED, ignored));
                end
            end
        end
        // join_none: return immediately (no aggregation possible — children still running)

        // 返回独立结果；不允许迟到子进程污染下一条 Tcl/socket 命令。
        if (join_type != "join_none") begin
            if (worst_status != 0) begin
                out_status = worst_status;
                out_result = {"fork: failure(s):", fail_list};
            end else begin
                out_status = 0;
                out_result = $sformatf("fork: %0d cmd(s) ok", done_count);
            end
        end else begin
            out_result = $sformatf("fork: %0d cmd(s) started", total);
        end
    endtask

    // 保留旧 fork_exec API；与 exec 一样只适合顺序读取兼容全局结果。
    static task fork_exec(string cmd_str, cmd_source_e src = SRC_INTERNAL);
        int result_status;
        string result_text;
        fork_exec_result(cmd_str, src, result_status, result_text);
        publish_compat_result(result_status, result_text);
    endtask

endclass

// 用户 task/sequence 宏的公共基类：无需用户修改任务签名即可支持 wait=0。
// 参数仍由同名 handle 持有，调度器保证一次只有一个 owner。
class aip_cmd_user_task extends aip_cmd;
    // 注册时开放后台；不改变实际 task 的解析、返回格式和异常处理。
    function new(string name);
        super.new(name);
        background_allowed = 1;
    endfunction
endclass

// 保留老 string 宏注册参数与任务签名；默认兼容裸全局返回槽，不相关调用
// 互斥、同步派发链允许嵌套；显式 LOCAL_RESULT=1 可消除全局槽依赖。
// 两种模式均支持 wait=0；局部模式业务不得再直接写 __aip_cmd_last_*。
class aip_cmd_legacy_result_task extends aip_cmd;
    // 旧调用默认占兼容槽；尾参只描述返回通道，不改变 task 的业务参数。
    function new(string name, bit local_result = 0);
        super.new(name);
        background_allowed = 1;
        uses_legacy_result = !local_result;
    endfunction
endclass

// ============================================================
// Built-in: set_param / clear_param — runtime parameter override
// ============================================================
class \__aip_cmd_set_param extends aip_cmd;
    task cmd_exec();
        string args, path_name, value;
        int path_start, path_end, val_start;
        args = this.args_in;

        // 手动解析 "path=xxx value=yyy"
        // 不用 get_arg — value 中可能含逗号/方括号/大括号等随机格式
        path_start = aip_str::str_find(args, "path=");
        if (path_start == -1) begin
            this.result_out = "ERROR: missing path argument";
            this.status = 1;
            return;
        end
        path_start = path_start + 5;

        // path 值到下一个空格结束
        path_end = path_start;
        while (path_end < args.len() && args[path_end] != 8'd32) path_end = path_end + 1;
        path_name = args.substr(path_start, path_end - 1);

        // value= 之后的所有内容都是 value（保留逗号/方括号/大括号）
        val_start = aip_str::str_find(args, "value=");
        if (val_start != -1) begin
            val_start = val_start + 6;
            value = aip_str::strip(args.substr(val_start, args.len() - 1));
        end else begin
            value = "";
        end

        aip_cmdline_override::set_val(path_name, value);
        `aip_info(("[SET_PARAM] %s = %s", path_name, value));
        this.result_out = $sformatf("OK: %s = %s", path_name, value);
        this.status = 0;
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_set_param __inst = new("set_param");
endclass

class \__aip_cmd_clear_param extends aip_cmd;
    task cmd_exec();
        string args, path_name;
        args = this.args_in;
        path_name = aip_cmd::get_arg(args, "path");

        if (path_name == "") begin
            aip_cmdline_override::clear_all();
            `aip_info(("[CLEAR_PARAM] all overrides cleared"));
            this.result_out = "OK: all cleared";
        end else begin
            aip_cmdline_override::clear(path_name);
            `aip_info(("[CLEAR_PARAM] %s cleared", path_name));
            this.result_out = $sformatf("OK: %s cleared", path_name);
        end
        this.status = 0;
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_clear_param __inst = new("clear_param");
endclass

// ============================================================
// Built-in: get_param command — 读运行期 plusarg (+name=value)
// 通用: $value$plusargs 用运行期格式串 "<name>=%s" 抓任意 +name=value 的字符串值.
// 种子特例: name=seed|ntb_random_seed 且未显式 +传时, 退到 $get_initial_random_seed().
// TCL: aip_getparam <name>  (封 aip_send_cmd "get_param name=<name>" + aip_read_result).
// 未传该 plusarg -> result_out="" 且 status=1 (用 aip_check_status 辨).
// ============================================================
class \__aip_cmd_get_param extends aip_cmd;
    task cmd_exec();
        string name, fmt, val;
        name = aip_cmd::get_arg(this.args_in, "name");
        if (name == "") begin
            this.result_out = "ERROR: missing name argument";
            this.status     = 1;
            return;
        end
        fmt = {name, "=%s"};
        if ($value$plusargs(fmt, val)) begin
            this.result_out = val;
            this.status     = 0;
        end else if (name == "seed" || name == "ntb_random_seed") begin
            this.result_out = $sformatf("%0d", $get_initial_random_seed());
            this.status     = 0;
        end else begin
            this.result_out = "";
            this.status     = 1;   // 未传该 plusarg
        end
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_get_param __inst = new("get_param");
endclass

// ============================================================
// Built-in: help command
// ============================================================
class \__aip_cmd_help extends aip_cmd;
    task cmd_exec();
        string target;
        target = aip_str::strip(this.args_in);
        if (target == "")
            show_all_commands();
        else
            show_command_detail(target);
    endtask

    task show_all_commands();
        string name;
        string groups_seen[$];
        bit found_ungrouped;

        $display("");
        $display("Available commands:");
        $display("-------------------");

        // Pass 1: collect unique group names
        if (__aip_cmd_registry.first(name)) begin
            do begin
                aip_cmd h = __aip_cmd_registry[name];
                if (h.group != "") begin
                    bit already = 0;
                    foreach (groups_seen[g]) begin
                        if (groups_seen[g] == h.group) begin
                            already = 1;
                            break;
                        end
                    end
                    if (!already) groups_seen.push_back(h.group);
                end
            end while (__aip_cmd_registry.next(name));
        end

        // Pass 2: for each group, print commands belonging to it
        foreach (groups_seen[g]) begin
            $display("");
            $display("[%s]", groups_seen[g]);
            if (__aip_cmd_registry.first(name)) begin
                do begin
                    aip_cmd h = __aip_cmd_registry[name];
                    if (h.group == groups_seen[g]) begin
                        if (h.description != "")
                            $display("  %-20s - %s", name, h.description);
                        else
                            $display("  %-20s", name);
                    end
                end while (__aip_cmd_registry.next(name));
            end
        end

        // Pass 3: print ungrouped commands under [other]
        found_ungrouped = 0;
        if (__aip_cmd_registry.first(name)) begin
            do begin
                aip_cmd h = __aip_cmd_registry[name];
                if (h.group == "") begin
                    if (!found_ungrouped) begin
                        $display("");
                        $display("[other]");
                        found_ungrouped = 1;
                    end
                    if (h.description != "")
                        $display("  %-20s - %s", name, h.description);
                    else
                        $display("  %-20s", name);
                end
            end while (__aip_cmd_registry.next(name));
        end

        $display("");
        $display("Use 'help <command>' for details.");
        this.result_out = "OK";
        this.status = 0;
    endtask

    task show_command_detail(string name);
        aip_cmd h;
        h = aip_cmd::get_handle(name);
        if (h == null) begin
            this.result_out = {"ERROR: Unknown command '", name, "'"};
            this.status = 1;
            $display("%s", this.result_out);
            return;
        end
        $display("");
        $display("Command: %s", name);
        if (h.group != "")
            $display("  Group      : %s", h.group);
        if (h.description != "")
            $display("  Description: %s", h.description);
        if (h.param_info != "")
            $display("  Parameters : %s", h.param_info);
        $display("");
        this.result_out = "OK";
        this.status = 0;
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_help __inst = new("help");
endclass

// ============================================================
// Registration Macros
// 以下宏创建常驻命令对象：task/typed/enum 用独立 handle/context 结果，可 wait=0。
// 用户 task 可通过 set_result 反馈失败；它在收尾时优先于 typed 自动返回值。
// str/mixed 宏保留兼容全局通道，显式 LOCAL_RESULT=1 切换为可并发的局部通道。
// 非兼容模式用户不能直接写 __aip_cmd_last_*；内置控制类默认仅同步。
// 所有用户 task/typed/enum/string 宏均建立顺序 direct cmd_exec 的临时上下文，
// 收尾发布兼容镜像；正常 dispatch 则复用框架上下文，不重复占槽/发布。
// ============================================================

// Basic: 0 input, 0 output
`define aip_cmd_task(Ccmd, svtask) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 执行用户无参任务；参数/结果可经同名 handle 访问，wait=0 由调度器处理。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        svtask(); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，并由用户任务基类开放后台派发能力。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// Metadata: optional layered info
`define aip_cmd_info(Ccmd, _group, _desc, _params) \
begin \
    aip_cmd __h = aip_cmd::get_handle(`"Ccmd`"); \
    if (__h != null) begin \
        __h.group = _group; \
        __h.description = _desc; \
        __h.param_info = _params; \
    end \
end

// ============================================================
// Typed Parameter Macros
// ============================================================

// 1 int input, 0 output
`define aip_cmd_1i(Ccmd, svtask, TI1, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            end \
            svtask(ni1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 0 output
`define aip_cmd_2i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
            end \
            svtask(ni1, ni2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 0 output
`define aip_cmd_3i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
            end \
            svtask(ni1, ni2, ni3); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 1 output
`define aip_cmd_1i1o(Ccmd, svtask, TI1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            end \
            svtask(ni1, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 1 output
`define aip_cmd_2i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
            end \
            svtask(ni1, ni2, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 2 outputs
`define aip_cmd_2i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TO1 no1; TO2 no2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
            end \
            svtask(ni1, ni2, no1, no2); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// str_* / 1i1s 的宏名、既有参数顺序和 task 签名保持不变；可选尾参
// LOCAL_RESULT=0 兼容旧裸全局写入（不相关执行链互斥，同步父子可借槽），
// LOCAL_RESULT=1 承诺业务仅写 set_result/context/handle，可与其他命令并发。
// 同步/后台的结果初始化与采集统一由调度器处理；沉默 task 返回 0/空串。
`define aip_cmd_str_1i(Ccmd, svtask, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析单个字符串参数；调度器按注册的局部/兼容模式统一收取结果。 */ \
    task cmd_exec(); \
        string ni1; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
        end \
        svtask(ni1); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 两个字符串参数；可选尾参选择返回通道，不改变业务参数位置。
`define aip_cmd_str_2i(Ccmd, svtask, ni1, di1, ni2, di2, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析两个字符串参数；调度器按注册的局部/兼容模式统一收取结果。 */ \
    task cmd_exec(); \
        string ni1; string ni2; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
        end \
        svtask(ni1, ni2); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 保留旧 status 命名变体；结果处理与无 status 后缀版本一致。
`define aip_cmd_str_1i_status(Ccmd, svtask, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析单个字符串参数；调度器统一初始化并获取 task 结果。 */ \
    task cmd_exec(); \
        string ni1; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
        end \
        svtask(ni1); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 两字符串 status 变体，尾参 LOCAL_RESULT 不进入用户 task 参数列表。
`define aip_cmd_str_2i_status(Ccmd, svtask, ni1, di1, ni2, di2, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析两个字符串参数；调度器统一初始化并获取 task 结果。 */ \
    task cmd_exec(); \
        string ni1; string ni2; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
        end \
        svtask(ni1, ni2); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 三字符串 status 变体；支持保持旧代码或显式选用局部结果的双轨迁移。
`define aip_cmd_str_3i_status(Ccmd, svtask, ni1, di1, ni2, di2, ni3, di3, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析三个字符串参数；调度器统一初始化并获取 task 结果。 */ \
    task cmd_exec(); \
        string ni1; string ni2; string ni3; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
            ni3 = (__v3 != "") ? __v3 : di3; \
        end \
        svtask(ni1, ni2, ni3); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 第三个业务键固定为 time=，局部变量由 ni3 命名，避开 SV 的 time 关键字。
// 可选 LOCAL_RESULT 不改变原有 command ... time=100ns 命令语法。
`define aip_cmd_str_3i_status_time(Ccmd, svtask, ni1, di1, ni2, di2, ni3, di3, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 解析两个普通字符串与 time 值；调度器统一处理结果与生命周期。 */ \
    task cmd_exec(); \
        string ni1; string ni2; string ni3; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            string __v3 = aip_cmd::get_arg(this.args_in, "time"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
            ni3 = (__v3 != "") ? __v3 : di3; \
        end \
        svtask(ni1, ni2, ni3); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 字符串与整数混合参数，例如 load_rom(file, offset)；尾参只选择结果通道。
`define aip_cmd_str_1i1i(Ccmd, svtask, TI1, ns1, ds1, TI2, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 按原类型/顺序解析字符串及整数；调度器统一处理结果与生命周期。 */ \
    task cmd_exec(); \
        TI1 ns1; TI2 ni1; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ns1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ns1 = (__v1 != "") ? __v1 : ds1; \
            ni1 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di1; \
        end \
        svtask(ns1, ni1); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 整数与字符串混合参数；维持既有宏调用顺序，供仍需要该参数形态的业务命令使用。
`define aip_cmd_1i1s(Ccmd, svtask, TI1, ni1, di1, TI2, ns1, ds1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    /* 按原类型/顺序解析整数及字符串；调度器统一处理结果与生命周期。 */ \
    task cmd_exec(); \
        TI1 ni1; TI2 ns1; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ns1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            ns1 = (__v2 != "") ? __v2 : ds1; \
        end \
        svtask(ni1, ns1); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// string + 64-bit unsigned integer + string command, used by the unified
// firmware image loader.  parse_int64_arg is intentional: image start
// addresses commonly use 0x8000_0000 and must not pass through a 32-bit int.
`define aip_cmd_str_1u1s_status(Ccmd, svtask, ns1, ds1, ni1, di1, ns2, ds2, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    task cmd_exec(); \
        string ns1; longint unsigned ni1; string ns2; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ns1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v3 = aip_cmd::get_arg(this.args_in, `"ns2`"); \
            ns1 = (__v1 != "") ? __v1 : ds1; \
            ni1 = (__v2 != "") ? aip_cmd::parse_int64_arg(__v2) : di1; \
            ns2 = (__v3 != "") ? __v3 : ds2; \
        end \
        svtask(ns1, ni1, ns2); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 0 output
`define aip_cmd_4i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
            end \
            svtask(ni1, ni2, ni3, ni4); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 0 output
`define aip_cmd_5i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 6 int inputs, 0 output
`define aip_cmd_6i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TI6 ni6; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                string __v6 = aip_cmd::get_arg(this.args_in, `"ni6`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
                ni6 = (__v6 != "") ? TI6'(aip_cmd::parse_int_arg(__v6)) : di6; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, ni6); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 7 int inputs, 0 output
`define aip_cmd_7i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TI6 ni6; TI7 ni7; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                string __v6 = aip_cmd::get_arg(this.args_in, `"ni6`"); \
                string __v7 = aip_cmd::get_arg(this.args_in, `"ni7`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
                ni6 = (__v6 != "") ? TI6'(aip_cmd::parse_int_arg(__v6)) : di6; \
                ni7 = (__v7 != "") ? TI7'(aip_cmd::parse_int_arg(__v7)) : di7; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, ni6, ni7); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 8 int inputs, 0 output
`define aip_cmd_8i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TI6 ni6; TI7 ni7; TI8 ni8; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                string __v6 = aip_cmd::get_arg(this.args_in, `"ni6`"); \
                string __v7 = aip_cmd::get_arg(this.args_in, `"ni7`"); \
                string __v8 = aip_cmd::get_arg(this.args_in, `"ni8`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
                ni6 = (__v6 != "") ? TI6'(aip_cmd::parse_int_arg(__v6)) : di6; \
                ni7 = (__v7 != "") ? TI7'(aip_cmd::parse_int_arg(__v7)) : di7; \
                ni8 = (__v8 != "") ? TI8'(aip_cmd::parse_int_arg(__v8)) : di8; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, ni6, ni7, ni8); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 9 int inputs, 0 output
`define aip_cmd_9i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TI6 ni6; TI7 ni7; TI8 ni8; TI9 ni9; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                string __v6 = aip_cmd::get_arg(this.args_in, `"ni6`"); \
                string __v7 = aip_cmd::get_arg(this.args_in, `"ni7`"); \
                string __v8 = aip_cmd::get_arg(this.args_in, `"ni8`"); \
                string __v9 = aip_cmd::get_arg(this.args_in, `"ni9`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
                ni6 = (__v6 != "") ? TI6'(aip_cmd::parse_int_arg(__v6)) : di6; \
                ni7 = (__v7 != "") ? TI7'(aip_cmd::parse_int_arg(__v7)) : di7; \
                ni8 = (__v8 != "") ? TI8'(aip_cmd::parse_int_arg(__v8)) : di8; \
                ni9 = (__v9 != "") ? TI9'(aip_cmd::parse_int_arg(__v9)) : di9; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, ni6, ni7, ni8, ni9); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 10 int inputs, 0 output
`define aip_cmd_10i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9, TI10, ni10, di10) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TI6 ni6; TI7 ni7; TI8 ni8; TI9 ni9; TI10 ni10; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                string __v6 = aip_cmd::get_arg(this.args_in, `"ni6`"); \
                string __v7 = aip_cmd::get_arg(this.args_in, `"ni7`"); \
                string __v8 = aip_cmd::get_arg(this.args_in, `"ni8`"); \
                string __v9 = aip_cmd::get_arg(this.args_in, `"ni9`"); \
                string __v10 = aip_cmd::get_arg(this.args_in, `"ni10`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
                ni6 = (__v6 != "") ? TI6'(aip_cmd::parse_int_arg(__v6)) : di6; \
                ni7 = (__v7 != "") ? TI7'(aip_cmd::parse_int_arg(__v7)) : di7; \
                ni8 = (__v8 != "") ? TI8'(aip_cmd::parse_int_arg(__v8)) : di8; \
                ni9 = (__v9 != "") ? TI9'(aip_cmd::parse_int_arg(__v9)) : di9; \
                ni10 = (__v10 != "") ? TI10'(aip_cmd::parse_int_arg(__v10)) : di10; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, ni6, ni7, ni8, ni9, ni10); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 1 output
`define aip_cmd_3i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
            end \
            svtask(ni1, ni2, ni3, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 1 output
`define aip_cmd_4i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
            end \
            svtask(ni1, ni2, ni3, ni4, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 1 output
`define aip_cmd_5i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 2 outputs
`define aip_cmd_1i2o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TO1 no1; TO2 no2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            end \
            svtask(ni1, no1, no2); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 3 outputs
`define aip_cmd_1i3o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TO1 no1; TO2 no2; TO3 no3; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            end \
            svtask(ni1, no1, no2, no3); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2, `"no3`", no3); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 2 outputs
`define aip_cmd_3i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TO1 no1; TO2 no2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
            end \
            svtask(ni1, ni2, ni3, no1, no2); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 2 outputs
`define aip_cmd_4i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TO1 no1; TO2 no2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
            end \
            svtask(ni1, ni2, ni3, ni4, no1, no2); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 2 outputs
`define aip_cmd_5i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TO1 no1; TO2 no2; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, no1, no2); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 3 outputs
`define aip_cmd_3i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TO1 no1; TO2 no2; TO3 no3; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
            end \
            svtask(ni1, ni2, ni3, no1, no2, no3); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2, `"no3`", no3); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 3 outputs
`define aip_cmd_4i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TO1 no1; TO2 no2; TO3 no3; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
            end \
            svtask(ni1, ni2, ni3, ni4, no1, no2, no3); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2, `"no3`", no3); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 3 outputs
`define aip_cmd_5i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TI1 ni1; TI2 ni2; TI3 ni3; TI4 ni4; TI5 ni5; TO1 no1; TO2 no2; TO3 no3; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
                string __v3 = aip_cmd::get_arg(this.args_in, `"ni3`"); \
                string __v4 = aip_cmd::get_arg(this.args_in, `"ni4`"); \
                string __v5 = aip_cmd::get_arg(this.args_in, `"ni5`"); \
                ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
                ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
                ni3 = (__v3 != "") ? TI3'(aip_cmd::parse_int_arg(__v3)) : di3; \
                ni4 = (__v4 != "") ? TI4'(aip_cmd::parse_int_arg(__v4)) : di4; \
                ni5 = (__v5 != "") ? TI5'(aip_cmd::parse_int_arg(__v5)) : di5; \
            end \
            svtask(ni1, ni2, ni3, ni4, ni5, no1, no2, no3); \
            this.result_out = $sformatf("%s=0x%0h %s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2, `"no3`", no3); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 enum input, 0 output
// Iterates enum values and matches name case-insensitively
`define aip_cmd_enum_1i(Ccmd, svtask, TE1, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TE1 ni1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                if (__v1 != "") begin \
                    TE1 __e = __e.first(); \
                    string __lower_v = aip_str::lower(__v1); \
                    bit __matched = 0; \
                    forever begin \
                        if (aip_str::lower(__e.name()) == __lower_v) begin \
                            ni1 = __e; \
                            __matched = 1; \
                            break; \
                        end \
                        if (__e == __e.last()) break; \
                        __e = __e.next(); \
                    end \
                    if (!__matched) ni1 = di1; \
                end else begin \
                    ni1 = di1; \
                end \
            end \
            svtask(ni1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 enum input, 1 output
`define aip_cmd_enum_1i1o(Ccmd, svtask, TE1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    /* 按注册类型解析参数并调用用户任务；输入/输出保留在当前命令 handle。 */ \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            TE1 ni1; TO1 no1; \
            begin \
                string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
                if (__v1 != "") begin \
                    TE1 __e = __e.first(); \
                    string __lower_v = aip_str::lower(__v1); \
                    bit __matched = 0; \
                    forever begin \
                        if (aip_str::lower(__e.name()) == __lower_v) begin \
                            ni1 = __e; \
                            __matched = 1; \
                            break; \
                        end \
                        if (__e == __e.last()) break; \
                        __e = __e.next(); \
                    end \
                    if (!__matched) ni1 = di1; \
                end else begin \
                    ni1 = di1; \
                end \
            end \
            svtask(ni1, no1); \
            this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
            this.status = 0; \
        end \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    /* 创建常驻注册对象，执行能力与结果通道由基类统一配置。 */ \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// ============================================================
// Seq Registration Macro — bind seq type + sequencer to command
//
// Usage:
//   `aip_cmd_seq(axi_write, axi_wr_seq, virtual_sqr::axi_wr_sqr)
//
// TCL (count mode — send N transactions):
//   axi_write count=10
//   axi_write                    ;# default count=1
//
// TCL (time mode — send for specified duration):
//   axi_write time=1us
//   axi_write time=500ns
//   axi_write time=100ps
//
// Seq class must have: int count;
// In time mode, count is set to max and a timer kills the seq.
// Trans parameters come from aip_cmdline (plusargs/override).
// ============================================================

`define aip_cmd_seq(cmd_name, seq_type, sequencer) \
class \__aip_seq_``cmd_name ; \
    /* 创建并登记本次seq；count正常完成或time到期取消后注销，不保证driver协议回滚。 */ \
    static task launch(); \
        string __args = aip_cmd::get_handle(`"cmd_name`").args_in; \
        string __count_s = aip_cmd::get_arg(__args, "count"); \
        string __time_s  = aip_cmd::get_arg(__args, "time"); \
        seq_type __seq; \
        __seq = seq_type::type_id::create(`"cmd_name`"); \
        \
        if (__time_s != "") begin \
            /* 时间到期取消sequence；driver已接受的事务仍需用户按协议处理。 */ \
            real __timeout_ns = aip_cmd::parse_time_ns(__time_s); \
            __seq.count = 2147483647; \
            aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
            `aip_info(("[SEQ] %s start, time=%s (%.1f ns)", `"cmd_name`", __time_s, __timeout_ns)); \
            fork \
                __seq.start(sequencer); \
                begin \
                    aip_time::delay_ns(__timeout_ns); \
                    __seq.kill(); \
                end \
            join \
            aip_cmd_seq_registry::unregister(`"cmd_name`"); \
            aip_activity::tick(); \
            `aip_info(("[SEQ] %s done (timed)", `"cmd_name`")); \
            begin \
                aip_cmd __h = aip_cmd::get_handle(`"cmd_name`"); \
                __h.result_out = $sformatf("OK: %s time=%s", `"cmd_name`", __time_s); \
                __h.status = 0; \
            end \
        end else begin \
            /* Count mode (default) */ \
            int __count = aip_cmd::parse_int_arg(__count_s, 1); \
            __seq.count = __count; \
            aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
            `aip_info(("[SEQ] %s start, count=%0d", `"cmd_name`", __count)); \
            __seq.start(sequencer); \
            aip_cmd_seq_registry::unregister(`"cmd_name`"); \
            aip_activity::tick(); \
            `aip_info(("[SEQ] %s done", `"cmd_name`")); \
            begin \
                aip_cmd __h = aip_cmd::get_handle(`"cmd_name`"); \
                __h.result_out = $sformatf("OK: %s count=%0d", `"cmd_name`", __count); \
                __h.status = 0; \
            end \
        end \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_seq_``cmd_name ::launch)

// ============================================================
// User Sequence Registration Macro — zero-adaptation launcher
//
// Usage:
//   `aip_cmd_user_seq(link_up, my_link_up_seq, my_vsqr::pcie_sqr)
//
// The user sequence owns all argument parsing and field setup.  This is
// intended for sequences such as SVT link-up/configuration wrappers where
// the sequence itself must set the official sequence's `enable` field.
// The framework only creates and starts the sequence, tracks it for
// kill_seq/watchdog, and supplies a default result when needed.
//
// A user sequence can read its Tcl arguments with:
//   aip_cmd::get_handle("link_up").args_in
// and can set result_out/status on that handle itself.
// ============================================================

`define aip_cmd_user_seq(cmd_name, seq_type, sequencer) \
class \__aip_user_seq_``cmd_name ; \
    /* 保留用户业务参数和返回值；登记本次seq所有权，正常返回后注销并报告活动。 */ \
    static task launch(); \
        aip_cmd __h; \
        seq_type __seq; \
        __h = aip_cmd::get_handle(`"cmd_name`"); \
        if (__h == null) begin \
            `aip_error(("[USER_SEQ] command '%s' handle not found", `"cmd_name`")); \
            return; \
        end \
        __seq = seq_type::type_id::create(`"cmd_name`"); \
        if (__seq == null) begin \
            __h.result_out = $sformatf("ERROR: %s sequence create failed", `"cmd_name`"); \
            __h.status = 1; \
            return; \
        end \
        aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
        `aip_info(("[USER_SEQ] %s start", `"cmd_name`")); \
        __seq.start(sequencer); \
        aip_cmd_seq_registry::unregister(`"cmd_name`"); \
        aip_activity::tick(); \
        if (__h.result_out == "") \
            __h.result_out = $sformatf("OK: %s", `"cmd_name`"); \
        `aip_info(("[USER_SEQ] %s done", `"cmd_name`")); \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_user_seq_``cmd_name ::launch)

// ============================================================
// Strict C-sequence registration.  The supplied sequencer is grabbed before
// the sequence starts and released after the complete sequence returns.  An
// grab itself does not interrupt an in-flight bus item; it is granted at the
// next sequencer arbitration point. Explicit kill/time/watchdog cancellation
// still needs protocol-specific driver cleanup when a request is pending.
// ============================================================

`define aip_cmd_cseq(cmd_name, seq_type, sequencer) \
class \__aip_cseq_impl_``cmd_name extends seq_type; \
    /* 沿用用户seq构造；本包装只在正常pre/post_body期间拥有sequencer仲裁权。 */ \
    function new(string name = `"cmd_name`"); super.new(name); endfunction \
    /* 开始业务前取得独占仲裁；被取消时依赖UVM kill释放sequence资源。 */ \
    virtual task pre_body(); this.grab(); super.pre_body(); endtask \
    /* 正常业务结束后释放独占仲裁，不负责driver侧已发事务的恢复。 */ \
    virtual task post_body(); super.post_body(); this.ungrab(); endtask \
endclass \
class \__aip_cseq_``cmd_name ; \
    /* 创建严格仲裁seq，按count/time运行；返回汇总写本次命令handle。 */ \
    static task launch(); \
        string __args = aip_cmd::get_handle(`"cmd_name`").args_in; \
        string __count_s = aip_cmd::get_arg(__args, "count"); \
        string __time_s  = aip_cmd::get_arg(__args, "time"); \
        \__aip_cseq_impl_``cmd_name __seq; \
        __seq = new(`"cmd_name`"); \
        if (__time_s != "") begin \
            real __timeout_ns = aip_cmd::parse_time_ns(__time_s); \
            __seq.count = 2147483647; \
            aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
            `aip_info(("[CSEQ] %s grab, time=%s (%.1f ns)", `"cmd_name`", __time_s, __timeout_ns)); \
            fork \
                __seq.start(sequencer); \
                begin \
                    aip_time::delay_ns(__timeout_ns); \
                    __seq.kill(); \
                end \
            join \
            aip_cmd_seq_registry::unregister(`"cmd_name`"); \
            aip_activity::tick(); \
            begin \
                aip_cmd __h = aip_cmd::get_handle(`"cmd_name`"); \
                __h.result_out = $sformatf("OK: %s time=%s", `"cmd_name`", __time_s); \
                __h.status = 0; \
            end \
        end else begin \
            int __count = aip_cmd::parse_int_arg(__count_s, 1); \
            __seq.count = __count; \
            aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
            `aip_info(("[CSEQ] %s grab, count=%0d", `"cmd_name`", __count)); \
            __seq.start(sequencer); \
            aip_cmd_seq_registry::unregister(`"cmd_name`"); \
            aip_activity::tick(); \
            begin \
                aip_cmd __h = aip_cmd::get_handle(`"cmd_name`"); \
                __h.result_out = $sformatf("OK: %s count=%0d", `"cmd_name`", __count); \
                __h.status = 0; \
            end \
        end \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_cseq_``cmd_name ::launch)

// ============================================================
// 寄存器 sequence 注册：共用严格标量解析，支持命名参数和 op addr len data [mask]。
// seq 必须提供 is_write/addr/len/mask/wdata/rdata；data 支持 1..128 位 packed 字段，
// 用注册类型的 $bits(wdata) 检查溢出，因此旧 64 位 sequence 无需改字段。
// len 缺省 4；mask 缺省改为 0，具体含义由总线 sequence 定义，PCIe 约定 1=屏蔽字节。
// 第四参数 error_expr 可选：在 sequence 返回后求值，空串表示成功，否则返回 status=1。
// 表达式可引用当前对象 seq，例如 seq.error_msg；旧三参数宏不要求新增错误字段。
//   `aip_cmd_reg(reg_acc, pcie_tl_reg_seq, my_vsqr::pcie_sqr, seq.error_msg)
//   reg_acc write 0x1000 16 0x112233445566778899aabbccddeeff00
//   reg_acc read 0x1000 16
// 可选第五项 seq.check_read_data 映射逐次比较策略；旧3/4参数注册不要求该字段。
// 缺少参数/非法数值/不支持的显式策略直接返回 ERROR，不启动 sequence。
// ============================================================
`include "core/aip_reg_args.sv"

`define aip_cmd_reg(cmd_name, seq_type, sequencer, error_expr = "", check_read_data_target = __aip_unused_read_check) \
class \__aip_reg_``cmd_name ; \
    /* 每次调用独占解析对象和sequence；错误返回前不登记任何总线活动。 */ \
    static task launch(); \
        aip_cmd	__h; \
        aip_reg_args	__args; \
        seq_type	seq; \
        string	__error; \
        bit	__aip_unused_read_check; \
        __h = aip_cmd::get_handle(`"cmd_name`"); \
        __args = new(); \
        seq = seq_type::type_id::create(`"cmd_name`"); \
        if (seq == null) begin \
            __h.result_out = "ERROR: register sequence create failed"; \
            __h.status = 1; \
            return; \
        end \
        if (!__args.parse(__h.args_in, $bits(seq.wdata))) begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": ", __args.error_msg}; \
            __h.status = 1; \
            return; \
        end \
        /* 未提供第五项映射的旧注册仍可编译，但显式请求新策略必须报错而非忽略。 */ \
        if (__args.check_read_data_present && `"check_read_data_target`" == "__aip_unused_read_check") begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": check_read_data is not supported by this registration"}; \
            __h.status = 1; \
            return; \
        end \
        check_read_data_target = __args.check_read_data; \
        seq.is_write = __args.is_write; \
        seq.addr = __args.addr; \
        seq.len = __args.len; \
        seq.mask = __args.mask; \
        seq.wdata = __args.wdata; \
        `aip_info(("[REG] %s op=%s addr=0x%0h len=%0d mask=0x%0h", `"cmd_name`", \
                   (__args.is_write ? "write" : "read"), __args.addr, __args.len, __args.mask)); \
        aip_cmd_seq_registry::register(`"cmd_name`", seq); \
        seq.start(sequencer); \
        aip_cmd_seq_registry::unregister(`"cmd_name`"); \
        aip_activity::tick(); \
        __error = error_expr; \
        if (__error != "") begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": ", __error}; \
            __h.status = 1; \
            return; \
        end \
        if (!__args.is_write) __h.result_out = $sformatf("rdata=0x%0h", seq.rdata); \
        else __h.result_out = $sformatf("OK: write addr=0x%0h data=0x%0h", __args.addr, __args.wdata); \
        __h.status = 0; \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_reg_``cmd_name ::launch)

// 严格寄存器入口沿用同一参数契约；仅在整个 sequence 正常执行期间 grab 仲裁权。
`define aip_cmd_creg(cmd_name, seq_type, sequencer, error_expr = "", check_read_data_target = __aip_unused_read_check) \
class \__aip_creg_impl_``cmd_name extends seq_type; \
    /* 派生类不改变业务字段或错误协议，只增加独占仲裁。 */ \
    function new(string name = `"cmd_name`"); super.new(name); endfunction \
    /* 已被driver接收的事务不会被打断；取得仲裁后执行用户pre_body。 */ \
    virtual task pre_body(); this.grab(); super.pre_body(); endtask \
    /* 正常返回释放仲裁；kill时的资源回收沿用UVM既有行为。 */ \
    virtual task post_body(); super.post_body(); this.ungrab(); endtask \
endclass \
class \__aip_creg_``cmd_name ; \
    /* 每次调用独占解析对象和sequence；错误返回前不登记任何总线活动。 */ \
    static task launch(); \
        aip_cmd	__h; \
        aip_reg_args	__args; \
        \__aip_creg_impl_``cmd_name	seq; \
        string	__error; \
        bit	__aip_unused_read_check; \
        __h = aip_cmd::get_handle(`"cmd_name`"); \
        __args = new(); \
        seq = new(`"cmd_name`"); \
        if (seq == null) begin \
            __h.result_out = "ERROR: register sequence create failed"; \
            __h.status = 1; \
            return; \
        end \
        if (!__args.parse(__h.args_in, $bits(seq.wdata))) begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": ", __args.error_msg}; \
            __h.status = 1; \
            return; \
        end \
        /* 未提供第五项映射的旧注册仍可编译，但显式请求新策略必须报错而非忽略。 */ \
        if (__args.check_read_data_present && `"check_read_data_target`" == "__aip_unused_read_check") begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": check_read_data is not supported by this registration"}; \
            __h.status = 1; \
            return; \
        end \
        check_read_data_target = __args.check_read_data; \
        seq.is_write = __args.is_write; \
        seq.addr = __args.addr; \
        seq.len = __args.len; \
        seq.mask = __args.mask; \
        seq.wdata = __args.wdata; \
        `aip_info(("[REG] %s op=%s addr=0x%0h len=%0d mask=0x%0h", `"cmd_name`", \
                   (__args.is_write ? "write" : "read"), __args.addr, __args.len, __args.mask)); \
        aip_cmd_seq_registry::register(`"cmd_name`", seq); \
        seq.start(sequencer); \
        aip_cmd_seq_registry::unregister(`"cmd_name`"); \
        aip_activity::tick(); \
        __error = error_expr; \
        if (__error != "") begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": ", __error}; \
            __h.status = 1; \
            return; \
        end \
        if (!__args.is_write) __h.result_out = $sformatf("rdata=0x%0h", seq.rdata); \
        else __h.result_out = $sformatf("OK: write addr=0x%0h data=0x%0h", __args.addr, __args.wdata); \
        __h.status = 0; \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_creg_``cmd_name ::launch)

// ============================================================
// CPU Command Registration Macro
// Registers a command name that routes to CPU firmware via aip_cpu_bridge.
// The command is registered as a placeholder in aip_cmd registry,
// and flagged in __aip_cmd_is_cpu for routing in exec().
//
// Usage:
//   `aip_cmd_cpu(read_reg)
//   `aip_cmd_cpu(dma_test)
//
// TCL:
//   read_reg addr=0x100              ;# sync, waits for CPU response
//   dma_test src=0x1000 async=1      ;# async, returns immediately
// ============================================================
`define aip_cmd_cpu(Ccmd) \
class \__aip_cmd_cpu_``Ccmd extends aip_cmd; \
    /* CPU入口是占位对象，调度器先按is_cpu路由，不调用此空业务方法。 */ \
    task cmd_exec(); \
    endtask \
    /* 注册CPU路由标志；等待语义由固件async协议提供，不开放框架wait。 */ \
    function new(string name); \
        super.new(name); \
        __aip_cmd_is_cpu[name] = 1; \
    endfunction \
    static \__aip_cmd_cpu_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`endif // AIP_CMD_SV
