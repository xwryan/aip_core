//===========================================================
// RAL接入契约：TB拥有hook/classifier及其业务资源；本文件只声明接口。
// 不自动创建、注册或调用，不添加对象级观察hook或adapter基类。
//===========================================================
`ifndef AIP_RAL_HOOKS_SV
`define AIP_RAL_HOOKS_SV
virtual class aip_ral_reset_hook;
    // 执行一次真实reset，成功时detail为空；失败时detail必须非空。
    pure virtual task reset(output bit ok,output string detail);
endclass
virtual class aip_ral_test_hook;
    // 暂停指定root自主变化和其他master，保持静默直到resume。
    pure virtual task quiesce(uvm_reg_block root,output bit ok,output string detail);
    // 恢复由quiesce暂停的资源，不隐式改写RAL对象。
    pure virtual task resume(uvm_reg_block root,output bit ok,output string detail);
endclass
virtual class aip_ral_response_classifier;
    // 按真实请求/响应协议分类；普通transport失败不能冒充权限拒绝。
    pure virtual function aip_ral_bus_status_e classify(uvm_sequence_item request,
        uvm_sequence_item response,uvm_status_e uvm_status,output string detail);
endclass
`endif
