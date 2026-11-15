`ifndef AIP_WAIT_POLICY_SV
`define AIP_WAIT_POLICY_SV

// ============================================================================
// aip_wait_policy
//
// 目录/层次：src/sv/util；由 aip_core_pkg 统一 include，依赖 UVM 与 aip_cmdline（aip_int）。
// 职责：各项目共用的等待/超时策略对象，迁自 virtio_net_vip 的 virtio_wait_policy 通用部分。
//   所有等待都应经过本类，禁止裸 #delay；项目专用的场景超时由子类增加字段。
// 规则：
//   - fork 全部命名，只 disable 具名块，绝不使用 "disable fork"，避免误杀调用方的并行线程；
//   - 轮询间隔钳位到 >=1ns；max_poll_attempts 是第二道防挂死保护，仿真时间不推进时也能退出；
//   - 实际超时 = 基准值 × timeout_multiplier（饱和乘法），一处放大即可整体放宽（真实 DUT/压力测试）；
//   - 超时统一报 uvm_error("WAIT_POLICY")，调用方凭 ref 标志或返回值判断成功/超时。
// 参数：load_params(path) 用 aip_int 读取 <path>.poll_ns / timeout_ns / multiplier / max_polls（ns）；
//   缺省保留当前字段值，先校验全部范围再提交，非法值（0、负数或超过 32 位）立即 fatal；
//   运行中的等待不会因 Tcl set_param 自动改变，需重新 load_params。
// 时间单位：所有时间差都在本类作用域内用 $realtime 计算并除以 1ns，与调用方 package 的
//   timeunit 无关；自行轮询的调用方必须用 wait_start() 取起点，不要传入自己作用域的 $realtime。
// 所有权/生命周期：策略数值归 test/config；等待线程归调用者。
// ============================================================================
class aip_wait_policy extends uvm_object;
    `uvm_object_utils(aip_wait_policy)

    int unsigned default_poll_interval_ns = 10;      // 默认轮询间隔
    int unsigned default_timeout_ns       = 10000;   // 默认基准超时 10us
    int unsigned timeout_multiplier       = 1;       // 全局倍率：>1 时放大全部超时
    int unsigned max_poll_attempts        = 10000;   // 迭代上限：时间不推进时防挂死

    // 构造函数：各字段用声明处默认值；测试可在 build 阶段直接改写字段或调用 load_params。
    function new(string name = "aip_wait_policy");
        super.new(name);
    endfunction

    // 读取 <path>.poll_ns/timeout_ns/multiplier/max_polls；子类覆盖时先调用 super 再读自有字段。
    extern virtual function void load_params(string path = "aip.wait");
    // 复制策略数值，供每个使用者独立持有；不复制等待线程或事件。
    extern virtual function void do_copy(uvm_object rhs);
    // 返回基准超时乘以倍率，超过 32 位时饱和；程序化旧配置的 0 倍率按 1 处理。
    extern function int unsigned effective_timeout(int unsigned base_ns);
    // 自行轮询的调用方取等待起点（本类作用域的 $realtime）。
    extern function realtime wait_start();
    // 距离 start 起算的有效超时还剩多少 ns；已超时返回 <=0。
    extern function realtime time_left_ns(realtime start, int unsigned base_timeout_ns);
    // 时间或次数上限是否已到；只判断不报错，由调用方带业务上下文报告。
    extern function bit deadline_reached(realtime start, int unsigned base_timeout_ns,
                                         int unsigned attempts);
    // 等待一轮统一轮询间隔，不超过调用者的剩余预算；不报告超时。
    extern task wait_poll_interval(realtime remaining);
    // 轮询 ref 标志直到置位或超时（标志由调用方的其他线程更新）。
    extern task poll_until_flag(string description, int unsigned timeout_ns,
                                int unsigned poll_interval_ns, ref bit success_flag,
                                ref bit timed_out);
    // 等待 uvm_event 触发或超时，先到者为准。
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
    // aip_int 把负数字面量读成无符号大数，同样落在上界之外而被拒绝。
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
    // 饱和乘法：结果会溢出 32 位时返回最大值。
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

// 单次延时总为正且有上界；零/负预算直接返回，外层据此结束等待。
task aip_wait_policy::wait_poll_interval(realtime remaining);
    realtime	interval_ns;

    if (remaining <= 0) return;
    interval_ns = (default_poll_interval_ns == 0) ? 1 : default_poll_interval_ns;
    if (interval_ns > remaining) interval_ns = remaining;
    #(interval_ns * 1ns);
endtask

// 双重保护：1) effective_timeout 时间上限；2) max_poll_attempts 迭代上限。
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

// 具名 fork，只 disable 本块。
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

// 每轮最多等待一个轮询间隔，再检查总超时；事件已触发时立即返回。
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
