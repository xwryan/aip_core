// aip_cmd_seq_registry::active 单元测试：执行中为 1；正常注销、登记进程被杀（watchdog 路径）、
// 登记进程结束未注销、未知名称都为 0；kill_cancelled_owners 回收被杀进程的登记。
`include "aip_core_pkg.sv"

module test_seq_registry_active;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    `include "uvm_macros.svh"

    class hold_seq extends uvm_sequence;
        function new(string name = "hold_seq");
            super.new(name);
        endfunction
        virtual task body();
            #1000ns;
        endtask
    endclass

    int unsigned failures = 0;

    function automatic void check(bit cond, string what);
        if (!cond) begin
            failures++;
            $display("TSRA_FAIL: %s", what);
        end else begin
            $display("TSRA_OK:   %s", what);
        end
    endfunction

    // 在独立进程中登记并启动 seq；unregister_at_end=0 模拟登记进程结束却未注销。
    task automatic run_registered(string name, bit unregister_at_end, output process owner);
        fork
            begin
                hold_seq seq;
                owner = process::self();
                seq = new(name);
                aip_cmd_seq_registry::register(name, seq);
                seq.start(null);
                if (unregister_at_end) aip_cmd_seq_registry::unregister(name);
            end
        join_none
        #0;
    endtask

    initial begin
        process owner;

        check(!aip_cmd_seq_registry::active("absent"), "unknown name is inactive");

        run_registered("normal", 1, owner);
        #10ns;
        check(aip_cmd_seq_registry::active("normal"), "running sequence is active");
        #2000ns;
        check(!aip_cmd_seq_registry::active("normal"), "unregistered after completion is inactive");

        run_registered("killed", 1, owner);
        #10ns;
        check(aip_cmd_seq_registry::active("killed"), "sequence active before its owner is killed");
        owner.kill();
        #0;
        check(!aip_cmd_seq_registry::active("killed"), "killed owner makes the entry inactive at once");
        check(aip_cmd_seq_registry::kill_cancelled_owners() == 1, "kill_cancelled_owners reclaims the entry");
        check(!aip_cmd_seq_registry::active("killed"), "reclaimed entry stays inactive");

        run_registered("stale", 0, owner);
        #2000ns;
        check(aip_cmd_seq_registry::count() == 1, "finished owner left a stale entry");
        check(!aip_cmd_seq_registry::active("stale"), "finished owner without unregister is inactive");
        aip_cmd_seq_registry::unregister("stale");

        run_registered("rerun", 1, owner);
        #10ns;
        check(aip_cmd_seq_registry::active("rerun"), "re-registration after a kill is active");
        #2000ns;

        if (failures == 0) $display("TEST_SEQ_REGISTRY_ACTIVE_PASS");
        else $display("TEST_SEQ_REGISTRY_ACTIVE_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
