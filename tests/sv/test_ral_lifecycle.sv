// 真实命令调度/bridge 生命周期测试：只用假 action，不连接 RAL transport。
// 产品 service 是永久单例，dirty 场景必须用独立仿真进程。
`include "aip_core_pkg.sv"
package ral_lifecycle_test_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;

    // 集中断言：任一失败都阻止最后的 COMPLETE，不把日志里的孤立 OK 算通过。
    class life_check;
        static int checks;
        static string scenario;
        static aip_cmd_execution last_execution;
        static aip_cmd_execution old_execution;
        static aip_cmd_result_context last_context;
        static aip_ral_owner_token old_token;
        static int actions, gate_parses, background_steps, hook_calls;
        static bit holding;

        static function void demand(bit condition, string label0);
            if (!condition) `uvm_fatal("RAL_LIFECYCLE_ASSERT", label0)
            checks++;
        endfunction

        // 构造六叶inventory，active/outside/EXCLUDED各有独立结果，方便校准中断升级。
        static function aip_ral_run_state inventory();
            aip_ral_run_state state0 = new();
            aip_ral_leaf_id_t id0;
            string why;
            for (int i = 0; i < 6; i++)
                demand(state0.add_leaf($sformatf("soc.f%0d", i), 0, id0, why), "inventory_leaf");
            demand(state0.commit_inventory(why), "inventory_commit");
            demand(state0.finish_leaf(1, AIP_RAL_LEAF_FAIL, AIP_RAL_CODE_POLICY_MISMATCH, why), "active_FAIL");
            demand(state0.finish_leaf(2, AIP_RAL_LEAF_EXCLUDED, AIP_RAL_CODE_NONE, why), "active_EXCLUDED");
            demand(state0.finish_leaf(3, AIP_RAL_LEAF_PASS, AIP_RAL_CODE_NONE, why), "outside_PASS");
            demand(state0.finish_leaf(4, AIP_RAL_LEAF_FAIL, AIP_RAL_CODE_POLICY_MISMATCH, why), "outside_FAIL");
            state0.requested_target = "soc";
            state0.effective_target = "soc";
            state0.am = "ral";
            return state0;
        endfunction
    endclass

    // 通用listener用于证明core不依赖RAL；与service订阅不同execution。
    class life_listener extends aip_cmd_liveness_listener;
        static int normal_count, cancel_count, watchdog_count;

        // 只统计终态，不访问DUT，不给普通命令发布替代结果。
        virtual function void on_terminal(aip_cmd_execution execution, aip_cmd_end_e reason);
            case (reason)
                AIP_CMD_COMPLETED: normal_count++;
                AIP_CMD_CANCELLED: cancel_count++;
                AIP_CMD_WATCHDOG: watchdog_count++;
            endcase
        endfunction
    endclass

    // 无总线的后台sequence；真实UVM进程登记供watchdog隔离测试，但不tick喂狗。
    class life_sequence extends uvm_sequence;
        function new(string name = "life_sequence"); super.new(name); endfunction

        // 持续推进独立后台状态，watchdog不应因别的命令超时而杀掉它。
        virtual task body();
            forever begin #10ns; life_check::background_steps++; end
        endtask
    endclass

    // 用户hook保持独立，统计调用并证明内部listener没有覆盖它。
    class life_hook extends aip_cmd_watchdog_hook;
        // 仅统计，不尝试修复协议；产品永久latch不能因hook返回而清掉。
        virtual function void on_timeout(string command_text); life_check::hook_calls++; endfunction
    endclass

    // 测试命令统一入口；不同注册对象避免框架同名BUSY掩盖service竞争。
    class life_command extends aip_cmd_user_task;
        function new(string name); super.new(name); endfunction

        // 经真实core进入，覆盖worker身份、快照复制、旧token、取消和watchdog。
        virtual task cmd_exec();
            aip_ral_service service0 = aip_ral_service::get();
            aip_ral_owner_token token0, forged;
            aip_ral_run_state state0, observed;
            aip_ral_leaf_id_t selected[$];
            aip_ral_code_e code0;
            aip_ral_phase_e published_phase;
            aip_cmd_execution execution0 = aip_cmd::get_current_execution();
            life_listener listener0;
            string text0, why;
            int result_status;

            if (cmd_name == "life_mode") begin result_out = life_check::scenario; return; end
            if (cmd_name == "life_reasons") begin
                observed = service0.snapshot();
                life_check::demand(observed != null && observed.leaf_reason(0) == "" &&
                                   observed.leaf_reason(99) == "", "invalid_leaf_reason_empty");
                result_out = {"active=", observed.leaf_reason(1), " pending=", observed.leaf_reason(5),
                              " outside=", observed.leaf_reason(4), " excluded=", observed.leaf_reason(2)};
                return;
            end
            if (cmd_name == "life_stats") begin
                #10ns;
                result_out = $sformatf("hooks=%0d background=%0d actions=%0d parses=%0d watchdog=%0d",
                    life_check::hook_calls, life_check::background_steps, life_check::actions,
                    life_check::gate_parses, life_listener::watchdog_count);
                return;
            end
            if (cmd_name == "life_background") begin
                life_sequence sequence0 = new();
                aip_cmd_seq_registry::register(cmd_name, sequence0);
                sequence0.start(null);
                aip_cmd_seq_registry::unregister(cmd_name);
                return;
            end
            if (cmd_name == "life_normal" || cmd_name == "life_plain_hang") begin
                listener0 = new();
                life_check::demand(execution0 != null && execution0.subscribe(listener0), "generic_subscribe");
                life_check::last_execution = execution0;
                life_check::last_context = aip_cmd::get_current_context();
                if (cmd_name == "life_plain_hang") forever #10ns;
                if (args_in == "cancel") life_check::demand(execution0.request_cancel(), "generic_cancel_request");
                result_out = "PLAIN_OK";
                return;
            end
            if (cmd_name == "life_wrapper") begin
                // 不传scope，必须自动继承外层bridge/fork的祖先scope。
                aip_cmd::exec_result("life_hang", SRC_INTERNAL, result_status, text0);
                status = result_status;
                result_out = text0;
                return;
            end
            if (cmd_name == "life_fast") begin #1ns; result_out = "FAST"; return; end
            if (cmd_name == "life_gate_op" || cmd_name == "life_gate_test") begin
                // recovery必须先于业务参数检查；故意给bad参数验证固定gate优先级。
                if (service0.recovery_gate(cmd_name == "life_gate_test", text0)) begin
                    status = 1; result_out = text0; return;
                end
                life_check::gate_parses++;
                status = 1; result_out = "ERROR code=BAD_ARGS"; return;
            end

            code0 = service0.acquire(1, token0, text0);
            if (cmd_name == "life_try") begin
                result_out = aip_ral_names::code(code0);
                if (code0 == AIP_RAL_CODE_NONE) begin
                    life_check::demand(service0.release_owner(token0), "try_release");
                end
                return;
            end
            life_check::demand(code0 == AIP_RAL_CODE_NONE && token0 != null, "service_acquire");
            life_check::last_execution = execution0;
            life_check::last_context = aip_cmd::get_current_context();
            if (cmd_name == "life_hold") begin
                life_check::holding = 1;
                forever #10ns;
            end

            if (cmd_name == "life_service") begin
                aip_ral_owner_token competing;
                if (args_in == "sequence_clean") begin
                    life_sequence sequence0 = new();
                    aip_cmd_seq_registry::register(cmd_name, sequence0);
                    aip_cmd_seq_registry::unregister(cmd_name);
                end
                life_check::demand(service0.acquire(1, competing, text0) == AIP_RAL_CODE_BUSY && competing == null,
                                   "nonblocking_reentrant_BUSY");
                forged = new(token0.get_generation());
                life_check::demand(!service0.release_owner(forged), "forged_token_rejected");
                if (life_check::old_token != null) begin
                    life_check::demand(token0.get_generation() > life_check::old_token.get_generation(), "monotonic_generation");
                    life_check::demand(!service0.release_owner(life_check::old_token), "old_token_cannot_release_new_owner");
                    service0.on_terminal(life_check::old_execution, life_check::old_execution.get_end_reason());
                    observed = service0.snapshot();
                    life_check::demand(observed.code == AIP_RAL_CODE_NONE && !observed.recovery_required,
                                       "late_generation_cannot_mutate_new_run");
                end
                service0.on_terminal(execution0, AIP_CMD_WATCHDOG);
                observed = service0.snapshot();
                life_check::demand(observed.code == AIP_RAL_CODE_NONE, "premature_callback_rejected");
                state0 = life_check::inventory();
                state0.phase = AIP_RAL_PHASE_INVENTORY;
                life_check::demand(service0.publish_state(token0, state0, selected, AIP_RAL_PHASE_INVENTORY), "atomic_publish");
                life_check::demand(state0.finish_leaf(5, AIP_RAL_LEAF_PASS, AIP_RAL_CODE_NONE, why), "caller_mutates_old_leaf");
                state0.total = 999;
                observed = service0.snapshot();
                life_check::demand(observed.total == 6 && observed.passed == 1, "deep_snapshot_not_caller_alias");
                observed.settle_pending();
                observed.detail = "MUTATED_COPY";
                observed = service0.snapshot();
                life_check::demand(observed.untestable == 0 && observed.detail == "", "returned_snapshot_not_internal_alias");
                selected.push_back(1); selected.push_back(1);
                life_check::demand(!service0.publish_state(token0, state0, selected, AIP_RAL_PHASE_ACTION), "invalid_publish_atomic_reject");
                selected.delete();
                observed.settle_pending();
                life_check::demand(service0.publish_state(token0, observed, selected, AIP_RAL_PHASE_INVENTORY), "settled_publish");
                life_check::old_token = token0;
                life_check::old_execution = execution0;
                if (args_in == "cancel") begin
                    life_check::demand(service0.cancel(token0, 1), "clean_cancel_request");
                    aip_cmd::set_result(0, "OLD_OK_MUST_NOT_ESCAPE");
                end else result_out = "SERVICE_OK";
                // 故意不release；正常终态通知+FINISHED共同允许下一代回收。
                return;
            end

            if (life_check::scenario == "parse" || life_check::scenario == "sequence") state0 = new();
            else state0 = life_check::inventory();
            case (life_check::scenario)
                "parse", "sequence": state0.phase = AIP_RAL_PHASE_PARSE;
                "inventory": state0.phase = AIP_RAL_PHASE_INVENTORY;
                "quiesce": state0.phase = AIP_RAL_PHASE_QUIESCE;
                "reset": begin state0.phase = AIP_RAL_PHASE_RESET; state0.reset_started(); end
                "resume": state0.phase = AIP_RAL_PHASE_RESUME;
                default: state0.phase = AIP_RAL_PHASE_ACTION;
            endcase
            if (state0.inventory_complete) begin selected.push_back(1); selected.push_back(2); selected.push_back(6); end
            if (!(life_check::scenario inside {"parse", "inventory", "sequence"})) begin
                state0.side_effects = AIP_RAL_ONE;
                state0.resumed = 0;
                life_check::actions++;
            end
            if (life_check::scenario == "sequence") begin
                life_sequence sequence0 = new();
                aip_cmd_seq_registry::register(cmd_name, sequence0);
                aip_cmd_seq_registry::unregister(cmd_name);
            end
            if (life_check::scenario == "cancelleak") state0.resumed = 1;
            published_phase = state0.phase;
            if (life_check::scenario == "priorerror")
                life_check::demand(state0.record_error(AIP_RAL_CODE_HOOK_ERROR, AIP_RAL_PHASE_QUIESCE), "earlier_global_error");
            life_check::demand(service0.publish_state(token0, state0, selected, published_phase,
                !(life_check::scenario inside {"parse", "inventory", "sequence"})), "phase_active_safety_publish");
            if (life_check::scenario == "normalleak" || life_check::scenario == "cancelleak") begin
                life_sequence sequence0 = new();
                aip_cmd_seq_registry::register(cmd_name, sequence0);
                life_check::demand(!service0.release_owner(token0), "normal_leaked_sequence_cannot_release");
                if (life_check::scenario == "cancelleak")
                    life_check::demand(service0.cancel(token0, 1), "leaked_sequence_negates_claimed_clean_cancel");
                aip_cmd::set_result(0, "OLD_OK_MUST_NOT_ESCAPE");
                return;
            end
            if (life_check::scenario == "dirtycancel") begin
                life_check::demand(service0.cancel(token0, 0), "dirty_cancel_request");
                aip_cmd::set_result(0, "OLD_OK_MUST_NOT_ESCAPE");
                return;
            end
            if (life_check::scenario == "restore") begin
                state0.restore = AIP_RAL_RESTORE_FAILED;
                state0.interrupt_state(selected, 1, AIP_RAL_CODE_RESTORE_ERROR,
                                       "restore_failed", "aborted_after_error");
                life_check::demand(service0.publish_state(token0, state0, selected, AIP_RAL_PHASE_RESTORE, 1), "restore_failure_latches");
                state0.restore = AIP_RAL_RESTORE_NOT_REQUIRED;
                state0.recovery_required = 0;
                life_check::demand(service0.publish_state(token0, state0, selected, AIP_RAL_PHASE_RESUME, 1), "later_leaf_publish");
                observed = service0.snapshot();
                life_check::demand(observed.restore == AIP_RAL_RESTORE_FAILED && observed.recovery_required,
                                   "later_publish_cannot_clear_latch_or_failed_restore");
                aip_cmd::set_result(0, "OLD_OK_MUST_NOT_ESCAPE");
                return;
            end
            forever #10ns;
        endtask
    endclass

    // 每个UVM run先做SV身份/复制测试，再交给真实UCLI桥接测试当前独立dirty场景。
    class ral_lifecycle_test extends uvm_test;
        `uvm_component_utils(ral_lifecycle_test)
        life_command commands[$];

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        // 静态名称在bridge启动前全部注册；不注册产品ral_op或ral_test。
        virtual function void build_phase(uvm_phase phase);
            string names[$] = '{"life_normal", "life_service", "life_hold", "life_try", "life_fast",
                "life_background", "life_plain_hang", "life_wrapper", "life_hang", "life_gate_op",
                "life_gate_test", "life_mode", "life_stats", "life_reasons"};
            super.build_phase(phase);
            foreach (names[i]) begin life_command cmd0 = new(names[i]); commands.push_back(cmd0); end
            if (!$value$plusargs("LIFECYCLE_CASE=%s", life_check::scenario)) life_check::scenario = "action";
        endfunction

        // 通过真实worker而非手造execution验证终态exactly-once、stale双条件和默认scope。
        virtual task run_phase(uvm_phase phase);
            int status0;
            string text0;
            process dispatch;
            aip_cmd_execution_scope scope0 = new();
            aip_cmd_execution ended0;
            aip_ral_run_state snapshot0;
            aip_ral_service service0 = aip_ral_service::get();
            life_hook hook0 = new();
            phase.raise_objection(this);
            life_check::demand($bits(uvm_reg_data_t) == `UVM_REG_DATA_WIDTH, "actual_UVM_width_matches_build");
            aip_cmd::exec_result("life_normal", SRC_INTERNAL, status0, text0);
            life_check::demand(life_listener::normal_count == 1, "normal_listener_exactly_once");
            life_check::last_execution.notify_dead(AIP_CMD_WATCHDOG);
            life_check::demand(life_listener::normal_count == 1 && life_listener::watchdog_count == 0, "late_terminal_no_repeat");
            life_check::demand(!life_check::last_context.is_active(), "finished_context_invalidated");
            aip_cmd::exec_result("life_normal cancel", SRC_INTERNAL, status0, text0);
            life_check::demand(life_listener::cancel_count == 1, "generic_cancel_exactly_once");
            aip_cmd::exec_result("life_service", SRC_INTERNAL, status0, text0);
            aip_cmd::exec_result("life_service", SRC_INTERNAL, status0, text0);
            aip_cmd::exec_result("life_service sequence_clean", SRC_INTERNAL, status0, text0);
            life_check::demand(!service0.recovery_gate(1, text0), "normally_unregistered_sequence_does_not_latch");
            aip_cmd::exec_result("life_service cancel", SRC_INTERNAL, status0, text0);
            life_check::demand(status0 == 1 && aip_str::str_find(text0, "code=CANCELLED") >= 0 &&
                               aip_str::str_find(text0, "recovery_required=0") >= 0, "actual_clean_CANCELLED_not_old_OK");
            // 再启动一代，使迟到的旧CANCELLED通知带合法reason；不能靠reason mismatch假通过。
            aip_cmd::exec_result("life_service", SRC_INTERNAL, status0, text0);
            life_check::holding = 0;
            fork
                begin
                    dispatch = process::self();
                    aip_cmd::exec_result("life_hold", SRC_INTERNAL, status0, text0, null, scope0);
                end
            join_none
            wait (life_check::holding);
            ended0 = life_check::last_execution;
            life_check::demand(ended0.get_owner() != dispatch, "actual_worker_not_dispatch_owner");
            dispatch.kill();
            aip_cmd::exec_result("life_try", SRC_INTERNAL, status0, text0);
            life_check::demand(text0 == "BUSY", "dead_without_generation_notice_still_BUSY");
            void'(scope0.notify_dead(AIP_CMD_CANCELLED, text0));
            snapshot0 = service0.snapshot();
            life_check::demand(snapshot0.code == AIP_RAL_CODE_CANCELLED && !snapshot0.recovery_required,
                               "safe_parse_kill_no_recovery");
            void'(scope0.notify_dead(AIP_CMD_CANCELLED, text0));
            snapshot0 = service0.snapshot();
            life_check::demand(snapshot0.global_errors == 1, "cancel_notice_exactly_once");
            aip_cmd::exec_result("life_try", SRC_INTERNAL, status0, text0);
            life_check::demand(text0 == "none", "dead_and_notified_stale_reclaimed");
            // 不显式传scope，公共fork取消仍须通知真正owner，而非永远BUSY。
            life_check::holding = 0;
            aip_cmd::exec_result("fork life_hold, life_fast join_any disable_remaining=1", SRC_INTERNAL, status0, text0);
            life_check::demand(life_check::holding, "fork_owner_started");
            aip_cmd::exec_result("life_try", SRC_INTERNAL, status0, text0);
            life_check::demand(text0 == "none", "default_scope_fork_cancel_reclaims");
            aip_tcl_bridge::cmd_watchdog_poll_ns = 10;
            aip_tcl_bridge::set_cmd_watchdog(40);
            aip_tcl_bridge::set_watchdog_hook(hook0);
            aip_tcl_bridge::run_loop();
            $display("RAL_LIFECYCLE_COMPLETE width=%0d checks=%0d case=%s", $bits(uvm_reg_data_t),
                     life_check::checks, life_check::scenario);
            phase.drop_objection(this);
        endtask
    endclass
endpackage

module test_ral_lifecycle;
    import uvm_pkg::*;
    import ral_lifecycle_test_pkg::*;
    initial run_test("ral_lifecycle_test");
endmodule
