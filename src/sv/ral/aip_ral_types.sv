// RAL 报告类型与纯格式化工具：不拥有模型、不发起 DUT 访问，每次运行的数据实例归调用者。
`ifndef AIP_RAL_TYPES_SV
`define AIP_RAL_TYPES_SV

localparam int AIP_RAL_RESULT_LIMIT = 1024;
localparam int AIP_RAL_DATA_BITS = (`UVM_REG_DATA_WIDTH < AIP_VEC_MAX_BITS) ?
                                  `UVM_REG_DATA_WIDTH : AIP_VEC_MAX_BITS;
typedef aip_vec_t aip_ral_vec_t;
typedef logic [AIP_VEC_MAX_BITS-1:0] aip_ral_logic_t;
typedef longint unsigned aip_ral_leaf_id_t;
typedef enum {AIP_RAL_MSW_FIRST, AIP_RAL_LSW_FIRST} aip_ral_mem_beat_order_e;
typedef enum {AIP_RAL_CFG_OK, AIP_RAL_CFG_BAD_ARG, AIP_RAL_CFG_DUPLICATE,
              AIP_RAL_CFG_FROZEN, AIP_RAL_CFG_INVALID, AIP_RAL_CFG_UNSUPPORTED} aip_ral_cfg_status_e;
typedef enum {AIP_RAL_BUS_OK, AIP_RAL_BUS_ACCESS_REJECT, AIP_RAL_BUS_ERROR} aip_ral_bus_status_e;
typedef enum {AIP_RAL_LEAF_PENDING, AIP_RAL_LEAF_PASS, AIP_RAL_LEAF_EXCLUDED,
              AIP_RAL_LEAF_FAIL, AIP_RAL_LEAF_ERROR, AIP_RAL_LEAF_UNTESTABLE} aip_ral_leaf_status_e;
typedef enum {AIP_RAL_PHASE_DISPATCH, AIP_RAL_PHASE_PARSE, AIP_RAL_PHASE_VALIDATE,
              AIP_RAL_PHASE_INVENTORY, AIP_RAL_PHASE_LEDGER, AIP_RAL_PHASE_PREFLIGHT,
              AIP_RAL_PHASE_RECOVERY, AIP_RAL_PHASE_QUIESCE, AIP_RAL_PHASE_RESET,
              AIP_RAL_PHASE_MODEL_RESET, AIP_RAL_PHASE_RESET_OBSERVE, AIP_RAL_PHASE_ACTION,
              AIP_RAL_PHASE_OBSERVE, AIP_RAL_PHASE_RESTORE, AIP_RAL_PHASE_RESUME,
              AIP_RAL_PHASE_FORMAT, AIP_RAL_PHASE_NONE} aip_ral_phase_e;
typedef enum {AIP_RAL_CODE_NONE, AIP_RAL_CODE_BAD_ARGS, AIP_RAL_CODE_NOT_FOUND,
              AIP_RAL_CODE_NOT_IN_MAP, AIP_RAL_CODE_WIDTH_OVERFLOW, AIP_RAL_CODE_INDEX_RANGE,
              AIP_RAL_CODE_ACCESS_DENIED, AIP_RAL_CODE_UNSAFE_READ, AIP_RAL_CODE_UNSAFE_RMW,
              AIP_RAL_CODE_UNSUPPORTED, AIP_RAL_CODE_X_DATA, AIP_RAL_CODE_BUS_ERROR,
              AIP_RAL_CODE_BUSY, AIP_RAL_CODE_CONFIG_ERROR, AIP_RAL_CODE_HOOK_ERROR,
              AIP_RAL_CODE_UNTESTABLE, AIP_RAL_CODE_CANCELLED, AIP_RAL_CODE_WATCHDOG_TIMEOUT,
              AIP_RAL_CODE_RECOVERY_REQUIRED, AIP_RAL_CODE_RESULT_TOO_LARGE,
              AIP_RAL_CODE_POLICY_MISMATCH, AIP_RAL_CODE_BACKDOOR_ERROR,
              AIP_RAL_CODE_RESTORE_ERROR} aip_ral_code_e;
typedef enum {AIP_RAL_ZERO, AIP_RAL_ONE, AIP_RAL_UNKNOWN} aip_ral_tristate_e;
typedef enum {AIP_RAL_RESTORE_NOT_REQUIRED, AIP_RAL_RESTORE_COMPLETED,
              AIP_RAL_RESTORE_REQUIRES_RESET, AIP_RAL_RESTORE_NOT_GUARANTEED,
              AIP_RAL_RESTORE_FAILED} aip_ral_restore_e;
typedef enum {AIP_RAL_MEM_NONE, AIP_RAL_MEM_ADDRESS_LINE, AIP_RAL_MEM_ALL} aip_ral_mem_mode_e;
typedef enum {AIP_RAL_SCOPE_NONE, AIP_RAL_SCOPE_SELECTED, AIP_RAL_SCOPE_ALL} aip_ral_restore_scope_e;

class aip_ral_names;
    // 去掉内部枚举前缀，外部错误码命名空间保持稳定。
    static function string code(aip_ral_code_e value);
        string name0=value.name();
        return value==AIP_RAL_CODE_NONE ? "none" : name0.substr(13,name0.len()-1);
    endfunction

    // phase按声明顺序排序；ledger/recovery只保留名字，不驱动流程。
    static function string phase(aip_ral_phase_e value);
        string name0=value.name();
        return name0.substr(14,name0.len()-1).tolower();
    endfunction

    // 叶状态仅用于账本，PENDING不能作为最终成功结果。
    static function string leaf(aip_ral_leaf_status_e value);
        string name0=value.name();
        return name0.substr(13,name0.len()-1);
    endfunction

    // 三态描述完成性，不借用二态默认值掩盖未知。
    static function string tristate_text(aip_ral_tristate_e value);
        case(value) AIP_RAL_ZERO:return "0"; AIP_RAL_ONE:return "1"; default:return "unknown"; endcase
    endfunction

    // restore枚举自身按严重程度递增，可安全聚合最高义务。
    static function string restore(aip_ral_restore_e value);
        string name0=value.name();
        return name0.substr(16,name0.len()-1).tolower();
    endfunction

    // memory模式仅影响报告范围，不执行测试。
    static function string mem_mode(aip_ral_mem_mode_e value);
        case(value) AIP_RAL_MEM_ALL:return "all"; AIP_RAL_MEM_ADDRESS_LINE:return "address-line"; default:return "none"; endcase
    endfunction

    // 恢复范围描述已选择集合，不声明未选地址已恢复。
    static function string scope(aip_ral_restore_scope_e value);
        case(value) AIP_RAL_SCOPE_ALL:return "all"; AIP_RAL_SCOPE_SELECTED:return "selected"; default:return "none"; endcase
    endfunction
endclass

// 调用者拥有的报告快照，与可变运行账本分层，格式化不修改快照。
class aip_ral_report;
    bit is_test=1;
    string requested_target,effective_target,am,detail;
    bit inventory_complete,reset_attempted,reset_performed,destructive;
    longint unsigned total,fields,memories,passed,excluded,failed,errors,untestable;
    longint unsigned memory_entries_tested,write_once_consumed,not_applicable,global_errors;
    aip_ral_mem_mode_e mem_mode=AIP_RAL_MEM_NONE;
    aip_ral_restore_scope_e restore_scope=AIP_RAL_SCOPE_NONE;
    aip_ral_code_e code=AIP_RAL_CODE_NONE,first_code=AIP_RAL_CODE_NONE;
    aip_ral_phase_e phase=AIP_RAL_PHASE_NONE;
    aip_ral_leaf_status_e first_status=AIP_RAL_LEAF_PENDING;
    string first;
    aip_ral_tristate_e side_effects=AIP_RAL_ZERO,partial=AIP_RAL_ZERO;
    aip_ral_restore_e restore=AIP_RAL_RESTORE_NOT_REQUIRED;
    bit resumed=1,recovery_required;
    function new(); endfunction

    // 采用扩展位宽求和，拒绝uint64溢出伪造的计数守恒。
    function bit counts_complete();
        bit [67:0] object_sum,result_sum;
        object_sum=68'(fields)+68'(memories);
        result_sum=68'(passed)+68'(excluded)+68'(failed)+68'(errors)+68'(untestable);
        return inventory_complete && total!=0 && object_sum==68'(total) && result_sum==68'(total);
    endfunction

    // 顶层优先级：命令错误优先；尚未提交/结清的inventory永不PASS。
    function string status();
        if(code!=AIP_RAL_CODE_NONE || global_errors!=0) return "ERROR";
        if(!is_test) return "OK";
        if(!counts_complete()) return "ERROR";
        if(errors!=0 || failed!=0 || untestable!=0) return "FAIL";
        return "PASS";
    endfunction
endclass

// run_state拥有叶记录；只保存稳定身份与结果，不持有RAL/DUT句柄。
class aip_ral_leaf_record;
    aip_ral_leaf_id_t id;
    string canonical_name;
    string reason;
    bit is_memory;
    aip_ral_leaf_status_e status=AIP_RAL_LEAF_PENDING;
    aip_ral_code_e code=AIP_RAL_CODE_NONE;
    function new(aip_ral_leaf_id_t id0,string name0,bit memory0);
        id=id0;
        canonical_name=name0;
        is_memory=memory0;
    endfunction
endclass

// 单次命令账本：拥有全部叶记录（leaf ID 仅在本次 run 内有效），提供 listener 所需深拷贝/中断结账，不拥有锁或测试策略。
class aip_ral_run_state extends aip_ral_report;
    local aip_ral_leaf_record leaves[$];
    local string global_root;
    local longint unsigned global_case;
    function new(); super.new(); endfunction

    // 原子发布用深拷贝：标量/string值复制，私有leaf逐一复制，绝不借用调用者记录。
    function aip_ral_run_state copy_state();
        aip_ral_run_state copied;
        copied = new this;
        foreach (leaves[i]) begin
            aip_ral_leaf_record leaf0 = new(leaves[i].id, leaves[i].canonical_name, leaves[i].is_memory);
            leaf0.status = leaves[i].status;
            leaf0.code = leaves[i].code;
            leaf0.reason = leaves[i].reason;
            copied.leaves[i] = leaf0;
        end
        return copied;
    endfunction

    // 发布active集合前确认身份属于已提交inventory；重复ID由service拒绝。
    function bit contains_leaf(aip_ral_leaf_id_t id0);
        return inventory_complete && id0 != 0 && id0 <= leaves.size();
    endfunction

    // 未知/未提交 ID 返回空串。
    function string leaf_reason(aip_ral_leaf_id_t id0);
        if (!contains_leaf(id0)) return "";
        return leaves[id0-1].reason;
    endfunction

    // 框架中断专用：必要时升级active内非EXCLUDED结果，保留active之外所有终态。
    // 随后结清PENDING；这不是普通finish_leaf的二次结账入口，不发起任何清理task。
    function void interrupt_state(input aip_ral_leaf_id_t active_ids[$],
                                  input bit upgrade_active, input aip_ral_code_e code0,
                                  input string active_reason = "interrupted",
                                  input string pending_reason = "aborted_after_error");
        if (!inventory_complete) return;
        if (upgrade_active) foreach (active_ids[i]) begin
            if (contains_leaf(active_ids[i]) && leaves[active_ids[i]-1].status != AIP_RAL_LEAF_EXCLUDED) begin
                leaves[active_ids[i]-1].status = AIP_RAL_LEAF_ERROR;
                leaves[active_ids[i]-1].code = code0;
                leaves[active_ids[i]-1].reason = active_reason;
                `uvm_info("AIP_RAL_LEAF_END", $sformatf("leaf=%s status=ERROR code=%s reason=%s",
                    leaves[active_ids[i]-1].canonical_name, aip_ral_names::code(code0), active_reason), UVM_LOW)
            end
        end
        foreach (leaves[i]) if (leaves[i].status == AIP_RAL_LEAF_PENDING) begin
            leaves[i].reason = pending_reason;
            `uvm_info("AIP_RAL_LEAF_END", $sformatf("leaf=%s status=UNTESTABLE code=UNTESTABLE reason=%s",
                leaves[i].canonical_name, pending_reason), UVM_LOW)
        end
        settle_pending();
    endfunction

    // inventory提交前分配稳定递增ID；失败不改变账本。
    function bit add_leaf(string name0,bit memory0,output aip_ral_leaf_id_t id0,output string why);
        aip_ral_leaf_record leaf0;
        id0=0;
        why="";
        if(inventory_complete) begin why="inventory already committed"; return 0; end
        if(name0=="") begin why="empty canonical name"; return 0; end
        foreach(leaves[i]) if(leaves[i].canonical_name==name0) begin why="duplicate canonical name"; return 0; end
        id0=leaves.size()+1;
        leaf0=new(id0,name0,memory0);
        leaves.push_back(leaf0);
        return 1;
    endfunction

    // 空inventory在提交前失败，不制造total=0的PASS。
    function bit commit_inventory(output string why);
        why="";
        if(inventory_complete) begin why="inventory already committed"; return 0; end
        if(leaves.size()==0) begin why="empty physical inventory"; return 0; end
        total=leaves.size();
        fields=0;
        memories=0;
        foreach(leaves[i]) if(leaves[i].is_memory) memories++; else fields++;
        inventory_complete=1;
        return 1;
    endfunction

    // 叶错误排序与顶层FAIL排序分离，ERROR优先于FAIL和UNTESTABLE。
    local function int rank(aip_ral_leaf_status_e value);
        case(value) AIP_RAL_LEAF_ERROR:return 3; AIP_RAL_LEAF_FAIL:return 2; AIP_RAL_LEAF_UNTESTABLE:return 1; default:return 0; endcase
    endfunction

    // 重建计数及稳定case顺序的首失败，不按异步结账先后来漂移first。
    local function void recount();
        passed=0;
        excluded=0;
        failed=0;
        errors=0;
        untestable=0;
        first="";
        first_code=AIP_RAL_CODE_NONE;
        first_status=AIP_RAL_LEAF_PENDING;
        foreach(leaves[i]) begin
            case(leaves[i].status)
                AIP_RAL_LEAF_PASS:passed++;
                AIP_RAL_LEAF_EXCLUDED:excluded++;
                AIP_RAL_LEAF_FAIL:failed++;
                AIP_RAL_LEAF_ERROR:errors++;
                AIP_RAL_LEAF_UNTESTABLE:untestable++;
                default:;
            endcase
            if(rank(leaves[i].status)>rank(first_status)) begin
                first=leaves[i].canonical_name;
                first_code=leaves[i].code;
                first_status=leaves[i].status;
            end
        end
    endfunction

    // 每个已提交leaf只能结账一次；PENDING不是合法终态。
    function bit finish_leaf(aip_ral_leaf_id_t id0,aip_ral_leaf_status_e status0,aip_ral_code_e code0,output string why);
        why="";
        if(!inventory_complete || id0==0 || id0>leaves.size()) begin why="unknown or uncommitted leaf"; return 0; end
        if(status0<AIP_RAL_LEAF_PASS || status0>AIP_RAL_LEAF_UNTESTABLE ||
           code0<AIP_RAL_CODE_NONE || code0>AIP_RAL_CODE_RESTORE_ERROR ||
           leaves[id0-1].status!=AIP_RAL_LEAF_PENDING) begin
            why="invalid or duplicate finalization";
            return 0;
        end
        if((status0==AIP_RAL_LEAF_PASS || status0==AIP_RAL_LEAF_EXCLUDED) && code0!=AIP_RAL_CODE_NONE) begin why="successful leaf has error code"; return 0; end
        if(status0==AIP_RAL_LEAF_UNTESTABLE && code0!=AIP_RAL_CODE_UNTESTABLE) begin why="untestable requires stable code"; return 0; end
        if((status0==AIP_RAL_LEAF_FAIL || status0==AIP_RAL_LEAF_ERROR) && code0==AIP_RAL_CODE_NONE) begin why="failure requires code"; return 0; end
        leaves[id0-1].status=status0;
        leaves[id0-1].code=code0;
        recount();
        return 1;
    endfunction

    // 中止时只结清未开始/未完成的PENDING，不覆盖已有结果。
    function void settle_pending();
        if(!inventory_complete) return;
        foreach(leaves[i]) if(leaves[i].status==AIP_RAL_LEAF_PENDING) begin
            leaves[i].status=AIP_RAL_LEAF_UNTESTABLE;
            leaves[i].code=AIP_RAL_CODE_UNTESTABLE;
        end
        recount();
    endfunction

    // 命令错误按phase/root/case排序；同键保留首次记录，叶结果不被覆写。
    function bit record_error(aip_ral_code_e code0,aip_ral_phase_e phase0,string root0="",longint unsigned case0=0);
        if(code0<=AIP_RAL_CODE_NONE || code0>=AIP_RAL_CODE_POLICY_MISMATCH ||
           phase0<AIP_RAL_PHASE_DISPATCH || phase0>=AIP_RAL_PHASE_NONE ||
           phase0==AIP_RAL_PHASE_LEDGER || phase0==AIP_RAL_PHASE_RECOVERY ||
           global_errors=='1) return 0;
        if(global_errors==0 || phase0<phase || (phase0==phase && (root0<global_root || (root0==global_root && case0<global_case)))) begin
            code=code0;
            phase=phase0;
            global_root=root0;
            global_case=case0;
        end
        global_errors++;
        return 1;
    endfunction

    // reset开始即标记destructive，成功前不得伪造performed。
    function void reset_started();
        reset_attempted=1;
        destructive=1;
        side_effects=AIP_RAL_UNKNOWN;
    endfunction

    // 只有确已开始的reset才能标记成功。
    function bit reset_succeeded();
        if(!reset_attempted) return 0;
        reset_performed=1;
        side_effects=AIP_RAL_ONE;
        return 1;
    endfunction
endclass

// 纯输出层，不拥有调用者数据。
class aip_ral_formatter;
    // UTF-8文本转ASCII安全Tcl元素；非BMP用Tcl8.6支持的UTF-16转义对。
    static function string element(string value,output bit ok);
        string result="";
        int unsigned b,cp,n,minimum,part;
        ok=0;
        if(value.len()==0) begin ok=1; return "{}"; end
        for(int i=0;i<value.len();i++) begin
            b=value.getc(i)&255;
            if(b<128) begin
                case(b)
                    10:result={result,"\\\\n"};
                    13:result={result,"\\\\r"};
                    9:result={result,"\\t"};
                    32,34,36,59,91,92,93,123,125:result={result,"\\",$sformatf("%c",b)};
                    default:begin
                        if(b<32 || b==127) result={result,$sformatf("\\u%04x",b)};
                        else result={result,$sformatf("%c",b)};
                    end
                endcase
                continue;
            end
            if(b>=192 && b<=223) begin n=1; cp=b&31; minimum=128; end
            else if(b>=224 && b<=239) begin n=2; cp=b&15; minimum=2048; end
            else if(b>=240 && b<=244) begin n=3; cp=b&7; minimum=65536; end
            else return "";
            if(i+n>=value.len()) return "";
            for(int j=0;j<n;j++) begin
                i++; part=value.getc(i)&255;
                if((part&192)!=128) return "";
                cp=(cp<<6)|(part&63);
            end
            if(cp<minimum || cp>1114111 || (cp>=55296 && cp<=57343)) return "";
            if(cp<=65535) result={result,$sformatf("\\u%04x",cp)};
            else begin
                cp-=65536;
                result={result,$sformatf("\\u%04x\\u%04x",55296+(cp>>10),56320+(cp&1023))};
            end
        end
        ok=1; return result;
    endfunction

    // 添加整个key=value元素，失败时不发布截断或部分元素。
    local static function bit add(ref string result_text,input string key,input string value);
        bit ok; string encoded=element({key,"=",value},ok);
        if(!ok) return 0;
        result_text={result_text," ",encoded}; return 1;
    endfunction

    // uint64统一十进制，避免隐式有符号窄化破坏长度计算。
    local static function string number(longint unsigned value);
        return $sformatf("%0d",value);
    endfunction

    // 所有fallback必须保留完整安全envelope，不回显任意长度对象名。
    local static function void safety(ref string result_text,input aip_ral_report data0,input bit clean);
        void'(add(result_text,"side_effects",clean?"0":aip_ral_names::tristate_text(data0.side_effects)));
        void'(add(result_text,"partial",clean?"0":aip_ral_names::tristate_text(data0.partial)));
        void'(add(result_text,"restore",clean?"not_required":aip_ral_names::restore(data0.restore)));
        void'(add(result_text,"resumed",clean?"1":number(data0.resumed)));
        void'(add(result_text,"recovery_required",clean?"0":number(data0.recovery_required)));
    endfunction

    // 已提交inventory的计数schema，调用前由formatter验证守恒。
    local static function void counts(ref string result_text,input aip_ral_report data0);
        void'(add(result_text,"total",number(data0.total)));
        void'(add(result_text,"fields",number(data0.fields)));
        void'(add(result_text,"memories",number(data0.memories)));
        void'(add(result_text,"mem_mode",aip_ral_names::mem_mode(data0.mem_mode)));
        void'(add(result_text,"memory_entries_tested",number(data0.memory_entries_tested)));
        void'(add(result_text,"restore_scope",aip_ral_names::scope(data0.restore_scope)));
        void'(add(result_text,"reset_attempted",number(data0.reset_attempted)));
        void'(add(result_text,"reset_performed",number(data0.reset_performed)));
        void'(add(result_text,"destructive",number(data0.destructive)));
        void'(add(result_text,"write_once_consumed",number(data0.write_once_consumed)));
        void'(add(result_text,"passed",number(data0.passed)));
        void'(add(result_text,"excluded",number(data0.excluded)));
        void'(add(result_text,"failed",number(data0.failed)));
        void'(add(result_text,"errors",number(data0.errors)));
        void'(add(result_text,"untestable",number(data0.untestable)));
        void'(add(result_text,"not_applicable",number(data0.not_applicable)));
        void'(add(result_text,"global_errors",number(data0.global_errors)));
    endfunction

    // 固定有界fallback；调用者记录完整原结果，文本自身不包含可变长detail。
    static function string fallback(aip_ral_report data0,longint unsigned required_bytes,bit preflight);
        string result_text="ERROR code=RESULT_TOO_LARGE";
        aip_ral_code_e original_code=data0.code;
        if(data0.status()=="ERROR" && original_code==AIP_RAL_CODE_NONE) original_code=AIP_RAL_CODE_CONFIG_ERROR;
        void'(add(result_text,"command",data0.is_test?"ral_test":"ral_op"));
        if(data0.is_test) void'(add(result_text,"suite","policy"));
        if(!preflight) begin
            void'(add(result_text,"original_status",data0.status()));
            void'(add(result_text,"original_code",aip_ral_names::code(original_code)));
        end
        void'(add(result_text,"phase",preflight?"preflight":"format"));
        if(!preflight) void'(add(result_text,"original_phase",aip_ral_names::phase(data0.phase)));
        if(data0.is_test) begin
            void'(add(result_text,"inventory_complete",preflight?"0":number(data0.inventory_complete)));
            if(!preflight && data0.inventory_complete) counts(result_text,data0);
            else begin
                void'(add(result_text,"reset_attempted","0"));
                void'(add(result_text,"reset_performed","0"));
                void'(add(result_text,"destructive","0"));
            end
        end
        safety(result_text,data0,preflight);
        void'(add(result_text,"required_bytes",number(required_bytes)));
        void'(add(result_text,"limit",number(AIP_RAL_RESULT_LIMIT)));
        return result_text;
    endfunction

    // 普通报告先完整序列化再按桥接字节预算判断，不允许bridge静默截断。
    static function aip_ral_cfg_status_e format_report(aip_ral_report data0,bit preflight,
        output string result_text,output longint unsigned required_bytes,output string why);
        string original;
        bit valid=1;
        aip_ral_code_e code0;
        result_text=""; why=""; required_bytes=0;
        if(data0==null) begin why="null report"; return AIP_RAL_CFG_BAD_ARG; end
        if(data0.code<AIP_RAL_CODE_NONE || data0.code>=AIP_RAL_CODE_POLICY_MISMATCH) begin
            why="invalid top-level code or leaf-only code";
            return AIP_RAL_CFG_INVALID;
        end
        if(data0.phase<AIP_RAL_PHASE_DISPATCH || data0.phase>AIP_RAL_PHASE_NONE ||
           data0.phase==AIP_RAL_PHASE_LEDGER || data0.phase==AIP_RAL_PHASE_RECOVERY ||
           data0.side_effects<AIP_RAL_ZERO || data0.side_effects>AIP_RAL_UNKNOWN ||
           data0.partial<AIP_RAL_ZERO || data0.partial>AIP_RAL_UNKNOWN ||
           data0.restore<AIP_RAL_RESTORE_NOT_REQUIRED || data0.restore>AIP_RAL_RESTORE_FAILED ||
           data0.mem_mode<AIP_RAL_MEM_NONE || data0.mem_mode>AIP_RAL_MEM_ALL ||
           data0.restore_scope<AIP_RAL_SCOPE_NONE || data0.restore_scope>AIP_RAL_SCOPE_ALL) begin
            why="invalid report enum";
            return AIP_RAL_CFG_INVALID;
        end
        if(data0.inventory_complete && !data0.counts_complete()) begin why="unsettled or inconsistent inventory"; return AIP_RAL_CFG_INVALID; end
        if(data0.is_test && !data0.inventory_complete && data0.reset_attempted) begin
            why="reset attempted before inventory commit";
            return AIP_RAL_CFG_INVALID;
        end
        if(data0.inventory_complete && (data0.errors!=0 || data0.failed!=0 || data0.untestable!=0) &&
           (data0.first=="" || data0.first_status<AIP_RAL_LEAF_FAIL || data0.first_status>AIP_RAL_LEAF_UNTESTABLE ||
            data0.first_code<=AIP_RAL_CODE_NONE || data0.first_code>AIP_RAL_CODE_RESTORE_ERROR)) begin
            why="failed inventory missing first result";
            return AIP_RAL_CFG_INVALID;
        end
        if(preflight && (data0.reset_attempted || data0.destructive || data0.side_effects!=AIP_RAL_ZERO ||
           data0.partial!=AIP_RAL_ZERO || data0.restore!=AIP_RAL_RESTORE_NOT_REQUIRED ||
           !data0.resumed || data0.recovery_required)) begin
            why="preflight cannot erase existing safety obligations";
            return AIP_RAL_CFG_INVALID;
        end
        if(data0.reset_performed && !data0.reset_attempted) begin why="reset performed without attempt"; return AIP_RAL_CFG_INVALID; end
        if(data0.reset_attempted && !data0.destructive) begin why="reset attempt must be destructive"; return AIP_RAL_CFG_INVALID; end
        code0=data0.code;
        original=data0.status();
        if(original=="ERROR" && code0==AIP_RAL_CODE_NONE) code0=AIP_RAL_CODE_CONFIG_ERROR;
        if(code0!=AIP_RAL_CODE_NONE) valid&=add(original,"code",aip_ral_names::code(code0));
        valid&=add(original,"command",data0.is_test?"ral_test":"ral_op");
        if(data0.is_test) valid&=add(original,"suite","policy");
        if(data0.requested_target!="") valid&=add(original,"requested_target",data0.requested_target);
        if(data0.is_test && data0.inventory_complete) valid&=add(original,"effective_target",data0.effective_target);
        if(data0.am!="") valid&=add(original,"am",data0.am);
        if(data0.is_test) begin
            valid&=add(original,"inventory_complete",number(data0.inventory_complete));
            if(data0.inventory_complete) counts(original,data0);
            else begin
                valid&=add(original,"reset_attempted","0"); valid&=add(original,"reset_performed","0"); valid&=add(original,"destructive","0");
            end
        end
        if(data0.first!="" && data0.inventory_complete) begin
            valid&=add(original,"first_status",aip_ral_names::leaf(data0.first_status));
            valid&=add(original,"first",data0.first); valid&=add(original,"first_code",aip_ral_names::code(data0.first_code));
        end
        if(data0.phase!=AIP_RAL_PHASE_NONE) valid&=add(original,"phase",aip_ral_names::phase(data0.phase));
        safety(original,data0,0);
        if(data0.detail!="") valid&=add(original,"detail",data0.detail);
        if(!valid) begin why="invalid UTF-8 report text"; return AIP_RAL_CFG_BAD_ARG; end
        required_bytes=original.len();
        if(required_bytes<=AIP_RAL_RESULT_LIMIT) begin result_text=original; return AIP_RAL_CFG_OK; end
        // 完整原文进入UVM日志，不在固定fallback回显任意长度字符串。
        `uvm_info("AIP_RAL_RESULT_FULL",original,UVM_LOW)
        result_text=fallback(data0,required_bytes,preflight);
        if(result_text.len()>AIP_RAL_RESULT_LIMIT) begin result_text=""; why="bounded fallback exceeded limit"; return AIP_RAL_CFG_INVALID; end
        return AIP_RAL_CFG_OK;
    endfunction
endclass

`endif
