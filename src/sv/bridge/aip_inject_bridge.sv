// src/sv/bridge：暂停调试期间的独立命令提交、FIFO 准入及逐 ticket 结果服务。
// 依赖 aip_cmd 的一次性预约和同步 exec_result；由 Tcl bridge 启动常驻服务，
// 服务拥有请求快照、32 个结果槽和执行线程，不借用普通 __tcl_* 请求/ACK。
// 调用方显式 release 终态 ticket 才回收槽；单调 ticket 永不因槽复用而重用。
// 此层不调用 $stop、不修改原 Tcl continuation、不持有 UVM objection；外层
// bridge 生命周期决定服务寿命。超时按提交后的绝对仿真时间计算，暂停不计时。
// 为避免破坏在途 driver/事务，运行中超时仅标记，不 kill；完成后才成为终态。
`ifndef AIP_INJECT_BRIDGE_SV
`define AIP_INJECT_BRIDGE_SV

// UCLI 可发现的协议与容量；ASCII 使用 32 位元素，兼容现有 VCS get/force。
// 请求先写完整 payload/id，最后置 trigger；接收器复制完后最后发布 ack_id。
reg [31:0] __inject_protocol_version = 1;
reg [31:0] __inject_slots = 32;
reg [31:0] __inject_request_ascii [0:1023];
reg [31:0] __inject_request_len = 0;
reg [31:0] __inject_request_id = 0;
reg [31:0] __inject_request_op = 0;
reg [31:0] __inject_request_timeout_ns = 0;
reg [63:0] __inject_request_ticket = 0;
reg __inject_request_trigger = 0;

// ACK 仅表明操作是否已接受；提交成功后的业务结果只从对应 slot/ticket 读取。
// status：0 成功，1 参数/命令非法，2 容量耗尽，3 旧 ticket，4 不可取消，
// 5 尚非终态；失败 ticket=0/slot=全一，不能误认作既有请求成功。
reg [31:0] __inject_ack_id = 0;
reg [31:0] __inject_ack_status = 0;
reg [31:0] __inject_ack_wait = 1;
reg [31:0] __inject_ack_slot = '1;
reg [63:0] __inject_ack_ticket = 0;
reg [31:0] __inject_ack_text_ascii [0:1023];
reg [31:0] __inject_ack_text_len = 0;

// result 地址为 slot*1024+字符下标；读者先核对 ticket，再读状态/长度。
// FREE 时旧字节不擦除，但 len=0/ticket=0 使其不可见。状态最后写入，终态
// 结果在 release 前不再改变；RUNNING_TIMEOUT 仍在执行，不能 release。
reg [31:0] __inject_slot_state [0:31] = '{default:0};
reg [63:0] __inject_slot_ticket [0:31] = '{default:0};
reg [31:0] __inject_slot_status [0:31] = '{default:0};
reg [31:0] __inject_slot_result_len [0:31] = '{default:0};
reg [31:0] __inject_result_ascii [0:32767];

typedef enum int {
    AIP_INJECT_FREE = 0,
    AIP_INJECT_QUEUED = 1,
    AIP_INJECT_RUNNING = 2,
    AIP_INJECT_DONE = 3,
    AIP_INJECT_CANCELLED = 4,
    AIP_INJECT_TIMED_OUT = 5,
    AIP_INJECT_RUNNING_TIMEOUT = 6
} aip_inject_state_e;

// 每次提交单独分配对象；command/handle/token/ticket 构造后不替换。仅服务
// 更新生命周期字段，普通命令始终写自己的 exec_result 局部输出。
class aip_inject_job;
    longint unsigned ticket;
    int slot;
    string command;
    aip_cmd handle;
    aip_cmd_admission admission;
    aip_inject_state_e state;
    int status;
    string result_text;
    int unsigned timeout_ns;
    realtime submitted_at;
    realtime started_at;
    realtime finished_at;

    // 快照完整请求和借用的注册 handle；预约只在容量/参数检查通过后建立。
    function new(longint unsigned id, int index, string request,
                 aip_cmd command_handle, int unsigned limit_ns);
        ticket = id;
        slot = index;
        command = request;
        handle = command_handle;
        timeout_ns = limit_ns;
        submitted_at = $realtime;
        started_at = 0;
        finished_at = 0;
        state = AIP_INJECT_QUEUED;
        status = 0;
        result_text = "";
        admission = handle.reserve_injection(ticket);
    endfunction

    // 只有下列状态允许释放槽；运行中超时必须保留资源直到真实命令退出。
    function bit terminal();
        return state == AIP_INJECT_DONE || state == AIP_INJECT_CANCELLED ||
               state == AIP_INJECT_TIMED_OUT;
    endfunction
endclass

// 与核心注册表一致，类对象数组放在 package 层以兼容旧 VCS。
aip_inject_job __aip_inject_jobs [0:31];

// 独立接收器与 dispatcher 是普通同步 bridge worker 的兄弟进程；原命令
// 阻塞时仍能接收请求。每个 job 的子执行边界隔离用户 disable/wait fork。
class aip_inject_bridge;
    local static bit started = 0;
    local static longint unsigned last_ticket = 0;
    local static mailbox #(aip_inject_job) ingress = new(32);

    // 正常释放由事件通知；外部 kill 无正常尾声，仅在有排队工作时低频
    // 查询 owner 状态。该兜底不用于业务进展/超时，避免全局活动掩盖死锁。
    static real reap_interval_ns = 1000.0;

    // 镜像同一对象的当前状态；已 release/reuse 的槽拒绝迟到线程写入。
    // 结果长度超限显式转成失败，避免将截断业务文本宣称为完整成功。
    static function void publish(aip_inject_job job);
        int count;
        string text;
        int status;
        if (__aip_inject_jobs[job.slot] != job) return;
        text = job.result_text;
        status = job.status;
        if (text.len() > 1024) begin
            text = {"ERROR: injection result exceeds 1024 bytes; ", text.substr(0, 978)};
            status = 1;
        end
        count = text.len() > 1024 ? 1024 : text.len();
        __inject_slot_ticket[job.slot] = job.ticket;
        __inject_slot_status[job.slot] = status;
        __inject_slot_result_len[job.slot] = count;
        for (int i = 0; i < count; i++)
            __inject_result_ascii[job.slot*1024+i] = text.getc(i);
        __inject_slot_state[job.slot] = int'(job.state);
    endfunction

    // 查找活槽中的精确 ticket；槽编号不能单独作为身份，release 后旧值失败。
    static function aip_inject_job find(longint unsigned ticket);
        if (ticket == 0) return null;
        foreach (__aip_inject_jobs[i])
            if (__aip_inject_jobs[i] != null && __aip_inject_jobs[i].ticket == ticket)
                return __aip_inject_jobs[i];
        return null;
    endfunction

    // 仅接受普通已注册 SV 命令；控制生命周期/注册表/全局参数的操作不应
    // 在原命令暂停处暗中改变环境。fork/CPU 另有异步协议，不转换为本队列。
    // wait 由外层调试 API 消费，raw submit 中出现任何顶层 wait 均明确失败。
    static function bit validate(string command, output aip_cmd handle,
                                 output string error_text);
        string name, args, user_args, wait_error;
        bit wait_for_done, explicit_wait;
        handle = null;
        error_text = "";
        if (command.len() == 0 || command.len() > 1024) begin
            error_text = "command length must be 1..1024 bytes";
            return 0;
        end
        aip_cmd::parse_cmd_str(command, name, args);
        if (name == "fork" || name == "end_test" || name == "so_load" ||
            name == "so_reload" || name == "so_unload" || name == "set_param" ||
            name == "clear_param" || name == "kill_seq" || name == "set_cmd_watchdog" ||
            name == "sv::cpu_bridge_reinit" || name == "load_image" ||
            name == "cpu_wait" ||
            (__aip_cmd_is_cpu.exists(name) && __aip_cmd_is_cpu[name])) begin
            error_text = {"command is not allowed in injection queue: ", name};
            return 0;
        end
        handle = aip_cmd::get_handle(name);
        if (handle == null) begin
            error_text = {"unknown injection command: ", name};
            return 0;
        end
        if (!aip_cmd::extract_wait(args, user_args, wait_for_done, explicit_wait, wait_error) ||
            explicit_wait) begin
            error_text = "submit command must not contain a top-level wait modifier";
            return 0;
        end
        return 1;
    endfunction

    // 普通命令暂停转接仍由核心解析 wait，避免 Tcl 重组逗号/brace/quote
    // 参数改变业务原文。op4 仅剥离现有框架控制字段，实际 job 始终同步执行；
    // wait=0 能力检查与普通 exec_result 一致，返回 wait 标志供 Tcl 决定等待。
    static function bit normalize_ordinary(string command, output string normalized,
                                           output bit wait_for_done, output string text);
        string name, args, user_args;
        bit explicit_wait;
        aip_cmd handle;
        aip_cmd::parse_cmd_str(command, name, args);
        if (!aip_cmd::extract_wait(args, user_args, wait_for_done, explicit_wait, text))
            return 0;
        handle = aip_cmd::get_handle(name);
        if (handle != null && !wait_for_done && !handle.background_allowed) begin
            text = {"wait=0 is not supported for this command: ", name};
            return 0;
        end
        normalized = user_args == "" ? name : {name, " ", user_args};
        return 1;
    endfunction

    // 原子提交：先校验再分配槽/预约，不运行用户业务。容量包括未 release
    // 的终态结果；耗尽时返回 ACK2，绝不覆盖最老结果。64 位 ticket 到顶后
    // 停止接受，不能回绕而令历史身份重新有效。
    static function aip_inject_job submit(string command, int unsigned timeout_ns,
                                          output int ack_status, output string text);
        aip_cmd handle;
        aip_cmd end_handle;
        aip_inject_job job;
        int slot = -1;
        ack_status = 1;
        if (!validate(command, handle, text)) return null;
        end_handle = aip_cmd::get_handle("end_test");
        if (end_handle != null && end_handle.is_busy()) begin
            text = "cannot submit injection while end_test is running";
            return null;
        end
        foreach (__aip_inject_jobs[i])
            if (__aip_inject_jobs[i] == null && slot < 0) slot = i;
        if (slot < 0 || last_ticket == 64'hffffffffffffffff) begin
            ack_status = 2;
            text = "injection capacity exhausted; release terminal tickets";
            return null;
        end
        last_ticket++;
        job = new(last_ticket, slot, command, handle, timeout_ns);
        __aip_inject_jobs[slot] = job;
        if (!ingress.try_put(job)) begin
            handle.retire_injection(job.admission);
            __aip_inject_jobs[slot] = null;
            ack_status = 2;
            text = "injection ingress is full; advance simulation before retry";
            return null;
        end
        __aip_injection_live_tickets++;
        publish(job);
        ack_status = 0;
        text = "QUEUED";
        return job;
    endfunction

    // 显式取消只接受 QUEUED；预约立即撤销，原命令和正在执行的任务均不 kill。
    // 终态重复取消也失败，使调用方不会把历史 ticket 当成新请求控制。
    static function int cancel(aip_inject_job job, output string text);
        if (job == null || __aip_inject_jobs[job.slot] != job) begin
            text = "unknown or released injection ticket";
            return 3;
        end
        if (job.state != AIP_INJECT_QUEUED) begin
            text = "only queued injection jobs can be cancelled";
            return 4;
        end
        job.state = AIP_INJECT_CANCELLED;
        job.status = 1;
        job.result_text = "CANCELLED: queued injection request";
        job.finished_at = $realtime;
        job.handle.retire_injection(job.admission);
        publish(job);
        text = "CANCELLED";
        return 0;
    endfunction

    // 回收终态槽；执行中或运行超时状态明确拒绝。对象由仍持引用的服务
    // 尾声自然回收，镜像清零后旧 ticket 无法读取/释放复用槽中的新请求。
    static function int release_job(aip_inject_job job, output string text);
        if (job == null || __aip_inject_jobs[job.slot] != job) begin
            text = "unknown or released injection ticket";
            return 3;
        end
        if (!job.terminal()) begin
            text = "injection job is not terminal";
            return 5;
        end
        __aip_inject_jobs[job.slot] = null;
        __aip_injection_live_tickets--;
        __inject_slot_ticket[job.slot] = 0;
        __inject_slot_result_len[job.slot] = 0;
        __inject_slot_status[job.slot] = 0;
        __inject_slot_state[job.slot] = AIP_INJECT_FREE;
        text = "RELEASED";
        return 0;
    endfunction

    // 队首/资源释放由事件驱动；在检查与 exec_result 预占之间无阻塞点。
    // 入队时借用的 handle 若被外部卸载/替换则终止本请求，不能执行新对象。
    static task execute_job(aip_inject_job job);
        int status;
        string result_text;
        while (job.state == AIP_INJECT_QUEUED &&
               !job.handle.injection_ready(job.admission))
            @(__aip_cmd_admission_changed);
        if (job.state != AIP_INJECT_QUEUED) return;
        if (aip_cmd::get_handle(job.handle.cmd_name) != job.handle) begin
            job.handle.retire_injection(job.admission);
            job.status = 1;
            job.result_text = "ERROR: registered command changed after injection submission";
        end else begin
            job.state = AIP_INJECT_RUNNING;
            job.started_at = $realtime;
            publish(job);
            aip_cmd::exec_result(job.command, SRC_TCL, status, result_text, job.admission);
            job.status = status;
            job.result_text = result_text;
        end
        if (job.state == AIP_INJECT_RUNNING_TIMEOUT) begin
            job.status = 1;
            job.result_text = $sformatf("TIMEOUT: absolute injection deadline exceeded; completed status=%0d result=%s",
                                       status, result_text);
            job.state = AIP_INJECT_TIMED_OUT;
        end else job.state = AIP_INJECT_DONE;
        job.finished_at = $realtime;
        job.handle.retire_injection(job.admission);
        publish(job);
    endtask

    // 每 job 独立绝对期限，包含排队时间；全局 activity 从不重置该期限。
    // QUEUED 超时即撤销预约；RUNNING 超时保留工作进程并报告非终态6，
    // 直到真实 exec_result 完成后发布终态5。只 kill 本服务自己的计时线程。
    static task supervise(aip_inject_job job);
        bit completed = 0;
        process timer_process;
        real remaining_ns;
        remaining_ns = job.timeout_ns - (($realtime - job.submitted_at) / 1ns);
        fork
            begin
                execute_job(job);
                completed = 1;
            end
            begin
                timer_process = process::self();
                if (job.timeout_ns == 0) wait (completed);
                else if (remaining_ns > 0) #(remaining_ns * 1ns);
            end
        join_any
        if (completed) begin
            if (timer_process != null && timer_process.status() != process::FINISHED)
                timer_process.kill();
            return;
        end
        if (job.state == AIP_INJECT_QUEUED) begin
            job.state = AIP_INJECT_TIMED_OUT;
            job.status = 1;
            job.result_text = "TIMEOUT: absolute injection deadline expired while queued";
            job.finished_at = $realtime;
            job.handle.retire_injection(job.admission);
            publish(job);
        end else if (job.state == AIP_INJECT_RUNNING) begin
            job.state = AIP_INJECT_RUNNING_TIMEOUT;
            job.status = 1;
            job.result_text = "TIMEOUT: command remains running; release waits for completion";
            publish(job);
        end
        wait (completed);
    endtask

    // 独立 dispatcher 只派生服务 worker，不在接收器内等待任何用户命令。
    static task dispatch_loop();
        forever begin
            aip_inject_job job;
            ingress.get(job);
            fork
                automatic aip_inject_job current_job = job;
                supervise(current_job);
            join_none
        end
    endtask

    // 低频异常 owner 回收；正常完成直接触发事件，因此没有固定1ns延迟。
    // 间隔可由 TB 配置，非法/零值回落1000ns，避免零时间忙循环。
    static task reap_loop();
        forever begin
            #(reap_interval_ns > 0 ? reap_interval_ns * 1ns : 1000ns);
            foreach (__aip_inject_jobs[i])
                if (__aip_inject_jobs[i] != null &&
                    __aip_inject_jobs[i].state == AIP_INJECT_QUEUED)
                    void'(__aip_inject_jobs[i].handle.injection_ready(
                          __aip_inject_jobs[i].admission));
        end
    endtask

    // 电平+请求ID握手避免暂停期间丢失posedge，也防止 force 保持1时重复
    // 消费。接收器只操作注入寄存器；错误也必须 ACK，不能令 Tcl 永久等待。
    static task receive_loop();
        forever begin
            int status;
            int unsigned request_id;
            string text, command;
            string normalized;
            bit wait_for_done;
            aip_inject_job job;
            wait (__inject_request_trigger == 1 &&
                  __inject_request_id != __inject_ack_id);
            request_id = __inject_request_id;
            status = 0;
            text = "";
            job = null;
            wait_for_done = 1;
            if (__inject_request_op == 1 || __inject_request_op == 4) begin
                if (__inject_request_len == 0 || __inject_request_len > 1024) begin
                    status = 1;
                    text = "command length must be 1..1024 bytes";
                end else begin
                    command = "";
                    for (int i = 0; i < __inject_request_len; i++)
                        command = {command, byte'(__inject_request_ascii[i])};
                    if (__inject_request_op == 4 &&
                        !normalize_ordinary(command, normalized, wait_for_done, text))
                        status = 1;
                    else begin
                        if (__inject_request_op == 4) command = normalized;
                        // 普通 wait=0 沿用原后台契约：启动后不附加命令期限；
                        // Tcl 等待启动的窗口独立有界。显式 submit 保留用户期限。
                        job = submit(command,
                            (__inject_request_op == 4 && !wait_for_done) ? 0 :
                            __inject_request_timeout_ns, status, text);
                    end
                end
            end else if (__inject_request_op == 2 || __inject_request_op == 3) begin
                job = find(__inject_request_ticket);
                if (job == null) begin
                    status = 3;
                    text = "unknown or released injection ticket";
                end else if (__inject_request_op == 2) status = cancel(job, text);
                else status = release_job(job, text);
            end else begin
                status = 1;
                text = "unknown injection operation";
            end
            __inject_ack_status = status;
            __inject_ack_wait = wait_for_done;
            __inject_ack_ticket = (job == null || status != 0) ? 0 : job.ticket;
            __inject_ack_slot = (job == null || status != 0) ? 32'hffffffff : job.slot;
            __inject_ack_text_len = text.len() > 1024 ? 1024 : text.len();
            for (int i = 0; i < __inject_ack_text_len; i++)
                __inject_ack_text_ascii[i] = text.getc(i);
            __inject_ack_id = request_id;
        end
    endtask

    // 幂等启动；调用发生在普通 bridge 初始 $stop 之前。服务线程不依赖
    // run_loop 当前 exec 的 fork 子树，正常命令 watchdog 不会误杀此入口。
    static task start();
        if (started) return;
        started = 1;
        fork
            receive_loop();
            dispatch_loop();
            reap_loop();
        join_none
    endtask
endclass

`endif // AIP_INJECT_BRIDGE_SV
