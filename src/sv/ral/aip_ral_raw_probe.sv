// 权限负向测试用的 raw frontdoor probe：绕过 reg/mem 权限检查但不绕过真实总线，地址与 response 仍由 selected map 计算；
// 调用者须以当前 runner sequence 作 parent，本类不更新 mirror。
`ifndef AIP_RAL_RAW_PROBE_SV
`define AIP_RAL_RAW_PROBE_SV

class aip_ral_raw_probe;
    local uvm_reg_map selected_map;
    local aip_ral_response_classifier classifier;
    local aip_ral_mem_beat_order_e beat_order;
    // runner读取首错诊断；所有权仍归probe，禁止替换执行器。
    aip_ral_beat_executor transport;

    function new(uvm_reg_map map0, aip_ral_response_classifier classifier0=null,
                 aip_ral_mem_beat_order_e order=AIP_RAL_MSW_FIRST);
        selected_map = map0;
        classifier = classifier0;
        beat_order = order;
        transport = new();
    endfunction

    // 以共享逐拍执行器绕过权限门禁；保持真实request/response供classifier分类。
    // register始终标准低位拍序；memory遵循构造时配置，失败read不发布部分值。
    task access(uvm_object element, bit is_write, longint unsigned offset,
                uvm_reg_data_t write_value, uvm_sequence_base parent,
                output uvm_status_e status, output aip_ral_bus_status_e bus_status,
                output string detail, output uvm_reg_data_t read_value);
        uvm_reg_item item;
        uvm_reg reg0;
        uvm_mem mem0;
        uvm_reg_map local_map;
        uvm_sequencer_base sequencer;
        uvm_reg_adapter adapter;
        status = UVM_NOT_OK;
        bus_status = AIP_RAL_BUS_ERROR;
        detail = "";
        read_value = '0;
        if (selected_map == null || element == null || parent == null) begin
            detail = "map, element and parent sequence are required";
            return;
        end
        if (!$cast(reg0,element) && !$cast(mem0,element)) begin
            detail = "raw probe supports only uvm_reg or uvm_mem";
            return;
        end
        if (!$cast(reg0,element) && offset >= mem0.get_size()) begin
            detail = "memory index out of range";
            return;
        end
        if ($cast(reg0,element)) local_map = reg0.get_local_map(selected_map);
        else local_map = mem0.get_local_map(selected_map);
        if (local_map == null) begin
            detail = "element is not in selected map";
            return;
        end
        sequencer = local_map.get_root_map().get_sequencer();
        adapter = local_map.get_root_map().get_adapter();
        if (sequencer == null || adapter == null) begin
            detail = "selected map has no sequencer/adapter";
            return;
        end
        item = new("aip_raw_probe_item");
        item.element = element;
        item.element_kind = $cast(reg0,element) ? UVM_REG : UVM_MEM;
        item.kind = is_write ? UVM_WRITE : UVM_READ;
        item.path = UVM_FRONTDOOR;
        item.map = selected_map;
        item.local_map = local_map;
        item.offset = offset;
        item.parent = parent;
        item.value = new[1];
        item.value[0] = write_value;
        transport.execute(item,parent,beat_order,classifier);
        status = item.status;
        if (!is_write && item.value.size() != 0) read_value = item.value[0];
        bus_status = transport.bus_status;
        detail = transport.detail;
    endtask

    function uvm_reg_map get_map(); return selected_map; endfunction
endclass

`endif
