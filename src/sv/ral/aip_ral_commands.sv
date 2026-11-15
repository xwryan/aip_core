// 命名 RAL 访问命令：语法层保持很薄，实际对象访问由 service 完成。
`ifndef AIP_RAL_COMMANDS_SV
`define AIP_RAL_COMMANDS_SV

class aip_ral_op_sequence extends uvm_sequence #(uvm_sequence_item);
    string operation,canonical,root_name,alias_name;
    bit has_index,has_value;
    longint unsigned index;
    uvm_reg_data_t input_value;
    uvm_status_e status;
    aip_ral_code_e code;
    uvm_reg_data_t result_value;
    int unsigned width;
    string kind,detail;
    function new(string name="aip_ral_op_sequence"); super.new(name); endfunction
    virtual task body();
        aip_ral_service::get().execute_op(operation,canonical,root_name,alias_name,
                                          has_index,index,has_value,input_value,this,
                                          status,code,result_value,width,kind,detail);
    endtask
endclass

class aip_ral_command_util;
    static function string_darray_t split_tokens(string args);
        string_darray_t result;
        string items[$];
        int pos=0,start_pos;
        while (pos<args.len()) begin
            while (pos<args.len() && (aip_cmd::is_arg_space(args[pos]) || args[pos]==",")) pos++;
            if (pos>=args.len()) break;
            start_pos=pos; pos=aip_cmd::arg_token_end(args,start_pos);
            if (pos<=start_pos) break;
            begin
                string tok=args.substr(start_pos,pos-1);
                if (tok.len()>=2 && tok[0]=="{" && tok[tok.len()-1]=="}")
                    tok=tok.substr(1,tok.len()-2);
                items.push_back(tok);
            end
        end
        result=new[items.size()];
        foreach(items[i]) result[i]=items[i];
        return result;
    endfunction

    static function bit contains_unknown_digit(string token);
        string low=aip_str::lower(token);
        for (int i=0;i<low.len();i++) begin
            byte c=low[i];
            // x in the C-style 0x prefix is syntax, not unknown data.
            if ((c=="x" && !(i==1 && low[0]=="0")) || c=="z" || c=="?") return 1;
        end
        return 0;
    endfunction

    static function bit parse_value(string token, int unsigned width,
                                    output uvm_reg_data_t value,
                                    output aip_ral_code_e code, output string detail);
        aip_vec_t vec;
        int explicit_width;
        bit negative;
        value='0; code=AIP_RAL_CODE_NONE; detail="";
        if (token=="") begin code=AIP_RAL_CODE_BAD_ARGS; detail="empty value"; return 0; end
        if (contains_unknown_digit(token)) begin code=AIP_RAL_CODE_X_DATA; detail="X/Z/? data is not accepted"; return 0; end
        if (!aip_str::str_to_vec(token,vec,explicit_width,negative)) begin
            code=AIP_RAL_CODE_BAD_ARGS; detail="invalid numeric literal"; return 0;
        end
        if (negative) begin code=AIP_RAL_CODE_BAD_ARGS; detail="negative RAL values are not accepted"; return 0; end
        if (width==0 || width>AIP_RAL_DATA_BITS) begin code=AIP_RAL_CODE_UNSUPPORTED; detail="object width is unsupported"; return 0; end
        if ((vec >> width) != 0 || (explicit_width!=0 && explicit_width>width)) begin
            code=AIP_RAL_CODE_WIDTH_OVERFLOW; detail="value exceeds object width"; return 0;
        end
        value=uvm_reg_data_t'(vec); return 1;
    endfunction

    static function string value_text(uvm_reg_data_t value, int unsigned width);
        string s;
        int digits=(width+3)/4;
        s=$sformatf("%0h",value);
        while (s.len()<digits) s={"0",s};
        return {"0x",s};
    endfunction

    static function string error_text(aip_ral_code_e code, string target, string detail);
        string result;
        result={"ERROR code=",aip_ral_names::code(code)," target=",target};
        if (detail!="") result={result," detail=",detail};
        return result;
    endfunction
endclass

class aip_cmd_ral_op extends aip_cmd_user_task;
    task cmd_exec();
        string_darray_t tok;
        string operation,target,alias_name="ral",root_name;
        bit has_index=0,has_value=0,am_seen=0;
        string positional[$];
        longint unsigned index;
        uvm_reg_data_t input_value;
        aip_ral_code_e parse_code;
        string parse_detail;
        aip_ral_service svc=aip_ral_service::get();
        aip_ral_owner_token token;
        string gate_text,canonical_detail;
        aip_ral_op_sequence seq;
        uvm_object object0;
        uvm_reg reg0;
        uvm_reg_field field0;
        uvm_mem mem0;
        uvm_vreg vreg0;
        uvm_vreg_field vfield0;
        int unsigned object_width;
        uvm_sequencer_base sequencer;
        uvm_reg_map map0;
        int dot;
        bit indexed_kind;
        int expected_pos;
        int iw;
        bit ineg;
        aip_vec_t iv;
        string value_token;
        tok=aip_ral_command_util::split_tokens(this.args_in);
        if (tok.size()<2) begin this.status=1; this.result_out="ERROR code=BAD_ARGS target=<missing> detail=expected operation and target"; return; end
        operation=aip_str::lower(tok[0]); target=tok[1];
        if (operation!="read" && operation!="write") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"operation must be read or write"); return; end
        if (target=="") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"target is required"); return; end
        // Optional am= is the only key/value argument in the command grammar. Keep
        // positional values until the indexed/non-indexed object kind is known.
        for (int i=2;i<tok.size();i++) begin
            if (tok[i].len()>3 && (tok[i][0]=="a" || tok[i][0]=="A") &&
                (tok[i][1]=="m" || tok[i][1]=="M") && tok[i][2]=="=") begin
                if (am_seen) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"duplicate am"); return; end
                am_seen=1;
                alias_name=tok[i].substr(3,tok[i].len()-1);
                if (alias_name=="") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"empty am"); return; end
            end else positional.push_back(tok[i]);
        end
        // Gate/lifecycle check precedes object resolution. A direct command call without an
        // aip_cmd execution context is rejected by service.acquire rather than touching DUT.
        if (svc.recovery_gate(0,gate_text)) begin this.status=1; this.result_out=gate_text; return; end
        if (svc.acquire(0,token,gate_text)!=AIP_RAL_CODE_NONE) begin this.status=1; this.result_out=gate_text!=""?gate_text:"ERROR code=BUSY command=ral_op"; return; end
        dot=aip_str::str_find(target,".");
        if (dot<=0) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"target must be root-qualified"); void'(svc.release_owner(token)); return; end
        root_name=target.substr(0,dot-1);
        seq=new(); seq.operation=operation; seq.canonical=target; seq.root_name=root_name; seq.alias_name=alias_name;
        if (!svc.is_frozen()) begin
            aip_ral_cfg_status_e vst=svc.validate(canonical_detail);
            if (vst!=AIP_RAL_CFG_OK) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_CONFIG_ERROR,target,canonical_detail); void'(svc.release_owner(token)); return; end
        end
        if (!svc.lookup(target,object0,seq.kind)) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_NOT_FOUND,target,"RAL object was not found"); void'(svc.release_owner(token)); return; end
        if ($cast(reg0,object0)) object_width=reg0.get_n_bits();
        else if ($cast(field0,object0)) object_width=field0.get_n_bits();
        else if ($cast(mem0,object0)) object_width=mem0.get_n_bits();
        else if ($cast(vreg0,object0)) object_width=vreg0.get_n_bytes()*8;
        else if ($cast(vfield0,object0)) object_width=vfield0.get_n_bits();
        else object_width=0;
        indexed_kind=(seq.kind=="mem" || seq.kind=="vreg" || seq.kind=="vfield");
        expected_pos=(indexed_kind ? (operation=="write" ? 2 : 1) : (operation=="write" ? 1 : 0));
        if (positional.size()!=expected_pos) begin
            this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"wrong positional argument count"); void'(svc.release_owner(token)); return;
        end
        if (indexed_kind) begin
            if (!aip_str::str_to_vec(positional[0],iv,iw,ineg) || ineg || (iv>>64)!=0) begin
                this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"invalid index"); void'(svc.release_owner(token)); return;
            end
            index=longint'(iv); has_index=1;
        end
        if (operation=="write") begin
            value_token=positional[indexed_kind ? 1 : 0];
            has_value=1;
            if (!aip_ral_command_util::parse_value(value_token,object_width,input_value,parse_code,parse_detail)) begin
                this.status=1; this.result_out=aip_ral_command_util::error_text(parse_code,target,parse_detail); void'(svc.release_owner(token)); return;
            end
        end
        if (!svc.get_map(root_name,alias_name,map0)) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_NOT_IN_MAP,target,"map alias was not found"); void'(svc.release_owner(token)); return; end
        sequencer=map0.get_root_map().get_sequencer();
        if (sequencer==null) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_CONFIG_ERROR,target,"map has no sequencer"); void'(svc.release_owner(token)); return; end
        seq.has_index=has_index; seq.index=index; seq.has_value=has_value; seq.input_value=input_value;
        seq.start(sequencer);
        void'(svc.release_owner(token));
        if (seq.code!=AIP_RAL_CODE_NONE || seq.status!=UVM_IS_OK) begin
            this.status=1; this.result_out=aip_ral_command_util::error_text(seq.code,target,seq.detail); return;
        end
        this.status=0;
        if (operation=="read") this.result_out={"OK op=read target=",target," kind=",seq.kind,
            $sformatf(" width=%0d am=%s value=%s",seq.width,alias_name,
                      aip_ral_command_util::value_text(seq.result_value,seq.width))};
        else this.result_out={"OK op=write target=",target," kind=",seq.kind,
            $sformatf(" width=%0d am=%s value=%s",seq.width,alias_name,
                      aip_ral_command_util::value_text(seq.result_value,seq.width))};
    endtask
    function new(string name="ral_op"); super.new(name); endfunction
    static aip_cmd_ral_op __inst=new("ral_op");
endclass

class aip_cmd_ral_test extends aip_cmd_user_task;
    task cmd_exec();
        string_darray_t tok;
        string target,operation,alias_name="ral",suite="policy",mem_text="address-line";
        bit am_seen=0,suite_seen=0,mem_seen=0;
        aip_ral_mem_mode_e mem_mode=AIP_RAL_MEM_ADDRESS_LINE;
        aip_ral_service svc=aip_ral_service::get();
        aip_ral_owner_token token;
        string gate_text,detail,root_name,format_why,reply;
        aip_ral_cfg_status_e cfg;
        aip_ral_code_e code;
        aip_ral_run_state report;
        aip_ral_test_sequence seq;
        uvm_reg_map map0;
        uvm_sequencer_base sequencer;
        aip_ral_leaf_id_t no_active[$];
        int dot; longint unsigned required_bytes;
        tok=aip_ral_command_util::split_tokens(this.args_in);
        target=(tok.size()>1)?tok[1]:"<missing>";
        if (tok.size()<2 || aip_str::lower(tok[0])!="run") begin
            this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"syntax is ral_test run target"); return;
        end
        for (int i=2;i<tok.size();i++) begin
            if (tok[i].len()>3 && tok[i].substr(0,1)=="am" && tok[i][2]=="=") begin
                if (am_seen) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"duplicate am"); return; end
                am_seen=1; alias_name=tok[i].substr(3,tok[i].len()-1);
                if (alias_name=="") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"empty am"); return; end
            end else if (tok[i].len()>6 && tok[i].substr(0,4)=="suite" && tok[i][5]=="=") begin
                if (suite_seen) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"duplicate suite"); return; end
                suite_seen=1; suite=tok[i].substr(6,tok[i].len()-1);
            end else if (tok[i].len()>4 && tok[i].substr(0,2)=="mem" && tok[i][3]=="=") begin
                if (mem_seen) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"duplicate mem"); return; end
                mem_seen=1; mem_text=tok[i].substr(4,tok[i].len()-1);
            end else begin
                this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"unknown option"); return;
            end
        end
        if (suite!="policy") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"suite must be policy"); return; end
        if (mem_text=="all") mem_mode=AIP_RAL_MEM_ALL;
        else if (mem_text!="address-line") begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_BAD_ARGS,target,"mem must be address-line or all"); return; end
        if (svc.recovery_gate(1,gate_text)) begin this.status=1; this.result_out=gate_text; return; end
        if (svc.acquire(1,token,gate_text)!=AIP_RAL_CODE_NONE) begin this.status=1; this.result_out=gate_text!=""?gate_text:"ERROR code=BUSY command=ral_test"; return; end
        dot=aip_str::str_find(target,"."); root_name=(dot<0)?target:target.substr(0,dot-1);
        if (!svc.is_frozen()) begin
            cfg=svc.validate(detail);
            if (cfg!=AIP_RAL_CFG_OK) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_CONFIG_ERROR,target,detail); void'(svc.release_owner(token)); return; end
        end
        if (!svc.get_map(root_name,alias_name,map0)) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_NOT_IN_MAP,target,"map alias was not found"); void'(svc.release_owner(token)); return; end
        sequencer=map0.get_root_map().get_sequencer();
        if (sequencer==null) begin this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_CONFIG_ERROR,target,"map has no sequencer"); void'(svc.release_owner(token)); return; end
        seq=new(); seq.target=target; seq.alias_name=alias_name; seq.svc=svc; seq.token=token; seq.mem_mode=mem_mode;
        seq.start(sequencer);
        report=seq.result;
        if (report==null) begin
            void'(svc.release_owner(token));
            this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_CONFIG_ERROR,target,"runner returned no report"); return;
        end
        report.am=alias_name;
        no_active.delete();
        if (report.phase>=AIP_RAL_PHASE_DISPATCH && report.phase<AIP_RAL_PHASE_NONE)
            void'(svc.publish_state(token,report,no_active,report.phase));
        void'(svc.release_owner(token));
        if (aip_ral_formatter::format_report(report,0,reply,required_bytes,format_why)!=AIP_RAL_CFG_OK) begin
            this.status=1; this.result_out=aip_ral_command_util::error_text(AIP_RAL_CODE_RESULT_TOO_LARGE,target,format_why); return;
        end
        this.status=(report.status()=="PASS")?0:1;
        this.result_out=reply;
    endtask
    function new(string name="ral_test"); super.new(name); endfunction
    static aip_cmd_ral_test __inst=new("ral_test");
endclass

`endif
