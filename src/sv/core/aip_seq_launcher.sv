// sequence 启动器：宏按类型名登记、持有静态类型，故运行时绑定无需 factory 按名创建或反射；
// aip_cmd_seq/aip_cmd_cseq 与 Tcl aip_reg_seq 生成的命令共用同一启动流程（count=/time=、kill_seq/watchdog 登记）。
// 依赖 aip_activity 与 Tcl bridge 的命令名表重发，故在 bridge/aip_tcl_bridge.sv 之后 include。
`ifndef AIP_SEQ_LAUNCHER_SV
`define AIP_SEQ_LAUNCHER_SV

typedef class aip_seq_launcher;

// 已声明类型名 -> 启动器；放在类外的原因同命令注册表。
aip_seq_launcher __aip_seq_launchers[string];

// 一种 sequence 类型的启动器；派生类由宏生成，create 新建 seq 并写 count（及可选 param_path）。
virtual class aip_seq_launcher;
    string type_name;
    bit    path_supported;
    // 宏所在源码位置：启动日志指向用户注册处，与原 aip_cmd_seq 宏展开的位置一致。
    string src_file;
    int    src_line;
    // cseq 改为 CSEQ/grab 且不打 done 行，保持原宏输出。
    protected string log_tag = "SEQ";
    protected string log_verb = "start";
    protected bit    log_done = 1;

    function new(string type_name, bit path_supported, string src_file, int src_line);
        this.type_name = type_name;
        this.path_supported = path_supported;
        this.src_file = src_file;
        this.src_line = src_line;
    endfunction

    // param_path 为空时不写，保留 seq 自身缺省值；只有 path_supported 的类型会收到非空值。
    pure virtual function uvm_sequence_base create(string inst_name, int count, string param_path);

    // 声明宏在静态初始化时登记；同名重复声明报错并保留首个，不静默覆盖。
    static function void declare(aip_seq_launcher launcher);
        if (__aip_seq_launchers.exists(launcher.type_name)) begin
            `aip_error(("[AIP_SEQ] sequence type '%s' declared again at %s(%0d); keeping %s(%0d)",
                        launcher.type_name, launcher.src_file, launcher.src_line,
                        __aip_seq_launchers[launcher.type_name].src_file,
                        __aip_seq_launchers[launcher.type_name].src_line));
            return;
        end
        __aip_seq_launchers[launcher.type_name] = launcher;
    endfunction

    static function aip_seq_launcher find(string type_name);
        if (!__aip_seq_launchers.exists(type_name)) return null;
        return __aip_seq_launchers[type_name];
    endfunction

    // 已声明类型名，逗号分隔，供诊断。
    static function string declared_names();
        string names = "";
        foreach (__aip_seq_launchers[name]) names = (names == "") ? name : {names, ", ", name};
        return names;
    endfunction

    // 共用启动流程：time= 优先（count 置最大值，到期 kill，不回滚 driver 已发事务），否则 count= 缺省 1；
    // 启动前登记供 kill_seq/watchdog 回收，结束后注销并 tick，缺省结果 OK: <cmd> count=N 或 time=T。
    task run(aip_cmd h, uvm_sequencer_base sqr, string param_path = "");
        string name = h.cmd_name;
        string count_s = aip_cmd::get_arg(h.args_in, "count");
        string time_s = aip_cmd::get_arg(h.args_in, "time");
        uvm_sequence_base seq;
        if (time_s != "") begin
            real timeout_ns = aip_cmd::parse_time_ns(time_s);
            seq = create(name, 2147483647, param_path);
            aip_cmd_seq_registry::register(name, seq);
            log_info($sformatf("[%s] %s %s, time=%s (%.1f ns)", log_tag, name, log_verb, time_s, timeout_ns));
            fork
                seq.start(sqr);
                begin
                    aip_time::delay_ns(timeout_ns);
                    seq.kill();
                end
            join
            aip_cmd_seq_registry::unregister(name);
            aip_activity::tick();
            if (log_done) log_info($sformatf("[%s] %s done (timed)", log_tag, name));
            h.result_out = $sformatf("OK: %s time=%s", name, time_s);
        end else begin
            int count = aip_cmd::parse_int_arg(count_s, 1);
            seq = create(name, count, param_path);
            aip_cmd_seq_registry::register(name, seq);
            log_info($sformatf("[%s] %s %s, count=%0d", log_tag, name, log_verb, count));
            seq.start(sqr);
            aip_cmd_seq_registry::unregister(name);
            aip_activity::tick();
            if (log_done) log_info($sformatf("[%s] %s done", log_tag, name));
            h.result_out = $sformatf("OK: %s count=%0d", name, count);
        end
        h.status = 0;
    endtask

    local function void log_info(string msg);
        aip_log::log(aip_log::INFO, src_file, src_line, "", msg);
    endfunction
endclass

// 声明可由 aip_reg_seq 运行时绑定的 sequence 类型，每类型一行、随用户代码编译，宏参数原文即 type= 的键。
// T 须 `uvm_object_utils 注册且有 int count；_path 版另需 string param_path，只有它接受 path=。
// count/param_path 在 create 之后、start 之前写入，依赖它们的参数须在 body 中读取（不要在 new 中读）。
//   `aip_seq_type(axi_wr_seq)            `aip_seq_type_path(vio_tx_seq)
`define aip_seq_type(T) \
class \__aip_seq_type_``T extends aip_seq_launcher; \
    function new(); \
        super.new(`"T`", 1'b0, `__FILE__, `__LINE__); \
        declare(this); \
    endfunction \
    virtual function uvm_sequence_base create(string inst_name, int count, string param_path); \
        T __seq = T::type_id::create(inst_name); \
        __seq.count = count; \
        return __seq; \
    endfunction \
    static \__aip_seq_type_``T __inst = new(); \
endclass

`define aip_seq_type_path(T) \
class \__aip_seq_type_``T extends aip_seq_launcher; \
    function new(); \
        super.new(`"T`", 1'b1, `__FILE__, `__LINE__); \
        declare(this); \
    endfunction \
    virtual function uvm_sequence_base create(string inst_name, int count, string param_path); \
        T __seq = T::type_id::create(inst_name); \
        __seq.count = count; \
        if (param_path != "") __seq.param_path = param_path; \
        return __seq; \
    endfunction \
    static \__aip_seq_type_``T __inst = new(); \
endclass

// aip_reg_seq 生成的命令：常驻注册表，行为同 aip_cmd_seq（count=/time=、wait=0、同名 BUSY、kill_seq/watchdog）。
// sequencer 在注册时解析并固定；对象属于 SV 状态，随快照保存/恢复。
class aip_reg_seq_cmd extends aip_cmd_user_task;
    aip_seq_launcher   launcher;
    uvm_sequencer_base sqr;
    string             param_path;

    function new(string name, aip_seq_launcher launcher, uvm_sequencer_base sqr, string param_path);
        super.new(name);
        this.launcher = launcher;
        this.sqr = sqr;
        this.param_path = param_path;
        group = "aip_reg_seq";
        description = {"type=", launcher.type_name, " sqr=", sqr.get_full_name(),
                       (param_path == "") ? "" : {" path=", param_path}};
        param_info = "count=N | time=T [wait=0]";
    endfunction

    task cmd_exec();
        bit owns_scope;
        owns_scope = begin_macro_result_scope();
        launcher.run(this, sqr, param_path);
        end_macro_result_scope(owns_scope);
    endtask

    // 严格解析 key=value：键须在 keys 中、只出现一次且值非空，required 中的键缺一即失败。
    static function bit parse_keys(string args, string keys, string required,
                                   output string values[string], output string why);
        string_darray_t allowed;
        string_darray_t needed;
        string missing;
        int pos;
        allowed = aip_str::split(keys);
        needed = aip_str::split(required);
        values.delete();
        why = "";
        pos = 0;
        while (pos < args.len()) begin
            int token_end;
            int eq;
            bit known;
            string token;
            string key;
            while (pos < args.len() && (aip_cmd::is_arg_space(args[pos]) || args[pos] == 8'd44)) pos++;
            if (pos >= args.len()) break;
            token_end = aip_cmd::arg_token_end(args, pos);
            token = args.substr(pos, token_end - 1);
            pos = token_end;
            eq = aip_str::str_find(token, "=");
            if (eq <= 0) begin
                why = {"malformed argument '", token, "'; expected key=value"};
                return 0;
            end
            key = token.substr(0, eq - 1);
            known = 0;
            foreach (allowed[i]) if (allowed[i] == key) known = 1;
            if (!known) begin
                why = {"unknown key '", key, "='; allowed keys: ", keys};
                return 0;
            end
            if (values.exists(key)) begin
                why = {"duplicate key '", key, "='"};
                return 0;
            end
            if (eq == token.len() - 1) begin
                why = {"empty value for '", key, "='"};
                return 0;
            end
            values[key] = token.substr(eq + 1, token.len() - 1);
        end
        missing = "";
        foreach (needed[i])
            if (!values.exists(needed[i])) missing = {missing, (missing == "") ? "" : " ", needed[i], "="};
        if (missing != "") begin
            why = {"missing ", missing};
            return 0;
        end
        return 1;
    endfunction

    // 以字母或 _ 开头，只含字母、数字和 _ . : -：Tcl 可直接调用，fork 按逗号拆分也不受影响；fork 为保留字。
    static function bit valid_name(string name);
        if (name == "" || name == "fork") return 0;
        foreach (name[i]) begin
            byte c = name[i];
            bit letter = (c >= 8'd65 && c <= 8'd90) || (c >= 8'd97 && c <= 8'd122) || c == 8'd95;
            bit other = (c >= 8'd48 && c <= 8'd57) || c == 8'd46 || c == 8'd58 || c == 8'd45;
            if (!letter && !(i > 0 && other)) return 0;
        end
        return 1;
    endfunction

    // 按 UVM 全路径逐级 has_child/get_child 查找：不支持通配符，查不到时不产生 UVM 警告。
    static function uvm_component find_component(string full_path);
        uvm_component comp;
        int start;
        comp = uvm_root::get();
        start = 0;
        if (full_path == "") return null;
        for (int i = 0; i <= full_path.len(); i++) begin
            if (i == full_path.len() || full_path[i] == 8'd46) begin
                string leaf;
                if (i == start) return null;
                leaf = full_path.substr(start, i - 1);
                if (!comp.has_child(leaf)) return null;
                comp = comp.get_child(leaf);
                start = i + 1;
            end
        end
        return comp;
    endfunction

    // 全部校验通过才创建命令（失败不改注册表）；成功后立即重发命令名表，Tcl 随即可调用新命令。
    static function bit register(string name, string type_name, string sqr_path, string param_path,
                                 output aip_reg_seq_cmd cmd, output string why);
        aip_seq_launcher launcher;
        uvm_component comp;
        uvm_sequencer_base sqr;
        cmd = null;
        why = "";
        if (!valid_name(name)) begin
            why = {"invalid command name '", name, "' (use letters, digits, _ . : - and start with a letter or _)"};
            return 0;
        end
        if (aip_cmd::get_handle(name) != null) begin
            why = {"command '", name, "' already exists"};
            return 0;
        end
        launcher = aip_seq_launcher::find(type_name);
        if (launcher == null) begin
            why = {"sequence type '", type_name, "' is not declared (`aip_seq_type/`aip_seq_type_path); declared: ",
                   (aip_seq_launcher::declared_names() == "") ? "none" : aip_seq_launcher::declared_names()};
            return 0;
        end
        if (param_path != "" && !launcher.path_supported) begin
            why = {"sequence type '", type_name, "' was declared without param_path support; path= needs `aip_seq_type_path"};
            return 0;
        end
        comp = find_component(sqr_path);
        if (comp == null) begin
            why = {"sqr '", sqr_path, "' not found in the UVM hierarchy (give the full name, e.g. uvm_test_top.env.agent.sqr)"};
            return 0;
        end
        if (!$cast(sqr, comp)) begin
            why = {"sqr '", sqr_path, "' is a ", comp.get_type_name(), ", not a uvm_sequencer"};
            return 0;
        end
        cmd = new(name, launcher, sqr, param_path);
        aip_tcl_bridge::sync_cmd_names();
        `aip_info(("[AIP_REG_SEQ] registered %s: %s", name, cmd.description));
        return 1;
    endfunction

    // 只注销 aip_reg_seq 生成且空闲（无在途执行、无排队注入）的命令；名称随即可重新注册。
    static function bit unregister(string name, output string why);
        aip_cmd handle;
        aip_reg_seq_cmd cmd;
        why = "";
        handle = aip_cmd::get_handle(name);
        if (handle == null) begin
            why = {"command '", name, "' does not exist"};
            return 0;
        end
        if (!$cast(cmd, handle)) begin
            why = {"command '", name, "' was not created by aip_reg_seq"};
            return 0;
        end
        if (handle.is_busy()) begin
            why = {"BUSY: command '", name, "' is still running"};
            return 0;
        end
        if (!handle.injection_turn()) begin
            why = {"BUSY: command '", name, "' has pending queued requests"};
            return 0;
        end
        aip_cmd::unregister(name);
        aip_tcl_bridge::sync_cmd_names();
        `aip_info(("[AIP_REG_SEQ] unregistered %s", name));
        return 1;
    endfunction
endclass

// aip_reg_seq cmd=<新命令名> type=<已声明类型> sqr=<sequencer 全路径> [path=<参数路径>]
// 任一校验失败返回 ERROR/status=1，不覆盖已有命令、不改注册表。
class \__aip_cmd_aip_reg_seq extends aip_cmd;
    task cmd_exec();
        string values[string];
        string why;
        aip_reg_seq_cmd cmd;
        if (aip_reg_seq_cmd::parse_keys(args_in, "cmd type sqr path", "cmd type sqr", values, why) &&
            aip_reg_seq_cmd::register(values["cmd"], values["type"], values["sqr"],
                                      values.exists("path") ? values["path"] : "", cmd, why)) begin
            result_out = {"OK: ", cmd.cmd_name, " ", cmd.description};
            status = 0;
        end else begin
            `aip_error(("[AIP_REG_SEQ] aip_reg_seq rejected: %s", why));
            result_out = {"ERROR: aip_reg_seq: ", why};
            status = 1;
        end
    endtask

    function new(string name);
        super.new(name);
        description = "bind a declared sequence type to a sequencer as a new command";
        param_info = "cmd=<name> type=<declared seq type> sqr=<sequencer full path> [path=<param path>]";
    endfunction
    static \__aip_cmd_aip_reg_seq __inst = new("aip_reg_seq");
endclass

// aip_unreg_seq cmd=<名>：注销 aip_reg_seq 生成的空闲命令；其他命令、执行中或有排队请求时报错。
class \__aip_cmd_aip_unreg_seq extends aip_cmd;
    task cmd_exec();
        string values[string];
        string why;
        if (aip_reg_seq_cmd::parse_keys(args_in, "cmd", "cmd", values, why) &&
            aip_reg_seq_cmd::unregister(values["cmd"], why)) begin
            result_out = {"OK: unregistered ", values["cmd"]};
            status = 0;
        end else begin
            `aip_error(("[AIP_REG_SEQ] aip_unreg_seq rejected: %s", why));
            result_out = {"ERROR: aip_unreg_seq: ", why};
            status = 1;
        end
    endtask

    function new(string name);
        super.new(name);
        description = "remove an idle command created by aip_reg_seq";
        param_info = "cmd=<name>";
    endfunction
    static \__aip_cmd_aip_unreg_seq __inst = new("aip_unreg_seq");
endclass

`endif // AIP_SEQ_LAUNCHER_SV
