`include "aip_core_pkg.sv"

class registry_test_checker extends aip_end_checker;
    string detail;
    bit done;
    bit failed;
    int unsigned done_queries;
    int unsigned failed_queries;

    function new(string detail = "pending");
        this.detail = detail;
    endfunction

    virtual function bit is_done();
        done_queries++;
        return done;
    endfunction

    virtual function bit has_failed();
        failed_queries++;
        return failed;
    endfunction

    virtual function string status_detail();
        return detail;
    endfunction
endclass

class base_contract_checker extends aip_end_checker;
    virtual function bit is_done();
        return 1;
    endfunction

    virtual function bit has_failed();
        return super.has_failed();
    endfunction

    virtual function string status_detail();
        return super.status_detail();
    endfunction
endclass

class cleanup_trace_state;
    static string value = "";
endclass

class cleanup_a_cmd extends aip_cmd;
    task cmd_exec();
        cleanup_trace_state::value = {cleanup_trace_state::value, "A"};
        this.result_out = "cleanup_a";
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static cleanup_a_cmd __inst = new("cleanup_a");
endclass

class cleanup_b_cmd extends aip_cmd;
    task cmd_exec();
        cleanup_trace_state::value = {cleanup_trace_state::value, "B"};
        this.result_out = "cleanup_b";
        this.status = 0;
    endtask
    function new(string name); super.new(name); endfunction
    static cleanup_b_cmd __inst = new("cleanup_b");
endclass

class cleanup_fail_cmd extends aip_cmd;
    task cmd_exec();
        cleanup_trace_state::value = {cleanup_trace_state::value, "F"};
        this.result_out = "intentional cleanup failure";
        this.status = 1;
    endtask
    function new(string name); super.new(name); endfunction
    static cleanup_fail_cmd __inst = new("cleanup_fail");
endclass

class checker_registry_test extends uvm_test;
    `uvm_component_utils(checker_registry_test)

    registry_test_checker legacy;
    registry_test_checker first;
    registry_test_checker second;
    base_contract_checker contract_fixture;
    string checker_case;
    time bridge_start;

    function new(string name = "checker_registry_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void validate_base_contract(aip_end_checker checker);
        if (checker.has_failed() || checker.status_detail() != "")
            `uvm_fatal("CHECKER_CONTRACT",
                       "aip_end_checker base contract did not dispatch")
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!$value$plusargs("CHECKER_CASE=%s", checker_case))
            `uvm_fatal("CHECKER_CASE", "CHECKER_CASE is required")

        aip_tcl_bridge::end_checker = null;
        aip_tcl_bridge::clear_end_checkers();
        cleanup_trace_state::value = "";
        legacy = new("legacy pending");
        first  = new("first pending");
        second = new("second pending");
        contract_fixture = new();
        validate_base_contract(contract_fixture);

        case (checker_case)
            "legacy", "direct_legacy", "idle_compat": begin
                legacy.done = 1;
                if (checker_case inside {"legacy", "idle_compat"})
                    aip_tcl_bridge::set_end_checker(legacy);
                else
                    aip_tcl_bridge::end_checker = legacy;
            end
            "multi": begin
                aip_tcl_bridge::register_end_checker("first", first);
                aip_tcl_bridge::register_end_checker("second", second);
            end
            "legacy_named": begin
                aip_tcl_bridge::set_end_checker(legacy);
                aip_tcl_bridge::register_end_checker("second", second);
            end
            "failure", "failure_nonstrict": begin
                first.failed = 1;
                first.detail = "irreversible transport loss";
                aip_tcl_bridge::register_end_checker("transport", first);
            end
            "same_handle": begin
                first.done = 1;
                aip_tcl_bridge::set_end_checker(first);
                aip_tcl_bridge::register_end_checker("same", first);
            end
            "nonstrict_timeout", "strict_timeout": begin
                aip_tcl_bridge::register_end_checker("pending", first);
            end
            "watchdog_end_test", "watchdog_fork_end_test": begin
                aip_tcl_bridge::register_end_checker("pending", first);
                aip_tcl_bridge::set_cmd_watchdog(500.0);
            end
            "watchdog_end_test_drain", "watchdog_fork_end_test_drain",
            "watchdog_fork_end_test_idle": begin
                aip_tcl_bridge::set_cmd_watchdog(500.0);
            end
            "cleanup_single", "cleanup_drain", "cleanup_multi",
            "cleanup_semicolon", "cleanup_failure": begin end
            "multi_timeout": begin
                first.detail = "first still pending";
                second.detail = "second still pending";
                aip_tcl_bridge::register_end_checker("first", first);
                aip_tcl_bridge::register_end_checker("second", second);
            end
            "invalid": begin
                first.done = 1;
                aip_tcl_bridge::register_end_checker("stable", first);
                aip_tcl_bridge::register_end_checker("stable", first);
                aip_tcl_bridge::register_end_checker("", second);
                aip_tcl_bridge::register_end_checker("null", null);
                aip_tcl_bridge::register_end_checker("stable", second);
            end
            "remove": begin
                legacy.done = 1;
                aip_tcl_bridge::set_end_checker(legacy);
                aip_tcl_bridge::register_end_checker("first", first);
                aip_tcl_bridge::unregister_end_checker("first");
                if (aip_tcl_bridge::named_end_checkers.exists("first"))
                    `uvm_fatal("CHECKER_REMOVE",
                               "unregister left the removed checker present")
                aip_tcl_bridge::register_end_checker("second", second);
                aip_tcl_bridge::clear_end_checkers();
            end
            "frozen": begin
                aip_tcl_bridge::register_end_checker("first", first);
            end
            "strict_missing": begin end
            default:
                `uvm_fatal("CHECKER_CASE",
                           $sformatf("unknown CHECKER_CASE=%s", checker_case))
        endcase
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        bridge_start = $time;
        fork
            begin
                case (checker_case)
                    "multi": begin
                        #300ns; first.done = 1; first.detail = "first done";
                        #300ns; second.done = 1; second.detail = "second done";
                    end
                    "legacy_named": begin
                        #200ns; legacy.done = 1; legacy.detail = "legacy done";
                        #200ns; second.done = 1; second.detail = "named done";
                    end
                    "frozen": begin
                        #200ns;
                        aip_tcl_bridge::register_end_checker("late", second);
                        aip_tcl_bridge::unregister_end_checker("first");
                        aip_tcl_bridge::clear_end_checkers();
                        aip_tcl_bridge::set_end_checker(second);
                        first.done = 1;
                        first.detail = "original done";
                    end
                    "idle_compat": begin
                        #200ns; aip_activity::tick();
                        #200ns; aip_activity::tick();
                    end
                endcase
            end
        join_none
        aip_tcl_bridge::run_loop();
        disable fork;

        if ((checker_case == "cleanup_single" ||
             checker_case == "cleanup_drain") &&
            cleanup_trace_state::value != "A")
            `uvm_fatal("CLEANUP_ORDER",
                       $sformatf("single cleanup trace=%s",
                                 cleanup_trace_state::value))
        if (checker_case == "cleanup_drain" && $time < 100ns)
            `uvm_fatal("CLEANUP_DRAIN",
                       $sformatf("drain did not use time unit: t=%0t", $time))
        if ((checker_case == "cleanup_multi" ||
             checker_case == "cleanup_semicolon") &&
            cleanup_trace_state::value != "AB")
            `uvm_fatal("CLEANUP_ORDER",
                       $sformatf("multi cleanup trace=%s",
                                 cleanup_trace_state::value))
        if (checker_case == "cleanup_failure" &&
            cleanup_trace_state::value != "FB")
            `uvm_fatal("CLEANUP_ORDER",
                       $sformatf("failure cleanup trace=%s",
                                 cleanup_trace_state::value))

        if (checker_case == "multi" &&
            (first.done_queries == 0 || second.done_queries == 0))
            `uvm_fatal("CHECKER_QUERY",
                       "both named checkers must be polled")
        if (checker_case == "legacy_named" &&
            (legacy.done_queries == 0 || second.done_queries == 0))
            `uvm_fatal("CHECKER_QUERY",
                       "both legacy and named checkers must be polled")
        if (checker_case == "frozen" && first.done_queries == 0)
            `uvm_fatal("CHECKER_QUERY", "registered checker was not polled")
        if (checker_case == "multi" &&
            ($time - bridge_start) < 600ns)
            `uvm_fatal("CHECKER_AGGREGATE",
                       "end_test exited before every named checker completed")
        if (checker_case == "legacy_named" &&
            ($time - bridge_start) < 400ns)
            `uvm_fatal("CHECKER_AGGREGATE",
                       "end_test exited before legacy and named checkers completed")
        if (checker_case == "nonstrict_timeout" &&
            ($time - bridge_start) < 500ns)
            `uvm_fatal("CHECKER_TIMEOUT",
                       "non-strict timeout returned before its deadline")
        if (checker_case == "frozen") begin
            if (aip_tcl_bridge::end_checker != null ||
                aip_tcl_bridge::named_end_checkers.num() != 1 ||
                !aip_tcl_bridge::named_end_checkers.exists("first") ||
                aip_tcl_bridge::named_end_checkers["first"] != first ||
                aip_tcl_bridge::named_end_checkers.exists("late"))
                `uvm_fatal("CHECKER_FREEZE",
                           "active-wait mutation changed the checker snapshot/registry")
        end
        if (checker_case == "invalid" &&
            (aip_tcl_bridge::named_end_checkers.num() != 1 ||
             aip_tcl_bridge::named_end_checkers["stable"] != first))
            `uvm_fatal("CHECKER_INVALID",
                       "invalid/idempotent registration changed the stable entry")
        if (checker_case == "idle_compat" &&
            ($time - bridge_start) < 800ns)
            `uvm_fatal("CHECKER_IDLE",
                       "end_test did not preserve the activity idle window")
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        $display("CHECKER_REGISTRY_REPORT_PASS case=%s", checker_case);
    endfunction
endclass

module test_end_checker_registry;
    initial run_test("checker_registry_test");
endmodule
