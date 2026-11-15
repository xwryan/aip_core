// RAL 独立物理总线夹具（基于本次 ralgen 生成的模型）：driver 持有四态 word 存储与观测 trace，
// 绝不以 RAL mirror 或产品 policy 转换函数充当硬件 oracle。
`ifndef AIP_RAL_FIXTURE_SV
`define AIP_RAL_FIXTURE_SV
`include "uvm_macros.svh"
package aip_ral_fixture_pkg;
    import uvm_pkg::*;
    `include "ral_aip_fixture.sv"

    // 请求/原位响应保留四态采样，adapter确认已知后才能交给二态RAL。
    class aip_ral_fixture_item extends uvm_sequence_item;
        uvm_reg_bus_op op;
        logic [31:0] sampled;
        bit completed;
        `uvm_object_utils(aip_ral_fixture_item)

        function new(string name = "aip_ral_fixture_item");
            super.new(name);
        endfunction
    endclass

    // 测试专用 adapter（不继承产品 adapter 基类）；公开计数用于断言数据在二态化之前已检查。
    class aip_ral_fixture_adapter extends uvm_reg_adapter;
        int unsigned unknown_count;
        `uvm_object_utils(aip_ral_fixture_adapter)
        // 使用标准原位响应并保留有效byte lane；不引入产品adapter基类。
        function new(string name = "aip_ral_fixture_adapter");
            super.new(name);
            supports_byte_enable = 1;
            provides_responses = 0;
        endfunction

        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            aip_ral_fixture_item item = new();
            item.op = rw;
            return item;
        endfunction

        // 只接受已完成合法单拍；有效lane含X/Z时NOT_OK且不复制sampled。
        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            aip_ral_fixture_item item;
            if (!$cast(item, bus_item)) begin
                rw.status = UVM_NOT_OK;
                return;
            end
            rw = item.op;
            if (!item.completed || rw.n_bits == 0 || rw.n_bits > 32) begin
                rw.status = UVM_NOT_OK;
                return;
            end
            if (rw.kind == UVM_READ) begin
                for (int b = 0; b < rw.n_bits; b++) begin
                    if (rw.byte_en[b / 8] && $isunknown(item.sampled[b])) begin
                        unknown_count++;
                        rw.status = UVM_NOT_OK;
                        return;
                    end
                end
                rw.data = '0;
                for (int b = 0; b < rw.n_bits; b++)
                    if (rw.byte_en[b / 8]) rw.data[b] = item.sampled[b];
            end
            rw.status = UVM_IS_OK;
        endfunction
    endclass

    // 稳定RW word设备，地址直接来自总线而非model查询；支持简单读故障校准。
    class aip_ral_fixture_driver extends uvm_driver #(aip_ral_fixture_item);
        logic [31:0] storage[uvm_reg_addr_t];
        uvm_reg_addr_t addresses[$];
        uvm_reg_data_t data_trace[$];
        uvm_reg_byte_en_t enables[$];
        int bits_trace[$];
        uvm_access_e kinds[$];
        bit read_x;
        bit read_corrupt;
        `uvm_component_utils(aip_ral_fixture_driver)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        // 只清 trace，物理存储与故障开关跨操作保留。
        function void clear_trace();
            addresses.delete();
            data_trace.delete();
            enables.delete();
            bits_trace.delete();
            kinds.delete();
        endfunction

        // 按 byte enable 修改存储后原位回复；无重试/预测/自动恢复。
        virtual task run_phase(uvm_phase phase);
            forever begin
                seq_item_port.get_next_item(req);
                addresses.push_back(req.op.addr);
                data_trace.push_back(req.op.data);
                enables.push_back(req.op.byte_en);
                bits_trace.push_back(req.op.n_bits);
                kinds.push_back(req.op.kind);
                if (!storage.exists(req.op.addr)) storage[req.op.addr] = '0;
                req.completed = (req.op.n_bits > 0 && req.op.n_bits <= 32);
                if (req.completed) begin
                    if (req.op.kind == UVM_WRITE)
                        for (int b = 0; b < req.op.n_bits; b++)
                            if (req.op.byte_en[b / 8]) storage[req.op.addr][b] = req.op.data[b];
                    req.sampled = storage[req.op.addr];
                    if (req.op.kind == UVM_READ) begin
                        if (read_corrupt) req.sampled[0] = ~req.sampled[0];
                        if (read_x) req.sampled[0] = 1'bx;
                    end
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    // 最小真实模型环境，仅提供标准RAL总线连接，不安装AIP service/frontdoor。
    class aip_ral_fixture_env extends uvm_env;
        ral_sys_aip_fixture model;
        uvm_mem memory;
        uvm_reg register0;
        uvm_sequencer #(aip_ral_fixture_item) sqr;
        aip_ral_fixture_driver driver;
        aip_ral_fixture_adapter adapter;
        `uvm_component_utils(aip_ral_fixture_env)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        // 默认 map 保持标准 UVM 拍序。
        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            model = new("model");
            model.build();
            model.lock_model();
            memory = model.LEAF.RAM;
            register0 = model.LEAF.WIDE;
            sqr = new("sqr", this);
            driver = new("driver", this);
            adapter = new();
            model.default_map.set_sequencer(sqr, adapter);
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            driver.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass
endpackage
`endif
