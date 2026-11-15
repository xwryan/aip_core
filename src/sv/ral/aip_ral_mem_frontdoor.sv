// memory frontdoor 与内部 raw 逐拍传输：map/adapter/原 parent 归 TB，临时特殊 parent clone 只存活一次 execute。
// 依赖 UVM 1.2 的 m_set_item/m_sequence_exiting helper（仅针对当前 VCS 自带的 UVM 1.2）。
`ifndef AIP_RAL_MEM_FRONTDOOR_SV
`define AIP_RAL_MEM_FRONTDOOR_SV

// 统一维护地址/数据配对和首错诊断，避免 raw 与标准 memory 的拍序漂移。
class aip_ral_beat_executor;
    int unsigned completed_beats;
    int failed_beat = -1;
    uvm_reg_addr_t failed_address;
    aip_ral_bus_status_e bus_status;
    string detail;

    // 有效位掩码支持满宽，避免移位等于向量位宽时溢出。
    static function uvm_reg_data_t mask(int unsigned bits0);
        return bits0 >= `UVM_REG_DATA_WIDTH ? '1 : (uvm_reg_data_t'(1) << bits0)-1;
    endfunction

    // 单 element 传输，调用方提供可用 owner；raw 可按真实请求/响应分类。
    // 任何失败均停止后拍，失败 read 清零；已完成写不重试、不回滚。
    task execute(uvm_reg_item rw, uvm_sequence_base fallback,
                 aip_ral_mem_beat_order_e order,
                 aip_ral_response_classifier classifier=null);
        uvm_mem memory0;
        uvm_reg register0;
        uvm_reg_map map0;
        uvm_reg_adapter adapter;
        uvm_sequencer_base sqr;
        uvm_sequence_base owner, saved_parent;
        uvm_object clone0;
        uvm_reg_addr_t addresses[];
        uvm_reg_data_t result, input_value;
        int unsigned width0, bus_bits;
        bit cloned, held;

        completed_beats=0; failed_beat=-1; failed_address=0;
        bus_status=AIP_RAL_BUS_ERROR; detail="invalid transport context";
        if (rw==null) return;
        rw.status=UVM_NOT_OK;
        if (rw.value.size()!=1 || rw.local_map==null) return;
        input_value=rw.value[0];
        if (rw.kind==UVM_READ) rw.value[0]=0;
        map0=rw.local_map;
        adapter=map0.get_adapter(UVM_HIER);
        sqr=map0.get_sequencer(UVM_HIER);
        bus_bits=8*map0.get_n_bytes(UVM_HIER);
        if ($cast(memory0,rw.element)) begin
            if (rw.offset>=memory0.get_size()) return;
            width0=memory0.get_n_bits();
            void'(memory0.get_addresses(rw.offset,map0,addresses));
        end
        else if ($cast(register0,rw.element)) begin
            width0=register0.get_n_bits();
            void'(register0.get_addresses(map0,addresses));
        end
        else return;
        if (adapter==null || sqr==null || bus_bits==0 ||
            bus_bits>`UVM_REG_DATA_WIDTH || width0==0 || width0>`UVM_REG_DATA_WIDTH) return;
        if (addresses.size()!=(width0+bus_bits-1)/bus_bits) begin
            detail="physical address count does not match effective bus width";
            return;
        end

        saved_parent=rw.parent;
        owner=(saved_parent==null)?fallback:saved_parent;
        if (owner==null) return;
        if (adapter.parent_sequence!=null) begin
            clone0=adapter.parent_sequence.clone();
            if (!$cast(owner,clone0)) begin detail="adapter parent clone failed"; return; end
            owner.set_parent_sequence(saved_parent);
            owner.set_sequencer(sqr);
            rw.parent=owner;
            cloned=1;
        end
         // 已有组合操作 owner 的 grab 不得被内层访问释放；普通单次操作由 executor 独占一次（标准 parent 不会预先持锁）。
        held=0;
        owner.grab(sqr);
        result=0; rw.status=UVM_IS_OK; bus_status=AIP_RAL_BUS_OK; detail="";
        for (int t=0;t<addresses.size();t++) begin
            int k;
            int valid_bits;
            uvm_reg_bus_op op;
            uvm_sequence_item request,response;
            aip_ral_bus_status_e classified;
            string classification_detail;
            k=(memory0!=null && order==AIP_RAL_MSW_FIRST)?addresses.size()-1-t:t;
            valid_bits=width0-k*bus_bits;
            if (valid_bits>bus_bits) valid_bits=bus_bits;
            op.kind=rw.kind; op.addr=addresses[k]; op.n_bits=valid_bits;
            op.byte_en='0;
            for (int lane=0;lane<(valid_bits+7)/8;lane++) op.byte_en[lane]=1;
            op.data=(input_value>>(k*bus_bits)) & mask(valid_bits);
            op.status=UVM_NOT_OK;
            adapter.m_set_item(rw);
            request=adapter.reg2bus(op);
            adapter.m_set_item(null);
            classified=AIP_RAL_BUS_ERROR;
            if (request!=null) begin
                request.set_sequencer(sqr);
                owner.start_item(request,rw.prior);
                owner.finish_item(request);
                if (adapter.provides_responses)
                    owner.get_base_response(response,request.get_transaction_id());
                else response=request;
                if (response!=null) begin
                    adapter.bus2reg(response,op);
                    classified=(op.status==UVM_IS_OK)?AIP_RAL_BUS_OK:AIP_RAL_BUS_ERROR;
                    if (classifier!=null)
                        classified=classifier.classify(request,response,op.status,classification_detail);
                    // 此层尚未接入 WO 无数据例外上下文，分类器不能将未知数据改为成功。
                    if (classified==AIP_RAL_BUS_OK && op.status!=UVM_IS_OK)
                        classified=AIP_RAL_BUS_ERROR;
                end
                aip_activity::tick();
            end
            if (classified!=AIP_RAL_BUS_OK) begin
                failed_beat=t; failed_address=addresses[k];
                bus_status=(completed_beats!=0)?AIP_RAL_BUS_ERROR:classified;
                rw.status=(op.status==UVM_IS_OK)?UVM_NOT_OK:op.status;
                detail=classification_detail.len()?classification_detail:"transport beat failed";
                break;
            end
            completed_beats++;
            result|=(op.data & mask(valid_bits))<<(k*bus_bits);
        end
        if (rw.kind==UVM_READ) rw.value[0]=(rw.status==UVM_IS_OK)?result:0;
        if (!held) owner.ungrab(sqr);
        rw.parent=saved_parent;
        if (cloned) sqr.m_sequence_exiting(owner);
    endtask
endclass

// 标准 memory 入口保留外层 callback，只替换物理 beat 发送；每个 memory/map slot 独享执行器与诊断。
class aip_ral_mem_frontdoor extends uvm_reg_frontdoor;
    local aip_ral_mem_beat_order_e beat_order;
    aip_ral_beat_executor transport;

    function new(string name="aip_ral_mem_frontdoor", aip_ral_mem_beat_order_e order=AIP_RAL_MSW_FIRST);
        super.new(name); beat_order=order; transport=new();
    endfunction

    // 标准 UVM 设置 rw_info；当前 sequence 是无显式 parent 时的发拍 owner。
    virtual task body();
        transport.execute(rw_info,this,beat_order);
    endtask
endclass
`endif
