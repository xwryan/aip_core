// 命令注册、参数分发与用户 task/sequence 的执行生命周期。注册对象常驻，同名调用共享 handle，
// 调度器须先取得执行所有权再改参数/结果；每次调用新建结果上下文，遗留子线程污染不了下一次调用。
// wait=0 时 worker 在后台持有 handle，前台只回 STARTED；注入预约在派发入口登记，直接调用不能插队。
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

typedef class aip_cmd;
typedef class aip_cmd_execution;
typedef class aip_cmd_execution_scope;

typedef enum {AIP_CMD_COMPLETED, AIP_CMD_CANCELLED, AIP_CMD_WATCHDOG} aip_cmd_end_e;

// 内部终态订阅，与用户 watchdog hook 分离，不依赖 RAL；回调是 function，不得启动阻塞清理。
virtual class aip_cmd_liveness_listener;
    // 每个 execution 至多回调一次；派生类自行核对 generation，不依赖 result context。
    pure virtual function void on_terminal(aip_cmd_execution execution, aip_cmd_end_e reason);
endclass

// 一次真实 worker 的执行身份，由调度器持有；旧引用不能冒充新调用。
// owner 是真实 worker，而非外层 dispatch 占位进程。
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

    function new(process owner0, aip_cmd_execution_scope scope0);
        if (next_id == '1) $fatal(1, "AIP_CMD execution identity exhausted");
        identity = ++next_id;
        owner = owner0;
        scope = scope0;
    endfunction

    // 数值仅供诊断；授权须同时比对对象身份与 owner。
    function longint unsigned get_id(); return identity; endfunction

    function process get_owner(); return owner; endfunction

    function bit subscribe(aip_cmd_liveness_listener listener0);
        if (terminal || listener0 == null || owner != process::self() || listener != null) return 0;
        listener = listener0;
        return 1;
    endfunction

    // 协作取消只记录意图，cleanup 仍由活着的 worker 完成。
    function bit request_cancel();
        if (terminal || owner != process::self()) return 0;
        cancel_requested = 1;
        return 1;
    endfunction

    // 曾登记 sequence 的证据不可撤销（注销不清除）：判定能否干净 kill 时，
    // 不能用 FINISHED 推断子 sequence 已清空。
    function void note_sequence(); sequence_seen = 1; endfunction

    function bit had_sequence(); return sequence_seen; endfunction

    function bit is_terminal(); return terminal; endfunction

    function aip_cmd_end_e get_end_reason(); return terminal_reason; endfunction

    // worker 正常尾声调用；回调先于 result context 失效，且只发生一次。
    function void complete();
        if (terminal || owner != process::self()) return;
        terminal = 1;
        terminal_reason = cancel_requested ? AIP_CMD_CANCELLED : AIP_CMD_COMPLETED;
        if (listener != null) listener.on_terminal(this, terminal_reason);
        listener = null;
        scope = null;
    endfunction

    // 只接受确已死亡的 owner；迟到的通知不覆盖首个终态。
    function void notify_dead(aip_cmd_end_e reason);
        if (!(reason inside {AIP_CMD_CANCELLED, AIP_CMD_WATCHDOG}) || terminal || owner == null ||
            !(owner.status() inside {process::KILLED, process::FINISHED})) return;
        terminal = 1;
        terminal_reason = reason;
        if (listener != null) listener.on_terminal(this, reason);
        listener = null;
        scope = null;
    endfunction

    // 订阅的 listener 在终态回调内发布独立结果，不接触已失效的 result context。
    function bit publish_terminal_result(aip_cmd_liveness_listener publisher, string text0);
        if (!terminal || listener == null || publisher != listener) return 0;
        terminal_text = text0;
        result_available = 1;
        return 1;
    endfunction

    // bridge 只消费 watchdog 生成的业务结果，其他情况保留命令原文字。
    function bit watchdog_result(output string text0);
        text0 = "";
        if (!result_available || terminal_reason != AIP_CMD_WATCHDOG) return 0;
        text0 = terminal_text;
        return 1;
    endfunction

    // finish 用它让取消/清理失败诊断覆盖业务旧 OK。
    function bit completion_result(output string text0);
        text0 = "";
        if (!result_available || terminal_reason == AIP_CMD_WATCHDOG) return 0;
        text0 = terminal_text;
        return 1;
    endfunction
endclass

// 一次 dispatch 树启动过的执行身份，跨同步嵌套/fork 传播；watchdog 按请求 scope 而非命令名寻址。
class aip_cmd_execution_scope;
    local aip_cmd_execution executions[$];

    function void add(aip_cmd_execution execution); executions.push_back(execution); endfunction

    // kill 后调用：只通知已死亡的后代，不影响仍活着的任务；返回首个 watchdog 业务结果。
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

// 一次性 FIFO 准入资格，不含业务参数或执行上下文。token 归注入服务；
// 核心只在准入/取消前持有队列引用，过期 token 不可再用。
class aip_cmd_admission;
    aip_cmd command_handle;
    longint unsigned ticket;
    bit active;

    function new(aip_cmd handle, longint unsigned id);
        command_handle = handle;
        ticket = id;
        active = 1;
    endfunction
endclass

// 放在 package 级而非类静态成员，以兼容旧 VCS；只通知资源变化，不携带结果。
event __aip_cmd_admission_changed;

// 注入服务接受时递增、release 时递减；派发入口据此拒绝生命周期命令，核心无需反向依赖注入桥。
int unsigned __aip_injection_live_tickets = 0;

// 单次调用的结果容器，调用结束即失效。fork 子线程须在 fork 前捕获它并显式调用 ctx.set_result，
// 因为 process API 无法查询父进程。
class aip_cmd_result_context;
    int status;
    string result_text;
    bit assigned;
    bit active;
    process owner_process;
    // 同步派发链，仅用于识别父命令等待子命令时的 legacy 重入；后台边界（parent_waits=0）截断该链。
    aip_cmd_result_context call_parent;
    bit parent_waits;
    // legacy 槽的上下文栈：子命令保存父全局值，结束或被取消后还原。
    aip_cmd_result_context legacy_parent;
    int legacy_saved_status;
    string legacy_saved_result;

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

    function void bind_owner(process owner);
        owner_process = owner;
    endfunction

    function bit is_active();
        if (active && owner_process != null &&
            (owner_process.status() == process::FINISHED ||
             owner_process.status() == process::KILLED))
            active = 0;
        return active;
    endfunction

    // fork 子线程须在命令 owner 返回前写入；失效后写入直接 fatal，绝不退回全局槽。
    function void set_result(int result_status, string text);
        if (!is_active()) begin
            $fatal(1, "AIP_CMD[result] Cannot write an inactive command result context");
            return;
        end
        status = result_status;
        result_text = text;
        assigned = 1;
    endfunction

    function void invalidate();
        active = 0;
    endfunction
endclass

// Kept outside the class for VCS Q-2020: static class-typed assoc arrays inside a class may break.
aip_cmd __aip_cmd_registry[string];

// 注册表每次新增/注销加 1，Tcl bridge 据此重发命令名表；不设初值，避免受静态初始化顺序影响。
int unsigned __aip_cmd_registry_version;

// 旧静态 facade 直接调用时没有注册 handle，在此登记临时上下文，供 set_result 按 process 定位。
aip_cmd_result_context __aip_compat_result_scopes[$];

// CPU command flag registry — 1 = route to aip_cpu_bridge
bit __aip_cmd_is_cpu[string];

// 活动 seq 登记表（放在类外的原因同命令注册表）。取消/watchdog 用 UVM kill() 终止 sequence，
// 不保证 driver 已发出的协议事务能回滚或恢复。
uvm_sequence_base __aip_active_seqs[string];
// 登记时的执行进程：watchdog 只清理已取消命令的 sequence，不误杀先前已 ACK 的后台 sequence。
process __aip_active_seq_owners[string];

class aip_cmd_seq_registry;
    static function void register(string cmd_name, uvm_sequence_base seq);
        aip_cmd_execution execution = aip_cmd::get_current_execution();
        __aip_active_seqs[cmd_name] = seq;
        __aip_active_seq_owners[cmd_name] = process::self();
        if (execution != null) execution.note_sequence();
    endfunction
    static function void unregister(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name)) __aip_active_seqs.delete(cmd_name);
        if (__aip_active_seq_owners.exists(cmd_name)) __aip_active_seq_owners.delete(cmd_name);
    endfunction
    // 显式全局清理；普通 watchdog 不使用。
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
    static function int kill_one(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name) && __aip_active_seqs[cmd_name] != null) begin
            __aip_active_seqs[cmd_name].kill();
            unregister(cmd_name);
            return 1;
        end
        return 0;
    endfunction
    // 只回收 owner 已被 KILLED 的 seq：FINISHED 不代表其子 sequence 已结束。
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

    static function int count();
        return __aip_active_seqs.num();
    endfunction

    // cmd_name 登记的 sequence 是否仍在执行：登记存在且登记进程未结束、未被杀；watchdog 取消后即为 0。
    static function bit active(string cmd_name);
        process owner;
        if (!__aip_active_seqs.exists(cmd_name) || __aip_active_seqs[cmd_name] == null) return 0;
        owner = __aip_active_seq_owners.exists(cmd_name) ? __aip_active_seq_owners[cmd_name] : null;
        return owner != null && !(owner.status() inside {process::FINISHED, process::KILLED});
    endfunction

    static function bit has_owner(process owner);
        foreach (__aip_active_seq_owners[name])
            if (__aip_active_seq_owners[name] == owner) return 1;
        return 0;
    endfunction
endclass


// 命令注册对象常驻、同名调用共享；process 与结果上下文只在一次 cmd_exec 期间有效。
// 不为每次调用复制 handle，是为了兼容用户 sequence 用 get_handle(get_name()) 取参数。
class aip_cmd;

    string cmd_name;
    string group;
    string description;
    string param_info;
    string args_in;
    string result_out;
    int    status;

    // 内置控制命令默认仅同步；用户宏经专用基类开放后台。
    bit background_allowed;
    bit uses_legacy_result;
    local bit execution_busy;
    local process execution_process;
    local aip_cmd_result_context result_context;
    local aip_cmd_execution execution;
    local aip_cmd_execution_scope execution_scope;
    local bit macro_result_scope_active;
    // legacy 全局结果槽：不同执行链互斥，同一同步调用链可压栈重入。
    local static process legacy_result_owner;
    local static aip_cmd_result_context legacy_result_context;

    // 注入准入 FIFO：局部命令按 handle 排队，legacy 命令共享全局槽故共用一个；只存 token。
    local aip_cmd_admission injection_admissions[$];
    local static aip_cmd_admission legacy_injection_admissions[$];

    static int    __aip_cmd_last_status;
    static string __aip_cmd_last_result;

    // 局部模式写 handle/context；legacy 模式须持有全局槽所有权才可写，避免交错写入。
    virtual task cmd_exec();
    endtask

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
            __aip_cmd_registry_version++;
        end
    endfunction

    static function aip_cmd get_handle(string name);
        if (__aip_cmd_registry.exists(name))
            return __aip_cmd_registry[name];
        else
            return null;
    endfunction

    // 供插件卸载；调用方须确保没有在途命令。
    static function void unregister(string name);
        if (__aip_cmd_registry.exists(name)) begin
            __aip_cmd_registry.delete(name);
            __aip_cmd_registry_version++;
        end
    endfunction

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

    // 宽松解析，brace 值保留括号；框架 wait 不用它，以免把嵌套业务字符串误认成控制参数。
    static function string get_arg(string args, string key);
        string search_key;
        int pos;
        int val_start;
        int val_end;
        int brace_depth;
        byte prev_char;

        if (args == "" || key == "") return "";

        search_key = {key, "="};
        // Match "key=" only at the start or after space/comma/tab ("xpath=" must not match "path").
        pos = aip_str::str_find(args, search_key);
        while (pos > 0) begin
            prev_char = args[pos - 1];
            if (prev_char == 8'd32 || prev_char == 8'd44 || prev_char == 8'd9) break;
            pos = aip_str::str_find(args, search_key, pos + 1);
        end
        if (pos == -1) return "";

        val_start = pos + search_key.len();
        if (val_start >= args.len()) return "";

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
            val_end = val_start;
            while (val_end < args.len()) begin
                if (args[val_end] == 8'd32 || args[val_end] == 8'd44 || args[val_end] == 8'd9) break;
                val_end = val_end + 1;
            end
            if (val_end == val_start) return "";
            return args.substr(val_start, val_end - 1);
        end
    endfunction

    // 返回同名参数的全部值（按出现顺序）；按顶层 token 切分，brace/bracket/quote 内不拆。
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

    static function int parse_int_arg(string s, int default_val = 0);
        int width;
        longint unsigned result;
        if (s == "") return default_val;
        result = aip_str::str_to_num(s, width);
        // str_to_num returns -1 ({64{1'b1}}) with width=0 on error
        if (width == 0 && result == {64{1'b1}}) return default_val;
        return int'(result);
    endfunction

    static function longint unsigned parse_int64_arg(string s, longint unsigned dv = 0);
        int width;
        longint unsigned result;
        if (s == "") return dv;
        result = aip_str::str_to_num(s, width);
        if (width == 0 && result == {64{1'b1}}) return dv;
        return result;
    endfunction

    // 严格无符号解析：空串取 dv；负数、非整数字面量或超过 max 返回 0 并给出原因，value 保持 dv
    // （parse_int64_arg 则静默回落默认值）。name 非空时原因以 "name=s" 开头。
    static function bit parse_uint_arg(string s, longint unsigned max, longint unsigned dv,
                                       output longint unsigned value, output string why,
                                       input string name = "");
        aip_vec_t v;
        int width;
        bit negative;
        string label;
        value = dv;
        why = "";
        if (s == "") return 1;
        label = (name == "") ? {"'", s, "'"} : {name, "=", s};
        if (!aip_str::str_to_vec(s, v, width, negative)) begin
            why = {label, ": not an unsigned integer literal"};
            return 0;
        end
        if (negative) begin
            why = {label, ": negative value; expected an unsigned integer literal"};
            return 0;
        end
        if (v > aip_vec_t'(max)) begin
            why = $sformatf("%s: exceeds the maximum 0x%0h", label, max);
            return 0;
        end
        value = v[63:0];
        return 1;
    endfunction

    static function string parse_string_arg(string s, string default_val = "");
        string stripped;
        if (s == "") return default_val;
        stripped = aip_str::strip(s);
        if (stripped == "") return default_val;
        return stripped;
    endfunction

    // 无单位按 ns；非法数值返回 0，未知单位警告后按 ns。
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

        value = stripped.substr(0, num_end - 1).atoreal();

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

    static function bit is_arg_space(byte c);
        return c == 8'd32 || c == 8'd9 || c == 8'd10 || c == 8'd13;
    endfunction

    // 返回顶层 token 的结束位置：brace/bracket/双引号内不切分，反斜线转义下一字符。
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

    // 供 fork 只消费末尾 join/disable_remaining 选项；无 token 返回 -1。
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

    // 解析 wait=0/1 并按原始字符区间删除，其余 args 逐字保留（不重组 token、不吞业务尾逗号）。
    // 开头 wait 删后分隔符，中间删前分隔符，末尾只删前导空白；重复/空值/孤立 wait 均报错。
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

    // 被 watchdog/kill_seq 杀死的 worker 不会执行收尾，故按 process 状态惰性回收，防止永久 BUSY。
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

    // 逐层弹出已失效的 legacy 栈顶并恢复父调用的全局快照；只查 owner 状态，不杀进程。
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

    // 提交时即预约 FIFO，不改写 handle 参数；调用方保证 ticket 唯一且已检查槽位容量。
    function aip_cmd_admission reserve_injection(longint unsigned ticket);
        aip_cmd_admission token;
        token = new(this, ticket);
        if (uses_legacy_result) legacy_injection_admissions.push_back(token);
        else injection_admissions.push_back(token);
        -> __aip_cmd_admission_changed;
        return token;
    endfunction

    // 幂等，可承受迟到的超时/取消尾声；先作废再通知，等待者不会把已回收的 token 当作执行资格。
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

    // token=null 表示普通 exec_result，仅在无预约时放行；
    // 同步 legacy 后代的例外由派发层处理，避免父命令持槽死锁。
    function bit injection_turn(aip_cmd_admission token = null);
        if (token != null && (!token.active || token.command_handle != this)) return 0;
        if (uses_legacy_result) begin
            if (legacy_injection_admissions.size() == 0) return token == null;
            return token != null && legacy_injection_admissions[0] == token;
        end
        if (injection_admissions.size() == 0) return token == null;
        return token != null && injection_admissions[0] == token;
    endfunction

    // 队列 worker 的零阻塞准入检查，与随后的 exec_result 处于同一调度片。
    function bit injection_ready(aip_cmd_admission token);
        return injection_turn(token) && !is_busy() &&
               (!uses_legacy_result || !legacy_result_busy());
    endfunction

    // 仅同步后代可重入父调用占用的 legacy 槽（允许 legacy -> local -> legacy）；
    // fork 子线程没有当前上下文，后台边界也不能穿透。
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

    // 须在派生 worker 或任何阻塞前压栈并保存父全局值；调用者已完成 BUSY/血缘检查。
    static function void acquire_legacy_result(aip_cmd_result_context ctx);
        void'(legacy_result_busy());
        ctx.legacy_parent = legacy_result_context;
        ctx.legacy_saved_status = __aip_cmd_last_status;
        ctx.legacy_saved_result = __aip_cmd_last_result;
        legacy_result_context = ctx;
        legacy_result_owner = ctx.owner_process;
    endfunction

    // legacy 在途时仅 owner 及其同步后代可发布，防止 ACK/其他命令覆盖该 worker
    // 尚未读回的全局结果；不拦截用户直接赋值。
    static function void publish_compat_result(int result_status, string result_text);
        if (legacy_result_busy() && legacy_result_owner != process::self() &&
            !can_nest_legacy_result(1'b1)) return;
        __aip_cmd_last_status = result_status;
        __aip_cmd_last_result = result_text;
    endfunction

    // 按当前 process 查找（fork 子线程须事先捕获）；null 表示不在命令上下文中，如直接 SV 调用。
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
        // facade 上下文不在注册表中；倒序遍历，删除失效项时不会漏项。
        for (int i = __aip_compat_result_scopes.size() - 1; i >= 0; i--) begin
            if (__aip_compat_result_scopes[i] == null ||
                !__aip_compat_result_scopes[i].is_active())
                __aip_compat_result_scopes.delete(i);
            else if (__aip_compat_result_scopes[i].owner_process == caller)
                return __aip_compat_result_scopes[i];
        end
        return null;
    endfunction

    // 只按当前 process 匹配真实 worker，不按命令名、结果 context 或外层 caller 猜血缘。
    static function aip_cmd_execution get_current_execution();
        process caller = process::self();
        foreach (__aip_cmd_registry[name]) begin
            if (__aip_cmd_registry[name].execution_busy &&
                __aip_cmd_registry[name].execution_process == caller)
                return __aip_cmd_registry[name].execution;
        end
        return null;
    endfunction

    // 供旧静态 facade 的直接 SV 调用：已有上下文时返回 null（借用，外层收尾），
    // 否则新建上下文并在业务前独占 legacy 槽，被占用则立即 fatal，不能先操作后报错。
    // 做成 function 是为了 loader.check 等 function 入口也能使用。
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
        // 不清空旧镜像：如 check() 只返回布尔值，不应改变最近结果。
        return ctx;
    endfunction

    // 调用方须在每条 return 前收尾（取消由 owner 状态惰性回收）；未写结果时保留旧镜像。
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

    // 绝不回退到全局返回槽；无上下文通常是误在 fork 子线程中调用。
    static function void set_result(int result_status, string result_text);
        aip_cmd_result_context ctx;
        ctx = get_current_context();
        if (ctx == null) begin
            $fatal(1, "AIP_CMD[result] No current command context; capture get_current_context() before fork and use ctx.set_result() in the child");
            return;
        end
        ctx.set_result(result_status, result_text);
    endfunction

    // 内置旧 facade 专用：ctx 持有 legacy 槽时立即写槽且不置 assigned，
    // 外层旧 task 仍可读取并改写最终结果；否则写 ctx。
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

    // worker 开始后接管预占的所有权；只有 legacy 命令清零全局槽，局部结果命令不触碰它。
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

    // 结果优先级：显式 context > legacy 全局槽 > handle/typed 输出；先快照再释放。
    // context 先行失效，命令返回后仍写结果的遗留子线程会得到明确诊断。
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

    // 兼容直接 get_handle()->args_in->cmd_exec()：无上下文时建临时上下文并返回 1，由宏尾收尾；
    // 嵌套/重入则拒绝。只保证顺序使用，无法撤销已写入的 args_in，并发须走 exec_result。
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

    function void end_macro_result_scope(bit owns_scope);
        int completed_status;
        string completed_result;
        macro_result_scope_active = 0;
        if (owns_scope) begin
            finish_execution(completed_status, completed_result);
            publish_compat_result(completed_status, completed_result);
        end
    endfunction

    // 后台结果只留在自身 handle 并写日志，不能覆盖已发出的 STARTED 确认或后续命令的前台返回槽。
    static task run_background(aip_cmd handle);
        int completed_status;
        string completed_result;
        handle.cmd_exec();
        handle.finish_execution(completed_status, completed_result);
        `aip_info(("[AIP_CMD_BACKGROUND] %s finished status=%0d result=%s",
                   handle.cmd_name, completed_status, completed_result));
    endtask

    // 逐次结果入口，输出归本次调用独占；wait=0 只确认 worker 已派发（STARTED），不代表业务完成。
    // admission 仅供注入队列：无 token 的普通调用遇到排队预约返回 BUSY 而不插队，
    // 但已持 legacy 槽的同步后代可重入，以免父调用持槽死锁。
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

        // 生命周期命令会销毁执行环境或改变在途解析配置，须等全部注入 ticket 回收。
        if (__aip_injection_live_tickets != 0 &&
            (name == "end_test" || name == "so_load" || name == "so_reload" ||
             name == "so_unload" || name == "set_param" || name == "clear_param")) begin
            out_status = 1;
            out_result = {"BUSY: release all injection tickets before lifecycle command '", name, "'"};
            return;
        end

        // fork 的 wait 属于各子命令，父层不解析。
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

        // 占用 handle 前捕获父上下文：仅同步边允许 legacy 槽重入，不授予 fork 子进程写权限。
        caller_context = get_current_context();
        if (admission != null) handle.retire_injection(admission);
        handle.execution_busy = 1;
        // worker 启动前先用调用进程占位：caller 若在启动窗口被杀，下次调度仍能看到 KILLED 并回收。
        handle.execution_process = process::self();
        handle.execution = null;
        handle.execution_scope = scope;
        handle.result_context = new(handle.execution_process);
        handle.result_context.call_parent = caller_context;
        handle.result_context.parent_waits = wait_for_done;
        // 派生前预占 legacy 槽，防止两个调用在 worker 获得调度前同时通过检查。
        if (handle.uses_legacy_result) acquire_legacy_result(handle.result_context);
        handle.args_in = user_args;
        handle.status = 0;
        handle.result_out = "";
        if (wait_for_done) begin
            int completed_status;
            string completed_result;
            bit completed = 0;
            // 同步业务也在独立子进程运行，用户 task 内 disable/wait fork 碰不到已 ACK 的后台任务。
            fork
                begin
                    handle.bind_execution();
                    handle.cmd_exec();
                    handle.finish_execution(completed_status, completed_result);
                    completed = 1;
                end
            join
            // worker 被单独 kill 时到达：立即惰性清理并恢复父 legacy 快照，不能假报成功。
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
            // 登记 process 后立即 ACK，不等 cmd_exec；也保证下一条同名调用看到确切的在途 owner。
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

    // 兼容接口：返回时才发布全局结果，并发调用方须用 exec_result。
    static task exec(string cmd_str, cmd_source_e src = SRC_INTERNAL);
        int result_status;
        string result_text;
        exec_result(cmd_str, src, result_status, result_text);
        publish_compat_result(result_status, result_text);
    endtask

    // Format: "cmd1 a=1, cmd2 b=2, cmd3 join|join_any|join_none [disable_remaining=1]"
    // Aggregates child statuses: first non-zero status wins; failure list collected
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

        // fork 只消费末尾选项，子命令参数原样保留。
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

    // 兼容接口，同 exec。
    static task fork_exec(string cmd_str, cmd_source_e src = SRC_INTERNAL);
        int result_status;
        string result_text;
        fork_exec_result(cmd_str, src, result_status, result_text);
        publish_compat_result(result_status, result_text);
    endtask

endclass

// 用户 task/sequence 宏基类：开放 wait=0 且无需改 task 签名。
// 参数仍由同名 handle 持有，调度器保证一次只有一个 owner。
class aip_cmd_user_task extends aip_cmd;
    function new(string name);
        super.new(name);
        background_allowed = 1;
    endfunction
endclass

// 老 string 宏基类：默认占用兼容全局返回槽，local_result=1 改用局部结果；两种模式均可 wait=0。
class aip_cmd_legacy_result_task extends aip_cmd;
    function new(string name, bit local_result = 0);
        super.new(name);
        background_allowed = 1;
        uses_legacy_result = !local_result;
    endfunction
endclass

class \__aip_cmd_set_param extends aip_cmd;
    task cmd_exec();
        string args, path_name, value;
        int path_start, path_end, val_start;
        args = this.args_in;

        // 不用 get_arg：value 可能含逗号/方括号/大括号，value= 之后的全部内容都是值。
        path_start = aip_str::str_find(args, "path=");
        if (path_start == -1) begin
            this.result_out = "ERROR: missing path argument";
            this.status = 1;
            return;
        end
        path_start = path_start + 5;

        path_end = path_start;
        while (path_end < args.len() && args[path_end] != 8'd32) path_end = path_end + 1;
        path_name = args.substr(path_start, path_end - 1);

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

// get_param name=<n>：返回 +<n>=value 的值（Tcl 端 aip_getparam），未传则 status=1、结果为空；
// seed/ntb_random_seed 未显式传入时回退到 $get_initial_random_seed()。
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
            this.status     = 1;
        end
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_get_param __inst = new("get_param");
endclass

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

// 注册宏生成常驻命令对象。task/typed/enum 宏走独立 handle/context 结果，可 wait=0；
// 用户 set_result 优先于 typed 自动返回值。直接顺序调用 cmd_exec 时宏自建临时上下文，
// 收尾发布兼容镜像；正常 dispatch 则复用框架上下文，不重复占槽/发布。

`define aip_cmd_task(Ccmd, svtask) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
    task cmd_exec(); \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        svtask(); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// Optional help metadata (group/description/params); procedural block, no-op if not registered.
`define aip_cmd_info(Ccmd, _group, _desc, _params) \
begin \
    aip_cmd __h = aip_cmd::get_handle(`"Ccmd`"); \
    if (__h != null) begin \
        __h.group = _group; \
        __h.description = _desc; \
        __h.param_info = _params; \
    end \
end

// 类型化参数宏：宏名 Ni/Mo 表示 N 个整数输入、M 个输出，输出按 name=0x.. 写入 result_out。

`define aip_cmd_1i(Ccmd, svtask, TI1, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_2i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_3i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_1i1o(Ccmd, svtask, TI1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_2i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_2i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// str/混合宏可选尾参 LOCAL_RESULT：0 兼容裸写 __aip_cmd_last_*（无关执行链互斥，同步父子可借槽），
// 1 承诺只写 set_result/context/handle，可与其他命令并发。未写结果的 task 返回 0/空串。
`define aip_cmd_str_1i(Ccmd, svtask, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_str_2i(Ccmd, svtask, ni1, di1, ni2, di2, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// _status 变体为兼容旧名保留，行为与无后缀版本相同。
`define aip_cmd_str_1i_status(Ccmd, svtask, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_str_2i_status(Ccmd, svtask, ni1, di1, ni2, di2, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_str_3i_status(Ccmd, svtask, ni1, di1, ni2, di2, ni3, di3, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 第三个参数键固定为 time=（局部变量沿用 ni3 命名，避开 SV 关键字 time）。
`define aip_cmd_str_3i_status_time(Ccmd, svtask, ni1, di1, ni2, di2, ni3, di3, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 先字符串后整数，如 load_rom(file, offset)。
`define aip_cmd_str_1i1i(Ccmd, svtask, TI1, ns1, ds1, TI2, ni1, di1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_1i1s(Ccmd, svtask, TI1, ni1, di1, TI2, ns1, ds1, LOCAL_RESULT=0) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
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
    function new(string name); super.new(name, LOCAL_RESULT); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// string + 64-bit unsigned + string, for the firmware image loader. parse_int64_arg is intentional:
// start addresses such as 0x8000_0000 must not pass through a 32-bit int.
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

`define aip_cmd_4i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_5i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_6i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_7i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_8i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_9i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_10i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9, TI10, ni10, di10) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_3i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_4i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_5i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_1i2o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_1i3o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_3i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_4i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_5i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_3i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_4i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_5i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// Enum names match case-insensitively; an unknown name falls back to the default.
`define aip_cmd_enum_1i(Ccmd, svtask, TE1, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`define aip_cmd_enum_1i1o(Ccmd, svtask, TE1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd_user_task; \
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
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// Binds a seq type + sequencer to a command. The seq needs `int count`; transaction fields come
// from aip_cmdline. Time mode sets count to max and kills the seq at expiry (no driver rollback).
//   `aip_cmd_seq(axi_write, axi_wr_seq, virtual_sqr::axi_wr_sqr)  ->  axi_write count=10 | time=1us
// 启动流程与 Tcl aip_reg_seq 共用 aip_seq_launcher::run（core/aip_seq_launcher.sv）；本类只负责创建并写 count。
`define aip_cmd_seq(cmd_name, seq_type, sequencer) \
class \__aip_seq_``cmd_name extends aip_seq_launcher; \
    function new(); super.new(`"seq_type`", 1'b0, `__FILE__, `__LINE__); endfunction \
    virtual function uvm_sequence_base create(string inst_name, int count, string param_path); \
        seq_type __seq = seq_type::type_id::create(inst_name); \
        __seq.count = count; \
        return __seq; \
    endfunction \
    static task launch(); \
        \__aip_seq_``cmd_name __launcher = new(); \
        __launcher.run(aip_cmd::get_handle(`"cmd_name`"), sequencer); \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_seq_``cmd_name ::launch)

//   `aip_cmd_user_seq(link_up, my_link_up_seq, my_vsqr::pcie_sqr)
// The seq reads aip_cmd::get_handle("link_up").args_in and sets its own fields (e.g. SVT `enable`);
// the framework only starts it, tracks it for kill_seq/watchdog and defaults the result to OK.
`define aip_cmd_user_seq(cmd_name, seq_type, sequencer) \
class \__aip_user_seq_``cmd_name ; \
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

// Strict aip_cmd_seq: holds a sequencer grab for the whole sequence (granted at the next
// arbitration point; in-flight items are not interrupted). Cancellation still needs driver cleanup.
`define aip_cmd_cseq(cmd_name, seq_type, sequencer) \
class \__aip_cseq_impl_``cmd_name extends seq_type; \
    function new(string name = `"cmd_name`"); super.new(name); endfunction \
    virtual task pre_body(); this.grab(); super.pre_body(); endtask \
    /* 仅正常返回时 ungrab；被取消时依赖 UVM kill 释放 sequence 资源。 */ \
    virtual task post_body(); super.post_body(); this.ungrab(); endtask \
endclass \
/* 共用 aip_seq_launcher::run；日志保持 [CSEQ] grab 且无 done 行。 */ \
class \__aip_cseq_``cmd_name extends aip_seq_launcher; \
    function new(); \
        super.new(`"seq_type`", 1'b0, `__FILE__, `__LINE__); \
        log_tag = "CSEQ"; \
        log_verb = "grab"; \
        log_done = 0; \
    endfunction \
    virtual function uvm_sequence_base create(string inst_name, int count, string param_path); \
        \__aip_cseq_impl_``cmd_name __seq = new(inst_name); \
        __seq.count = count; \
        return __seq; \
    endfunction \
    static task launch(); \
        \__aip_cseq_``cmd_name __launcher = new(); \
        __launcher.run(aip_cmd::get_handle(`"cmd_name`"), sequencer); \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_cseq_``cmd_name ::launch)

// 寄存器 sequence 注册：命名参数或 op addr len data [mask]；len 缺省 4，mask 缺省 0
// （含义由总线 seq 定义，PCIe 为 1=屏蔽字节）。参数非法时直接返回 ERROR，不启动 seq。
// seq 须有 is_write/addr/len/mask/wdata/rdata；data 为 1..128 位，按 $bits(wdata) 检查溢出。
// 可选 error_expr 在 seq 返回后求值，非空则 status=1；可选第五项映射 seq.check_read_data。
//   `aip_cmd_reg(reg_acc, pcie_tl_reg_seq, my_vsqr::pcie_sqr, seq.error_msg)
//   reg_acc write 0x1000 16 0x112233445566778899aabbccddeeff00 ; reg_acc read 0x1000 16
`include "core/aip_reg_args.sv"

`define aip_cmd_reg(cmd_name, seq_type, sequencer, error_expr = "", check_read_data_target = __aip_unused_read_check) \
class \__aip_reg_``cmd_name ; \
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
        /* 目标仍为默认的 __aip_unused_read_check 即未映射：显式请求必须报错而非忽略。 */ \
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

// 严格寄存器入口：参数契约同 aip_cmd_reg，整个 sequence 执行期间 grab 仲裁权。
`define aip_cmd_creg(cmd_name, seq_type, sequencer, error_expr = "", check_read_data_target = __aip_unused_read_check) \
class \__aip_creg_impl_``cmd_name extends seq_type; \
    function new(string name = `"cmd_name`"); super.new(name); endfunction \
    virtual task pre_body(); this.grab(); super.pre_body(); endtask \
    /* 仅正常返回时 ungrab；被取消时依赖 UVM kill 释放 sequence 资源。 */ \
    virtual task post_body(); super.post_body(); this.ungrab(); endtask \
endclass \
class \__aip_creg_``cmd_name ; \
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

// Routes a command to CPU firmware via aip_cpu_bridge (placeholder flagged in __aip_cmd_is_cpu).
//   `aip_cmd_cpu(dma_test)  ->  dma_test src=0x1000 async=1   (async=1 returns at once, else waits)
`define aip_cmd_cpu(Ccmd) \
class \__aip_cmd_cpu_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
    endtask \
    function new(string name); \
        super.new(name); \
        __aip_cmd_is_cpu[name] = 1; \
    endfunction \
    static \__aip_cmd_cpu_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`endif // AIP_CMD_SV
