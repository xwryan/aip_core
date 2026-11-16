// Tcl/UCLI 命令桥：把一次请求映射到公共命令调度器；握手寄存器在 aip_core_pkg（Tcl 经 __tcl_* 路径 force/get），调用者在 run_loop 期间保持 objection。
// run_loop 拥有每次请求的 ID、局部结果与 watchdog，ACK 只发布本次调用的输出；wait=0 的后台进程归调度层，不受后续 watchdog 监控。
// 独立注入接收器在首个暂停前启动，不共享普通 ACK，普通命令阻塞期间仍可排队。
`ifndef AIP_TCL_BRIDGE_SV
`define AIP_TCL_BRIDGE_SV

// Package state — UCLI must force/get it through aip_core_pkg::__tcl_* paths.
reg [31:0] __tcl_cmd_ascii [0:1023];
reg [31:0] __tcl_cmd_len = 0;

reg [31:0] __tcl_result_ascii [0:1023];
reg [31:0] __tcl_result_len = 0;
reg [31:0] __tcl_result_status = 0;
reg [31:0] __tcl_result_known = 0;

// 仿真时间字符串（SV 格式化后 TCL 读取）
reg [31:0] __tcl_sim_time_ascii [0:63];
reg [31:0] __tcl_sim_time_len = 0;

// free_run 模式：TCL force 为 1 时 SV 跳过 $stop，让仿真正常推进
reg __tcl_free_run = 0;

// bridge idle 标志：1=可接收下一条命令，0=正在处理当前请求。
// wait=0 返回后该值可以为1，即使后台seq仍在运行，不能当作所有seq已完成。
reg __tcl_bridge_idle = 0;

// Event-driven cmd trigger: TCL forces 0→1 transition to signal cmd ready.
// SV bridge @(posedge) blocks waiting, eliminates $stop race in chip TB
// with multiple $stop sites.
reg __tcl_cmd_trigger = 0;

// cmd_id ack: Tcl assigns a monotonic id per cmd and SV writes it back after processing, so Tcl can tell
// whether the $stop that returned _vcs_run belongs to this cmd (not a stray chip-TB $stop or a leftover
// stop from an interrupted cmd).
reg [31:0] __tcl_cmd_id    = 0;
reg [31:0] __tcl_result_id = 0;

// 已注册命令名表 (逗号分隔). bridge 启动时写一次 (静态注册), TCL 启动 get
// 后门读 (零握手) 缓存成 dict, 用于未注册命令快速失败. 4096 字符够装上百条.
reg [31:0] __tcl_cmd_names_ascii [0:4095];
reg [31:0] __tcl_cmd_names_len = 0;

// Tcl 只读镜像：ACK 等待只计活动计数不变的时间，且不早于命令停滞 watchdog 放弃（禁用时 stall=0）。
reg [31:0] __tcl_activity_count = 0;
reg [63:0] __tcl_cmd_watchdog_stall_ns = 50000;
reg [63:0] __tcl_cmd_watchdog_poll_ns = 1000;

// 全局活动计数：monitor/scoreboard/driver 调 tick() 表示有进展，供 end_test idle 检测、命令停滞 watchdog 与 Tcl ACK 等待使用。
class aip_activity;
    static int unsigned count = 0;

    // 只表示业务进展，不代表命令完成。
    static function void tick();
        count = count + 1;
        __tcl_activity_count = count;
    endfunction

    static function int unsigned get_count();
        return count;
    endfunction
endclass

// end_test 退出检查回调基类：用户实现 is_done()，end_test wait_done=1 时轮询。
virtual class aip_end_checker;
    // 由 end_test 轮询，不能阻塞或消费业务数据。
    pure virtual function bit is_done();

    // 派生类可在完成前报告不可恢复的业务失败。
    virtual function bit has_failed();
        return 0;
    endfunction

    virtual function string status_detail();
        return "";
    endfunction
endclass

// 命令停滞超时清理回调：watchdog 强杀死锁命令后调 on_timeout(cmd_str)，供用户按命令类型补做子系统清理（如 seq.kill()、复位 mailbox flag）。
virtual class aip_cmd_watchdog_hook;
    // 当次命令进程取消后通知用户清理；不保证seq.kill已修复driver的协议状态。
    pure virtual function void on_timeout(string cmd_str);
endclass

class aip_tcl_bridge;

    static bit __tcl_exit = 0;

    // Watchdog: auto-exit after N consecutive idle cycles (0=disabled)
    static int idle_limit = 0;

    static aip_end_checker end_checker = null;
    static aip_end_checker named_end_checkers[string];
    static bit end_checker_wait_active = 0;
    static process end_checker_wait_owner = null;
    static process end_test_owner = null;

    // 命令停滞看门狗：某命令连续 cmd_watchdog_stall_ns 无 activity 进展即判死锁并强杀（0 = 禁用）；
    // 检测的是停滞而非绝对超时，持续 tick 的长 seq 不会被误杀。
    static real cmd_watchdog_stall_ns = 50000.0;

    // 停滞采样间隔：越小越灵敏，越大开销越低。
    static real cmd_watchdog_poll_ns = 1000.0;

    static aip_cmd_watchdog_hook watchdog_hook = null;

    function new();
    endfunction

    // 设置空命令循环阈值；与按命令的停滞watchdog不是同一个限制。
    static function void set_watchdog(int limit);
        idle_limit = limit;
        `aip_info(("[AIP_TCL_BRIDGE] Watchdog set to %0d idle cycles", limit));
    endfunction

    // 检查器等待期间冻结注册表，避免本次快照与运行时修改相互矛盾。
    protected static function bit reject_checker_mutation(string operation);
        if (!end_checker_wait_active)
            return 0;

        `aip_error(("[AIP_TCL_BRIDGE] Cannot %s while end-checker wait is active",
                    operation));
        return 1;
    endfunction

    // 借用具名检查器；拒绝空名、空句柄及异对象重名，重复注册同一对象幂等。
    static function void register_end_checker(string name,
                                              aip_end_checker checker);
        if (reject_checker_mutation("register an end checker"))
            return;
        if (name == "") begin
            `aip_error(("[AIP_TCL_BRIDGE] End checker name must not be empty"));
            return;
        end
        if (checker == null) begin
            `aip_error(("[AIP_TCL_BRIDGE] End checker '%s' must not be null",
                        name));
            return;
        end
        if (named_end_checkers.exists(name)) begin
            if (named_end_checkers[name] == checker)
                return;
            `aip_error(("[AIP_TCL_BRIDGE] End checker '%s' is already registered",
                        name));
            return;
        end

        named_end_checkers[name] = checker;
    endfunction

    // 等待未开始时移除关联，不销毁用户拥有的检查器对象。
    static function void unregister_end_checker(string name);
        if (reject_checker_mutation("unregister an end checker"))
            return;
        named_end_checkers.delete(name);
    endfunction

    // 清空具名关联；活动end_test检查期间不允许修改。
    static function void clear_end_checkers();
        if (reject_checker_mutation("clear end checkers"))
            return;
        named_end_checkers.delete();
    endfunction

    // 设置兼容旧接口的单一检查器；null可清空，但等待期间不能替换。
    static function void set_end_checker(aip_end_checker checker);
        if (reject_checker_mutation("set the legacy end checker"))
            return;
        end_checker = checker;
    endfunction

    // 设命令停滞看门狗阈值 (ns). 0=禁用. Tcl 的 ACK 等待至少持续 stall+2×poll 无进展，
    // 被杀命令总能先返回 error result.
    static function void set_cmd_watchdog(real stall_ns);
        cmd_watchdog_stall_ns = stall_ns;
        publish_watchdog();
        `aip_info(("[AIP_TCL_BRIDGE] Cmd watchdog stall timeout = %.0f ns", stall_ns));
    endfunction

    // 向 Tcl 发布生效的 watchdog 配置（向上取整 ns）；静态量可被直接赋值，故每条命令受理时也重发。
    static function void publish_watchdog();
        __tcl_cmd_watchdog_stall_ns = (cmd_watchdog_stall_ns > 0.0) ?
                                      longint'($ceil(cmd_watchdog_stall_ns)) : 0;
        __tcl_cmd_watchdog_poll_ns = (cmd_watchdog_poll_ns > 0.0) ?
                                     longint'($ceil(cmd_watchdog_poll_ns)) : 0;
    endfunction

    static function void set_watchdog_hook(aip_cmd_watchdog_hook h);
        watchdog_hook = h;
    endfunction

    // 供 Tcl 在 senv time 不可用时兜底读取；run_loop 在命令处理完暂停前与 free_run 每步推进时刷新。
    static function void update_sim_time();
        string time_s;
        // $realtime/1ns 恒为 ns、与 timeunit 无关；按 real'(1ns) 阈值猜单位会把 10ps/100ps/10ns 标错。
        real t_ns = $realtime / 1ns;
        time_s = $sformatf("%.3f ns", t_ns);
        __tcl_sim_time_len = time_s.len();
        for (int j = 0; j < time_s.len() && j < 64; j = j + 1)
            __tcl_sim_time_ascii[j] = time_s[j];
    endfunction

    // 初始 $stop 让首个 _vcs_run 返回 UCLI 提示符；之后每条命令等 Tcl 的 trigger 脉冲（与芯片 TB 的其他 $stop 无关）。
    // 同步命令等执行完，wait=0 只等调度器启动确认；watchdog 只取消当次执行进程及其 seq，不能全局杀 seq。
    static task run_loop();
        int idle_count;
        __tcl_exit = 0;
        idle_count = 0;
        aip_inject_bridge::start();
        publish_watchdog();

        `aip_info(("[AIP_TCL_BRIDGE] Started, waiting for commands..."));

        // 命令名表在 elaboration 期静态注册，启动时写一次供 Tcl 后门读取（零握手），用于未注册命令快速失败。
        begin
            string cmd_names;
            cmd_names = aip_cmd::get_all_cmd_names();
            if (cmd_names.len() > 4096)
                `aip_warning(("[AIP_TCL_BRIDGE] cmd-name list %0d chars > 4096 buf; truncated, unknown-cmd fast-fail may miss tail", cmd_names.len()));
            __tcl_cmd_names_len = (cmd_names.len() > 4096) ? 4096 : cmd_names.len();
            for (int n = 0; n < cmd_names.len() && n < 4096; n = n + 1)
                __tcl_cmd_names_ascii[n] = cmd_names[n];
        end

        // 启动 break: 让 source aip_cmd.tcl 末尾的 _vcs_run 返回 ucli prompt
        __tcl_bridge_idle = 1;
        $stop(0);

        forever begin
            if (__tcl_exit) begin
                `aip_info(("[AIP_TCL_BRIDGE] Exit flag set, leaving loop at t=%0t", $time));
                return;
            end

            __tcl_bridge_idle = 1;

            // free_run 模式：让 sim 推进, 跳过 trigger wait
            if (__tcl_free_run) begin
                #1;
                update_sim_time();  // run 推进期间持续刷新, 兜底串紧跟当前时间
                continue;
            end

            // 阻塞等 TCL force trigger=1. 用 wait(== 1) 而非 @(posedge), 因为
            // TCL force 发生在 sim $stop 暂停期间, sim resume 时 trigger 已是 1,
            // @(posedge) 可能 miss 这次跳变. wait() 检查电平, 无 edge 依赖.
            wait (__tcl_cmd_trigger == 1);

            begin
                string cmd_str;
                string result;
                int command_status;
                int i;
                int unsigned local_cmd_id;
                bit          __wd_done;
                bit          __wd_killed;
                process      __wd_exec_process;
                process      __wd_monitor_process;
                process::state __wd_owner_status;
                int unsigned __wd_last_act;
                real         __wd_stall;
                string       __wd_kname;
                string       __wd_kargs;
                aip_cmd_execution_scope __wd_scope;
                string __wd_snapshot;

                __tcl_bridge_idle = 0;
                publish_watchdog();
                result = "";
                command_status = 0;
                __wd_scope = new();

                // Latch cmd_id at accept time: after Ctrl+C recovery Tcl may force a new id while this exec
                // is in flight, and the ack must still name the originally accepted command.
                local_cmd_id = __tcl_cmd_id;

                // int[] → string (cmd_str also implicitly latches cmd_ascii/len)
                cmd_str = "";
                for (i = 0; i < __tcl_cmd_len && i < 1024; i = i + 1) begin
                    cmd_str = {cmd_str, string'(__tcl_cmd_ascii[i][7:0])};
                end

                __tcl_result_known = 0;
                if (cmd_str == "") begin
                    idle_count = idle_count + 1;
                    if (idle_limit > 0 && idle_count >= idle_limit) begin
                        `aip_warning(("[AIP_TCL_BRIDGE] Watchdog: %0d idle cycles, auto exit at t=%0t",
                                 idle_count, $time));
                        return;
                    end
                    $stop(0);
                    continue;
                end

                idle_count = 0;

                aip_cmd::parse_cmd_str(cmd_str, __wd_kname, __wd_kargs);
                __tcl_result_known = ((__wd_kname == "fork") ||
                                      (aip_cmd::get_handle(__wd_kname) != null));

                `aip_debug(("[AIP_TCL_BRIDGE] Received: %s", cmd_str));

                // 停滞检测 watchdog：连续无活动进展判死锁并强杀 exec，保证 run_loop 总能回到接命令态。
                __wd_killed = 0;
                if (cmd_watchdog_stall_ns <= 0.0) begin
                    // watchdog 禁用时直接调度；业务自身的独立执行进程由core提供。
                    aip_cmd::exec_result(cmd_str, SRC_TCL, command_status, result, null, __wd_scope);
                end else begin
                    // These handles are per-command.  Clear both so a fast
                    // branch can never leave the previous command's process
                    // handle as the cancellation target.
                    __wd_exec_process    = null;
                    __wd_monitor_process = null;
                    __wd_done     = 0;
                    __wd_last_act = aip_activity::count;
                    __wd_stall    = 0.0;
                    fork
                        begin
                            __wd_exec_process = process::self();
                            aip_cmd::exec_result(cmd_str, SRC_TCL, command_status, result, null, __wd_scope);
                            __wd_done = 1;
                        end
                        // 停滞监控：采样 activity count，持续无进展才判死锁。
                        begin
                            __wd_monitor_process = process::self();
                            while (__wd_done == 0) begin
                                aip_time::delay_ns(cmd_watchdog_poll_ns);
                                if (__wd_done) break;
                                if (aip_activity::count != __wd_last_act) begin
                                    __wd_last_act = aip_activity::count;  // 有进展, 喂狗
                                    __wd_stall    = 0.0;
                                end else begin
                                    __wd_stall = __wd_stall + cmd_watchdog_poll_ns;
                                    if (__wd_stall >= cmd_watchdog_stall_ns) begin
                                        // 判死锁: 写 error result + 内置清理 + 用户 hook
                                        command_status = -1;
                                        result = $sformatf(
                                            "ERROR: cmd '%s' stalled %.0f ns, no activity progress (bridge watchdog killed it)",
                                            cmd_str, __wd_stall);
                                        // 真正取消及seq回收在join_any后进行；此处不得
                                        // 对fork使用kill_active，否则会误杀既有后台seq。
                                        break;
                                    end
                                end
                            end
                        end
                    join_any
                    // join_any may resume before the losing child has run its
                    // first statement.  Wait for both current children to
                    // publish their handles before deciding which one lost.
                    wait ((__wd_exec_process != null) &&
                          (__wd_monitor_process != null));
                    __wd_killed = !__wd_done;
                    // Kill only the unfinished watchdog child.  A bare
                    // disable fork would also kill unrelated join_none
                    // descendants owned by the run_loop caller.
                    if (__wd_killed) begin
                        if ((__wd_exec_process.status() != process::FINISHED) &&
                            (__wd_exec_process.status() != process::KILLED))
                            __wd_exec_process.kill();
                        void'(aip_cmd_seq_registry::kill_cancelled_owners());
                        // scope只记录本请求实际启动的worker。先让内部listener提交
                        // 独立快照，再调用旧用户hook；core/bridge不引用任何RAL类型。
                        if (__wd_scope.notify_dead(AIP_CMD_WATCHDOG, __wd_snapshot))
                            result = __wd_snapshot;
                        if (watchdog_hook != null) watchdog_hook.on_timeout(cmd_str);
                    end else begin
                        if ((__wd_monitor_process.status() != process::FINISHED) &&
                            (__wd_monitor_process.status() != process::KILLED))
                            __wd_monitor_process.kill();
                    end
                end

                // A watchdog-cancelled end_test cannot execute its normal
                // cleanup or request bridge exit.  Its exact full-lifetime
                // owner covers drain, checker wait, idle, and nested fork.
                // Never disturb an unrelated owner that is still live.
                if (__wd_killed && end_test_owner != null) begin
                    __wd_owner_status = end_test_owner.status();
                    if ((__wd_owner_status == process::KILLED) ||
                        (__wd_owner_status == process::FINISHED)) begin
                        if (end_checker_wait_active &&
                            end_checker_wait_owner == end_test_owner) begin
                            end_checker_wait_owner = null;
                            end_checker_wait_active = 0;
                        end
                        end_test_owner = null;
                        __tcl_exit = 1;
                    end
                end

                // Tcl ACK始终使用本次局部输出；兼容镜像不得覆盖在途legacy返回槽。
                // 后台任务在别的命令等待期间结束，不能改变这份结果或请求ID。
                aip_cmd::publish_compat_result(command_status, result);
                __tcl_result_status = command_status;

                if (result.len() > 1024) begin
                    `aip_warning(("[AIP_TCL_BRIDGE] result truncated %0d → 1024 bytes",
                                  result.len()));
                    __tcl_result_len = 1024;
                end else begin
                    __tcl_result_len = result.len();
                end
                for (i = 0; i < result.len() && i < 1024; i = i + 1) begin
                    __tcl_result_ascii[i] = result[i];
                end

                `aip_debug(("[AIP_TCL_BRIDGE] Result: status=%0d, msg=%s", __tcl_result_status, result));

                update_sim_time();

                __tcl_cmd_len = 0;

                // Ack with the id latched at wake-time so Tcl can tell this cmd's $stop from a previous cmd's.
                __tcl_result_id = local_cmd_id;

                $fflush();

                // 处理完, 暂停让 TCL 读 result. _vcs_run 返回 TCL.
                __tcl_bridge_idle = 1;
                $stop(0);
            end
        end
    endtask

endclass

// end_test：退出 Tcl bridge。用法 end_test [drain=ns] [idle=t] [timeout=t] [wait_done=1] [cmd=c ...]；
// 依次执行固定 drain、检查器等待、活动空闲检测，最后按书写顺序同步执行清理命令。
class \__aip_cmd_end_test extends aip_cmd;
    // 去掉命令列表值外层的一对 brace；内部 brace 仍保留给子命令参数。
    static function string unwrap_cleanup_value(string value);
        string text;

        text = aip_str::strip(value);
        if (text.len() >= 2 && text[0] == "{" &&
            text[text.len() - 1] == "}")
            return text.substr(1, text.len() - 2);
        return text;
    endfunction

    // 按顶层分号拆清理命令；子命令的 brace、bracket、quote 内容原样保留。
    static function string_darray_t split_cleanup_commands(string text);
        string items[$];
        string_darray_t result;
        int start_pos;
        int braces;
        int brackets;
        bit quoted;
        bit escaped;

        start_pos = 0;
        braces = 0;
        brackets = 0;
        quoted = 0;
        escaped = 0;
        for (int i = 0; i < text.len(); i++) begin
            byte c;
            c = text[i];
            if (escaped) begin
                escaped = 0;
                continue;
            end
            if (c == 8'd92) begin
                escaped = 1;
                continue;
            end
            if (c == 8'd34 && braces == 0) begin
                quoted = !quoted;
                continue;
            end
            if (quoted) continue;

            if (c == "{") braces++;
            else if (c == "}" && braces > 0) braces--;
            else if (c == "[") brackets++;
            else if (c == "]" && brackets > 0) brackets--;
            else if (c == ";" && braces == 0 && brackets == 0) begin
                if (i > start_pos) begin
                    string item;
                    item = aip_str::strip(text.substr(start_pos, i - 1));
                    if (item != "") items.push_back(item);
                end
                start_pos = i + 1;
            end
        end

        if (start_pos < text.len()) begin
            string item;
            item = aip_str::strip(text.substr(start_pos, text.len() - 1));
            if (item != "") items.push_back(item);
        end

        result = new[items.size()];
        foreach (items[index]) result[index] = items[index];
        return result;
    endfunction

    // 生命周期命令会改变 bridge/命令注册环境，不能嵌套在 end_test 清理阶段。
    static function bit cleanup_command_allowed(string command);
        string name;
        string args;

        aip_cmd::parse_cmd_str(command, name, args);
        return name != "end_test" && name != "fork" &&
               name != "so_load" && name != "so_reload" &&
               name != "so_unload";
    endfunction

    // 拥有退出请求和检查器快照；只允许同步执行，取消清理由run_loop负责。
    task cmd_exec();
        string args;
        string drain_s;
        string idle_s, timeout_s, wait_done_s, strict_s;
        real drain_ns, idle_ns, timeout_ns;
        real start_time;
        bit exact_failed;
        string exact_detail;
        string cleanup_values[];
        int cleanup_count;
        bit cleanup_failed;
        string cleanup_detail;

        aip_tcl_bridge::end_test_owner = process::self();

        args = this.args_in;
        drain_s     = aip_cmd::get_arg(args, "drain");
        idle_s      = aip_cmd::get_arg(args, "idle");
        timeout_s   = aip_cmd::get_arg(args, "timeout");
        wait_done_s = aip_cmd::get_arg(args, "wait_done");
        strict_s    = aip_cmd::get_arg(args, "strict");

        exact_failed = 0;
        exact_detail = "";
        cleanup_count = 0;
        cleanup_failed = 0;
        cleanup_detail = "";

        // 支持重复 cmd=，也支持把整个参数块包在一对 brace 中。
        cleanup_values = aip_cmd::get_arg_values(args, "cmd");
        if (cleanup_values.size() == 0) begin
            string outer_args;
            outer_args = aip_str::strip(args);
            if (outer_args.len() >= 2 && outer_args[0] == "{" &&
                outer_args[outer_args.len() - 1] == "}") begin
                cleanup_values = aip_cmd::get_arg_values(
                    outer_args.substr(1, outer_args.len() - 2), "cmd");
            end
        end

        drain_ns   = (drain_s != "")   ? aip_cmd::parse_time_ns(drain_s)   : 0;
        idle_ns    = (idle_s != "")    ? aip_cmd::parse_time_ns(idle_s)    : 0;
        timeout_ns = (timeout_s != "") ? aip_cmd::parse_time_ns(timeout_s) : 0;

        start_time = real'($realtime / 1ns);

        // 1. 固定 drain
        if (drain_ns > 0) begin
            `aip_info(("[END_TEST] Drain %.0f ns at t=%0t", drain_ns, $time));
            #(drain_ns * 1ns);
        end

        // 2. wait_done — snapshot and aggregate every registered checker.
        if (wait_done_s == "1") begin
            aip_end_checker checkers[$];
            string checker_names[$];
            bit all_done;
            bit any_failed;
            string pending_detail;
            string failure_detail;

            aip_tcl_bridge::end_checker_wait_owner =
                aip_tcl_bridge::end_test_owner;
            aip_tcl_bridge::end_checker_wait_active = 1;
            if (aip_tcl_bridge::end_checker != null) begin
                checkers.push_back(aip_tcl_bridge::end_checker);
                checker_names.push_back("legacy");
            end
            foreach (aip_tcl_bridge::named_end_checkers[name]) begin
                checkers.push_back(aip_tcl_bridge::named_end_checkers[name]);
                checker_names.push_back(name);
            end

            if (checkers.size() == 0 && strict_s == "1") begin
                exact_failed = 1;
                exact_detail = "ERROR: strict end_test requires at least one checker";
                `aip_error(("[END_TEST] %s", exact_detail));
            end else if (checkers.size() == 0) begin
                exact_detail = "no end checker (compatibility mode)";
            end else begin
                `aip_info(("[END_TEST] Waiting for %0d end checker(s)...",
                           checkers.size()));
                forever begin
                    all_done = 1;
                    any_failed = 0;
                    pending_detail = "";
                    failure_detail = "";

                    foreach (checkers[index]) begin
                        if (checkers[index].has_failed()) begin
                            any_failed = 1;
                            failure_detail = {
                                failure_detail,
                                (failure_detail == "") ? "" : "; ",
                                $sformatf("%s: %s", checker_names[index],
                                          checkers[index].status_detail())
                            };
                        end else if (!checkers[index].is_done()) begin
                            all_done = 0;
                            pending_detail = {
                                pending_detail,
                                (pending_detail == "") ? "" : "; ",
                                $sformatf("%s: %s", checker_names[index],
                                          checkers[index].status_detail())
                            };
                        end
                    end

                    if (any_failed) begin
                        exact_failed = 1;
                        exact_detail = {"ERROR: checker failure: ",
                                        failure_detail};
                        `aip_error(("[END_TEST] %s", exact_detail));
                        break;
                    end
                    if (all_done) begin
                        exact_detail = "all end checkers complete";
                        break;
                    end
                    if (timeout_ns > 0 &&
                        (real'($realtime / 1ns) - start_time) >= timeout_ns) begin
                        exact_detail = {"timeout waiting for: ", pending_detail};
                        if (strict_s == "1") begin
                            exact_failed = 1;
                            `aip_error(("[END_TEST] %s", exact_detail));
                        end else begin
                            `aip_warning(("[END_TEST] %s; force exit",
                                          exact_detail));
                        end
                        break;
                    end
                    #(100 * 1ns);
                end
            end

            // The only normal cleanup point.  Watchdog cancellation is
            // handled by run_loop because it prevents this task from resuming.
            aip_tcl_bridge::end_checker_wait_owner = null;
            aip_tcl_bridge::end_checker_wait_active = 0;
        end

        // 3. idle — 等活动计数器稳定
        if (!exact_failed && idle_ns > 0) begin
            int unsigned last_count;
            `aip_info(("[END_TEST] Waiting for idle (%.0f ns no activity)...", idle_ns));
            forever begin
                last_count = aip_activity::get_count();
                aip_time::delay_ns(idle_ns);
                if (aip_activity::get_count() == last_count) begin
                    `aip_info(("[END_TEST] Idle detected, exiting"));
                    break;
                end
                if (timeout_ns > 0 && (real'($realtime / 1ns) - start_time) >= timeout_ns) begin
                    `aip_warning(("[END_TEST] Timeout %.0f ns reached, force exit", timeout_ns));
                    break;
                end
            end
        end

        // 4. cleanup commands — 等待完成后按书写顺序同步执行。
        foreach (cleanup_values[value_index]) begin
            string cleanup_value;
            string_darray_t commands;

            cleanup_value = unwrap_cleanup_value(cleanup_values[value_index]);
            commands = split_cleanup_commands(cleanup_value);
            foreach (commands[command_index]) begin
                string cleanup_command;
                int cleanup_status;
                string cleanup_result;

                cleanup_command = aip_str::strip(commands[command_index]);
                if (cleanup_command == "") continue;
                cleanup_count++;

                if (!cleanup_command_allowed(cleanup_command)) begin
                    cleanup_failed = 1;
                    cleanup_detail = {
                        cleanup_detail,
                        (cleanup_detail == "") ? "" : "; ",
                        cleanup_command, ": command is not allowed in end_test cleanup"
                    };
                    `aip_error(("[END_TEST] Cleanup command rejected: %s",
                                cleanup_command));
                    continue;
                end

                `aip_info(("[END_TEST] Cleanup command: %s", cleanup_command));
                aip_cmd::exec_result(cleanup_command, SRC_TCL,
                                      cleanup_status, cleanup_result);
                if (cleanup_status != 0) begin
                    cleanup_failed = 1;
                    cleanup_detail = {
                        cleanup_detail,
                        (cleanup_detail == "") ? "" : "; ",
                        $sformatf("%s -> status=%0d: %s",
                                  cleanup_command, cleanup_status,
                                  cleanup_result)
                    };
                    `aip_error(("[END_TEST] Cleanup command failed: %s -> %s",
                                cleanup_command, cleanup_result));
                end
            end
        end

        if (cleanup_failed) begin
            exact_failed = 1;
            exact_detail = {
                exact_detail,
                (exact_detail == "") ? "" : "; ",
                "cleanup failed: ", cleanup_detail
            };
        end else if (cleanup_count > 0) begin
            exact_detail = {
                exact_detail,
                (exact_detail == "") ? "" : "; ",
                $sformatf("cleanup %0d command(s) complete", cleanup_count)
            };
        end

        `aip_info(("[END_TEST] Test ending at t=%0t", $time));
        aip_tcl_bridge::end_test_owner = null;
        aip_tcl_bridge::__tcl_exit = 1;
        if (exact_failed) begin
            this.result_out = exact_detail;
            this.status = 1;
        end else begin
            this.result_out = $sformatf("OK: ended at t=%0t (%s)",
                                        $time, exact_detail);
            this.status = 0;
        end
    endtask

    function new(string name); super.new(name); endfunction
    static \__aip_cmd_end_test __inst = new("end_test");
endclass

// Watchdog 控制命令（Tcl 直接调用，无需重编译）。

// set_cmd_watchdog [ns=N]   改停滞超时阈值 (0=禁用); 无参则只读当前值
class \__aip_cmd_set_cmd_watchdog extends aip_cmd;
    // 修改或查询全局停滞阈值；不改变单条命令wait的缺省同步语义。
    task cmd_exec();
        string __v;
        real   __ns;
        __v = aip_cmd::get_arg(this.args_in, "ns");
        if (__v != "") begin
            __ns = real'(aip_cmd::parse_int64_arg(__v));
            aip_tcl_bridge::set_cmd_watchdog(__ns);
            this.result_out = $sformatf("watchdog stall_ns=%.0f", __ns);
        end else begin
            this.result_out = $sformatf("watchdog stall_ns=%.0f (unchanged)",
                                        aip_tcl_bridge::cmd_watchdog_stall_ns);
        end
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_set_cmd_watchdog __inst = new("set_cmd_watchdog");
endclass

// kill_seq [name=xxx]   手动杀活动 seq (无 name = 杀全部)
class \__aip_cmd_kill_seq extends aip_cmd;
    // 显式用户取消，可按名称或全部取消seq；不保证协议driver的pending状态恢复。
    task cmd_exec();
        string __nm = aip_cmd::get_arg(this.args_in, "name");
        int __n;
        if (__nm != "") begin
            __n = aip_cmd_seq_registry::kill_one(__nm);
            this.result_out = $sformatf("killed=%0d name=%s", __n, __nm);
        end else begin
            __n = aip_cmd_seq_registry::kill_active();
            this.result_out = $sformatf("killed=%0d (all)", __n);
        end
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_kill_seq __inst = new("kill_seq");
endclass

// watchdog_status   查看 watchdog 配置 + 活动 seq 数
class \__aip_cmd_watchdog_status extends aip_cmd;
    task cmd_exec();
        this.result_out = $sformatf("stall_ns=%.0f poll_ns=%.0f active_seqs=%0d hook=%s",
            aip_tcl_bridge::cmd_watchdog_stall_ns,
            aip_tcl_bridge::cmd_watchdog_poll_ns,
            aip_cmd_seq_registry::count(),
            (aip_tcl_bridge::watchdog_hook != null) ? "set" : "none");
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_watchdog_status __inst = new("watchdog_status");
endclass

// Macro: start TCL bridge run loop in an initial block
`define aip_tcl_bridge_create(name) \
    initial begin \
        aip_tcl_bridge::run_loop(); \
    end

`endif // AIP_TCL_BRIDGE_SV
