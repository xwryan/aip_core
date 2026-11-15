// src/sv/ral：Task2单例生命周期与永久恢复门禁；依赖core execution及RAL报告类型。
// service拥有锁token、深拷贝快照和latch；调用者仅借用token且必须在真实worker中操作。
// 不注册命令、不解析RAL对象、不访问DUT；listener只作零时间bookkeeping，不调用hook。
`ifndef AIP_RAL_SERVICE_SV
`define AIP_RAL_SERVICE_SV

// 配置阶段的对象种类；索引只保存稳定名称和UVM句柄，不复制或接管模型所有权。
typedef enum {AIP_RAL_CFG_REG, AIP_RAL_CFG_FIELD, AIP_RAL_CFG_MEM,
              AIP_RAL_CFG_VREG, AIP_RAL_CFG_VFIELD} aip_ral_cfg_object_kind_e;

// 一个真实map的别名绑定；alias不改变UVM map层次和物理地址。
class aip_ral_cfg_map_binding;
    string alias_name;
    uvm_reg_map map;
    aip_ral_response_classifier classifier;
    // 配置对象只在service生命周期内使用，不能单独释放map或classifier。
    function new(string alias0, uvm_reg_map map0);
        alias_name = alias0;
        map = map0;
    endfunction
endclass

// 一个用户注册root的配置快照；maps[0]固定为保留的ral alias。
class aip_ral_cfg_root_binding;
    string root_name;
    uvm_reg_block root;
    uvm_reg_map default_map;
    aip_ral_test_hook test_hook;
    aip_ral_cfg_map_binding maps[$];
    // root binding只借用TB拥有的handle，冻结后不再接受替换。
    function new(string name0, uvm_reg_block root0, uvm_reg_map map0);
        aip_ral_cfg_map_binding map_binding;
        root_name = name0;
        root = root0;
        default_map = map0;
        map_binding = new("ral", map0);
        maps.push_back(map_binding);
    endfunction
endclass

// canonical索引的单条记录；同名不同类型也必须在validate阶段报冲突。
class aip_ral_cfg_object_entry;
    string canonical_name;
    string full_name;
    aip_ral_cfg_object_kind_e kind;
    uvm_object object;
    // entry不拥有object，模型仍由testbench控制其生命周期。
    function new(string name0, string full0, aip_ral_cfg_object_kind_e kind0,
                 uvm_object object0);
        canonical_name = name0;
        full_name = full0;
        kind = kind0;
        object = object0;
    endfunction
endclass

// exclusion配置保留原始handle和理由，validate前不会转成模糊名称。
class aip_ral_cfg_exclusion;
    uvm_object object;
    string reason;
    function new(uvm_object object0, string reason0);
        object = object0;
        reason = reason0;
    endfunction
endclass

// token权限来自service保存的对象身份，外部new同类对象不能伪造持锁资格。
class aip_ral_owner_token;
    local longint unsigned generation;

    // generation只读；值相等不等于有权限，release还必须核对对象和owner。
    function new(longint unsigned value); generation = value; endfunction

    // 返回代号用于诊断和迟到通知校验，不暴露可修改字段。
    function longint unsigned get_generation(); return generation; endfunction
endclass

// 单例保存整个仿真期的recovery latch；刻意没有reset/clear/recover公共方法。
class aip_ral_service extends aip_cmd_liveness_listener;
    local static aip_ral_service instance;
    local aip_ral_owner_token token;
    local process owner;
    local aip_cmd_execution execution;
    local longint unsigned generation;
    local longint unsigned dead_generation;
    local aip_ral_run_state committed;
    local aip_ral_leaf_id_t active_ids[$];
    local aip_ral_phase_e current_phase;
    local bit entered_external;
    local bit grab_pending;
    local bit cancel_clean;
    local bit recovery_latched;
    local aip_ral_tristate_e latched_side_effects, latched_partial;
    local aip_ral_restore_e latched_restore;
    local bit latched_resumed;

    // 配置缓存：validate成功前可重试；全部能力检查成功后安装memory frontdoor并冻结。
    local aip_ral_cfg_root_binding root_cfgs[$];
    local aip_ral_cfg_object_entry object_index[$];
    local aip_ral_cfg_exclusion exclusions[$];
    local aip_ral_reset_hook reset_hook;
    local aip_ral_mem_beat_order_e mem_beat_order = AIP_RAL_MSW_FIRST;
    local bit mem_beat_order_explicit;
    local bit config_frozen;

    // 只能通过get取得仿真期单例，测试也不能重建以清除永久latch。
    local function new(); endfunction

    // 惰性建立唯一实例；function无时间控制，检查和发布在同一调度片内完成。
    static function aip_ral_service get();
        if (instance == null) instance = new();
        return instance;
    endfunction

    // 按注册名查找root；失败返回-1，不修改任何配置缓存。
    local function int root_pos(string root_name);
        foreach (root_cfgs[i]) if (root_cfgs[i].root_name == root_name) return i;
        return -1;
    endfunction

    // UVM map必须来自root的真实map层次，禁止建立第二套地址数据库。
    local function bit map_belongs(uvm_reg_block root, uvm_reg_map map);
        uvm_reg_map maps[$];
        if (root == null || map == null) return 0;
        root.get_maps(maps);
        foreach (maps[i]) if (maps[i] == map) return 1;
        return 0;
    endfunction

    // alias注册前确认最终root map已连接sequencer和adapter；空配置不能留到运行时。
    local function bit map_connected(uvm_reg_map map);
        return map != null && map.get_sequencer(UVM_HIER) != null &&
               map.get_adapter(UVM_HIER) != null;
    endfunction

    // block关系用于拒绝祖先/后代root重叠注册，避免同一对象出现两套canonical名称。
    local function bit block_contains(uvm_reg_block ancestor, uvm_reg_block candidate);
        uvm_reg_block cursor;
        if (ancestor == null || candidate == null) return 0;
        cursor = candidate;
        while (cursor != null) begin
            if (cursor == ancestor) return 1;
            cursor = cursor.get_parent();
        end
        return 0;
    endfunction

    // 解析配置对象所属block；vreg/vfield只用于索引，不允许作为exclusion scope。
    local function uvm_reg_block object_block(uvm_object object0);
        uvm_reg_block block0;
        uvm_reg reg0;
        uvm_reg_field field0;
        uvm_mem mem0;
        uvm_vreg vreg0;
        uvm_vreg_field vfield0;
        if (object0 == null) return null;
        if ($cast(block0, object0)) return block0;
        if ($cast(reg0, object0)) return reg0.get_block();
        if ($cast(field0, object0)) return field0.get_parent().get_block();
        if ($cast(mem0, object0)) return mem0.get_block();
        if ($cast(vreg0, object0)) return vreg0.get_block();
        if ($cast(vfield0, object0)) return vfield0.get_parent().get_block();
        return null;
    endfunction

    // scope必须落在已注册root内；同一root的child map不改变归属判断。
    local function int object_root_pos(uvm_object object0);
        uvm_reg_block owner0;
        owner0 = object_block(object0);
        if (owner0 == null) return -1;
        foreach (root_cfgs[i]) if (block_contains(root_cfgs[i].root, owner0)) return i;
        return -1;
    endfunction

    // canonical名称只公开root名和模型相对路径，不泄露TB component层次。
    local function string canonical_name(string root_name, uvm_reg_block root,
                                         string full_name);
        string root_full, relative;
        root_full = root.get_full_name();
        relative = full_name;
        if (root_full != "" && full_name.len() >= root_full.len() &&
            full_name.substr(0,root_full.len()-1) == root_full) begin
            if (full_name.len() == root_full.len()) relative = "";
            else begin
                relative = full_name.substr(root_full.len(),full_name.len()-1);
                if (relative.len() != 0 && relative.getc(0) == 8'h2e)
                    relative = relative.substr(1,relative.len()-1);
            end
        end
        if (relative == "") return root_name;
        return {root_name,".",relative};
    endfunction

    // 输出稳定种类名，供后续ral_op解析和配置测试使用。
    local function string object_kind_text(aip_ral_cfg_object_kind_e kind0);
        case (kind0)
            AIP_RAL_CFG_REG:    return "reg";
            AIP_RAL_CFG_FIELD:  return "field";
            AIP_RAL_CFG_MEM:    return "mem";
            AIP_RAL_CFG_VREG:   return "vreg";
            default:            return "vfield";
        endcase
    endfunction

    // 将一个对象放入临时索引；发生canonical冲突时只报告，不改正式index。
    local function bit stage_entry(ref aip_ral_cfg_object_entry staged[$],
                                   input aip_ral_cfg_root_binding cfg,
                                   input uvm_object object0,
                                   input aip_ral_cfg_object_kind_e kind0,
                                   input int unsigned width0,
                                   output string detail);
        string name0,full0;
        detail = "";
        if (object0 == null || width0 == 0 || width0 > AIP_RAL_DATA_BITS) begin
            detail = $sformatf("unsupported object width name=%s width=%0d",
                               object0 == null ? "<null>" : object0.get_full_name(), width0);
            return 0;
        end
        full0 = object0.get_full_name();
        name0 = canonical_name(cfg.root_name,cfg.root,full0);
        foreach (staged[i]) begin
            if (staged[i].canonical_name == name0) begin
                detail = $sformatf("canonical name collision name=%s first=%s/%s second=%s/%s",
                                   name0, staged[i].full_name, object_kind_text(staged[i].kind),
                                   full0, object_kind_text(kind0));
                return 0;
            end
        end
        begin
            aip_ral_cfg_object_entry entry0;
            entry0 = new(name0,full0,kind0,object0);
            staged.push_back(entry0);
        end
        return 1;
    endfunction

    // 遍历UVM公开的五类对象，建立临时canonical索引；不创建逐对象配置表。
    local function bit stage_root_entries(ref aip_ral_cfg_object_entry staged[$],
                                          input aip_ral_cfg_root_binding cfg,
                                          output string detail);
        uvm_reg regs[$];
        uvm_reg_field fields[$];
        uvm_mem mems[$];
        uvm_vreg vregs[$];
        uvm_vreg_field vfields[$];
        detail = "";
        cfg.root.get_registers(regs,UVM_HIER);
        cfg.root.get_fields(fields,UVM_HIER);
        cfg.root.get_memories(mems,UVM_HIER);
        cfg.root.get_virtual_registers(vregs,UVM_HIER);
        cfg.root.get_virtual_fields(vfields,UVM_HIER);
        foreach (regs[i])
            if (!stage_entry(staged,cfg,regs[i],AIP_RAL_CFG_REG,regs[i].get_n_bits(),detail)) return 0;
        foreach (fields[i])
            if (!stage_entry(staged,cfg,fields[i],AIP_RAL_CFG_FIELD,fields[i].get_n_bits(),detail)) return 0;
        foreach (mems[i])
            if (!stage_entry(staged,cfg,mems[i],AIP_RAL_CFG_MEM,mems[i].get_n_bits(),detail)) return 0;
        foreach (vregs[i])
            if (!stage_entry(staged,cfg,vregs[i],AIP_RAL_CFG_VREG,vregs[i].get_n_bytes()*8,detail)) return 0;
        foreach (vfields[i])
            if (!stage_entry(staged,cfg,vfields[i],AIP_RAL_CFG_VFIELD,vfields[i].get_n_bits(),detail)) return 0;
        return 1;
    endfunction

    // validate前拒绝自定义frontdoor；安装提交阶段不能覆盖用户所有的frontdoor。
    local function bit map_has_unsupported_frontdoor(aip_ral_cfg_root_binding cfg,
                                                     output string detail);
        uvm_reg regs[$];
        uvm_mem mems[$];
        uvm_vreg vregs[$];
        detail = "";
        cfg.root.get_registers(regs,UVM_HIER);
        cfg.root.get_memories(mems,UVM_HIER);
        cfg.root.get_virtual_registers(vregs,UVM_HIER);
        foreach (cfg.maps[m]) begin
            foreach (regs[i]) if (regs[i].is_in_map(cfg.maps[m].map) &&
                                   regs[i].get_frontdoor(cfg.maps[m].map) != null) begin
                detail = $sformatf("custom frontdoor unsupported object=%s map=%s",
                                   regs[i].get_full_name(),cfg.maps[m].alias_name);
                return 1;
            end
            foreach (mems[i]) if (mems[i].is_in_map(cfg.maps[m].map) &&
                                   mems[i].get_frontdoor(cfg.maps[m].map) != null) begin
                detail = $sformatf("custom frontdoor unsupported object=%s map=%s",
                                   mems[i].get_full_name(),cfg.maps[m].alias_name);
                return 1;
            end
            foreach (vregs[i]) if (vregs[i].is_in_map(cfg.maps[m].map) &&
                                    vregs[i].get_memory() != null &&
                                    vregs[i].get_memory().get_frontdoor(cfg.maps[m].map) != null) begin
                detail = $sformatf("custom frontdoor unsupported object=%s map=%s",
                                   vregs[i].get_full_name(),cfg.maps[m].alias_name);
                return 1;
            end
        end
        return 0;
    endfunction

    // 事务无关的配置入口：root必须已lock、map必须连接，失败不产生半注册状态。
    function aip_ral_cfg_status_e register_root(string root_name, uvm_reg_block root,
                                                  uvm_reg_map default_map,
                                                  output string detail);
        int existing;
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (root_name == "" || root == null || default_map == null) begin
            detail="root name, root and default map are required"; return AIP_RAL_CFG_BAD_ARG;
        end
        if (!root.is_locked()) begin detail="root model must be locked"; return AIP_RAL_CFG_INVALID; end
        if (root.get_default_map() != default_map || !map_belongs(root,default_map)) begin
            detail="default map does not belong to root"; return AIP_RAL_CFG_INVALID;
        end
        if (!map_connected(default_map)) begin detail="default map has no sequencer/adapter"; return AIP_RAL_CFG_INVALID; end
        existing = root_pos(root_name);
        if (existing >= 0) begin
            if (root_cfgs[existing].root == root && root_cfgs[existing].default_map == default_map) return AIP_RAL_CFG_OK;
            detail="root name already registered with a different handle"; return AIP_RAL_CFG_DUPLICATE;
        end
        foreach (root_cfgs[i]) begin
            if (root_cfgs[i].root == root) begin detail="same root handle has another name"; return AIP_RAL_CFG_DUPLICATE; end
            if (block_contains(root_cfgs[i].root,root) || block_contains(root,root_cfgs[i].root)) begin
                detail="ancestor/descendant root overlap"; return AIP_RAL_CFG_DUPLICATE;
            end
        end
        begin
            aip_ral_cfg_root_binding root_binding;
            root_binding = new(root_name,root,default_map);
            root_cfgs.push_back(root_binding);
        end
        return AIP_RAL_CFG_OK;
    endfunction

    // 注册额外map alias只选择已有真实map，不能用alias伪造偏移或重复物理map。
    function aip_ral_cfg_status_e register_map(string root_name, string alias_name,
                                                 uvm_reg_map map, output string detail);
        int rpos;
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (alias_name == "" || map == null) begin detail="map alias and map are required"; return AIP_RAL_CFG_BAD_ARG; end
        rpos = root_pos(root_name);
        if (rpos < 0) begin detail="unknown root"; return AIP_RAL_CFG_INVALID; end
        if (alias_name == "ral") begin detail="ral is a reserved alias"; return AIP_RAL_CFG_DUPLICATE; end
        if (!map_belongs(root_cfgs[rpos].root,map)) begin detail="map does not belong to root"; return AIP_RAL_CFG_INVALID; end
        if (!map_connected(map)) begin detail="map has no sequencer/adapter"; return AIP_RAL_CFG_INVALID; end
        foreach (root_cfgs[rpos].maps[i]) begin
            if (root_cfgs[rpos].maps[i].alias_name == alias_name) begin
                if (root_cfgs[rpos].maps[i].map == map) return AIP_RAL_CFG_OK;
                detail="map alias already registered with a different handle"; return AIP_RAL_CFG_DUPLICATE;
            end
            if (root_cfgs[rpos].maps[i].map == map) begin detail="same physical map has multiple aliases"; return AIP_RAL_CFG_DUPLICATE; end
        end
        begin
            aip_ral_cfg_map_binding map_binding;
            map_binding = new(alias_name,map);
            root_cfgs[rpos].maps.push_back(map_binding);
        end
        return AIP_RAL_CFG_OK;
    endfunction

    // 仅允许一个全局reset hook；重复设置同一handle幂等，冲突不可覆盖旧值。
    function aip_ral_cfg_status_e set_reset_hook(aip_ral_reset_hook hook, output string detail);
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (hook == null) begin detail="reset hook is required"; return AIP_RAL_CFG_BAD_ARG; end
        if (reset_hook == null) begin reset_hook=hook; return AIP_RAL_CFG_OK; end
        if (reset_hook == hook) return AIP_RAL_CFG_OK;
        detail="reset hook already configured"; return AIP_RAL_CFG_DUPLICATE;
    endfunction

    // 每个root最多一个quiesce/resume hook；root名必须先注册。
    function aip_ral_cfg_status_e set_test_hook(string root_name, aip_ral_test_hook hook,
                                                 output string detail);
        int rpos;
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (root_name == "" || hook == null) begin detail="root name and test hook are required"; return AIP_RAL_CFG_BAD_ARG; end
        rpos = root_pos(root_name);
        if (rpos < 0) begin detail="unknown root"; return AIP_RAL_CFG_INVALID; end
        if (root_cfgs[rpos].test_hook == null) begin root_cfgs[rpos].test_hook=hook; return AIP_RAL_CFG_OK; end
        if (root_cfgs[rpos].test_hook == hook) return AIP_RAL_CFG_OK;
        detail="test hook already configured"; return AIP_RAL_CFG_DUPLICATE;
    endfunction

    // classifier绑定到root/map alias，不能在未知slot上隐式创建map。
    function aip_ral_cfg_status_e set_response_classifier(string root_name, string alias_name,
                                                          aip_ral_response_classifier classifier,
                                                          output string detail);
        int rpos;
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (root_name == "" || alias_name == "" || classifier == null) begin detail="root, alias and classifier are required"; return AIP_RAL_CFG_BAD_ARG; end
        rpos = root_pos(root_name);
        if (rpos < 0) begin detail="unknown root"; return AIP_RAL_CFG_INVALID; end
        foreach (root_cfgs[rpos].maps[i]) if (root_cfgs[rpos].maps[i].alias_name == alias_name) begin
            if (root_cfgs[rpos].maps[i].classifier == null) begin root_cfgs[rpos].maps[i].classifier=classifier; return AIP_RAL_CFG_OK; end
            if (root_cfgs[rpos].maps[i].classifier == classifier) return AIP_RAL_CFG_OK;
            detail="response classifier already configured"; return AIP_RAL_CFG_DUPLICATE;
        end
        detail="unknown map alias"; return AIP_RAL_CFG_INVALID;
    endfunction

    // 全局memory拍序默认MSW_FIRST；validate提交时传给每个memory frontdoor。
    function aip_ral_cfg_status_e set_mem_beat_order(aip_ral_mem_beat_order_e order,
                                                      output string detail);
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (!(order inside {AIP_RAL_MSW_FIRST,AIP_RAL_LSW_FIRST})) begin detail="invalid memory beat order"; return AIP_RAL_CFG_BAD_ARG; end
        if (!mem_beat_order_explicit) begin mem_beat_order=order; mem_beat_order_explicit=1; return AIP_RAL_CFG_OK; end
        if (mem_beat_order == order) return AIP_RAL_CFG_OK;
        detail="memory beat order already configured"; return AIP_RAL_CFG_DUPLICATE;
    endfunction

    // 仅register/block/field/memory可以排除；vreg/vfield保留配置访问但不进入测试排除表。
    function aip_ral_cfg_status_e exclude_from_test(uvm_object scope, string reason,
                                                     output string detail);
        int rpos;
        uvm_reg block_reg;
        uvm_reg_field field0;
        uvm_mem mem0;
        uvm_reg_block block0;
        uvm_vreg vreg0;
        uvm_vreg_field vfield0;
        detail = "";
        if (config_frozen) begin detail="configuration is frozen"; return AIP_RAL_CFG_FROZEN; end
        if (scope == null || reason == "") begin detail="scope and exclusion reason are required"; return AIP_RAL_CFG_BAD_ARG; end
        if ($cast(vreg0,scope) || $cast(vfield0,scope)) begin detail="vreg/vfield cannot be test exclusions"; return AIP_RAL_CFG_BAD_ARG; end
        if (!$cast(block0,scope) && !$cast(block_reg,scope) && !$cast(field0,scope) && !$cast(mem0,scope)) begin
            detail="unsupported exclusion scope type"; return AIP_RAL_CFG_BAD_ARG;
        end
        rpos = object_root_pos(scope);
        if (rpos < 0) begin detail="scope is outside registered roots"; return AIP_RAL_CFG_INVALID; end
        foreach (exclusions[i]) if (exclusions[i].object == scope) begin
            if (exclusions[i].reason == reason) return AIP_RAL_CFG_OK;
            detail="same exclusion scope has a different reason"; return AIP_RAL_CFG_DUPLICATE;
        end
        begin
            aip_ral_cfg_exclusion exclusion0;
            exclusion0 = new(scope,reason);
            exclusions.push_back(exclusion0);
        end
        return AIP_RAL_CFG_OK;
    endfunction

    // 两阶段validate：所有几何/能力检查通过后才安装frontdoor、提交index并冻结。
    function aip_ral_cfg_status_e validate(output string detail);
        aip_ral_cfg_object_entry staged[$];
        aip_ral_mem_frontdoor frontdoors[$];
        uvm_mem install_mems[$];
        uvm_reg_map install_maps[$];
        detail = "";
        if (config_frozen) return AIP_RAL_CFG_OK;
        if (root_cfgs.size() == 0) begin detail="no registered roots"; return AIP_RAL_CFG_INVALID; end
        foreach (root_cfgs[i]) begin
            if (root_cfgs[i].root == null || !root_cfgs[i].root.is_locked()) begin detail="root is not locked"; return AIP_RAL_CFG_INVALID; end
            foreach (root_cfgs[i].maps[m]) begin
                if (!map_belongs(root_cfgs[i].root,root_cfgs[i].maps[m].map)) begin detail="registered map left root hierarchy"; return AIP_RAL_CFG_INVALID; end
                if (!map_connected(root_cfgs[i].maps[m].map)) begin detail=$sformatf("map %s is not connected",root_cfgs[i].maps[m].alias_name); return AIP_RAL_CFG_INVALID; end
            end
            if (map_has_unsupported_frontdoor(root_cfgs[i],detail)) return AIP_RAL_CFG_UNSUPPORTED;
            if (!stage_root_entries(staged,root_cfgs[i],detail)) begin
                // stage_entry对宽度错误使用固定前缀；碰撞仍保持既有DUPLICATE接口。
                if (detail.len()>=24 && detail.substr(0,23)=="unsupported object width")
                    return AIP_RAL_CFG_UNSUPPORTED;
                return AIP_RAL_CFG_DUPLICATE;
            end
        end
        if (staged.size() == 0) begin detail="no supported RAL objects found"; return AIP_RAL_CFG_INVALID; end
        // 所有能力检查已完成后才创建并安装memory frontdoor；reg不被接管，失败路径不冻结。
        foreach (root_cfgs[r]) begin
            uvm_mem mems[$];
            root_cfgs[r].root.get_memories(mems,UVM_HIER);
            foreach (root_cfgs[r].maps[m]) begin
                foreach (mems[i]) if (mems[i].is_in_map(root_cfgs[r].maps[m].map)) begin
                    aip_ral_mem_frontdoor frontdoor0;
                    uvm_reg_map local_map0;
                    uvm_reg_addr_t addresses0[];
                    int unsigned bus_bits0;
                    local_map0=mems[i].get_local_map(root_cfgs[r].maps[m].map);
                    bus_bits0=local_map0.get_n_bytes(UVM_HIER)*8;
                    void'(mems[i].get_addresses(0,local_map0,addresses0));
                    if (bus_bits0==0 || bus_bits0>AIP_RAL_DATA_BITS) begin
                        detail=$sformatf("unsupported bus width memory=%s bits=%0d",mems[i].get_full_name(),bus_bits0);
                        return AIP_RAL_CFG_UNSUPPORTED;
                    end
                    if (addresses0.size()!=(mems[i].get_n_bits()+bus_bits0-1)/bus_bits0) begin
                        detail=$sformatf("unsupported memory geometry name=%s beats=%0d",mems[i].get_full_name(),addresses0.size());
                        return AIP_RAL_CFG_UNSUPPORTED;
                    end
                    frontdoor0 = new($sformatf("aip_mem_fd_%0d_%0d",r,m),mem_beat_order);
                    frontdoors.push_back(frontdoor0);
                    install_mems.push_back(mems[i]);
                    install_maps.push_back(root_cfgs[r].maps[m].map);
                end
            end
        end
        foreach (install_mems[i]) install_mems[i].set_frontdoor(frontdoors[i],install_maps[i]);
        object_index = staged;
        config_frozen = 1;
        return AIP_RAL_CFG_OK;
    endfunction

    // 配置状态与索引查询为后续ral_op/runner复用的只读接口，不提供删除或替换。
    function bit is_frozen(); return config_frozen; endfunction
    function aip_ral_mem_beat_order_e get_mem_beat_order(); return mem_beat_order; endfunction
    function int unsigned get_root_count(); return root_cfgs.size(); endfunction
    function bit get_root_at(int index, output string root_name, output uvm_reg_block root,
                             output aip_ral_test_hook hook);
        root_name = "";
        root = null;
        hook = null;
        if (index < 0 || index >= root_cfgs.size()) return 0;
        root_name = root_cfgs[index].root_name;
        root = root_cfgs[index].root;
        hook = root_cfgs[index].test_hook;
        return 1;
    endfunction
    function bit get_reset_hook(output aip_ral_reset_hook hook);
        hook = reset_hook;
        return hook != null;
    endfunction
    function bit get_map(string root_name, string alias_name, output uvm_reg_map map);
        int rpos;
        map = null;
        rpos = root_pos(root_name);
        if (rpos < 0) return 0;
        foreach (root_cfgs[rpos].maps[i]) if (root_cfgs[rpos].maps[i].alias_name == alias_name) begin
            map = root_cfgs[rpos].maps[i].map;
            return 1;
        end
        return 0;
    endfunction
    function bit get_response_classifier(string root_name, string alias_name,
                                         output aip_ral_response_classifier classifier);
        int rpos;
        classifier = null;
        rpos = root_pos(root_name);
        if (rpos < 0) return 0;
        foreach (root_cfgs[rpos].maps[i]) if (root_cfgs[rpos].maps[i].alias_name == alias_name) begin
            classifier = root_cfgs[rpos].maps[i].classifier;
            return classifier != null;
        end
        return 0;
    endfunction
    function bit lookup(string canonical, output uvm_object object0, output string kind);
        object0 = null;
        kind = "";
        if (!config_frozen || canonical == "") return 0;
        foreach (object_index[i]) if (object_index[i].canonical_name == canonical) begin
            object0 = object_index[i].object;
            kind = object_kind_text(object_index[i].kind);
            return 1;
        end
        return 0;
    endfunction

    // runner只读遍历冻结后的canonical index；不暴露内部entry或配置所有权。
    function int unsigned get_object_count();
        return object_index.size();
    endfunction
    function bit get_object_at(int unsigned index, output string canonical,
                               output uvm_object object0, output string kind);
        canonical=""; object0=null; kind="";
        if (!config_frozen || index>=object_index.size()) return 0;
        canonical=object_index[index].canonical_name;
        object0=object_index[index].object;
        kind=object_kind_text(object_index[index].kind);
        return 1;
    endfunction
    function bit is_excluded(uvm_object object0, output string reason);
        uvm_reg_block object_block0;
        uvm_reg_block exclusion_block0;
        reason="";
        if (object0==null) return 0;
        object_block0=object_block(object0);
        foreach (exclusions[i]) begin
            if (exclusions[i].object==object0) begin reason=exclusions[i].reason; return 1; end
            if ($cast(exclusion_block0,exclusions[i].object) && object_block0!=null &&
                block_contains(exclusion_block0,object_block0)) begin
                reason=exclusions[i].reason; return 1;
            end
            // A register exclusion applies recursively to its fields.
            begin
                uvm_reg excluded_reg;
                uvm_reg_field object_field;
                if ($cast(excluded_reg,exclusions[i].object) &&
                    $cast(object_field,object0) && object_field.get_parent()==excluded_reg) begin
                    reason=exclusions[i].reason; return 1;
                end
            end
        end
        return 0;
    endfunction

    // field RMW只接受UVM能给出确定中性写值的策略。未知策略不能靠旧mirror
    // 猜测；这类组合在任何callback或总线动作前明确拒绝。
    local function bit field_neutral_policy(string access0);
        return access0 inside {"RW", "RO", "W1C", "W1S", "W1T",
                               "W0C", "W0S", "W0T"};
    endfunction

    // sibling读副作用会让field read无法证明读前状态，必须在read前拒绝。
    local function bit field_read_side_effect_policy(string access0);
        return access0 inside {"RC", "RS", "W1SRC", "W1CRC", "W0SRC", "W0CRS"};
    endfunction

    // 单次命名访问的执行底座。命令层只负责语法/数值解析；对象、map、权限和
    // 标准 UVM API 均在这里即时解析，避免维护第二份地址或属性数据库。
    task execute_op(string operation, string canonical, string root_name, string alias_name,
                    bit has_index, longint unsigned index, bit has_value,
                    uvm_reg_data_t input_value, uvm_sequence_base parent,
                    output uvm_status_e status, output aip_ral_code_e code,
                    output uvm_reg_data_t result_value, output int unsigned width,
                    output string kind, output string detail);
        uvm_object object0;
        uvm_reg reg0;
        uvm_reg_field field0;
        uvm_mem mem0;
        uvm_vreg vreg0;
        uvm_vreg_field vfield0;
        uvm_reg_map map0;
        string access0;
        bit is_write;
        uvm_reg parent_reg;
        uvm_reg_field fields0[$];
        bit [AIP_VEC_MAX_BITS-1:0] covered;
        bit has_rw_sibling;
        uvm_reg_data_t parent_value;
        uvm_status_e parent_status;

        status=UVM_NOT_OK; code=AIP_RAL_CODE_NONE; result_value='0;
        width=0; kind=""; detail="";
        is_write=(aip_str::lower(operation)=="write");
        if (operation!="read" && operation!="write") begin
            code=AIP_RAL_CODE_BAD_ARGS; detail="operation must be read or write"; return;
        end
        if (!has_value && is_write) begin code=AIP_RAL_CODE_BAD_ARGS; detail="write value is required"; return; end
        if (!lookup(canonical,object0,kind)) begin code=AIP_RAL_CODE_NOT_FOUND; detail="RAL object was not found"; return; end
        if (!get_map(root_name,alias_name,map0)) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="map alias was not found"; return; end
        if (object0==null || map0==null || parent==null) begin code=AIP_RAL_CODE_BAD_ARGS; detail="invalid operation context"; return; end

        if ($cast(reg0,object0)) begin
            if (has_index) begin code=AIP_RAL_CODE_BAD_ARGS; detail="register does not accept index"; return; end
            if (reg0.get_local_map(map0)==null) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="register is not in selected map"; return; end
            width=reg0.get_n_bits(); access0=reg0.get_rights(map0);
        end else if ($cast(field0,object0)) begin
            if (has_index) begin code=AIP_RAL_CODE_BAD_ARGS; detail="field does not accept index"; return; end
            parent_reg=field0.get_parent();
            if (parent_reg.get_local_map(map0)==null) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="field is not in selected map"; return; end
            width=field0.get_n_bits(); access0=field0.get_access(map0);
            if (is_write && access0 inside {"RO","RC","RS","NOACCESS","R"}) begin
                code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies field write"; return;
            end
            if (!is_write && access0 inside {"WO","WOC","WOS","WO1","NOACCESS"}) begin
                code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies field read"; return;
            end
            // A field read is a parent-register read when individual field access is
            // unavailable.  Refuse sibling read-side effects instead of consuming
            // them and returning a value that cannot be attributed to this field.
            if (!is_write) begin
                parent_reg.get_fields(fields0);
                foreach (fields0[i]) if (fields0[i] != field0 &&
                    field_read_side_effect_policy(fields0[i].get_access(map0))) begin
                    code=AIP_RAL_CODE_UNSAFE_READ;
                    detail=$sformatf("sibling field %s has read side effect",fields0[i].get_full_name());
                    return;
                end
            end else if (field0.get_n_bits() != parent_reg.get_n_bits() ||
                         field0.get_lsb_pos() != 0) begin
                // Verify that the whole parent is explicitly modeled.  Reserved holes
                // have no neutral value and therefore cannot be synthesized safely.
                if (parent_reg.get_n_bits()>AIP_VEC_MAX_BITS) begin
                    code=AIP_RAL_CODE_UNSUPPORTED; detail="parent register exceeds RMW capacity"; return;
                end
                parent_reg.get_fields(fields0);
                covered='0;
                foreach (fields0[i]) begin
                    if (fields0[i].get_lsb_pos()+fields0[i].get_n_bits()>parent_reg.get_n_bits()) begin
                        code=AIP_RAL_CODE_UNSAFE_RMW; detail="field extends beyond parent register"; return;
                    end
                    for (int b=0;b<fields0[i].get_n_bits();b++) begin
                        if (covered[fields0[i].get_lsb_pos()+b]) begin
                            code=AIP_RAL_CODE_UNSAFE_RMW; detail="overlapping parent fields"; return;
                        end
                        covered[fields0[i].get_lsb_pos()+b]=1;
                    end
                    if (!field_neutral_policy(fields0[i].get_access(map0))) begin
                        code=AIP_RAL_CODE_UNSAFE_RMW;
                        detail=$sformatf("field policy %s cannot be neutralized",fields0[i].get_access(map0));
                        return;
                    end
                    if (fields0[i] != field0 && fields0[i].get_access(map0)=="RW")
                        has_rw_sibling=1;
                end
                for (int b=0;b<parent_reg.get_n_bits();b++) if (!covered[b]) begin
                    code=AIP_RAL_CODE_UNSAFE_RMW; detail="parent register contains an unmodeled hole"; return;
                end
                // A real parent read is required before field.write whenever an RW
                // sibling is present.  This refreshes the mirror and prevents stale
                // values from being used for the sibling portion of the RMW.
                if (has_rw_sibling) begin
                    parent_reg.read(parent_status,parent_value,UVM_FRONTDOOR,map0,parent);
                    if (parent_status!=UVM_IS_OK) begin
                        code=AIP_RAL_CODE_BUS_ERROR; detail="parent read for safe field RMW failed"; return;
                    end
                    if (!parent_reg.predict(parent_value,'1,UVM_PREDICT_DIRECT,UVM_FRONTDOOR,map0)) begin
                        code=AIP_RAL_CODE_UNSAFE_RMW; detail="parent mirror synchronization failed"; return;
                    end
                end
            end
        end else if ($cast(mem0,object0)) begin
            if (!has_index) begin code=AIP_RAL_CODE_BAD_ARGS; detail="memory index is required"; return; end
            if (index>=mem0.get_size()) begin code=AIP_RAL_CODE_INDEX_RANGE; detail="memory index is out of range"; return; end
            if (!mem0.is_in_map(map0)) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="memory is not in selected map"; return; end
            width=mem0.get_n_bits(); access0=mem0.get_access(map0);
        end else if ($cast(vreg0,object0)) begin
            if (!has_index) begin code=AIP_RAL_CODE_BAD_ARGS; detail="vreg index is required"; return; end
            if (index>=vreg0.get_size()) begin code=AIP_RAL_CODE_INDEX_RANGE; detail="vreg index is out of range"; return; end
            if (!vreg0.is_in_map(map0)) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="vreg backing memory is not in selected map"; return; end
            width=vreg0.get_n_bytes()*8; access0=vreg0.get_access(map0);
            // UVM exposes vreg width only as whole bytes.  AIP supports a vreg
            // operation only when it maps to one complete backing memory element;
            // a partial/multi-element write would require an unprovable RMW.
            if (is_write && (vreg0.get_memory()==null ||
                vreg0.get_n_bytes()!=vreg0.get_memory().get_n_bytes())) begin
                code=AIP_RAL_CODE_UNSUPPORTED; detail="vreg write must cover one complete memory element"; return;
            end
            if (vreg0.get_memory()==null || vreg0.get_n_bytes()>vreg0.get_memory().get_n_bytes()) begin
                code=AIP_RAL_CODE_UNSUPPORTED; detail="vreg geometry is unsupported"; return;
            end
        end else if ($cast(vfield0,object0)) begin
            if (!has_index) begin code=AIP_RAL_CODE_BAD_ARGS; detail="vfield index is required"; return; end
            if (index>=vfield0.get_parent().get_size()) begin code=AIP_RAL_CODE_INDEX_RANGE; detail="vfield index is out of range"; return; end
            if (!vfield0.get_parent().is_in_map(map0)) begin code=AIP_RAL_CODE_NOT_IN_MAP; detail="vfield backing memory is not in selected map"; return; end
            width=vfield0.get_n_bits(); access0=vfield0.get_access(map0);
            if (is_write && access0 inside {"RO","RC","RS","NOACCESS","R"}) begin
                code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies vfield write"; return;
            end
            if (!is_write && access0 inside {"WO","WOC","WOS","WO1","NOACCESS"}) begin
                code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies vfield read"; return;
            end
            // A partial vfield write is a backing-memory RMW.  It is only safe on a
            // stable RW, single-element backing entry; otherwise report before the
            // standard vfield implementation can issue its pre-read/write pair.
            if (is_write && (vfield0.get_parent().get_memory()==null ||
                vfield0.get_parent().get_n_bytes()!=vfield0.get_parent().get_memory().get_n_bytes() ||
                vfield0.get_parent().get_memory().get_access(map0)!="RW")) begin
                code=AIP_RAL_CODE_UNSAFE_RMW; detail="vfield write requires one stable RW backing element"; return;
            end
        end else begin
            code=AIP_RAL_CODE_BAD_ARGS; detail="unsupported RAL object kind"; return;
        end
        if (width==0 || width>AIP_RAL_DATA_BITS) begin code=AIP_RAL_CODE_UNSUPPORTED; detail="object width is unsupported"; return; end
        if (is_write) begin
            if (access0=="RO" || access0=="RC" || access0=="RS" || access0=="NOACCESS" ||
                access0=="R") begin code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies write"; return; end
        end else begin
            if (access0=="WO" || access0=="WOC" || access0=="WOS" || access0=="WO1" ||
                access0=="NOACCESS") begin code=AIP_RAL_CODE_ACCESS_DENIED; detail="selected map denies read"; return; end
        end
        if (is_write) begin
            if ($cast(reg0,object0)) reg0.write(status,input_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(field0,object0)) field0.write(status,input_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(mem0,object0)) mem0.write(status,index,input_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(vreg0,object0)) vreg0.write(index,status,input_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(vfield0,object0)) vfield0.write(index,status,input_value,UVM_FRONTDOOR,map0,parent);
            result_value=input_value;
        end else begin
            if ($cast(reg0,object0)) reg0.read(status,result_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(field0,object0)) field0.read(status,result_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(mem0,object0)) mem0.read(status,index,result_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(vreg0,object0)) vreg0.read(index,status,result_value,UVM_FRONTDOOR,map0,parent);
            else if ($cast(vfield0,object0)) vfield0.read(index,status,result_value,UVM_FRONTDOOR,map0,parent);
        end
        if (status!=UVM_IS_OK) begin code=AIP_RAL_CODE_BUS_ERROR; detail="UVM RAL access failed"; result_value='0; return; end
        code=AIP_RAL_CODE_NONE;
    endtask

    // 身份、代号与真实process必须同时匹配；拒绝同值伪token及旧owner尾声。
    local function bit owns(aip_ral_owner_token candidate);
        return candidate != null && token != null && candidate == token &&
               candidate.get_generation() == generation && owner == process::self();
    endfunction

    // 固定recovery入口envelope，不解析参数或取得锁；只复用首次触发时的安全值。
    function bit recovery_gate(bit is_test, output string result_text);
        result_text = "";
        if (!recovery_latched) return 0;
        result_text = {"ERROR code=RECOVERY_REQUIRED command=", is_test ? "ral_test" : "ral_op",
                       " phase=dispatch"};
        if (is_test) result_text = {result_text,
            " inventory_complete=0 reset_attempted=0 reset_performed=0 destructive=0"};
        result_text = {result_text,
            " side_effects=", aip_ral_names::tristate_text(latched_side_effects),
            " partial=", aip_ral_names::tristate_text(latched_partial),
            " restore=", aip_ral_names::restore(latched_restore),
            " resumed=", latched_resumed ? "1" : "0", " recovery_required=1"};
        return 1;
    endfunction

    // 非阻塞取锁。recovery优先于参数/身份检查；死亡process与本代通知缺一不可。
    // 调用方进入service后先调用recovery_gate，再做未来RAL解析；此入口仍重复防护。
    function aip_ral_code_e acquire(bit is_test, output aip_ral_owner_token acquired,
                                    output string result_text);
        aip_cmd_execution current;
        acquired = null;
        result_text = "";
        if (recovery_gate(is_test, result_text)) return AIP_RAL_CODE_RECOVERY_REQUIRED;
        if (token != null && owner != null && dead_generation == generation &&
            (owner.status() inside {process::KILLED, process::FINISHED})) begin
            token = null;
            owner = null;
            execution = null;
        end
        if (token != null) return AIP_RAL_CODE_BUSY;
        current = aip_cmd::get_current_execution();
        if (current == null || current.is_terminal() || current.get_owner() != process::self() ||
            generation == '1) return AIP_RAL_CODE_CONFIG_ERROR;
        if (!current.subscribe(this)) return AIP_RAL_CODE_CONFIG_ERROR;
        generation++;
        dead_generation = 0;
        owner = process::self();
        execution = current;
        token = new(generation);
        acquired = token;
        committed = new();
        committed.is_test = is_test;
        committed.phase = AIP_RAL_PHASE_PARSE;
        current_phase = AIP_RAL_PHASE_PARSE;
        active_ids.delete();
        entered_external = 0;
        grab_pending = 0;
        cancel_clean = 0;
        return AIP_RAL_CODE_NONE;
    endfunction

    // 正常owner主动释放；不重置latch、snapshot或generation，不允许旧token解新锁。
    function bit release_owner(aip_ral_owner_token candidate);
        if (!owns(candidate)) return 0;
        if (grab_pending || aip_cmd_seq_registry::has_owner(owner)) return 0;
        token = null;
        owner = null;
        return 1;
    endfunction

    // 原子发布整份深拷贝、phase和active集合；先验证再替换，失败完全不修改已提交状态。
    // entered_external单调置位，调用者必须在可能阻塞的hook/backdoor/bus之前发布。
    // restore输入必须汇总本命令全部义务；已知failed不能被后续无义务leaf抹除。
    // phase0单独描述当前执行位置，state0.phase保留报告的最早全局错误位置。
    function bit publish_state(aip_ral_owner_token candidate, aip_ral_run_state state0,
                               input aip_ral_leaf_id_t selected[$],
                               input aip_ral_phase_e phase0,
                               input bit entered = 0, input bit grabbed = 0);
        aip_ral_run_state copied;
        if (!owns(candidate) || state0 == null || state0.is_test != committed.is_test ||
            phase0 < AIP_RAL_PHASE_DISPATCH || phase0 >= AIP_RAL_PHASE_NONE ||
            phase0 == AIP_RAL_PHASE_LEDGER || phase0 == AIP_RAL_PHASE_RECOVERY) return 0;
        foreach (selected[i]) begin
            if (!state0.contains_leaf(selected[i])) return 0;
            for (int j = 0; j < i; j++) if (selected[j] == selected[i]) return 0;
        end
        if (committed.inventory_complete && !state0.inventory_complete) return 0;
        if (committed.reset_attempted && !state0.reset_attempted) return 0;
        if (committed.reset_performed && !state0.reset_performed) return 0;
        if (state0.reset_performed && !state0.reset_attempted) return 0;
        if (state0.reset_attempted && (!state0.inventory_complete || !state0.destructive)) return 0;
        copied = state0.copy_state();
        if (copied.code == AIP_RAL_CODE_NONE && copied.global_errors == 0) copied.phase = phase0;
        if (committed.restore == AIP_RAL_RESTORE_FAILED) copied.restore = AIP_RAL_RESTORE_FAILED;
        committed = copied;
        if (recovery_latched) committed.recovery_required = 1;
        active_ids = selected;
        current_phase = phase0;
        entered_external |= entered;
        grab_pending = grabbed;
        if (committed.recovery_required || committed.restore == AIP_RAL_RESTORE_FAILED) latch_recovery();
        return 1;
    endfunction

    // 对外读取再深拷贝；调用者无法通过快照句柄更改已发布报告或永久latch。
    function aip_ral_run_state snapshot();
        if (committed == null) return null;
        return committed.copy_state();
    endfunction

    // 首次触发永久保存安全字段；当前响应立即置位，后续发布不得清除恢复门禁。
    local function void latch_recovery();
        committed.recovery_required = 1;
        if (recovery_latched) return;
        latched_side_effects = committed.side_effects;
        latched_partial = committed.partial;
        latched_restore = committed.restore;
        latched_resumed = committed.resumed;
        recovery_latched = 1;
    endfunction

    // 活owner声明协作取消；clean仅在全部cleanup/restore/resume确已验证时可传1。
    // 明确不确定partial或恢复失败会否决clean，不能靠请求参数清除安全义务。
    function bit cancel(aip_ral_owner_token candidate, bit cleanup_verified);
        if (!owns(candidate)) return 0;
        cancel_clean = cleanup_verified && !grab_pending && !aip_cmd_seq_registry::has_owner(owner) &&
                       committed.partial == AIP_RAL_ZERO && committed.resumed &&
                       (committed.restore inside {AIP_RAL_RESTORE_NOT_REQUIRED, AIP_RAL_RESTORE_COMPLETED});
        return execution.request_cancel();
    endfunction

    // listener的唯一终态入口；严格按执行对象核对，不接受旧generation迟到事件。
    // hard kill不启动任何清理task；只更新active/PENDING、latch和独立结果快照。
    virtual function void on_terminal(aip_cmd_execution execution, aip_cmd_end_e reason);
        bit owner_dead, safe_kill, upgrade_active, normal_leak;
        aip_ral_code_e code0;
        string result_text, why;
        longint unsigned required_bytes;
        process ended_owner;
        if (execution == null || execution != this.execution || !execution.is_terminal() ||
            execution.get_end_reason() != reason || dead_generation == generation) return;
        dead_generation = generation;
        ended_owner = execution.get_owner();
        owner_dead = ended_owner.status() inside {process::KILLED, process::FINISHED};
        normal_leak = reason == AIP_CMD_COMPLETED &&
                      (grab_pending || aip_cmd_seq_registry::has_owner(ended_owner));
        if (normal_leak) begin
            committed.interrupt_state(active_ids, 1, AIP_RAL_CODE_BUS_ERROR,
                                      "unclosed_sequence_or_grab", "aborted_after_error");
            void'(committed.record_error(AIP_RAL_CODE_BUS_ERROR, current_phase));
            committed.partial = AIP_RAL_UNKNOWN;
            if (committed.side_effects != AIP_RAL_ONE) committed.side_effects = AIP_RAL_UNKNOWN;
            if (committed.restore < AIP_RAL_RESTORE_NOT_GUARANTEED)
                committed.restore = AIP_RAL_RESTORE_NOT_GUARANTEED;
            committed.resumed = 0;
            latch_recovery();
        end
        if (reason != AIP_CMD_COMPLETED) begin
            code0 = reason == AIP_CMD_WATCHDOG ? AIP_RAL_CODE_WATCHDOG_TIMEOUT : AIP_RAL_CODE_CANCELLED;
            safe_kill = (current_phase inside {AIP_RAL_PHASE_PARSE, AIP_RAL_PHASE_INVENTORY}) &&
                        !entered_external && !grab_pending && !execution.had_sequence() &&
                        !aip_cmd_seq_registry::has_owner(execution.get_owner()) &&
                        committed.side_effects == AIP_RAL_ZERO && committed.partial == AIP_RAL_ZERO &&
                        !committed.reset_attempted && committed.resumed &&
                        committed.restore == AIP_RAL_RESTORE_NOT_REQUIRED;
            upgrade_active = owner_dead ?
                (current_phase inside {AIP_RAL_PHASE_ACTION, AIP_RAL_PHASE_OBSERVE, AIP_RAL_PHASE_RESTORE}) :
                !cancel_clean;
            committed.interrupt_state(active_ids, upgrade_active, code0,
                reason == AIP_CMD_WATCHDOG ? "watchdog_killed" : "cancel_cleanup_failed",
                reason == AIP_CMD_WATCHDOG ? "aborted_after_watchdog" : "aborted_after_cancel");
            void'(committed.record_error(code0, current_phase));
            if ((owner_dead && !safe_kill) || (!owner_dead && !cancel_clean)) begin
                if (owner_dead) begin
                    if (committed.side_effects != AIP_RAL_ONE) committed.side_effects = AIP_RAL_UNKNOWN;
                    committed.partial = AIP_RAL_UNKNOWN;
                    if (committed.restore < AIP_RAL_RESTORE_NOT_GUARANTEED)
                        committed.restore = AIP_RAL_RESTORE_NOT_GUARANTEED;
                    committed.resumed = 0;
                end
                latch_recovery();
            end
        end
        if (recovery_latched) committed.recovery_required = 1;
        active_ids.delete();
        if ((reason != AIP_CMD_COMPLETED || normal_leak || committed.recovery_required) &&
            aip_ral_formatter::format_report(committed, 0, result_text, required_bytes, why) == AIP_RAL_CFG_OK)
            void'(execution.publish_terminal_result(this, result_text));
    endfunction
endclass

`endif
