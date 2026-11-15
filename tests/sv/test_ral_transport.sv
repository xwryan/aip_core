// tests/sv：Task4逐拍传输永久回归；依赖真实ralgen fixture及AIP package。
// driver持有独立物理存储；测试拥有adapter/sequence配置，禁止用mirror作为数据oracle。
`include "aip_core_pkg.sv"
`include "aip_ral_fixture.sv"
package ral_transport_test_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import aip_ral_fixture_pkg::*;

    // 完成与错误码独立于二态数据；classifier读取真实response的证据。
    class transport_item extends aip_ral_fixture_item;
        int code;
        function new(string name="transport_item"); super.new(name); endfunction
    endclass

    // 特殊parent模板通过标准clone复制；body不会被executor启动。
    class transport_parent extends uvm_sequence #(aip_ral_fixture_item);
        `uvm_object_utils(transport_parent)
        function new(string name="transport_parent"); super.new(name); endfunction
    endclass

    // 每拍检查上下文和response，不允许driver原位成功掩盖独立response故障。
    class transport_adapter extends uvm_reg_adapter;
        uvm_sequence_base caller;
        uvm_object extension;
        int contexts, bad_contexts;
        bit has_x;
        function new(string name="transport_adapter");
            super.new(name); supports_byte_enable=1;
        endfunction
        // get_item必须仍是标准RAL item，并带有原extension及正确parent祖先。
        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            transport_item item=new();
            uvm_reg_item ri=get_item();
            transport_parent typed;
            bit parent_ok;
            if (ri!=null) begin
                if (parent_sequence==null) parent_ok=(ri.parent==caller);
                else parent_ok=$cast(typed,ri.parent) && ri.parent!=parent_sequence &&
                               ri.parent.get_parent_sequence()==caller;
            end
            if (ri!=null && parent_ok && ri.extension==extension) contexts++;
            else bad_contexts++;
            item.op=rw; return item;
        endfunction
        // 在二态转换前检查有效位；故意返回整个word以校准executor末拍mask。
        virtual function void bus2reg(uvm_sequence_item item0,ref uvm_reg_bus_op rw);
            transport_item item;
            if (!$cast(item,item0)) begin rw.status=UVM_NOT_OK; return; end
            rw=item.op;
            if (!item.completed || item.code!=0) begin rw.status=UVM_NOT_OK; return; end
            if (rw.kind==UVM_READ) begin
                for (int b=0;b<rw.n_bits;b++) if ($isunknown(item.sampled[b])) begin
                    rw.status=has_x?UVM_HAS_X:UVM_NOT_OK; return;
                end
                rw.data=item.sampled;
            end
            rw.status=UVM_IS_OK;
        endfunction
    endclass

    // 物理设备只认识请求地址/有效位，不调用RAL地址计算或产品mask函数。
    class transport_driver extends aip_ral_fixture_driver;
        int fail_at=-1, fault_code;
        bit separate, inject_z, response_only;
        function new(string name,uvm_component parent); super.new(name,parent); endfunction
        // request成功而response失败可独立注入，响应沿标准sequence/transaction id路由。
        virtual task run_phase(uvm_phase phase);
            forever begin
                transport_item item,response;
                seq_item_port.get_next_item(req);
                if (!$cast(item,req)) `uvm_fatal("TRANSPORT_TYPE","unexpected item")
                addresses.push_back(item.op.addr); data_trace.push_back(item.op.data);
                enables.push_back(item.op.byte_en); bits_trace.push_back(item.op.n_bits);
                if (!storage.exists(item.op.addr)) storage[item.op.addr]='1;
                item.completed=1;
                if (item.op.kind==UVM_WRITE)
                    for (int b=0;b<item.op.n_bits;b++)
                        if(item.op.byte_en[b/8]) storage[item.op.addr][b]=item.op.data[b];
                item.sampled=storage[item.op.addr];
                if (addresses.size()-1==fail_at && !response_only) begin
                    item.code=fault_code;
                    if (fault_code==0) item.sampled[0]=inject_z?1'bz:1'bx;
                end
                if (separate) begin
                    response=new(); response.op=item.op; response.sampled=item.sampled;
                    response.code=item.code; response.completed=item.completed; response.set_id_info(item);
                    if (response_only && addresses.size()-1==fail_at) response.completed=0;
                    seq_item_port.item_done(response);
                end
                else seq_item_port.item_done();
            end
        endtask
    endclass

    // callback计数验证外层标准memory行为；post必须看到原parent已恢复。
    class transport_callback extends uvm_reg_cbs;
        int pre_count,post_count,bad_parent;
        uvm_sequence_base caller;
        function new(string name="transport_callback"); super.new(name); endfunction
        virtual task pre_read(uvm_reg_item rw); pre_count++; endtask
        virtual task pre_write(uvm_reg_item rw); pre_count++; endtask
        virtual task post_read(uvm_reg_item rw);
            post_count++; if(rw.parent!=caller) bad_parent++;
        endtask
        virtual task post_write(uvm_reg_item rw);
            post_count++; if(rw.parent!=caller) bad_parent++;
        endtask
    endclass

    // 分类只把明确协议code=1当拒绝；code=2和未完成均是基础设施错误。
    class transport_classifier extends aip_ral_response_classifier;
        int calls;
        virtual function aip_ral_bus_status_e classify(uvm_sequence_item request,
            uvm_sequence_item response,uvm_status_e status,output string detail);
            transport_item item;
            calls++; detail="";
            if (!$cast(item,response) || !item.completed) return AIP_RAL_BUS_ERROR;
            if (item.code==1) return AIP_RAL_BUS_ACCESS_REJECT;
            if (item.code==0 && status==UVM_IS_OK) return AIP_RAL_BUS_OK;
            return AIP_RAL_BUS_ERROR;
        endfunction
    endclass

    // 每次操作单独创建parent，使响应队列和生命周期归属可检查。
    class transport_operation extends uvm_sequence #(aip_ral_fixture_item);
        uvm_mem memory0;
        uvm_reg register0;
        uvm_reg_map map0;
        uvm_object extension;
        bit read0,reg0,raw0;
        uvm_reg_data_t value;
        uvm_status_e status;
        aip_ral_raw_probe probe;
        aip_ral_bus_status_e bus_status;
        string detail;
        function new(string name="transport_operation"); super.new(name); endfunction
        // raw显式绕过权限；普通调用使用完整标准callback入口。
        virtual task body();
            if(raw0) probe.access(memory0,!read0,0,value,this,status,bus_status,detail,value);
            else if(reg0) begin
                if(read0) register0.read(status,value,UVM_FRONTDOOR,map0,this,-1,extension);
                else register0.write(status,value,UVM_FRONTDOOR,map0,this,-1,extension);
            end
            else begin
                if(read0) memory0.read(status,0,value,UVM_FRONTDOOR,map0,this,-1,extension);
                else memory0.write(status,0,value,UVM_FRONTDOOR,map0,this,-1,extension);
            end
        endtask
    endclass

    class transport_test extends uvm_test;
        `uvm_component_utils(transport_test)
        ral_sys_aip_fixture model;
        transport_adapter ad;
        transport_driver drv;
        transport_callback cb;
        transport_classifier classifier;
        uvm_sequencer #(aip_ral_fixture_item) sqr;
        aip_ral_mem_frontdoor fd;
        aip_ral_raw_probe probe;
        uvm_sequence_item extension;
        int checks;
        function new(string name,uvm_component parent); super.new(name,parent); endfunction
        // 失败立即终止，完整marker只在所有断言通过后打印。
        function void demand(bit ok,string label0);
            if(!ok) `uvm_fatal("TRANSPORT_ASSERT",label0)
            checks++;
        endfunction
        // 真实生成模型的root word-address偏移0x200，memory偏移0x100。
        virtual function void build_phase(uvm_phase phase);
            model=new("model"); model.build(); model.lock_model();
            sqr=new("sqr",this); drv=new("drv",this); ad=new(); cb=new();
            classifier=new(); extension=new("extension");
            model.default_map.set_sequencer(sqr,ad);
            uvm_mem_cb::add(model.LEAF.RAM,cb);
        endfunction
        // 唯一总线连接；无predictor参与物理oracle。
        virtual function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
        // 执行并返回操作对象，保留status/value以及raw分类结果供独立断言。
        task operate(bit read0,bit reg0,bit raw0,uvm_reg_data_t value,
                     output transport_operation op);
            op=new(); op.memory0=model.LEAF.RAM; op.register0=model.LEAF.WIDE;
            op.map0=model.default_map; op.extension=extension; op.read0=read0;
            op.reg0=reg0; op.raw0=raw0; op.value=value; op.probe=probe;
            ad.caller=op; ad.extension=raw0?null:extension; ad.contexts=0; ad.bad_contexts=0;
            cb.caller=op; op.start(sqr);
        endtask
        // 逐响应模式/clone/拍序覆盖成功及每个故障位置；oracle不调用get_addresses。
        virtual task run_phase(uvm_phase phase);
            transport_operation op;
            transport_parent template0;
            uvm_reg_data_t pattern;
            int beats=`UVM_REG_DATA_WIDTH/32;
            phase.raise_objection(this);
            for(int b=0;b<`UVM_REG_DATA_WIDTH;b++) pattern[b]=(b%7==1 || b%7==4);
            for(int rsp=0;rsp<2;rsp++) for(int special=0;special<2;special++) begin
                drv.separate=rsp; ad.provides_responses=rsp;
                template0=new(); ad.parent_sequence=special?template0:null;
                for(int order0=0;order0<2;order0++) begin
                    aip_ral_mem_beat_order_e order1=order0?AIP_RAL_MSW_FIRST:AIP_RAL_LSW_FIRST;
                    fd=new("fd",order1); model.LEAF.RAM.set_frontdoor(fd,model.default_map);
                    probe=new(model.default_map,classifier,order1);
                    drv.fail_at=-1; drv.clear_trace(); operate(0,0,0,pattern,op);
                    demand(op.status==UVM_IS_OK && drv.addresses.size()==beats,"write complete");
                    for(int t=0;t<beats;t++) begin
                        int k=order0?beats-1-t:t;
                        demand(drv.addresses[t]=='h300+k,"independent address");
                        demand(drv.data_trace[t]==32'(pattern>>(32*k)),"independent data");
                        demand(drv.enables[t]==15 && drv.bits_trace[t]==32,"byte enables");
                    end
                    demand(ad.contexts==beats && ad.bad_contexts==0,"parent extension");
                    drv.clear_trace(); operate(1,0,0,0,op);
                    demand(op.status==UVM_IS_OK && op.value==pattern,"read assemble");
                    demand(cb.pre_count==cb.post_count && cb.bad_parent==0,"callback and parent restoration");
                    drv.clear_trace(); operate(0,1,0,pattern,op);
                    for(int t=0;t<beats;t++) demand(drv.addresses[t]=='h200+t,"register order unchanged");
                    for(int raw0=0;raw0<2;raw0++) for(int hx=0;hx<2;hx++)
                    for(int z=0;z<2;z++) for(int f=0;f<beats;f++) begin
                        aip_ral_beat_executor ex;
                        drv.clear_trace(); drv.fail_at=f; drv.fault_code=0; drv.inject_z=z; ad.has_x=hx;
                        operate(1,0,raw0,0,op); ex=raw0?probe.transport:fd.transport;
                        demand(op.status==(hx?UVM_HAS_X:UVM_NOT_OK) && op.value==0,"first fault status no partial data");
                        demand(drv.addresses.size()==f+1 && ex.completed_beats==f && ex.failed_beat==f,"first fault stops beats");
                        demand(ex.failed_address=='h300+(order0?beats-1-f:f),"failed request address");
                    end
                    ad.has_x=0;
                    for(int code0=1;code0<3;code0++) for(int f=0;f<beats;f++) begin
                        drv.clear_trace(); drv.fail_at=f; drv.fault_code=code0;
                        operate(0,0,1,pattern,op);
                        demand(op.bus_status==((code0==1 && f==0)?AIP_RAL_BUS_ACCESS_REJECT:AIP_RAL_BUS_ERROR),"raw permission vs partial infrastructure failure");
                        demand(drv.addresses.size()==f+1,"raw first failure stop");
                    end
                    if(rsp) begin
                        drv.clear_trace(); drv.fail_at=0; drv.response_only=1;
                        operate(1,0,0,0,op);
                        demand(op.status==UVM_NOT_OK && drv.addresses.size()==1,"separate response failure");
                        drv.response_only=0;
                    end
                    drv.fail_at=-1; drv.fault_code=0;
                end
            end
            $display("RAL_TRANSPORT_COMPLETE width=%0d checks=%0d",`UVM_REG_DATA_WIDTH,checks);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
module test_ral_transport;
    import uvm_pkg::*;
    import ral_transport_test_pkg::*;
    initial run_test("transport_test");
endmodule
