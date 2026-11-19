`ifndef AIP_WAIT_POLICY_SV
`define AIP_WAIT_POLICY_SV

// 各项目共用的等待/超时策略：所有等待都应经过本类而非裸 #delay，项目专用超时由子类加字段。
// 时间差均在本类作用域按 $realtime/1ns 计算，与调用方 timeunit 无关。
// fork 均具名且只 disable 具名块（不用 disable fork），避免误杀调用方的并行线程。
class aip_wait_policy extends uvm_object;
    `uvm_object_utils(aip_wait_policy)

    int unsigned default_poll_interval_ns = 10;
    int unsigned default_timeout_ns       = 10000;
    int unsigned timeout_multiplier       = 1;       // 全局倍率：>1 时放大全部超时
    int unsigned max_poll_attempts        = 10000;   // 迭代上限：时间不推进时防挂死

    function new(string name = "aip_wait_policy");
        super.new(name);
    endfunction

    // 全部参数校验通过才提交；运行中的等待不随 set_param 改变。子类覆盖时先调 super。
    extern virtual function void load_params(string path = "aip.wait");
    extern virtual function void do_copy(uvm_object rhs);
    // 32 位饱和；倍率 0 按 1 处理。
    extern function int unsigned effective_timeout(int unsigned base_ns);
    // 自行轮询须用它取起点，不要传调用方作用域的 $realtime。
    extern function realtime wait_start();
    // 已超时返回 <=0。
    extern function realtime time_left_ns(realtime start, int unsigned base_timeout_ns);
    // 只判断不报错，由调用方带业务上下文报告。
    extern function bit deadline_reached(realtime start, int unsigned base_timeout_ns,
                                         int unsigned attempts);
    // 不超过剩余预算；不报告超时。
    extern task wait_poll_interval(realtime remaining);
    // 时间上限 + 次数上限双重保护，仿真时间不推进时也能退出。
    extern task poll_until_flag(string description, int unsigned timeout_ns,
                                int unsigned poll_interval_ns, ref bit success_flag,
                                ref bit timed_out);
    extern task wait_event_or_timeout(string description, uvm_event evt,
                                      int unsigned timeout_ns, ref bit triggered);
    // 事件等待加轮询兜底：事件可能已触发或被错过时使用。
    extern task wait_event_or_poll(string description, uvm_event evt, int unsigned timeout_ns,
                                   int unsigned poll_interval_ns, ref bit triggered);

    // 子类共用的范围检查：1..2^32-1，否则 fatal 并返回 0。
    extern protected function bit check_param(string path, string name, longint unsigned value);
endclass

function void aip_wait_policy::load_params(string path = "aip.wait");
    longint unsigned	poll_ns;
    longint unsigned	timeout_ns;
    longint unsigned	multiplier;
    longint unsigned	max_polls;

    `aip_int(path, longint unsigned, poll_ns, default_poll_interval_ns)
    `aip_int(path, longint unsigned, timeout_ns, default_timeout_ns)
    `aip_int(path, longint unsigned, multiplier, timeout_multiplier)
    `aip_int(path, longint unsigned, max_polls, max_poll_attempts)
    if (!check_param(path, "poll_ns", poll_ns) || !check_param(path, "timeout_ns", timeout_ns) ||
        !check_param(path, "multiplier", multiplier) || !check_param(path, "max_polls", max_polls))
        return;
    default_poll_interval_ns = int'(poll_ns);
    default_timeout_ns = int'(timeout_ns);
    timeout_multiplier = int'(multiplier);
    max_poll_attempts = int'(max_polls);
endfunction

function bit aip_wait_policy::check_param(string path, string name, longint unsigned value);
    // 负数与超出 64 位的值已在 aip_int 解析时 hard fatal；这里只检查 1..2^32-1。
    if ((value == 0) || (value > 64'hffff_ffff)) begin
        `uvm_fatal("WAIT_PARAM", $sformatf("%s.%s 必须为 1..2^32-1，当前值 %0d", path, name, value))
        return 0;
    end
    return 1;
endfunction

function void aip_wait_policy::do_copy(uvm_object rhs);
    aip_wait_policy	typed_rhs;

    if (!$cast(typed_rhs, rhs)) begin
        `uvm_error("WAIT_PARAM", "wait policy copy 类型不兼容")
        return;
    end
    super.do_copy(rhs);
    default_poll_interval_ns = typed_rhs.default_poll_interval_ns;
    default_timeout_ns = typed_rhs.default_timeout_ns;
    timeout_multiplier = typed_rhs.timeout_multiplier;
    max_poll_attempts = typed_rhs.max_poll_attempts;
endfunction

function int unsigned aip_wait_policy::effective_timeout(int unsigned base_ns);
    int unsigned	mult;

    mult = (timeout_multiplier == 0) ? 1 : timeout_multiplier;
    if (base_ns > (32'hFFFF_FFFF / mult))
        return 32'hFFFF_FFFF;
    return base_ns * mult;
endfunction

function realtime aip_wait_policy::wait_start();
    return $realtime;
endfunction

function realtime aip_wait_policy::time_left_ns(realtime start, int unsigned base_timeout_ns);
    realtime	elapsed_ns;

    elapsed_ns = ($realtime - start) / 1ns;
    return realtime'(effective_timeout(base_timeout_ns)) - elapsed_ns;
endfunction

function bit aip_wait_policy::deadline_reached(realtime start, int unsigned base_timeout_ns,
                                               int unsigned attempts);
    return (time_left_ns(start, base_timeout_ns) <= 0) || (attempts >= max_poll_attempts);
endfunction

task aip_wait_policy::wait_poll_interval(realtime remaining);
    realtime	interval_ns;

    if (remaining <= 0) return;
    interval_ns = (default_poll_interval_ns == 0) ? 1 : default_poll_interval_ns;
    if (interval_ns > remaining) interval_ns = remaining;
    #(interval_ns * 1ns);
endtask

task aip_wait_policy::poll_until_flag(string description, int unsigned timeout_ns,
                                      int unsigned poll_interval_ns, ref bit success_flag,
                                      ref bit timed_out);
    int unsigned	eff_timeout;
    int unsigned	interval;
    int unsigned	attempts;
    realtime	start_time;

    eff_timeout = effective_timeout(timeout_ns);
    interval    = (poll_interval_ns < 1) ? 1 : poll_interval_ns;
    attempts    = 0;
    start_time  = $realtime;
    timed_out   = 0;

    while (!success_flag) begin
        realtime	elapsed_ns;
        elapsed_ns = ($realtime - start_time) / 1ns;

        if (elapsed_ns >= eff_timeout) begin
            timed_out = 1;
            `uvm_error("WAIT_POLICY",
                $sformatf("poll_until_flag TIMEOUT after %0t: %s (timeout=%0dns, attempts=%0d)",
                          $realtime, description, eff_timeout, attempts))
            return;
        end

        if (attempts >= max_poll_attempts) begin
            timed_out = 1;
            `uvm_error("WAIT_POLICY",
                $sformatf("poll_until_flag MAX_ATTEMPTS (%0d) exceeded at %0t: %s",
                          max_poll_attempts, $realtime, description))
            return;
        end

        #(interval * 1ns);
        attempts++;
    end

    `uvm_info("WAIT_POLICY",
        $sformatf("poll_until_flag SUCCESS at %0t: %s (attempts=%0d)",
                  $realtime, description, attempts),
        UVM_HIGH)
endtask

task aip_wait_policy::wait_event_or_timeout(string description, uvm_event evt,
                                            int unsigned timeout_ns, ref bit triggered);
    int unsigned	eff_timeout;
    bit	event_triggered;

    eff_timeout = effective_timeout(timeout_ns);
    event_triggered = 0;

    fork : wait_evt_blk
        begin : evt_arm
            evt.wait_trigger();
            event_triggered = 1;
        end
        begin : timeout_arm
            #(eff_timeout * 1ns);
        end
    join_any
    disable wait_evt_blk;
    triggered = event_triggered;

    if (!triggered) begin
        `uvm_error("WAIT_POLICY",
            $sformatf("wait_event_or_timeout TIMEOUT after %0dns at %0t: %s",
                      eff_timeout, $realtime, description))
    end else begin
        `uvm_info("WAIT_POLICY",
            $sformatf("wait_event_or_timeout SUCCESS at %0t: %s", $realtime, description),
            UVM_HIGH)
    end
endtask

task aip_wait_policy::wait_event_or_poll(string description, uvm_event evt,
                                         int unsigned timeout_ns, int unsigned poll_interval_ns,
                                         ref bit triggered);
    int unsigned	eff_timeout;
    int unsigned	interval;
    int unsigned	attempts;
    realtime	start_time;
    bit	local_hit;

    eff_timeout = effective_timeout(timeout_ns);
    interval    = (poll_interval_ns < 1) ? 1 : poll_interval_ns;
    attempts    = 0;
    start_time  = $realtime;
    triggered   = 0;

    if (evt.is_on()) begin
        triggered = 1;
        `uvm_info("WAIT_POLICY",
            $sformatf("wait_event_or_poll: event already on at %0t: %s", $realtime, description),
            UVM_HIGH)
        return;
    end

    while (!triggered) begin
        realtime	elapsed_ns;
        elapsed_ns = ($realtime - start_time) / 1ns;

        if (elapsed_ns >= eff_timeout) begin
            `uvm_error("WAIT_POLICY",
                $sformatf("wait_event_or_poll TIMEOUT after %0dns at %0t: %s (attempts=%0d)",
                          eff_timeout, $realtime, description, attempts))
            return;
        end

        if (attempts >= max_poll_attempts) begin
            `uvm_error("WAIT_POLICY",
                $sformatf("wait_event_or_poll MAX_ATTEMPTS (%0d) exceeded at %0t: %s",
                          max_poll_attempts, $realtime, description))
            return;
        end

        local_hit = 0;

        fork : poll_evt_iter_blk
            begin : poll_evt_arm
                evt.wait_trigger();
                local_hit = 1;
            end
            begin : poll_timeout_arm
                #(interval * 1ns);
            end
        join_any
        disable poll_evt_iter_blk;

        attempts++;

        if (local_hit || evt.is_on()) begin
            triggered = 1;
            `uvm_info("WAIT_POLICY",
                $sformatf("wait_event_or_poll SUCCESS at %0t: %s (attempts=%0d)",
                          $realtime, description, attempts),
                UVM_HIGH)
        end
    end
endtask

`endif // AIP_WAIT_POLICY_SV
