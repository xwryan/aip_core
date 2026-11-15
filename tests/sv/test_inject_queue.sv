// tests/sv：独立注入队列生产门禁，复用真实 cw_test 的 driver/sequencer。
// 依赖同目录 test_cmd_wait.sv 和统一 package；本测试拥有请求引用与断言，
// 生产服务拥有队列和线程。仅测试 top 启动服务，不运行普通 Tcl $stop 循环。
// 测试覆盖原同步 sequence 保持、FIFO/legacy串行、准入公平、容量、回收、
// 取消、绝对期限和真实传输 ACK；总期限避免错误导致无人观察的无限仿真。
`timescale 1ns/1ps
`include "tests/sv/test_cmd_wait.sv"

// 两个注册别名共享旧全局结果资源，结果必须各自保存在独立 ticket。
class iq_legacy_ops;
    // 先写再等待，暴露其他命令错误发布全局镜像的竞争窗口。
    static task first(string text);
        aip_cmd::__aip_cmd_last_status = 31;
        aip_cmd::__aip_cmd_last_result = {"OLD_A:", text};
        #10ns;
    endtask

    // 使用不同结果/延迟，使跨别名 FIFO 和结果串扰都能被断言发现。
    static task second(string text);
        aip_cmd::__aip_cmd_last_status = 32;
        aip_cmd::__aip_cmd_last_result = {"OLD_B:", text};
        #20ns;
    endtask
endclass
`aip_cmd_str_1i(iq_old_a, iq_legacy_ops::first, text, "")
`aip_cmd_str_1i(iq_old_b, iq_legacy_ops::second, text, "")

// 沿用原 UVM driver，所有断言均通过公开状态/输出观察，不读取核心私锁。
class iq_test extends cw_test;
    `uvm_component_utils(iq_test)
    int checks = 0;

    // 标准 UVM 构造；资源实际创建仍由父 build/connect phase 完成。
    function new(string name = "iq_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 任一失败终止仿真，外部还需检查总 PASS 和 UVM report 错误数量。
    function void verify(string label, bit condition);
        checks++;
        if (!condition) `uvm_fatal("INJECT_CHECK", label)
        $display("INJECT_CHECK_PASS %s", label);
    endfunction

    // 直接提交用于机制测试；接收ACK0之外还检查对象确已交给服务持有。
    function aip_inject_job enqueue(string command, int unsigned timeout_ns = 0);
        aip_inject_job job;
        int status;
        string text;
        job = aip_inject_bridge::submit(command, timeout_ns, status, text);
        verify({"accepted ", command}, status == 0 && job != null);
        return job;
    endfunction

    // 模拟UCLI的完整payload/ID/trigger次序；不推进固定时间，等真实独立ACK。
    task transport(int op, string command, longint unsigned ticket = 0);
        int unsigned id;
        id = __inject_request_id + 1;
        __inject_request_op = op;
        __inject_request_len = command.len();
        __inject_request_ticket = ticket;
        for (int i = 0; i < command.len(); i++)
            __inject_request_ascii[i] = command.getc(i);
        __inject_request_id = id;
        __inject_request_trigger = 1;
        wait (__inject_ack_id == id);
        __inject_request_trigger = 0;
    endtask

    // 保持同步原命令并逐层验证资源与结果；容量循环有真实排队阻塞者，
    // 不将完成/STARTED/BUSY假冒为任务执行。运行超时从不强杀driver。
    task run_phase(uvm_phase phase);
        aip_inject_job front, first, second, old_a, old_b, local_job;
        aip_inject_job expired, timed, cancelled, capacity[32], rejected, reused;
        int original_status, legacy_status, status;
        string original_result, legacy_result, text;
        string original_args;
        bit original_done = 0;
        bit legacy_done = 0;
        longint unsigned old_ticket;
        process killed_owner;
        realtime killed_at;
        phase.raise_objection(this);
        aip_inject_bridge::start();
        fork
            begin
                aip_cmd::exec_result("cw_seq ns=400 tag=ORIGINAL", SRC_TCL,
                                     original_status, original_result);
                original_done = 1;
            end
        join_none
        #50ns;
        original_args = aip_cmd::get_handle("cw_seq").args_in;
        front = enqueue("cw_front ns=30 tag=INSERTED code=17");
        first = enqueue("cw_seq ns=40 tag=FIRST code=23");
        second = enqueue("cw_seq ns=10 tag=SECOND code=29");
        aip_cmd::exec_result("end_test", SRC_SOCKET, status, text);
        verify("socket cannot exit with retained injection tickets", status == 1 && !aip_tcl_bridge::__tcl_exit);
        aip_cmd::exec_result("set_param name=TEST value=1", SRC_INTERNAL, status, text);
        verify("direct lifecycle mutation cannot bypass injection guard", status == 1 && text.substr(0, 3) == "BUSY");
        #1ns;
        verify("same handle remains queued", first.state == AIP_INJECT_QUEUED &&
                                            second.state == AIP_INJECT_QUEUED);
        verify("foreign handle runs concurrently", front.state == AIP_INJECT_RUNNING && !original_done);
        verify("queued calls preserve original args", aip_cmd::get_handle("cw_seq").args_in == original_args);
        wait (front.state == AIP_INJECT_DONE);
        verify("foreign result independent", front.status == 17 && front.result_text == "DONE:cw_front:INSERTED" && !original_done);
        wait (original_done);
        aip_cmd::exec_result("cw_seq ns=1 tag=OVERTAKE", SRC_TCL, status, text);
        verify("direct call cannot overtake queued jobs", status == 1 && text.substr(0, 3) == "BUSY");
        verify("original sync result intact", original_status == 0 && original_result == "DONE:cw_seq:ORIGINAL");
        wait (first.state == AIP_INJECT_DONE);
        wait (second.state == AIP_INJECT_DONE);
        verify("event completion no extra nanosecond", first.started_at == 700ns && second.started_at == first.finished_at);
        verify("real driver completed all three sequences", cw_record::driver_count == 3 && aip_cmd_seq_registry::count() == 0);
        verify("tickets retain independent status/results", first.status == 23 && second.status == 29 &&
            first.result_text == "DONE:cw_seq:FIRST" && second.result_text == "DONE:cw_seq:SECOND");
        verify("original args preserved on body exit", cw_record::args_enter["cw_seq"] == cw_record::args_leave["cw_seq"]);
        void'(aip_inject_bridge::release_job(front, text));
        void'(aip_inject_bridge::release_job(first, text));
        void'(aip_inject_bridge::release_job(second, text));

        // 不让出调度片：此时handle确实空闲，只有预约能阻止直接入口插队。
        local_job = enqueue("cw_front ns=1 tag=RESERVED");
        aip_cmd::exec_result("cw_front ns=1 tag=OVERTAKE", SRC_SOCKET, status, text);
        verify("reservation blocks direct admission before worker starts", status == 1 &&
            text == "BUSY: command 'cw_front' has pending queued requests" &&
            local_job.state == AIP_INJECT_QUEUED);
        wait (local_job.state == AIP_INJECT_DONE);
        void'(aip_inject_bridge::release_job(local_job, text));

        fork
            begin
                aip_cmd::exec_result("cw_legacy_late text=ORIGINAL", SRC_TCL, legacy_status, legacy_result);
                legacy_done = 1;
            end
        join_none
        #1ns;
        old_a = enqueue("iq_old_a text=FIRST");
        old_b = enqueue("iq_old_b text=SECOND");
        local_job = enqueue("cw_front ns=3 tag=LOCAL");
        wait (local_job.state == AIP_INJECT_DONE);
        verify("local result independent of blocked legacy FIFO", !legacy_done && old_a.state == AIP_INJECT_QUEUED && old_b.state == AIP_INJECT_QUEUED);
        wait (old_b.state == AIP_INJECT_DONE);
        verify("original legacy result survives locals", legacy_status == 23 && legacy_result == "LEGACY_SAVED:ORIGINAL");
        verify("legacy aliases share FIFO", old_b.started_at == old_a.finished_at && old_a.status == 31 && old_b.status == 32);
        verify("legacy ticket results immutable", old_a.result_text == "OLD_A:FIRST" && old_b.result_text == "OLD_B:SECOND");
        void'(aip_inject_bridge::release_job(old_a, text));
        void'(aip_inject_bridge::release_job(old_b, text));
        void'(aip_inject_bridge::release_job(local_job, text));

        aip_cmd::exec_result("cw_task ns=200 tag=BLOCK wait=0", SRC_TCL, status, text);
        expired = enqueue("cw_task ns=1 tag=EXPIRED", 25);
        cancelled = enqueue("cw_task ns=1 tag=CANCELLED");
        verify("queued cancel accepted", aip_inject_bridge::cancel(cancelled, text) == 0);
        wait (expired.state == AIP_INJECT_TIMED_OUT);
        verify("queued deadline does not kill original", aip_cmd::get_handle("cw_task").is_busy() && expired.started_at == 0);
        verify("cancelled job never starts", cancelled.state == AIP_INJECT_CANCELLED && cancelled.started_at == 0);
        void'(aip_inject_bridge::release_job(expired, text));
        void'(aip_inject_bridge::release_job(cancelled, text));
        timed = enqueue("cw_front ns=100 tag=RUNNING_TIMEOUT", 20);
        wait (timed.state == AIP_INJECT_RUNNING_TIMEOUT);
        verify("running timeout retains busy execution", aip_cmd::get_handle("cw_front").is_busy());
        verify("running cancel denied", aip_inject_bridge::cancel(timed, text) == 4);
        verify("running release denied", aip_inject_bridge::release_job(timed, text) == 5);
        wait (timed.state == AIP_INJECT_TIMED_OUT);
        verify("running timeout finishes naturally", cw_record::args_leave["cw_front"] == "ns=100 tag=RUNNING_TIMEOUT" && timed.status == 1);
        void'(aip_inject_bridge::release_job(timed, text));

        foreach (capacity[i]) capacity[i] = enqueue("cw_task ns=1 tag=CAPACITY");
        rejected = aip_inject_bridge::submit("cw_front ns=1", 0, status, text);
        verify("bounded capacity rejects without overwrite", rejected == null && status == 2 && aip_inject_bridge::find(capacity[0].ticket) == capacity[0]);
        #1ns;
        foreach (capacity[i]) begin
            void'(aip_inject_bridge::cancel(capacity[i], text));
            void'(aip_inject_bridge::release_job(capacity[i], text));
        end
        old_ticket = capacity[0].ticket;
        reused = enqueue("cw_front ns=1 tag=REUSED");
        verify("slot reuse has a new ticket", reused.slot == capacity[0].slot && reused.ticket > old_ticket && aip_inject_bridge::find(old_ticket) == null);
        verify("stale SV object cannot release reused slot", aip_inject_bridge::release_job(capacity[0], text) == 3);
        wait (reused.state == AIP_INJECT_DONE);
        verify("cancelled tails cannot overwrite reused slot", __inject_slot_ticket[reused.slot] == reused.ticket && __inject_slot_state[reused.slot] == AIP_INJECT_DONE);
        void'(aip_inject_bridge::release_job(reused, text));

        transport(1, "cw_front ns=1 wait=1");
        verify("raw submit rejects wait modifier", __inject_ack_status == 1 && __inject_ack_ticket == 0);
        transport(4, "cw_front ns=1,wait=0,tag={WITH SPACES}");
        verify("ordinary submit exposes parsed wait", __inject_ack_status == 0 && __inject_ack_wait == 0);
        reused = aip_inject_bridge::find(__inject_ack_ticket);
        wait (reused.state == AIP_INJECT_DONE);
        verify("ordinary submit preserves raw business tokens", cw_record::args_leave["cw_front"] == "ns=1,tag={WITH SPACES}");
        transport(3, "", reused.ticket);
        verify("terminal release ACK", __inject_ack_status == 0);
        transport(3, "", reused.ticket);
        verify("stale ticket rejected by receiver", __inject_ack_status == 3);
        transport(1, "end_test");
        verify("lifecycle command denied", __inject_ack_status == 1);
        transport(1, "fork cw_front ns=1 join");
        verify("fork command denied", __inject_ack_status == 1);

        #100ns;
        fork
            begin
                int killed_status;
                string killed_result;
                killed_owner = process::self();
                aip_cmd::exec_result("cw_task ns=5000 tag=KILLED", SRC_TCL, killed_status, killed_result);
            end
        join_none
        #1ns;
        reused = enqueue("cw_task ns=1 tag=AFTER_KILL");
        // worker先进入事件等待，再kill原owner；否则首次准入查询即可回收，
        // 无法证明没有正常完成事件时的低频reaper兜底真正有效。
        #1ns;
        killed_at = $realtime;
        killed_owner.kill();
        wait (reused.state == AIP_INJECT_DONE);
        verify("external killed owner reaped", reused.status == 0 && reused.result_text == "DONE:cw_task:AFTER_KILL");
        verify("reaper unblocks already waiting worker", reused.started_at > killed_at &&
            reused.started_at <= killed_at + 1000ns);
        void'(aip_inject_bridge::release_job(reused, text));
        verify("all retained tickets released", __aip_injection_live_tickets == 0);
        $display("INJECT_QUEUE_PASS checks=%0d driver_count=%0d", checks, cw_record::driver_count);
        phase.drop_objection(this);
    endtask
endclass

// 只选择此top，包含的旧test_cmd_wait模块不作为根实例，避免重复run_test。
module test_inject_queue;
    initial run_test("iq_test");
    initial begin
        #50000ns;
        $fatal(1, "INJECT_QUEUE_DEADLINE");
    end
endmodule
