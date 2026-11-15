// src/sv/ral：内部物理观察层，依赖UVM标准HDL路径及backdoor API。
// runner拥有observer及四态snapshot；本类借用模型，不改变mirror或产生总线事务。
// field始终使用完整parent register，从而保留sibling/hole；不假设独立field路径。
`ifndef AIP_RAL_RAW_OBSERVER_SV
`define AIP_RAL_RAW_OBSERVER_SV
class aip_ral_raw_observer;
    // 不注册额外provider；访问所有权完全来自模型配置。
    function new(); endfunction

    // 写前验证全部副本覆盖。缺能力为UNTESTABLE；实际HDL路径不存在由访问报告失败。
    local function aip_ral_code_e resolve(uvm_object target, longint unsigned index,
        output uvm_object physical, output uvm_reg_backdoor backdoor,
        output uvm_hdl_path_concat paths[$], output int width, output bit memory0,
        output string detail);
        uvm_reg rg;
        uvm_reg_field field0;
        uvm_mem mem;
        physical=target; backdoor=null; paths.delete(); width=0; memory0=0; detail="";
        if ($cast(field0,target)) physical=field0.get_parent();
        if ($cast(rg,physical)) begin
            if (index!=0) begin detail="register index must be zero"; return AIP_RAL_CODE_INDEX_RANGE; end
            width=rg.get_n_bits(); backdoor=rg.get_backdoor();
            if (backdoor==null) begin
                if (!rg.has_hdl_path()) begin detail="no HDL path or custom backdoor"; return AIP_RAL_CODE_UNTESTABLE; end
                rg.get_full_hdl_path(paths);
            end
        end else if ($cast(mem,physical)) begin
            memory0=1;
            if (index>=mem.get_size()) begin detail="memory index outside object"; return AIP_RAL_CODE_INDEX_RANGE; end
            width=mem.get_n_bits(); backdoor=mem.get_backdoor();
            if (backdoor==null) begin
                if (!mem.has_hdl_path()) begin detail="no HDL path or custom backdoor"; return AIP_RAL_CODE_UNTESTABLE; end
                mem.get_full_hdl_path(paths);
            end
        end else begin detail="observer requires register, field or memory"; return AIP_RAL_CODE_BAD_ARGS; end
        if (width<1 || width>AIP_VEC_MAX_BITS ||
            (backdoor!=null && width>`UVM_REG_DATA_WIDTH) ||
            (backdoor==null && width>`UVM_HDL_MAX_WIDTH)) begin
            detail="physical width exceeds observer backend capacity"; return AIP_RAL_CODE_UNTESTABLE;
        end
        if (backdoor!=null) return AIP_RAL_CODE_NONE;
        if (paths.size()==0) begin detail="no raw observation provider"; return AIP_RAL_CODE_UNTESTABLE; end
        foreach (paths[p]) begin
            bit [AIP_VEC_MAX_BITS-1:0] covered='0;
            foreach (paths[p].slices[s]) begin
                int offset0=paths[p].slices[s].offset;
                int count=paths[p].slices[s].size;
                if (offset0==-1 && count==-1) begin offset0=0; count=width; end
                if (paths[p].slices[s].path=="" || offset0<0 || count<1 ||
                    offset0>=width || count>width-offset0) begin
                    detail="unrepresentable HDL slice"; return AIP_RAL_CODE_UNTESTABLE;
                end
                for (int b=0;b<count;b++) begin
                    if (covered[offset0+b]) begin detail="overlapping HDL slices"; return AIP_RAL_CODE_UNTESTABLE; end
                    covered[offset0+b]=1;
                end
            end
            for (int b=0;b<width;b++) if (!covered[b]) begin
                detail="incomplete HDL slice coverage"; return AIP_RAL_CODE_UNTESTABLE;
            end
        end
        return AIP_RAL_CODE_NONE;
    endfunction

    // 能力检查仅分析模型，不访问DUT；four_state只有HDL后端为真。
    function aip_ral_code_e capability(uvm_object target, longint unsigned index,
        output bit four_state, output string detail);
        uvm_object physical;
        uvm_reg_backdoor backdoor;
        uvm_hdl_path_concat paths[$];
        int width;
        bit memory0;
        aip_ral_code_e code0=resolve(target,index,physical,backdoor,paths,width,memory0,detail);
        four_state=(code0==AIP_RAL_CODE_NONE && backdoor==null);
        return code0;
    endfunction

    // 返回完整物理值；OK且known=0表示有效HDL X/Z，不是接口失败。
    // custom成功表示已知是模型契约；HAS_X同样拒绝，绝不绕过custom读HDL。
    task read(uvm_object target, longint unsigned index, output aip_ral_logic_t value,
        output bit known, output uvm_status_e status, output string detail);
        uvm_object physical;
        uvm_reg_backdoor backdoor;
        uvm_hdl_path_concat paths[$];
        int width;
        bit memory0;
        value='0; known=0; status=UVM_NOT_OK;
        if (resolve(target,index,physical,backdoor,paths,width,memory0,detail)!=AIP_RAL_CODE_NONE) return;
        if (backdoor!=null) begin
            uvm_reg_item rw=new("raw_observe");
            rw.element=physical; rw.element_kind=memory0?UVM_MEM:UVM_REG;
            rw.kind=UVM_READ; rw.path=UVM_BACKDOOR; rw.offset=index;
            rw.value=new[1]; rw.status=UVM_NOT_OK;
            backdoor.read(rw);
            if (rw.status!=UVM_IS_OK || rw.value.size()!=1) begin detail="custom backdoor read failed known-only contract"; return; end
            for (int b=0;b<width;b++) value[b]=rw.value[0][b];
        end else foreach (paths[p]) begin
            aip_ral_logic_t assembled='0;
            foreach (paths[p].slices[s]) begin
                uvm_hdl_data_t sample;
                string path0=paths[p].slices[s].path;
                int offset0=paths[p].slices[s].offset;
                int count=paths[p].slices[s].size;
                if (offset0==-1 && count==-1) begin offset0=0; count=width; end
                if (memory0) path0=$sformatf("%s[%0d]",path0,index);
                if (!uvm_hdl_read(path0,sample)) begin detail={"HDL read failed: ",path0}; return; end
                for (int b=0;b<count;b++) assembled[offset0+b]=sample[b];
            end
            if (p==0) value=assembled;
            else if (value!==assembled) begin detail="HDL copies disagree"; return; end
        end
        known=!$isunknown(value); status=UVM_IS_OK;
    endtask

    // 写完整物理值，HDL保留X/Z；custom拒绝有效宽度内未知值。中途失败可能已写
    // 部分副本，runner须保留恢复义务；本函数不做会掩盖原错误的自动回滚。
    task write(uvm_object target, longint unsigned index, input aip_ral_logic_t value,
        output bit known, output uvm_status_e status, output string detail);
        uvm_object physical;
        uvm_reg_backdoor backdoor;
        uvm_hdl_path_concat paths[$];
        aip_ral_logic_t normalized='0;
        int width;
        bit memory0;
        known=0; status=UVM_NOT_OK;
        if (resolve(target,index,physical,backdoor,paths,width,memory0,detail)!=AIP_RAL_CODE_NONE) return;
        for (int b=width;b<AIP_VEC_MAX_BITS;b++) if (!$isunknown(value[b]) && value[b]!==1'b0) begin
            detail="write value sets bits above physical width"; return;
        end
        for (int b=0;b<width;b++) normalized[b]=value[b];
        // 先检查所有路径，再进行首个deposit，避免后续副本失效造成部分破坏。
        if (backdoor==null) foreach (paths[p]) foreach (paths[p].slices[s]) begin
            string check_path=paths[p].slices[s].path;
            if (memory0) check_path=$sformatf("%s[%0d]",check_path,index);
            if (!uvm_hdl_check_path(check_path)) begin detail={"HDL path unavailable: ",check_path}; return; end
        end
        if (backdoor!=null) begin
            uvm_reg_item rw=new("raw_prepare");
            if ($isunknown(normalized)) begin detail="custom backdoor cannot preserve X/Z"; return; end
            rw.element=physical; rw.element_kind=memory0?UVM_MEM:UVM_REG;
            rw.kind=UVM_WRITE; rw.path=UVM_BACKDOOR; rw.offset=index;
            rw.value=new[1]; rw.value[0]=normalized; rw.status=UVM_NOT_OK;
            backdoor.write(rw);
            if (rw.status!=UVM_IS_OK) begin detail="custom backdoor write failed"; return; end
        end else foreach (paths[p]) foreach (paths[p].slices[s]) begin
            uvm_hdl_data_t sample='0;
            string path0=paths[p].slices[s].path;
            int offset0=paths[p].slices[s].offset;
            int count=paths[p].slices[s].size;
            if (offset0==-1 && count==-1) begin offset0=0; count=width; end
            if (memory0) path0=$sformatf("%s[%0d]",path0,index);
            for (int b=0;b<count;b++) sample[b]=value[offset0+b];
            if (!uvm_hdl_deposit(path0,sample)) begin detail={"HDL deposit failed: ",path0}; return; end
        end
        known=!$isunknown(normalized); status=UVM_IS_OK;
    endtask

    // 恢复后重读全部副本，用case equality核对X/Z；仅write成功不足以报告完成。
    task restore(uvm_object target, longint unsigned index, input aip_ral_logic_t snapshot,
        output bit known, output uvm_status_e status, output string detail);
        aip_ral_logic_t checked, normalized='0;
        uvm_object physical;
        uvm_reg_backdoor backdoor;
        uvm_hdl_path_concat paths[$];
        int width;
        bit memory0;
        known=0; status=UVM_NOT_OK;
        if (resolve(target,index,physical,backdoor,paths,width,memory0,detail)!=AIP_RAL_CODE_NONE) return;
        for (int b=0;b<width;b++) normalized[b]=snapshot[b];
        write(target,index,snapshot,known,status,detail);
        if (status!=UVM_IS_OK) return;
        read(target,index,checked,known,status,detail);
        if (status==UVM_IS_OK && checked!==normalized) begin
            status=UVM_NOT_OK; detail="restore reobservation mismatch";
        end
    endtask
endclass
`endif
