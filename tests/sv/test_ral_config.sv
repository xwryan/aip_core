// RAL fixture/报告底座与配置索引契约测试；不启动 ral_op/ral_test/policy runner。
// env 持有独立四态物理存储，不以 mirror 自证。
`include "aip_core_pkg.sv"
`include "aip_ral_fixture.sv"
package ral_config_test_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import aip_ral_fixture_pkg::*;
    class foundation_reset_hook extends aip_ral_reset_hook;
        int calls;
        // 只检查纯虚接口调用，不把计数stub冒充真实DUT reset验证。
        virtual task reset(output bit ok,output string detail);
            calls++; ok=1; detail="";
        endtask
    endclass
    class foundation_test_hook extends aip_ral_test_hook;
        int quiesces,resumes;
        // 仅作接口调用计数正控。
        virtual task quiesce(uvm_reg_block root,output bit ok,output string detail);
            quiesces++; ok=(root!=null); detail=ok?"":"null root";
        endtask
        virtual task resume(uvm_reg_block root,output bit ok,output string detail);
            resumes++; ok=(root!=null); detail=ok?"":"null root";
        endtask
    endclass
    class foundation_classifier extends aip_ral_response_classifier;
        // null 响应不能冒充已完成。
        virtual function aip_ral_bus_status_e classify(uvm_sequence_item request,
            uvm_sequence_item response,uvm_status_e uvm_status,output string detail);
            if(request!=null && response!=null && uvm_status==UVM_IS_OK) begin detail=""; return AIP_RAL_BUS_OK; end
            detail="unconfirmed transport"; return AIP_RAL_BUS_ERROR;
        endfunction
    endclass
    // 故意安装的用户frontdoor只用于验证validate失败后不冻结、可修正重试。
    class task3_custom_frontdoor extends uvm_reg_frontdoor;
        function new(string name="task3_custom_frontdoor"); super.new(name); endfunction
        virtual task body(); endtask
    endclass
    // raw probe必须运行在真实UVM sequence中，确保parent/grab和driver响应归属正确。
    class task3_raw_sequence extends uvm_sequence #(uvm_sequence_item);
        aip_ral_raw_probe probe;
        uvm_object element;
        bit is_write;
        longint unsigned offset;
        uvm_reg_data_t write_value;
        uvm_status_e status;
        aip_ral_bus_status_e bus_status;
        string detail;
        uvm_reg_data_t read_value;
        function new(string name="task3_raw_sequence"); super.new(name); endfunction
        virtual task body();
            probe.access(element,is_write,offset,write_value,this,status,bus_status,detail,read_value);
        endtask
    endclass
    class ral_foundation_test extends uvm_test;
        `uvm_component_utils(ral_foundation_test)
        aip_ral_fixture_env env;
        int checks,records;
        function new(string name,uvm_component parent); super.new(name,parent); endfunction
        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase); env=new("env",this);
        endfunction
        function void demand(bit condition,string label0);
            if(!condition) `uvm_fatal("RAL_CONFIG_ASSERT",label0)
            checks++;
        endfunction
        // 逐byte检查旧bridge/inject均可接收，记录整行ASCII文本。
        function void record(string label0,string result_text);
            for(int i=0;i<result_text.len();i++) demand((result_text.getc(i)&255)<128 && result_text.getc(i)!=10 && result_text.getc(i)!=13,"ASCII_single_line_wire");
            $fdisplay(records,"%s\t%s",label0,result_text);
        endfunction
        // 格式器必须显式成功且不超过桥接预算。
        function string format0(aip_ral_report report0,bit preflight=0);
            string result_text,why; longint unsigned required0;
            demand(aip_ral_formatter::format_report(report0,preflight,result_text,required0,why)==AIP_RAL_CFG_OK,"format_status");
            demand(why=="" && result_text.len()<=1024,"format_bounded"); return result_text;
        endfunction
        // 引用/UTF8和边界先验检查在任何fixture总线访问之前完成。
        task test_serializer();
            bit ok; string result_text,why,encoded,hostile0;
            int cr_count=0,lf_count=0;
            longint unsigned required0;
            aip_ral_report report0=new();
            result_text=aip_ral_formatter::element("detail=two words",ok);
            demand(ok && result_text=="detail=two\\ words","whole_element_space_quote"); record("QUOTE_SPACE",result_text);
            result_text=aip_ral_formatter::element("",ok); demand(ok && result_text=="{}","empty_element"); record("QUOTE_EMPTY",result_text);
            // 显式构造byte13并核对输入，避免SV不识别\r时实际只测了裸r。
            hostile0={"detail= a {b} \\path [cmd] $x; \"q\"\n",$sformatf("%c",8'd13),"\t中😀"};
            for(int i=0;i<hostile0.len();i++) begin
                if(hostile0.getc(i)==13) cr_count++;
                if(hostile0.getc(i)==10) lf_count++;
            end
            demand(cr_count==1 && lf_count==1,"raw_input_contains_CR_and_LF");
            result_text=aip_ral_formatter::element(hostile0,ok);
            demand(ok,"hostile_unicode_encode"); record("QUOTE_HOSTILE",result_text);
            result_text=aip_ral_formatter::element("detail=é中😀",ok);
            demand(ok && result_text=="detail=\\u00e9\\u4e2d\\ud83d\\ude00","Unicode_codepoints_not_UTF8_Latin1"); record("QUOTE_UTF8",result_text);
            encoded=$sformatf("%c%c",8'hc0,8'haf);
            result_text=aip_ral_formatter::element(encoded,ok); demand(!ok && result_text=="","overlong_UTF8_rejected");
            encoded=$sformatf("%c%c%c",8'hed,8'ha0,8'h80);
            result_text=aip_ral_formatter::element(encoded,ok); demand(!ok && result_text=="","UTF8_surrogate_rejected");
            report0.code=AIP_RAL_CODE_CONFIG_ERROR; report0.phase=AIP_RAL_PHASE_INVENTORY;
            report0.requested_target="soc"; report0.am="ral"; record("PRE_ERROR",format0(report0));
            result_text=format0(report0);
            for(int i=result_text.len()+8;i<1024;i++) report0.detail={report0.detail,"x"};
            demand(aip_ral_formatter::format_report(report0,0,result_text,required0,why)==AIP_RAL_CFG_OK && required0==1024 && result_text.len()==1024,"exact_1024_bytes_not_truncated"); record("EXACT_LIMIT",result_text);
            report0.detail={report0.detail,"x"};
            demand(aip_ral_formatter::format_report(report0,1,result_text,required0,why)==AIP_RAL_CFG_OK && required0==1025,"1025_preflight_fallback"); record("PREFLIGHT",result_text);
            demand(env.driver.addresses.size()==0,"oversize_preflight_zero_DUT_actions");
            report0.side_effects=AIP_RAL_UNKNOWN; report0.partial=AIP_RAL_UNKNOWN;
            report0.restore=AIP_RAL_RESTORE_NOT_GUARANTEED; report0.resumed=0; report0.recovery_required=1;
            demand(aip_ral_formatter::format_report(report0,1,result_text,required0,why)==AIP_RAL_CFG_INVALID && result_text=="","preflight_cannot_erase_dirty_envelope");
            report0.code=AIP_RAL_CODE_WATCHDOG_TIMEOUT; report0.phase=AIP_RAL_PHASE_PARSE; record("RUNTIME_PRE",format0(report0));
            for(int i=0;i<250;i++) report0.detail={report0.detail,"x"};
            report0.is_test=0; report0.code=AIP_RAL_CODE_BUS_ERROR; report0.phase=AIP_RAL_PHASE_ACTION; record("RUNTIME_OP",format0(report0));
            report0.code=AIP_RAL_CODE_POLICY_MISMATCH;
            demand(aip_ral_formatter::format_report(report0,0,result_text,required0,why)==AIP_RAL_CFG_INVALID && result_text=="" && env.driver.addresses.size()==0,"leaf_only_top_code_rejected_zero_action");
            report0.code=AIP_RAL_CODE_BUS_ERROR;
            report0.detail=encoded;
            demand(aip_ral_formatter::format_report(report0,0,result_text,required0,why)==AIP_RAL_CFG_BAD_ARG && result_text=="" && why!="","invalid_text_explicit_status");
        endtask
        // 叶 ID、计数和优先级属于单次 run。
        task test_ledger();
            aip_ral_run_state run0=new(),pass0=new();
            aip_ral_leaf_id_t ids[5],id0;
            string why,result_text; longint unsigned required0;
            aip_ral_report worst=new();
            demand(run0.status()=="ERROR" && !run0.commit_inventory(why) && why!="","empty_inventory_not_PASS");
            for(int i=0;i<5;i++) demand(run0.add_leaf($sformatf("soc.leaf%0d",i),i>=3,ids[i],why) && ids[i]==i+1,"unique_run_leaf_id");
            demand(!run0.add_leaf("soc.leaf0",0,id0,why) && why!="","duplicate_leaf_rejected");
            demand(run0.commit_inventory(why) && run0.total==5 && run0.fields==3 && run0.memories==2,"inventory_commit");
            demand(run0.status()=="ERROR" && !run0.counts_complete(),"PENDING_not_PASS");
            demand(!run0.add_leaf("late",0,id0,why),"no_late_inventory_change");
            demand(!run0.finish_leaf(ids[0],aip_ral_leaf_status_e'(99),AIP_RAL_CODE_NONE,why) && why!="","invalid_leaf_enum_rejected");
            demand(run0.finish_leaf(ids[3],AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BACKDOOR_ERROR,why),"late_case_error");
            demand(run0.finish_leaf(ids[2],AIP_RAL_LEAF_FAIL,AIP_RAL_CODE_POLICY_MISMATCH,why),"leaf_failure");
            demand(run0.finish_leaf(ids[0],AIP_RAL_LEAF_ERROR,AIP_RAL_CODE_BUS_ERROR,why),"earlier_case_error");
            demand(run0.first=="soc.leaf0" && run0.first_code==AIP_RAL_CODE_BUS_ERROR,"stable_case_and_severity_priority");
            demand(run0.finish_leaf(ids[1],AIP_RAL_LEAF_EXCLUDED,AIP_RAL_CODE_NONE,why),"explicit_exclusion");
            run0.settle_pending();
            demand(run0.counts_complete() && run0.errors==2 && run0.failed==1 && run0.excluded==1 && run0.untestable==1 && run0.status()=="FAIL","leaf_count_conservation");
            demand(!run0.finish_leaf(ids[0],AIP_RAL_LEAF_PASS,AIP_RAL_CODE_NONE,why) && run0.errors==2,"double_finalize_preserves_counts");
            run0.requested_target="soc"; run0.effective_target="soc"; run0.am="ral"; record("LEAF_FAIL",format0(run0));
            demand(run0.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_RESUME,"z",3),"late_global_error");
            demand(run0.record_error(AIP_RAL_CODE_CANCELLED,AIP_RAL_PHASE_RESET,"z",3),"earlier_phase_error");
            demand(run0.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_QUIESCE,"b",3),"earliest_phase_error");
            demand(run0.record_error(AIP_RAL_CODE_CONFIG_ERROR,AIP_RAL_PHASE_QUIESCE,"a",1),"same_phase_root_order");
            demand(run0.code==AIP_RAL_CODE_CONFIG_ERROR && run0.phase==AIP_RAL_PHASE_QUIESCE && run0.global_errors==4 && run0.status()=="ERROR","global_priority_preserves_leaf_counts");
            demand(!run0.record_error(AIP_RAL_CODE_HOOK_ERROR,AIP_RAL_PHASE_LEDGER) && run0.global_errors==4,"reserved_phase_unused");
            demand(!run0.reset_succeeded(),"performed_requires_attempt"); run0.reset_started(); demand(run0.destructive && !run0.reset_performed,"attempt_marks_destructive");
            demand(run0.reset_succeeded(),"reset_success_marker"); run0.partial=AIP_RAL_ONE; run0.restore=AIP_RAL_RESTORE_FAILED; run0.resumed=0; run0.recovery_required=1;
            for(int i=0;i<1100;i++) run0.detail={run0.detail,"中"}; record("RUNTIME_POST",format0(run0));
            demand(pass0.add_leaf("soc.a",0,id0,why) && pass0.commit_inventory(why),"independent_run_inventory");
            demand(pass0.finish_leaf(id0,AIP_RAL_LEAF_PASS,AIP_RAL_CODE_NONE,why) && pass0.status()=="PASS","completed_leaf_PASS");
            pass0.requested_target="soc.a"; pass0.effective_target="soc.a"; pass0.am="ral"; record("PASS",format0(pass0));
            // 此不守恒输入只校准最大位数预算，不作为可接受报告发布。
            worst.inventory_complete=1; worst.total='1; worst.fields='1; worst.memories='1;
            worst.passed='1; worst.excluded='1; worst.failed='1; worst.errors='1; worst.untestable='1;
            worst.memory_entries_tested='1; worst.write_once_consumed='1; worst.not_applicable='1; worst.global_errors='1;
            worst.mem_mode=AIP_RAL_MEM_ADDRESS_LINE; worst.restore_scope=AIP_RAL_SCOPE_SELECTED;
            worst.code=AIP_RAL_CODE_RECOVERY_REQUIRED; worst.phase=AIP_RAL_PHASE_RESET_OBSERVE;
            worst.side_effects=AIP_RAL_UNKNOWN; worst.partial=AIP_RAL_UNKNOWN; worst.restore=AIP_RAL_RESTORE_NOT_GUARANTEED;
            result_text=aip_ral_formatter::fallback(worst,'1,0); demand(result_text.len()<=1024,"worst_uint64_fallback_bound");
            demand(!worst.counts_complete() && aip_ral_formatter::format_report(worst,0,result_text,required0,why)==AIP_RAL_CFG_INVALID,"overflow_not_fake_conservation");
        endtask
        // 物理word固定地址oracle与故障注入证明夹具已接入，不复用mirror。
        task test_fixture();
            uvm_status_e status0; uvm_reg_data_t pattern,value;
            aip_ral_logic_t four_state;
            int beats=`UVM_REG_DATA_WIDTH/32;
            foundation_reset_hook reset0=new(); foundation_test_hook hook0=new();
            foundation_classifier classifier0=new(); uvm_sequence_item item0=new(); bit ok; string why;
            four_state='0; four_state[17]=1'bx; four_state[39]=1'bz;
            demand($bits(aip_ral_vec_t)==1024 && $bits(four_state)==1024 && four_state[17]===1'bx && four_state[39]===1'bz && AIP_RAL_DATA_BITS==`UVM_REG_DATA_WIDTH,"wide_two_and_four_state_types");
            demand(env.memory.get_n_bits()==`UVM_REG_DATA_WIDTH && env.register0.get_n_bits()==`UVM_REG_DATA_WIDTH,"real_generated_width");
            for(int i=0;i<beats;i++) pattern|=uvm_reg_data_t'(32'h10203040+i)<<(32*i);
            env.driver.clear_trace(); env.memory.write(status0,0,pattern,UVM_FRONTDOOR,env.model.default_map);
            demand(status0==UVM_IS_OK && env.driver.addresses.size()==beats,"real_memory_write");
            for(int i=0;i<beats;i++) demand(env.driver.addresses[i]=='h300+i && env.driver.storage['h300+i]===32'h10203040+i,"independent_word_storage_oracle");
            env.memory.read(status0,0,value,UVM_FRONTDOOR,env.model.default_map); demand(status0==UVM_IS_OK && value==pattern,"real_memory_read");
            env.driver.read_corrupt=1; env.memory.read(status0,0,value,UVM_FRONTDOOR,env.model.default_map);
            demand(status0==UVM_IS_OK && value!=pattern,"bad_DUT_read_detected_by_oracle");
            env.driver.read_corrupt=0; env.driver.read_x=1; env.driver.clear_trace(); env.memory.read(status0,0,value,UVM_FRONTDOOR,env.model.default_map);
            demand(status0==UVM_NOT_OK && env.adapter.unknown_count==1 && env.driver.addresses.size()==1,"unknown_before_two_state_first_error"); env.driver.read_x=0;
            reset0.reset(ok,why); demand(ok && why=="" && reset0.calls==1,"reset_hook_interface");
            hook0.quiesce(env.model,ok,why); demand(ok && why=="","quiesce_hook_interface"); hook0.resume(env.model,ok,why); demand(ok && why=="" && hook0.resumes==1,"resume_hook_interface");
            demand(classifier0.classify(item0,item0,UVM_IS_OK,why)==AIP_RAL_BUS_OK && why=="","classifier_positive");
            demand(classifier0.classify(item0,null,UVM_IS_OK,why)==AIP_RAL_BUS_ERROR && why!="","classifier_null_response_negative");
        endtask
        // 先验证公共注册 API 的状态契约，再检查冻结后的名称索引；不发起 DUT 访问，也不以 mirror 为 oracle。
        task test_config_api();
            aip_ral_service svc;
            aip_ral_cfg_status_e cfg_st;
            string detail,kind;
            uvm_object object0;
            uvm_reg reg0;
            uvm_reg_field field0;
            uvm_mem mem0;
            uvm_reg_map map0;
            uvm_reg_block root0;
            aip_ral_test_hook hook1;
            aip_ral_reset_hook reset1;
            aip_ral_response_classifier classifier1;
            string root_name0;
            foundation_reset_hook reset0=new();
            foundation_test_hook hook0=new();
            foundation_classifier classifier0=new();
            aip_ral_mem_beat_order_e test_order;
            string order_arg;
            svc=aip_ral_service::get();
            cfg_st=svc.register_root("",env.model,env.model.default_map,detail);
            demand(cfg_st==AIP_RAL_CFG_BAD_ARG && detail!="","config_null_name_rejected");
            cfg_st=svc.set_test_hook("missing",hook0,detail);
            demand(cfg_st==AIP_RAL_CFG_INVALID && detail!="","unknown_root_hook_rejected");
            cfg_st=svc.register_root("soc",env.model,env.model.default_map,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","root_registered");
            cfg_st=svc.register_root("soc",env.model,env.model.default_map,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","identical_root_is_idempotent");
            cfg_st=svc.register_map("soc","ral",env.model.default_map,detail);
            demand(cfg_st==AIP_RAL_CFG_DUPLICATE && detail!="","reserved_map_alias_rejected");
            cfg_st=svc.register_map("soc","apb0",env.model.default_map,detail);
            demand(cfg_st==AIP_RAL_CFG_DUPLICATE && detail!="","physical_map_alias_collision");
            cfg_st=svc.set_reset_hook(reset0,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","reset_hook_registered");
            cfg_st=svc.set_reset_hook(reset0,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","identical_reset_hook_is_idempotent");
            cfg_st=svc.set_test_hook("soc",hook0,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","test_hook_registered");
            cfg_st=svc.set_response_classifier("soc","ral",classifier0,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","classifier_registered");
            test_order=AIP_RAL_MSW_FIRST;
            if ($value$plusargs("RAL_MEM_ORDER=%s",order_arg) && order_arg=="lsw") test_order=AIP_RAL_LSW_FIRST;
            cfg_st=svc.set_mem_beat_order(test_order,detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="" && svc.get_mem_beat_order()==test_order,"memory_order_registered");
            cfg_st=svc.exclude_from_test(env.model.LEAF.WIDE.get_field_by_name("DATA"),"configuration-only field",detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","field_exclusion_registered");
            cfg_st=svc.exclude_from_test(env.model.LEAF.WIDE.get_field_by_name("DATA"),"configuration-only field",detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","identical_exclusion_is_idempotent");
            cfg_st=svc.exclude_from_test(env.model.LEAF.WIDE.get_field_by_name("DATA"),"different reason",detail);
            demand(cfg_st==AIP_RAL_CFG_DUPLICATE && detail!="","conflicting_exclusion_rejected");
            cfg_st=svc.exclude_from_test(env.model.LEAF.VIEW,"virtual register",detail);
            demand(cfg_st==AIP_RAL_CFG_BAD_ARG && detail!="","vreg_exclusion_rejected");
            begin
                task3_custom_frontdoor custom_frontdoor0=new();
                env.memory.set_frontdoor(custom_frontdoor0,env.model.default_map);
                cfg_st=svc.validate(detail);
                demand(cfg_st==AIP_RAL_CFG_UNSUPPORTED && detail!="" && !svc.is_frozen(),"custom_frontdoor_atomic_reject");
                env.memory.set_frontdoor(null,env.model.default_map);
            end
            cfg_st=svc.validate(detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="" && svc.is_frozen(),"atomic_validate_freezes");
            cfg_st=svc.validate(detail);
            demand(cfg_st==AIP_RAL_CFG_OK && detail=="","validate_is_idempotent");
            begin
                uvm_status_e fd_status;
                uvm_reg_data_t fd_pattern,fd_value;
                int fd_beats=`UVM_REG_DATA_WIDTH/32;
                fd_pattern='0;
                for (int fd_i=0; fd_i<fd_beats; fd_i++)
                    fd_pattern |= uvm_reg_data_t'(32'h5566_0000+fd_i) << (32*fd_i);
                env.driver.clear_trace();
                env.memory.write(fd_status,0,fd_pattern,UVM_FRONTDOOR,env.model.default_map);
                demand(fd_status==UVM_IS_OK && env.driver.addresses.size()==fd_beats,"memory_frontdoor_write");
                for (int fd_i=0; fd_i<fd_beats; fd_i++) begin
                    int expected_idx=(test_order==AIP_RAL_MSW_FIRST) ? fd_beats-1-fd_i : fd_i;
                    demand(env.driver.addresses[fd_i]=='h300+expected_idx,
                           $sformatf("memory_%s_address_order idx=%0d actual=%h",
                                     test_order==AIP_RAL_MSW_FIRST ? "msw" : "lsw",fd_i,env.driver.addresses[fd_i]));
                    demand(env.driver.data_trace[fd_i]===32'h5566_0000+expected_idx,
                           $sformatf("memory_%s_data_order idx=%0d actual=%h expected=%h",
                                     test_order==AIP_RAL_MSW_FIRST ? "msw" : "lsw",fd_i,
                                     env.driver.data_trace[fd_i],32'h5566_0000+expected_idx));
                end
                env.memory.read(fd_status,0,fd_value,UVM_FRONTDOOR,env.model.default_map);
                demand(fd_status==UVM_IS_OK && fd_value==fd_pattern,"memory_frontdoor_read");
            end
            begin
                task3_raw_sequence raw_seq;
                raw_seq=new("raw_reg_write");
                raw_seq.probe=new(env.model.default_map);
                raw_seq.element=env.register0;
                raw_seq.is_write=1'b1;
                raw_seq.write_value=uvm_reg_data_t'('h1234);
                raw_seq.start(env.sqr);
                demand(raw_seq.status==UVM_IS_OK && raw_seq.bus_status==AIP_RAL_BUS_OK &&
                       raw_seq.detail=="","raw_probe_register_write");
                raw_seq=new("raw_reg_read");
                raw_seq.probe=new(env.model.default_map);
                raw_seq.element=env.register0;
                raw_seq.is_write=1'b0;
                raw_seq.start(env.sqr);
                demand(raw_seq.status==UVM_IS_OK && raw_seq.bus_status==AIP_RAL_BUS_OK &&
                       raw_seq.read_value==uvm_reg_data_t'('h1234),"raw_probe_register_read");
            end
            begin
                aip_ral_raw_observer observer0=new();
                aip_ral_logic_t observed0;
                bit known0,four_state0;
                uvm_status_e observer_status;
                aip_ral_code_e observer_code;
                observer_code=observer0.capability(env.register0,0,four_state0,detail);
                demand(observer_code==AIP_RAL_CODE_UNTESTABLE && !four_state0 && detail!="",
                       "missing_hdl_is_untestable");
                observer0.read(env.register0,0,observed0,known0,observer_status,detail);
                demand(observer_status==UVM_NOT_OK && !known0 && detail!="",
                       "missing_hdl_observation_rejected");
            end
            demand(svc.lookup("soc.LEAF.WIDE",object0,kind) && kind=="reg" && $cast(reg0,object0) && reg0==env.register0,"canonical_register_index");
            demand(svc.lookup("soc.LEAF.WIDE.DATA",object0,kind) && kind=="field" && $cast(field0,object0),"canonical_field_index");
            demand(svc.lookup("soc.LEAF.RAM",object0,kind) && kind=="mem" && $cast(mem0,object0) && mem0==env.memory,"canonical_memory_index");
            demand(svc.lookup("soc.LEAF.VIEW",object0,kind) && kind=="vreg","canonical_vreg_index");
            demand(svc.lookup("soc.LEAF.VIEW.LODATA",object0,kind) && kind=="vfield","canonical_vfield_index");
            demand(!svc.lookup("soc.LEAF.NOT_FOUND",object0,kind),"unknown_canonical_rejected");
            cfg_st=svc.set_mem_beat_order(AIP_RAL_MSW_FIRST,detail);
            demand(cfg_st==AIP_RAL_CFG_FROZEN && detail!="","frozen_config_rejected");
            demand(svc.get_map("soc","ral",map0) && map0==env.model.default_map,"default_map_alias_resolved");
            demand(svc.get_root_count()==1 && svc.get_root_at(0,root_name0,root0,hook1) &&
                   root_name0=="soc" && root0==env.model && hook1==hook0,"root_readback");
            demand(svc.get_reset_hook(reset1) && reset1==reset0,"reset_hook_readback");
            demand(svc.get_response_classifier("soc","ral",classifier1) && classifier1==classifier0,"classifier_readback");
        endtask
        // 只有全部断言通过才关闭文件并发布底座完成标记。
        virtual task run_phase(uvm_phase phase);
            phase.raise_objection(this); records=$fopen("ral_records.txt","w"); demand(records!=0,"records_open");
            test_serializer(); test_ledger(); test_fixture(); test_config_api(); $fclose(records);
            $display("RAL_FOUNDATION_COMPLETE width=%0d checks=%0d",`UVM_REG_DATA_WIDTH,checks); phase.drop_objection(this);
        endtask
    endclass
endpackage
module test_ral_config;
    import uvm_pkg::*;
    import ral_config_test_pkg::*;
    initial run_test("ral_foundation_test");
endmodule
