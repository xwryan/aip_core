`ifndef AIP_CMD_SV
`define AIP_CMD_SV

`include "aip_str.sv"

// Command source enum: determines error handling behavior
typedef enum int {
    SRC_TCL      = 0,  // Soft fail: set status=-1, no $fatal
    SRC_DPI      = 1,  // Hard fail: $fatal on unknown command
    SRC_INTERNAL = 2   // Hard fail: $fatal on unknown command
} cmd_source_e;

// Forward declaration for registry
typedef class aip_cmd;

// Global command registry — declared outside class for VCS Q-2020 compatibility
// (static associative arrays of class type inside class may cause issues)
aip_cmd __aip_cmd_registry[string];

// CPU command flag registry — 1 = route to aip_cpu_bridge
bit __aip_cmd_is_cpu[string];

// 活动 seq 登记表 — 命令 launch 时登记正在跑的 seq, watchdog 停滞超时可自动
// kill() 清 sequencer pending item 残留. (assoc array of class type 放类外,
// VCS Q-2020 兼容, 同 __aip_cmd_registry)
uvm_sequence_base __aip_active_seqs[string];

// 活动 seq 登记表操作封装
class aip_cmd_seq_registry;
    // seq 开跑前登记 (cmd_name -> seq 句柄)
    static function void register(string cmd_name, uvm_sequence_base seq);
        __aip_active_seqs[cmd_name] = seq;
    endfunction
    // seq 正常跑完注销
    static function void unregister(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name)) __aip_active_seqs.delete(cmd_name);
    endfunction
    // kill 所有活动 seq, 返回 kill 数量 (watchdog 内置默认清理)
    static function int kill_active();
        int n = 0;
        foreach (__aip_active_seqs[nm]) begin
            if (__aip_active_seqs[nm] != null) begin
                __aip_active_seqs[nm].kill();
                n = n + 1;
            end
        end
        __aip_active_seqs.delete();
        return n;
    endfunction
    // kill 指定命令的活动 seq, 返回 1=杀了 0=没找到 (供 TCL kill_seq)
    static function int kill_one(string cmd_name);
        if (__aip_active_seqs.exists(cmd_name) && __aip_active_seqs[cmd_name] != null) begin
            __aip_active_seqs[cmd_name].kill();
            __aip_active_seqs.delete(cmd_name);
            return 1;
        end
        return 0;
    endfunction
    static function int count();
        return __aip_active_seqs.num();
    endfunction
endclass

class aip_cmd;

    // Instance fields
    string cmd_name;
    string group;
    string description;
    string param_info;
    string args_in;
    string result_out;
    int    status;

    // Static fields for last execution result
    static int    __aip_cmd_last_status;
    static string __aip_cmd_last_result;

    // Virtual task: subclasses override this
    virtual task cmd_exec();
    endtask

    // Constructor: sets cmd_name and auto-registers to global registry
    function new(string name);
        this.cmd_name    = name;
        this.group       = "";
        this.description = "";
        this.param_info  = "";
        this.args_in     = "";
        this.result_out  = "";
        this.status      = 0;
        if (__aip_cmd_registry.exists(name)) begin
            `aip_error(("[AIP_CMD] Command '%s' already registered", name));
        end else begin
            __aip_cmd_registry[name] = this;
        end
    endfunction

    // Lookup command handle from registry by name
    static function aip_cmd get_handle(string name);
        if (__aip_cmd_registry.exists(name))
            return __aip_cmd_registry[name];
        else
            return null;
    endfunction

    // Remove a command from the registry (used by aip_soload unload).
    static function void unregister(string name);
        if (__aip_cmd_registry.exists(name))
            __aip_cmd_registry.delete(name);
    endfunction

    // Return comma-separated list of all registered command names
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

    // Parse command string: split at first space into cmd_name and args
    static function void parse_cmd_str(string cmd_str, output string cmd_name, output string args);
        string s;
        int space_pos;
        s = aip_str::strip(cmd_str);
        space_pos = aip_str::str_find(s, " ");
        if (space_pos == -1) begin
            cmd_name = s;
            args = "";
        end else begin
            cmd_name = s.substr(0, space_pos - 1);
            args = aip_str::strip(s.substr(space_pos + 1, s.len() - 1));
        end
    endfunction

    // Extract value for "key=value" from args string
    // Supports brace-enclosed values: key={a=1,b=2}
    static function string get_arg(string args, string key);
        string search_key;
        int pos;
        int val_start;
        int val_end;
        int brace_depth;
        byte prev_char;

        if (args == "" || key == "") return "";

        search_key = {key, "="};
        pos = aip_str::str_find(args, search_key);
        if (pos == -1) return "";

        // Verify key is at start of string or preceded by space/comma
        if (pos > 0) begin
            prev_char = args[pos - 1];
            if (prev_char != " " && prev_char != "," && prev_char != "\t") return "";
        end

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
                if (args[val_end] == " " || args[val_end] == "," || args[val_end] == "\t") break;
                val_end = val_end + 1;
            end
            if (val_end == val_start) return "";
            return args.substr(val_start, val_end - 1);
        end
    endfunction

    // Parse int from string, return default_val if empty/invalid
    static function int parse_int_arg(string s, int default_val = 0);
        int width;
        longint unsigned result;
        if (s == "") return default_val;
        result = aip_str::str_to_num(s, width);
        // str_to_num returns -1 ({64{1'b1}}) with width=0 on error
        if (width == 0 && result == {64{1'b1}}) return default_val;
        return int'(result);
    endfunction

    // Parse 64-bit unsigned int from string, return dv if empty/invalid.
    // Unlike parse_int_arg, does NOT truncate to 32-bit.
    static function longint unsigned parse_int64_arg(string s, longint unsigned dv = 0);
        int width;
        longint unsigned result;
        if (s == "") return dv;
        result = aip_str::str_to_num(s, width);
        // str_to_num returns -1 ({64{1'b1}}) with width=0 on error
        if (width == 0 && result == {64{1'b1}}) return dv;
        return result;
    endfunction

    // Parse string arg (strip whitespace), return default_val if empty
    static function string parse_string_arg(string s, string default_val = "");
        string stripped;
        if (s == "") return default_val;
        stripped = aip_str::strip(s);
        if (stripped == "") return default_val;
        return stripped;
    endfunction

    // Parse time string to nanoseconds: "100ns"→100.0, "1us"→1000.0, "500ps"→0.5
    // Supported units: s, ms, us, ns, ps, fs (default: ns)
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

    // Execute a command by command string
    static task exec(string cmd_str, cmd_source_e src = SRC_INTERNAL);
        string name;
        string args;
        aip_cmd handle;

        parse_cmd_str(cmd_str, name, args);

        // Handle fork command specially
        if (name == "fork") begin
            fork_exec(args);
            return;
        end

        handle = get_handle(name);
        if (handle == null) begin
            if (src == SRC_TCL) begin
                __aip_cmd_last_status = -1;
                __aip_cmd_last_result = {"Unknown command: ", name};
                return;
            end else begin
                $fatal(1, "AIP_CMD[exec] Unknown command '%s'. Available commands: %s",
                       name, get_all_cmd_names());
            end
        end

        // Check if this is a CPU command
        if (__aip_cmd_is_cpu.exists(name) && __aip_cmd_is_cpu[name]) begin
            int cpu_status;
            string cpu_result;
            bit is_async;
            string async_val;
            async_val = get_arg(args, "async");
            is_async = (async_val == "1");
            aip_cpu_bridge::send_cmd(cmd_str, is_async, cpu_status, cpu_result);
            __aip_cmd_last_status = cpu_status;
            __aip_cmd_last_result = cpu_result;
        end else begin
            handle.args_in    = args;
            handle.status     = 0;
            handle.result_out = "";
            handle.cmd_exec();
            __aip_cmd_last_status = handle.status;
            __aip_cmd_last_result = handle.result_out;
        end
    endtask

    // Fork-execute multiple commands in parallel
    // Format: "cmd1 a=1, cmd2 b=2, cmd3 join|join_any|join_none [disable_remaining=1]"
    // Aggregates child statuses: first non-zero status wins; failure list collected
    // and written to __aip_cmd_last_result so SRC_TCL caller sees failures.
    // Race note: if two children dispatch the SAME registered cmd name, handle
    // state (handle.status / handle.result_out) is shared — avoid same-name
    // parallel cmds or accept best-effort aggregation.
    static task fork_exec(string cmd_str);
        string s;
        string join_type;
        int disable_remaining;
        int total;
        int done_count;
        int worst_status;
        string fail_list;
        event done_event;
        string_darray_t cmd_list;
        int jn_pos;

        s = aip_str::strip(cmd_str);
        if (s == "") begin
            `aip_warning(("AIP_CMD[fork_exec] Empty fork command string"));
            return;
        end

        // Detect and remove disable_remaining option
        disable_remaining = 0;
        begin
            string dr_val;
            dr_val = get_arg(s, "disable_remaining");
            if (dr_val == "1") begin
                disable_remaining = 1;
                s = aip_str::replace(s, "disable_remaining=1", "");
                s = aip_str::strip(s);
            end
        end

        // Detect join type from the end of the string
        // Check longest match first: join_none, then join_any, then join
        join_type = "join";
        jn_pos = aip_str::str_find(s, "join_none");
        if (jn_pos != -1 && (jn_pos + 9) >= s.len()) begin
            join_type = "join_none";
            if (jn_pos > 0)
                s = aip_str::strip(s.substr(0, jn_pos - 1));
            else
                s = "";
        end else begin
            jn_pos = aip_str::str_find(s, "join_any");
            if (jn_pos != -1 && (jn_pos + 8) >= s.len()) begin
                join_type = "join_any";
                if (jn_pos > 0)
                    s = aip_str::strip(s.substr(0, jn_pos - 1));
                else
                    s = "";
            end else begin
                jn_pos = aip_str::str_find(s, "join");
                if (jn_pos != -1 && (jn_pos + 4) >= s.len()) begin
                    join_type = "join";
                    if (jn_pos > 0)
                        s = aip_str::strip(s.substr(0, jn_pos - 1));
                    else
                        s = "";
                end
            end
        end

        // Remove trailing comma if present after stripping join keyword
        if (s.len() > 0 && s[s.len() - 1] == ",") begin
            if (s.len() > 1)
                s = aip_str::strip(s.substr(0, s.len() - 2));
            else
                s = "";
        end

        // Split by comma for individual commands
        cmd_list = aip_str::split(s, ",");
        total = cmd_list.size();

        if (total == 0) begin
            `aip_warning(("AIP_CMD[fork_exec] No commands to fork"));
            return;
        end

        done_count = 0;
        worst_status = 0;
        fail_list = "";

        // Launch all commands with fork...join_none
        for (int i = 0; i < total; i++) begin
            automatic string cmd_i = aip_str::strip(cmd_list[i]);
            fork
                begin
                    automatic int child_status;
                    automatic string child_result;
                    exec(cmd_i, SRC_INTERNAL);
                    // Snapshot immediately before sibling overwrites globals.
                    child_status = __aip_cmd_last_status;
                    child_result = __aip_cmd_last_result;
                    if (child_status != 0) begin
                        if (worst_status == 0) worst_status = child_status;
                        fail_list = {fail_list, $sformatf(" [%s:status=%0d,msg=%s]",
                                                          cmd_i, child_status, child_result)};
                    end
                    done_count = done_count + 1;
                    -> done_event;
                end
            join_none
        end

        // Wait based on join type
        if (join_type == "join") begin
            wait (done_count == total);
        end else if (join_type == "join_any") begin
            @(done_event);
            if (disable_remaining) begin
                disable fork;
            end
        end
        // join_none: return immediately (no aggregation possible — children still running)

        // Write aggregate status back to globals (skip for join_none since children
        // may still be running and would overwrite this anyway).
        if (join_type != "join_none") begin
            if (worst_status != 0) begin
                __aip_cmd_last_status = worst_status;
                __aip_cmd_last_result = {"fork: failure(s):", fail_list};
            end else begin
                __aip_cmd_last_status = 0;
                __aip_cmd_last_result = $sformatf("fork: %0d cmd(s) ok", done_count);
            end
        end
    endtask

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
// ============================================================

// Basic: 0 input, 0 output
`define aip_cmd_task(Ccmd, svtask) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); svtask(); endtask \
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
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
        end \
        svtask(ni1); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 0 output
`define aip_cmd_2i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; TI2 ni2; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            ni2 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di2; \
        end \
        svtask(ni1, ni2); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 0 output
`define aip_cmd_3i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 1 output
`define aip_cmd_1i1o(Ccmd, svtask, TI1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; TO1 no1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
        end \
        svtask(ni1, no1); \
        this.result_out = $sformatf("%s=0x%0h", `"no1`", no1); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 1 output
`define aip_cmd_2i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 int inputs, 2 outputs
`define aip_cmd_2i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 string input, 0 output
`define aip_cmd_str_1i(Ccmd, svtask, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        string ni1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
        end \
        svtask(ni1); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 string inputs, 0 output
`define aip_cmd_str_2i(Ccmd, svtask, ni1, di1, ni2, di2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        string ni1; string ni2; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
        end \
        svtask(ni1, ni2); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 string input, status/result forwarded from static task
`define aip_cmd_str_1i_status(Ccmd, svtask, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        string ni1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
        end \
        svtask(ni1); \
        this.status = aip_cmd::__aip_cmd_last_status; \
        this.result_out = aip_cmd::__aip_cmd_last_result; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 2 string inputs, status/result forwarded from static task
`define aip_cmd_str_2i_status(Ccmd, svtask, ni1, di1, ni2, di2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        string ni1; string ni2; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni2`"); \
            ni1 = (__v1 != "") ? __v1 : di1; \
            ni2 = (__v2 != "") ? __v2 : di2; \
        end \
        svtask(ni1, ni2); \
        this.status = aip_cmd::__aip_cmd_last_status; \
        this.result_out = aip_cmd::__aip_cmd_last_result; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 string + 1 int input, 0 output (e.g. load_rom(file, offset))
`define aip_cmd_str_1i1i(Ccmd, svtask, TI1, ns1, ds1, TI2, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ns1; TI2 ni1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ns1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ns1 = (__v1 != "") ? __v1 : ds1; \
            ni1 = (__v2 != "") ? TI2'(aip_cmd::parse_int_arg(__v2)) : di1; \
        end \
        svtask(ns1, ni1); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int + 1 string input, 0 output (e.g. load_hex_at(addr, file))
`define aip_cmd_1i1s(Ccmd, svtask, TI1, ni1, di1, TI2, ns1, ds1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; TI2 ns1; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            string __v2 = aip_cmd::get_arg(this.args_in, `"ns1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
            ns1 = (__v2 != "") ? __v2 : ds1; \
        end \
        svtask(ni1, ns1); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 0 output
`define aip_cmd_4i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 0 output
`define aip_cmd_5i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 6 int inputs, 0 output
`define aip_cmd_6i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 7 int inputs, 0 output
`define aip_cmd_7i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 8 int inputs, 0 output
`define aip_cmd_8i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 9 int inputs, 0 output
`define aip_cmd_9i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 10 int inputs, 0 output
`define aip_cmd_10i(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TI6, ni6, di6, TI7, ni7, di7, TI8, ni8, di8, TI9, ni9, di9, TI10, ni10, di10) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 1 output
`define aip_cmd_3i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 1 output
`define aip_cmd_4i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 1 output
`define aip_cmd_5i1o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 2 outputs
`define aip_cmd_1i2o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; TO1 no1; TO2 no2; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
        end \
        svtask(ni1, no1, no2); \
        this.result_out = $sformatf("%s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 int input, 3 outputs
`define aip_cmd_1i3o(Ccmd, svtask, TI1, ni1, di1, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
        TI1 ni1; TO1 no1; TO2 no2; TO3 no3; \
        begin \
            string __v1 = aip_cmd::get_arg(this.args_in, `"ni1`"); \
            ni1 = (__v1 != "") ? TI1'(aip_cmd::parse_int_arg(__v1)) : di1; \
        end \
        svtask(ni1, no1, no2, no3); \
        this.result_out = $sformatf("%s=0x%0h %s=0x%0h %s=0x%0h", `"no1`", no1, `"no2`", no2, `"no3`", no3); \
        this.status = 0; \
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 2 outputs
`define aip_cmd_3i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 2 outputs
`define aip_cmd_4i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 2 outputs
`define aip_cmd_5i2o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 3 int inputs, 3 outputs
`define aip_cmd_3i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 4 int inputs, 3 outputs
`define aip_cmd_4i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 5 int inputs, 3 outputs
`define aip_cmd_5i3o(Ccmd, svtask, TI1, ni1, di1, TI2, ni2, di2, TI3, ni3, di3, TI4, ni4, di4, TI5, ni5, di5, TO1, no1, TO2, no2, TO3, no3) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 enum input, 0 output
// Iterates enum values and matches name case-insensitively
`define aip_cmd_enum_1i(Ccmd, svtask, TE1, ni1, di1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
    function new(string name); super.new(name); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

// 1 enum input, 1 output
`define aip_cmd_enum_1i1o(Ccmd, svtask, TE1, ni1, di1, TO1, no1) \
class \__aip_cmd_``Ccmd extends aip_cmd; \
    task cmd_exec(); \
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
    endtask \
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
    static task launch(); \
        string __args = aip_cmd::get_handle(`"cmd_name`").args_in; \
        string __count_s = aip_cmd::get_arg(__args, "count"); \
        string __time_s  = aip_cmd::get_arg(__args, "time"); \
        seq_type __seq; \
        __seq = seq_type::type_id::create(`"cmd_name`"); \
        \
        if (__time_s != "") begin \
            /* Time mode: run seq until timeout, kill() for clean stop */ \
            /* kill() removes seq from sequencer, cleans pending items */ \
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
// Register R/W Seq Registration Macro
//
// 一行把一个"寄存器访问"sequence 注册成 TCL 命令。inline 传
// op/addr/len/mask/data，read 时把回读数据经 result_out 返回。
// 框架只做管道，实际总线访问由 seq body 实现（RAL 或自定义 bus item）。
//
// seq_type 必须声明以下固定命名字段（launch 直接按名读写）:
//   bit              is_write;   // 1=write 0=read
//   longint unsigned addr;       // 目标地址
//   int  unsigned    len;        // 缺省 4，语义由 seq 决定
//   int  unsigned    mask;       // 缺省 32'hFFFF_FFFF，语义由 seq 决定
//   longint unsigned wdata;      // 写数据
//   longint unsigned rdata;      // 输出：read 时 seq body 写此字段
//
// Usage:
//   `aip_cmd_reg(reg_acc, my_reg_seq, virtual_sqr::reg_sqr)
//
// TCL:
//   reg_acc op=write addr=0x1000 len=4 mask=0xff data=0xdead
//     -> OK: write addr=0x1000 data=0xdead
//   reg_acc op=read addr=0x1000
//     -> rdata=0xdead
//   reg_acc op=read                      ;# 缺 addr
//     -> ERROR: reg reg_acc: missing op/addr   (aip_check_status -> 1)
//
// op 别名: write = {write, wr, w, 1}; 其余按 read（含 read, rd, r, 0）。大小写不敏感。
// ============================================================

`define aip_cmd_reg(cmd_name, seq_type, sequencer) \
class \__aip_reg_``cmd_name ; \
    static task launch(); \
        aip_cmd __h = aip_cmd::get_handle(`"cmd_name`"); \
        string __args = __h.args_in; \
        string __op   = aip_cmd::get_arg(__args, "op"); \
        string __addr_s = aip_cmd::get_arg(__args, "addr"); \
        bit __is_write; \
        string __op_lc; \
        longint unsigned __addr; longint unsigned __wdata; \
        int unsigned __len; int unsigned __mask; \
        seq_type __seq; \
        if (__op == "" || __addr_s == "") begin \
            __h.result_out = {"ERROR: reg ", `"cmd_name`", ": missing op/addr"}; \
            __h.status = 1; \
            return; \
        end \
        __op_lc = aip_str::lower(__op); \
        __is_write = (__op_lc == "write" || __op_lc == "wr" || __op_lc == "w" || __op_lc == "1"); \
        __addr  = aip_cmd::parse_int64_arg(__addr_s); \
        __len   = aip_cmd::parse_int_arg(aip_cmd::get_arg(__args, "len"), 4); \
        __mask  = aip_cmd::parse_int_arg(aip_cmd::get_arg(__args, "mask"), 32'hFFFF_FFFF); \
        __wdata = aip_cmd::parse_int64_arg(aip_cmd::get_arg(__args, "data")); \
        __seq = seq_type::type_id::create(`"cmd_name`"); \
        __seq.is_write = __is_write; \
        __seq.addr = __addr; \
        __seq.len = __len; \
        __seq.mask = __mask; \
        __seq.wdata = __wdata; \
        `aip_info(("[REG] %s op=%s addr=0x%0h", `"cmd_name`", (__is_write ? "write" : "read"), __addr)); \
        aip_cmd_seq_registry::register(`"cmd_name`", __seq); \
        __seq.start(sequencer); \
        aip_cmd_seq_registry::unregister(`"cmd_name`"); \
        aip_activity::tick(); \
        if (!__is_write) __h.result_out = $sformatf("rdata=0x%0h", __seq.rdata); \
        else             __h.result_out = $sformatf("OK: write addr=0x%0h data=0x%0h", __addr, __wdata); \
        __h.status = 0; \
    endtask \
endclass \
`aip_cmd_task(cmd_name, \__aip_reg_``cmd_name ::launch)

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
    task cmd_exec(); \
    endtask \
    function new(string name); \
        super.new(name); \
        __aip_cmd_is_cpu[name] = 1; \
    endfunction \
    static \__aip_cmd_cpu_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`endif // AIP_CMD_SV
