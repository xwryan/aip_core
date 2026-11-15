// 精简确定性 RAL runner：inventory、reset/quiesce、RW 数据契约、memory 恢复与明确 UNTESTABLE 的最小可审计闭环，
// 不复制完整随机验证平台；vreg/vfield 只保留 ral_op 配置访问。
`ifndef AIP_RAL_TEST_RUNNER_SV
`define AIP_RAL_TEST_RUNNER_SV

class aip_ral_runner_leaf;
    string canonical;
    string kind;
    uvm_object object0;
    aip_ral_leaf_id_t id;
    function new(string name0, string kind0, uvm_object object1);
        canonical=name0; kind=kind0; object0=object1; id=0;
    endfunction
endclass

class aip_ral_test_runner;
    local aip_ral_service svc;
    local uvm_reg_map map0;
    local uvm_sequence_base parent;
    local aip_ral_mem_mode_e mem_mode;
    local aip_ral_run_state state;
    local aip_ral_runner_leaf leaves[$];
    local bit any_write;
    local bit restore_failed;

    function new(aip_ral_service svc0, uvm_reg_map map1, uvm_sequence_base parent0,
                 aip_ral_mem_mode_e mem_mode0=AIP_RAL_MEM_ADDRESS_LINE);
        svc=svc0; map0=map1; parent=parent0; mem_mode=mem_mode0;
    endfunction

    local function uvm_reg_data_t mask(int unsigned width0);
        if (width0>=`UVM_REG_DATA_WIDTH) return '1;
        return (uvm_reg_data_t'(1)<<width0)-1;
    endfunction

    local function bit has_prefix(string value0, string prefix0);
        return value0.len()>=prefix0.len() &&
               value0.substr(0,prefix0.len()-1)==prefix0;
    endfunction

    local function bit add_candidate(string canonical, string kind, uvm_object object0,
                                     output string why);
        aip_ral_runner_leaf leaf0;
        aip_ral_leaf_id_t id0;
        bit excluded;
        why="";
        if (kind!="field" && kind!="mem") return 1;
        leaf0=new(canonical,kind,object0);
        if (!state.add_leaf(canonical,kind=="mem",id0,why)) return 0;
        leaf0.id=id0;
        leaves.push_back(leaf0);
        excluded=svc.is_excluded(object0,why);
        return 1;
    endfunction

    // 先解析effective target，再一次性提交账本；target field扩大到parent register。
    local function bit build_inventory(string target, output string effective, output string detail,
                                       output aip_ral_code_e code);
        string root_name,kind,canonical,why;
        int dot;
        uvm_reg_block root0;
        aip_ral_test_hook hook0;
        uvm_object target_obj;
        string target_kind;
        uvm_reg forced_reg;
        uvm_reg_field target_field;
        bit exact,found;
        detail=""; code=AIP_RAL_CODE_NONE; effective=target; leaves.delete();
        dot=aip_str::str_find(target,".");
        root_name=(dot<0)?target:target.substr(0,dot-1);
        found=0;
        for (int r=0;r<svc.get_root_count();r++) begin
            string rn; uvm_reg_block rb; aip_ral_test_hook rh;
            if (svc.get_root_at(r,rn,rb,rh) && rn==root_name) begin found=1; root0=rb; hook0=rh; end
        end
        if (!found) begin detail="unknown root"; code=AIP_RAL_CODE_NOT_FOUND; return 0; end
        exact=svc.lookup(target,target_obj,target_kind);
        if (exact && (target_kind=="vreg" || target_kind=="vfield")) begin
            detail="vreg/vfield are configuration targets, not ral_test targets";
            code=AIP_RAL_CODE_BAD_ARGS; return 0;
        end
        if (exact && target_kind=="field") begin
            $cast(target_field,target_obj); forced_reg=target_field.get_parent();
            effective=target;
            for (int p=0;p<svc.get_object_count();p++) begin
                string pn,pk; uvm_object po;
                if (svc.get_object_at(p,pn,po,pk) && po==forced_reg) effective=pn;
            end
        end else if (exact && target_kind=="reg") begin
            $cast(forced_reg,target_obj);
        end
        for (int i=0;i<svc.get_object_count();i++) begin
            uvm_object object0; string obj_name,obj_kind;
            if (!svc.get_object_at(i,obj_name,object0,obj_kind)) continue;
            if (obj_kind!="field" && obj_kind!="mem") continue;
            begin
                uvm_reg_field map_field; uvm_mem map_mem;
                if (obj_kind=="field" && $cast(map_field,object0) && map_field.get_parent().get_local_map(map0)==null) continue;
                if (obj_kind=="mem" && $cast(map_mem,object0) && !map_mem.is_in_map(map0)) continue;
            end
            if (exact && target_kind=="field") begin
                uvm_reg_field f0; if (!$cast(f0,object0) || f0.get_parent()!=forced_reg) continue;
            end else if (exact && target_kind=="reg") begin
                uvm_reg_field f1; uvm_mem m1;
                if (obj_kind=="field") begin if (!$cast(f1,object0) || f1.get_parent()!=forced_reg) continue; end
                else continue;
            end else if (exact && target_kind=="mem") begin
                if (obj_name!=target) continue;
            end else begin
                if (target==root_name) begin
                    if (!has_prefix(obj_name,{root_name,"."})) continue;
                end else if (!has_prefix(obj_name,{target,"."}) && obj_name!=target) continue;
            end
            if (!add_candidate(obj_name,obj_kind,object0,why)) begin detail=why; code=AIP_RAL_CODE_CONFIG_ERROR; return 0; end
        end
        if (leaves.size()==0) begin detail="target has no physical register fields or memories"; code=AIP_RAL_CODE_BAD_ARGS; return 0; end
        if (!state.commit_inventory(why)) begin detail=why; code=AIP_RAL_CODE_CONFIG_ERROR; return 0; end
        return 1;
    endfunction

    local function void finish(aip_ral_runner_leaf leaf0, aip_ral_leaf_status_e leaf_status,
                               aip_ral_code_e code0, string reason0);
        string why;
        leaf0.id=leaf0.id;
        void'(state.finish_leaf(leaf0.id,leaf_status,code0,why));
        if (reason0!="") begin
            `uvm_info("AIP_RAL_LEAF", $sformatf("leaf=%s status=%s reason=%s",
                leaf0.canonical,aip_ral_names::leaf(leaf_status),reason0),UVM_LOW)
        end
    endfunction

    local task test_field(aip_ral_runner_leaf leaf0);
        uvm_reg_field field0; string access0,why; uvm_status_e st;
        uvm_reg_data_t baseline,got,all1,pattern,bitmask;
        int unsigned width0;
        if (!$cast(field0,leaf0.object0)) begin finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_CONFIG_ERROR,"field cast failed"); return; end
        if (svc.is_excluded(field0,why)) begin finish(leaf0,AIP_RAL_LEAF_EXCLUDED,AIP_RAL_CODE_NONE,why); return; end
        access0=field0.get_access(map0); width0=field0.get_n_bits(); all1=mask(width0);
        if (access0!="RW" || field0.is_volatile()) begin
            finish(leaf0,AIP_RAL_LEAF_UNTESTABLE,AIP_RAL_CODE_UNTESTABLE,
                   access0=="RW" ? "volatile field requires quiesce contract" : "policy requires raw observer"); return;
        end
        field0.read(st,baseline,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK) begin finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"baseline read failed"); return; end
        any_write=1;
        field0.write(st,'0,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"zero write failed"); return; end
        field0.read(st,got,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK || got!==0) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"zero pattern mismatch"); return; end
        field0.write(st,all1,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"one write failed"); return; end
        field0.read(st,got,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK || got!==all1) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"one pattern mismatch"); return; end
        // 对每个有效位执行walking-1和walking-0；移位使用目标数据类型，避免
        // 32-bit unsized literal在128-bit模型中截断。
        for (int b=0;b<width0;b++) begin
            bitmask=uvm_reg_data_t'(1)<<b;
            pattern=bitmask;
            field0.write(st,pattern,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"walking-1 write failed"); return; end
            field0.read(st,got,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK || got!==pattern) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"walking-1 mismatch"); return; end
            pattern=all1 ^ bitmask;
            field0.write(st,pattern,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"walking-0 write failed"); return; end
            field0.read(st,got,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK || got!==pattern) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"walking-0 mismatch"); return; end
        end
        field0.write(st,baseline,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_RESTORE_ERROR,"field restore write failed"); return; end
        field0.read(st,got,UVM_FRONTDOOR,map0,parent);
        if (st!=UVM_IS_OK || got!==baseline) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_RESTORE_ERROR,"field restore mismatch"); return; end
        finish(leaf0,AIP_RAL_LEAF_PASS,AIP_RAL_CODE_NONE,"");
        aip_activity::tick();
    endtask

    local function void memory_indices(uvm_mem mem0, ref longint unsigned indexes[$]);
        longint unsigned depth=mem0.get_size();
        indexes.delete();
        if (mem_mode==AIP_RAL_MEM_ALL || depth<=16) begin
            for (longint unsigned i=0;i<depth;i++) indexes.push_back(i);
        end else begin
            indexes.push_back(0); indexes.push_back(depth-1);
            for (longint unsigned step=1;step<depth;step<<=1) begin
                if (step<depth) indexes.push_back(step);
                if (depth-1>=step) indexes.push_back(depth-1-step);
            end
            // deterministic ascending order and duplicate removal
            for (int i=0;i<indexes.size();i++) for (int j=i+1;j<indexes.size();j++)
                if (indexes[j]<indexes[i]) begin longint unsigned t=indexes[i]; indexes[i]=indexes[j]; indexes[j]=t; end
            for (int i=indexes.size()-1;i>0;i--) if (indexes[i]==indexes[i-1]) indexes.delete(i);
        end
    endfunction

    local task test_memory(aip_ral_runner_leaf leaf0);
        uvm_mem mem0; string access0,why; uvm_status_e st;
        uvm_reg_data_t baseline,got,all1,pattern,bitmask;
        longint unsigned indexes[$];
        if (!$cast(mem0,leaf0.object0)) begin finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_CONFIG_ERROR,"memory cast failed"); return; end
        if (svc.is_excluded(mem0,why)) begin finish(leaf0,AIP_RAL_LEAF_EXCLUDED,AIP_RAL_CODE_NONE,why); return; end
        access0=mem0.get_access(map0); all1=mask(mem0.get_n_bits());
        if (access0!="RW") begin finish(leaf0,AIP_RAL_LEAF_UNTESTABLE,AIP_RAL_CODE_UNTESTABLE,"memory policy requires raw observer"); return; end
        memory_indices(mem0,indexes); state.memory_entries_tested+=indexes.size();
        foreach (indexes[i]) begin
            mem0.read(st,indexes[i],baseline,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"memory baseline read failed"); return; end
            any_write=1; mem0.write(st,indexes[i],'0,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"memory zero write failed"); return; end
            mem0.read(st,indexes[i],got,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK || got!==0) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"memory zero mismatch"); return; end
            mem0.write(st,indexes[i],all1,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"memory one write failed"); return; end
            mem0.read(st,indexes[i],got,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK || got!==all1) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"memory one mismatch"); return; end
            for (int b=0;b<mem0.get_n_bits();b++) begin
                bitmask=uvm_reg_data_t'(1)<<b;
                pattern=bitmask;
                mem0.write(st,indexes[i],pattern,UVM_FRONTDOOR,map0,parent);
                if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"memory walking-1 write failed"); return; end
                mem0.read(st,indexes[i],got,UVM_FRONTDOOR,map0,parent);
                if (st!=UVM_IS_OK || got!==pattern) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"memory walking-1 mismatch"); return; end
                pattern=all1 ^ bitmask;
                mem0.write(st,indexes[i],pattern,UVM_FRONTDOOR,map0,parent);
                if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,"memory walking-0 write failed"); return; end
                mem0.read(st,indexes[i],got,UVM_FRONTDOOR,map0,parent);
                if (st!=UVM_IS_OK || got!==pattern) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,"memory walking-0 mismatch"); return; end
            end
            mem0.write(st,indexes[i],baseline,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_RESTORE_ERROR,"memory restore write failed"); return; end
            mem0.read(st,indexes[i],got,UVM_FRONTDOOR,map0,parent);
            if (st!=UVM_IS_OK || got!==baseline) begin restore_failed=1; finish(leaf0,AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_RESTORE_ERROR,"memory restore mismatch"); return; end
            aip_activity::tick();
        end
        finish(leaf0,AIP_RAL_LEAF_PASS,AIP_RAL_CODE_NONE,"");
    endtask

    task run(string target, string effective_target, output aip_ral_run_state result,
             output aip_ral_code_e code, output string detail);
        string why,root_name,rn; uvm_reg_block root0; aip_ral_test_hook hook0;
        aip_ral_reset_hook reset0; bit ok; bit called[$];
        int dot; uvm_reg_map local_map;
        result=new(); result.is_test=1; result.requested_target=target; result.am="ral";
        result.mem_mode=mem_mode; result.restore_scope=(mem_mode==AIP_RAL_MEM_ALL)?AIP_RAL_SCOPE_ALL:AIP_RAL_SCOPE_SELECTED;
        code=AIP_RAL_CODE_NONE; detail=""; state=result; any_write=0; restore_failed=0;
        if (!build_inventory(target,effective_target,detail,code)) begin
            result.code=code; result.phase=AIP_RAL_PHASE_INVENTORY; result.detail=detail; return;
        end
        result.effective_target=effective_target;
        if (!svc.get_reset_hook(reset0)) begin
            result.record_error(AIP_RAL_CODE_CONFIG_ERROR,AIP_RAL_PHASE_VALIDATE);
            result.phase=AIP_RAL_PHASE_VALIDATE; result.detail="global reset hook is required";
            result.settle_pending(); return;
        end
        // quiesce all roots in registration order; a global reset affects every root.
        for (int r=0;r<svc.get_root_count();r++) begin
            if (!svc.get_root_at(r,rn,root0,hook0)) continue;
            called.push_back(0);
            if (hook0!=null) begin
                hook0.quiesce(root0,ok,why); called[r]=1;
                if (!ok) begin
                    result.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_QUIESCE,rn,r);
                    result.detail=why; result.settle_pending();
                    for (int q=r;q>=0;q--) if (called[q]) begin
                        string resume_why; bit resume_ok; uvm_reg_block rr; aip_ral_test_hook rh; string rname;
                        svc.get_root_at(q,rname,rr,rh); rh.resume(rr,resume_ok,resume_why);
                        if (!resume_ok) result.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_RESUME,rname,q);
                    end
                    return;
                end
            end
        end
        result.reset_started();
        reset0.reset(ok,why);
        if (!ok) begin
            result.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_RESET); result.detail=why;
            result.settle_pending();
        end else begin
            result.reset_succeeded();
            for (int r=0;r<svc.get_root_count();r++) begin
                svc.get_root_at(r,rn,root0,hook0); root0.reset("HARD");
            end
            foreach (leaves[i]) begin
                if (leaves[i].kind=="field") test_field(leaves[i]);
                else test_memory(leaves[i]);
            end
        end
        // 正常和失败路径都逆序恢复；resume失败是命令级错误。
        for (int r=svc.get_root_count()-1;r>=0;r--) if (r<called.size() && called[r]) begin
            string resume_why; bit resume_ok; uvm_reg_block rr; aip_ral_test_hook rh; string rname;
            svc.get_root_at(r,rname,rr,rh); rh.resume(rr,resume_ok,resume_why);
            if (!resume_ok) result.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_RESUME,rname,r);
        end
        result.resumed=1;
        if (restore_failed) begin result.restore=AIP_RAL_RESTORE_FAILED; result.recovery_required=1; end
        else if (any_write) result.restore=AIP_RAL_RESTORE_COMPLETED;
        result.side_effects=AIP_RAL_ONE; result.partial=AIP_RAL_ZERO; result.destructive=1;
        result.settle_pending();
        result.phase=(result.code!=AIP_RAL_CODE_NONE)?AIP_RAL_PHASE_RESUME:AIP_RAL_PHASE_FORMAT;
        code=result.code; detail=result.detail;
    endtask
endclass

class aip_ral_test_sequence extends uvm_sequence #(uvm_sequence_item);
    string target;
    string alias_name="ral";
    aip_ral_mem_mode_e mem_mode;
    aip_ral_service svc;
    aip_ral_owner_token token;
    aip_ral_run_state result;
    aip_ral_code_e code;
    string detail;
    function new(string name="aip_ral_test_sequence"); super.new(name); endfunction
    virtual task body();
        string root_name; int dot; uvm_reg_map map0; aip_ral_test_runner runner;
        dot=aip_str::str_find(target,".");
        root_name=(dot<0)?target:target.substr(0,dot-1);
        void'(svc.get_map(root_name,alias_name,map0));
        runner=new(svc,map0,this,mem_mode);
        runner.run(target,target,result,code,detail);
    endtask
endclass

`endif
