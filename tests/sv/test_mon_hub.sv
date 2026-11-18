// aip_mon_hub / aip_sample_seq 单元测试：无订阅不留历史、多订阅独立副本、阻塞/超时/取消、重订阅隔离、
// 复位清队列与通知、容量溢出不部分广播、单读者独占与被杀读者接管、配置错误，以及 sequencer 登记与 seq 采样路径。
`timescale 1ns/1ps
`include "aip_core_pkg.sv"

module test_mon_hub;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    `include "uvm_macros.svh"

    class hub_item extends uvm_sequence_item;
        int value;
        `uvm_object_utils_begin(hub_item)
            `uvm_field_int(value, UVM_ALL_ON)
        `uvm_object_utils_end
        function new(string name = "hub_item");
            super.new(name);
        endfunction
    endclass

    // 预期的 fatal/error 按 id 计数并降级为 INFO，其余照常抛出。
    class expect_catcher extends uvm_report_catcher;
        int counts[string];
        function new();
            super.new("expect_catcher");
        endfunction
        virtual function action_e catch();
            string id = get_id();
            if (id inside {"AIP_MON_TIMEOUT", "AIP_MON_OVERFLOW", "AIP_MON_READER", "AIP_MON_CFG",
                           "AIP_MON_SUB", "AIP_SAMPLE_SQR"}) begin
                counts[id]++;
                set_severity(UVM_INFO);
                set_action(UVM_DISPLAY);
            end
            return THROW;
        endfunction
        function int count(string id);
            return counts.exists(id) ? counts[id] : 0;
        endfunction
    endclass

    // 代替真实 agent：一个 hub 加一个采样 sequencer。
    class hub_agent extends uvm_component;
        `uvm_component_utils(hub_agent)
        aip_mon_hub#(hub_item)    hub;
        aip_sample_sqr#(hub_item) sqr;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            hub = aip_mon_hub#(hub_item)::type_id::create("hub", this);
            sqr = aip_sample_sqr#(hub_item)::type_id::create("sqr", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            sqr.m_hub = hub;
        endfunction
    endclass

    class reset_listener extends uvm_component;
        `uvm_component_utils(reset_listener)
        uvm_analysis_imp#(aip_mon_reset_t, reset_listener) notice_export;
        aip_mon_reset_t notices[$];
        function new(string name, uvm_component parent);
            super.new(name, parent);
            notice_export = new("notice_export", this);
        endfunction
        function void write(aip_mon_reset_t notice);
            notices.push_back(notice);
        endfunction
    endclass

    class hub_test extends uvm_test;
        `uvm_component_utils(hub_test)
        hub_agent      agt;
        reset_listener listener;
        expect_catcher catcher;
        int unsigned   failures;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = hub_agent::type_id::create("agt", this);
            listener = reset_listener::type_id::create("listener", this);
            catcher = new();
            uvm_report_cb::add(null, catcher);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agt.hub.reset_ap.connect(listener.notice_export);
        endfunction

        function void expect_that(bit cond, string what);
            if (!cond) begin
                failures++;
                $display("TMH_FAIL: %s", what);
            end else begin
                $display("TMH_OK:   %s", what);
            end
        endfunction

        function hub_item make(int value);
            hub_item item = hub_item::type_id::create("item");
            item.value = value;
            return item;
        endfunction

        task run_phase(uvm_phase phase);
            aip_mon_hub#(hub_item) hub = agt.hub;
            aip_sample_seq#(hub_item) seq;
            hub_item got, got_cancel, got_reset, got_second;
            aip_mon_reset_t seen;
            process first_reader;
            bit woke, reset_done, seen_valid;
            time t0;
            int unsigned epoch0;

            phase.raise_objection(this);

            hub.write(make(1));
            hub.subscribe(0);
            expect_that(hub.pending(0) == 0, "no history is kept before subscription");

            hub.subscribe(1);
            hub.write(make(10));
            hub.write(make(11));
            expect_that(hub.pending(0) == 2 && hub.pending(1) == 2, "every subscriber queues its own copy");
            hub.mon_xaction(got, 0);
            got.value = 99;
            hub.mon_xaction(got_second, 1);
            expect_that(got_second.value == 10, "copies are independent deep clones");
            hub.mon_xaction(got, 0);
            expect_that(got.value == 11, "consumer 0 keeps arrival order");
            hub.mon_xaction(got, 1);
            expect_that(got.value == 11, "consumer 1 keeps arrival order");

            t0 = $time;
            fork
                begin
                    #50ns;
                    hub.write(make(20));
                end
            join_none
            hub.mon_xaction(got, 0);
            expect_that(got != null && got.value == 20 && $time - t0 == 50, "blocking read waits for the next transaction");
            hub.mon_xaction(got, 1);

            t0 = $time;
            hub.mon_xaction(got, 0, 30ns);
            expect_that(got == null && $time - t0 == 30 && catcher.count("AIP_MON_TIMEOUT") == 1,
                  "timeout returns null and reports one error");

            fork
                begin
                    hub.mon_xaction(got_cancel, 1);
                    woke = 1;
                end
            join_none
            #5ns;
            hub.unsubscribe(1);
            #0;
            expect_that(woke && got_cancel == null, "unsubscribe wakes the waiter with null");
            hub.subscribe(1);
            hub.write(make(30));
            hub.mon_xaction(got, 1);
            expect_that(got.value == 30, "a resubscribed portid receives only new data");
            hub.mon_xaction(got, 0);
            expect_that(got.value == 30, "the other subscriber still receives its copy");

            hub.write(make(40));
            hub.mon_xaction(got, 1);
            epoch0 = hub.reset_epoch();
            fork
                begin
                    hub.mon_xaction(got_reset, 1);
                    reset_done = 1;
                end
            join_none
            #5ns;
            hub.set_reset(1);
            expect_that(hub.pending(0) == 0 && hub.is_subscribed(0) && hub.in_reset(),
                  "reset clears queues but keeps subscriptions");
            hub.write(make(41));
            expect_that(hub.pending(0) == 0, "transactions during reset are dropped");
            #5ns;
            hub.set_reset(0);
            #1ns;
            expect_that(!reset_done, "a waiter keeps waiting across reset");
            hub.write(make(42));
            wait (reset_done);
            expect_that(got_reset != null && got_reset.value == 42, "the waiter gets the first post-reset transaction");
            expect_that(hub.reset_epoch() == epoch0 + 1, "epoch increments once per assertion");
            expect_that(listener.notices.size() == 2 && listener.notices[0].asserted && !listener.notices[1].asserted &&
                  listener.notices[1].epoch == epoch0 + 1, "reset_ap publishes assert and release notices");
            hub.mon_xaction(got, 0);
            hub.set_reset(0);
            expect_that(listener.notices.size() == 2, "an unchanged reset level publishes nothing");

            fork
                begin
                    hub.wait_reset(seen);
                    seen_valid = 1;
                end
            join_none
            #1ns;
            hub.set_reset(1);
            #0;
            expect_that(seen_valid && seen.asserted && seen.epoch == epoch0 + 2, "wait_reset returns the next notice");
            hub.set_reset(0);

            hub.unsubscribe(0);
            hub.unsubscribe(1);
            hub.subscribe(0, 2);
            hub.subscribe(1, 4);
            hub.write(make(50));
            hub.write(make(51));
            hub.write(make(52));
            expect_that(catcher.count("AIP_MON_OVERFLOW") == 1, "overflow is fatal, never silent");
            expect_that(hub.pending(0) == 2 && hub.pending(1) == 2, "overflow does not broadcast partially");

            hub.unsubscribe(0);
            hub.unsubscribe(1);
            hub.subscribe(0);
            fork
                begin
                    first_reader = process::self();
                    hub.mon_xaction(got, 0);
                end
            join_none
            #1ns;
            hub.mon_xaction(got_second, 0, 5ns);
            expect_that(catcher.count("AIP_MON_READER") == 1 && got_second == null,
                  "a second live reader on one subscription is rejected");
            first_reader.kill();
            #1ns;
            hub.write(make(60));
            hub.mon_xaction(got_second, 0, 5ns);
            expect_that(got_second != null && got_second.value == 60, "a killed reader releases the subscription");

            hub.subscribe(0);
            expect_that(catcher.count("AIP_MON_CFG") == 1, "duplicate subscription is a configuration fatal");
            hub.mon_xaction(got, 7, 1ns);
            expect_that(catcher.count("AIP_MON_SUB") == 1 && got == null, "reading an unsubscribed portid is fatal");

            expect_that(aip_sample_sqr#(hub_item)::get_sqr(agt.get_full_name()) == agt.sqr,
                  "the sequencer is registered under its agent name");
            expect_that(aip_sample_sqr#(hub_item)::get_sqr("nobody") == null, "an unknown name returns null");
            seq = aip_sample_seq#(hub_item)::type_id::create("seq");
            seq.mon_xaction(got, 0, 1ns);
            expect_that(catcher.count("AIP_SAMPLE_SQR") == 1 && got == null, "sampling without a sequencer is fatal");
            seq.set_sequencer(agt.sqr);
            seq.subscribe(3);
            hub.write(make(70));
            expect_that(seq.pending(3) == 1, "seq subscribe/pending go through the hub");
            seq.mon_xaction(got, 3);
            expect_that(got != null && got.value == 70, "seq mon_xaction returns the sampled transaction");
            expect_that(seq.reset_epoch() == hub.reset_epoch(), "seq exposes the hub reset epoch");
            seq.unsubscribe(3);
            expect_that(!hub.is_subscribed(3), "seq unsubscribe removes the slot");

            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server server = uvm_report_server::get_server();
            super.report_phase(phase);
            expect_that(server.get_severity_count(UVM_ERROR) == 0 && server.get_severity_count(UVM_FATAL) == 0,
                  "no unexpected UVM error or fatal");
            if (failures == 0) $display("TEST_MON_HUB_PASS");
            else $display("TEST_MON_HUB_FAIL failures=%0d", failures);
        endfunction
    endclass

    initial run_test("hub_test");
endmodule
