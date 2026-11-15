//===========================================================
// aip_tcl_bridge - TCL/UCLI command bridge
// Bridge state lives in aip_core_pkg; the class owns the run loop.
// TCL uses fully qualified aip_core_pkg::__tcl_* paths, and SV reads the
// package state on resume from $stop.
// Synchronization: $stop(0)/run handshake.
//
// Usage: `aip_tcl_bridge_create(name)
// Exit:  end_test [drain=1000] [idle=1us] [timeout=10us]
// Depends: aip_cmd.sv
//===========================================================
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

// bridge idle 标志：1=循环顶部等待命令，0=正在执行命令
// TCL resume 用这个检测 seq 是否跑完
reg __tcl_bridge_idle = 0;

// Event-driven cmd trigger: TCL forces 0→1 transition to signal cmd ready.
// SV bridge @(posedge) blocks waiting, eliminates $stop race in chip TB
// with multiple $stop sites.
reg __tcl_cmd_trigger = 0;

// cmd_id ack handshake: TCL assigns monotonic id per cmd, SV writes back after
// processing. TCL's bounded retry loop polls __tcl_result_id == my_id to confirm
// the $stop that returned _vcs_run actually corresponds to this cmd (not a
// stray chip-TB $stop or a leftover stop from a prior interrupted cmd).
reg [31:0] __tcl_cmd_id    = 0;
reg [31:0] __tcl_result_id = 0;

// 已注册命令名表 (逗号分隔). bridge 启动时写一次 (静态注册), TCL 启动 get
// 后门读 (零握手) 缓存成 dict, 用于未注册命令快速失败. 4096 字符够装上百条.
reg [31:0] __tcl_cmd_names_ascii [0:4095];
reg [31:0] __tcl_cmd_names_len = 0;

// ============================================================
// aip_activity — 全局活动计数器
// monitor/scoreboard/driver 调 tick() 表示有活动
// end_test idle=N 检测计数器稳定后退出
// ============================================================
class aip_activity;
    static int unsigned count = 0;

    static function void tick();
        count = count + 1;
    endfunction

    static function int unsigned get_count();
        return count;
    endfunction
endclass

// ============================================================
// aip_end_checker — 退出检查回调基类（虚类）
// 用户实现 is_done()，end_test wait_done=1 时轮询
// ============================================================
virtual class aip_end_checker;
    pure virtual function bit is_done();

    virtual function bit has_failed();
        return 0;
    endfunction

    virtual function string status_detail();
        return "";
    endfunction
endclass

// ============================================================
// aip_cmd_watchdog_hook — 命令停滞超时清理回调（虚类）
// run_loop 的停滞检测 watchdog 判定某条命令死锁并强杀后，调 on_timeout()
// 让用户补做子系统脏状态清理（如 seq.kill()、复位 mailbox flag）。
// cmd_str 是被杀的命令原文，供用户按命令类型分派清理。
// ============================================================
virtual class aip_cmd_watchdog_hook;
    pure virtual function void on_timeout(string cmd_str);
endclass

class aip_tcl_bridge;

    // Exit control
    static bit __tcl_exit = 0;

    // Watchdog: auto-exit after N consecutive idle cycles (0=disabled)
    static int idle_limit = 0;

    // End checker callbacks
    static aip_end_checker end_checker = null;
    static aip_end_checker named_end_checkers[string];
    static bit end_checker_wait_active = 0;
    static process end_checker_wait_owner = null;
    static process end_test_owner = null;

    // 命令停滞看门狗: 某条命令连续 cmd_watchdog_stall_ns 无活动进展
    // (aip_activity::count 不变) 判死锁, 强杀 exec, 让 run_loop 回到接命令态.
    // 0 = 禁用. 默认 50us. 停滞检测 (非绝对超时): 正常长 seq 只要持续 tick 不被误杀.
    static real cmd_watchdog_stall_ns = 50000.0;

    // 停滞采样间隔 (每隔多久看一次 activity count). 越小越灵敏, 越大开销越低.
    static real cmd_watchdog_poll_ns = 1000.0;

    // 停滞超时后的脏状态清理回调 (可选).
    static aip_cmd_watchdog_hook watchdog_hook = null;

    function new();
    endfunction

    static function void set_watchdog(int limit);
        idle_limit = limit;
        `aip_info(("[AIP_TCL_BRIDGE] Watchdog set to %0d idle cycles", limit));
    endfunction

    protected static function bit reject_checker_mutation(string operation);
        if (!end_checker_wait_active)
            return 0;

        `aip_error(("[AIP_TCL_BRIDGE] Cannot %s while end-checker wait is active",
                    operation));
        return 1;
    endfunction

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

    static function void unregister_end_checker(string name);
        if (reject_checker_mutation("unregister an end checker"))
            return;
        named_end_checkers.delete(name);
    endfunction

    static function void clear_end_checkers();
        if (reject_checker_mutation("clear end checkers"))
            return;
        named_end_checkers.delete();
    endfunction

    static function void set_end_checker(aip_end_checker checker);
        if (reject_checker_mutation("set the legacy end checker"))
            return;
        end_checker = checker;
    endfunction

    // 设命令停滞看门狗阈值 (ns). 0=禁用. 建议 < TCL 侧 aip_ack_timeout_ns
    // (默认 50us) 才能让被杀命令在 TCL 放弃前干净返回 error result.
    static function void set_cmd_watchdog(real stall_ns);
        cmd_watchdog_stall_ns = stall_ns;
        `aip_info(("[AIP_TCL_BRIDGE] Cmd watchdog stall timeout = %.0f ns", stall_ns));
    endfunction

    // 注册停滞超时清理钩子.
    static function void set_watchdog_hook(aip_cmd_watchdog_hook h);
        watchdog_hook = h;
    endfunction

    // 刷新仿真时间字符串供 TCL 兜底读取 (senv time 不可用时).
    // run_loop 在 (a) 命令处理完暂停前 (b) free_run 推进每步 都调, 保证不陈旧.
    static function void update_sim_time();
        string time_s;
        // timeunit 无关: $realtime 与 1ns 同 timeunit, 比值恒为 ns.
        // 取代旧的 real'(1ns) 阈值猜单位 (只对 1ps/1ns/1us/1ms 正确,
        // 10ps/100ps/10ns 等会标错单位导致 10x/100x 放大).
        real t_ns = $realtime / 1ns;
        time_s = $sformatf("%.3f ns", t_ns);
        __tcl_sim_time_len = time_s.len();
        for (int j = 0; j < time_s.len() && j < 64; j = j + 1)
            __tcl_sim_time_ascii[j] = time_s[j];
    endfunction

    // Main loop: event-driven trigger pulse from TCL.
    // Initial $stop lets first _vcs_run return so user gets ucli prompt.
    // Then @(posedge __tcl_cmd_trigger) blocks until TCL pulses trigger
    // for each cmd. This is independent of any other $stop in chip TB.
    static task run_loop();
        int idle_count;
        __tcl_exit = 0;
        idle_count = 0;

        `aip_info(("[AIP_TCL_BRIDGE] Started, waiting for commands..."));

        // 把已注册命令名 (逗号分隔) 写进后门 reg, 供 TCL 启动 get 读 (零握手)
        // 缓存, 未注册命令快速失败用. 命令 elaboration 期静态注册, 写一次即可.
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

                __tcl_bridge_idle = 0;

                // Latch cmd_id at accept time so subsequent TCL force on
                // __tcl_cmd_id (next cmd) does not contaminate this cmd's ack.
                // Critical for Ctrl+C recovery: if TCL force a new id while
                // this exec is mid-flight, our ack still reflects the
                // originally-accepted id, so TCL retry loop knows this $stop
                // is NOT its new cmd.
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

                // ---- 停滞检测 watchdog: 命令连续无活动进展判死锁, 强杀 exec ----
                // 保证 run_loop 永远能回到接命令态, 后续命令不被一条卡死的命令连累.
                __wd_killed = 0;
                if (cmd_watchdog_stall_ns <= 0.0) begin
                    // watchdog 禁用: 裸调 (向后兼容)
                    aip_cmd::exec(cmd_str, SRC_TCL);
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
                        // 分支A: 真正执行命令
                        begin
                            __wd_exec_process = process::self();
                            aip_cmd::exec(cmd_str, SRC_TCL);
                            __wd_done = 1;
                        end
                        // 分支B: 停滞监控 (采样 activity count, 持续无进展才判死锁)
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
                                        aip_cmd::__aip_cmd_last_status = -1;
                                        aip_cmd::__aip_cmd_last_result = $sformatf(
                                            "ERROR: cmd '%s' stalled %.0f ns, no activity progress (bridge watchdog killed it)",
                                            cmd_str, __wd_stall);
                                        // 精准杀肇事命令的 seq; fork 并行命令则杀其全部子 seq
                                        if (__wd_kname == "fork")
                                            void'(aip_cmd_seq_registry::kill_active());
                                        else
                                            void'(aip_cmd_seq_registry::kill_one(__wd_kname));
                                        if (watchdog_hook != null) watchdog_hook.on_timeout(cmd_str);
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

                result = aip_cmd::__aip_cmd_last_result;
                __tcl_result_status = aip_cmd::__aip_cmd_last_status;

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

                // 更新仿真时间字符串供 TCL 读取
                update_sim_time();

                __tcl_cmd_len = 0;

                // ack: write back the LATCHED id (captured at wake-time), so
                // TCL retry loop can distinguish "$stop from THIS cmd" from
                // "$stop from prev cmd whose id was overwritten by TCL force".
                __tcl_result_id = local_cmd_id;

                $fflush;

                // 处理完, 暂停让 TCL 读 result. _vcs_run 返回 TCL.
                __tcl_bridge_idle = 1;
                $stop(0);
            end
        end
    endtask

endclass

// ============================================================
// Built-in: end_test — exit TCL bridge
// Usage:
//   end_test                          ;# 立即退出
//   end_test drain=1000               ;# 固定 drain 1000ns
//   end_test idle=1us                 ;# 等活动计数器稳定 1us
//   end_test idle=500 timeout=10us    ;# idle 检测 + 超时保底
//   end_test wait_done=1 timeout=5us  ;# 等回调 is_done() + 超时
// ============================================================
class \__aip_cmd_end_test extends aip_cmd;
    task cmd_exec();
        string args;
        int drain_ns;
        string idle_s, timeout_s, wait_done_s, strict_s;
        real idle_ns, timeout_ns;
        real start_time;
        bit exact_failed;
        string exact_detail;

        aip_tcl_bridge::end_test_owner = process::self();

        args = this.args_in;
        drain_ns    = aip_cmd::parse_int_arg(aip_cmd::get_arg(args, "drain"), 0);
        idle_s      = aip_cmd::get_arg(args, "idle");
        timeout_s   = aip_cmd::get_arg(args, "timeout");
        wait_done_s = aip_cmd::get_arg(args, "wait_done");
        strict_s    = aip_cmd::get_arg(args, "strict");

        exact_failed = 0;
        exact_detail = "";

        idle_ns    = (idle_s != "")    ? aip_cmd::parse_time_ns(idle_s)    : 0;
        timeout_ns = (timeout_s != "") ? aip_cmd::parse_time_ns(timeout_s) : 0;

        start_time = real'($realtime / 1ns);

        // 1. 固定 drain
        if (drain_ns > 0) begin
            `aip_info(("[END_TEST] Drain %0d ns at t=%0t", drain_ns, $time));
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

// ============================================================
// Watchdog 控制命令 (TCL 直接调用, 无需重编译)
// ============================================================

// set_cmd_watchdog [ns=N]   改停滞超时阈值 (0=禁用); 无参则只读当前值
class \__aip_cmd_set_cmd_watchdog extends aip_cmd;
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
