// agent 采样/发包的 sequencer 与 sequence 基类：RM/SCB 持有长期 sequence 对象，只用 set_sequencer
// 关联、不调用 start()，经本 agent 的 monitor hub 订阅并拉取整笔事务；发包仍走普通 start_item/finish_item。
`ifndef AIP_SAMPLE_SEQ_SV
`define AIP_SAMPLE_SEQ_SV

// 持有本 agent 的 hub；connect 后按所在 agent 的全名登记，供 test/Tcl 按名查找，final 时撤销。
// passive agent 也创建本 sequencer，can_send=0 表示只能采样不能发包。
class aip_sample_sqr #(type T = uvm_sequence_item) extends uvm_sequencer #(T);
    `uvm_component_param_utils(aip_sample_sqr#(T))

    aip_mon_hub#(T) m_hub;
    bit             can_send;

    protected static aip_sample_sqr#(T) m_by_name[string];
    protected string                    m_registered_name;

    function new(string name = "aip_sample_sqr", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 登记名取所在 agent 的全名（直接挂在 root 下时取自身全名）；同名重复登记报错，避免两个 agent 互相覆盖。
    function void connect_phase(uvm_phase phase);
        uvm_component owner = get_parent();
        super.connect_phase(phase);
        m_registered_name = (owner != null && owner != uvm_root::get()) ? owner.get_full_name() : get_full_name();
        if (m_by_name.exists(m_registered_name) && m_by_name[m_registered_name] != this) begin
            `uvm_fatal("AIP_SAMPLE_NAME", {"duplicate sampling sequencer name: ", m_registered_name})
            return;
        end
        m_by_name[m_registered_name] = this;
    endfunction

    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        if (m_registered_name != "" && m_by_name.exists(m_registered_name) && m_by_name[m_registered_name] == this)
            m_by_name.delete(m_registered_name);
    endfunction

    // connect_phase 之后可用；找不到返回 null，由调用者决定是否报错。
    static function aip_sample_sqr#(T) get_sqr(string agent_name);
        return m_by_name.exists(agent_name) ? m_by_name[agent_name] : null;
    endfunction
endclass

// 采样接口全部委托给 sequencer 上的 hub；同一 agent 的多个消费者用不同 portid 各取一份。
class aip_sample_seq #(type T = uvm_sequence_item) extends uvm_sequence #(T);
    `uvm_object_param_utils(aip_sample_seq#(T))

    function new(string name = "aip_sample_seq");
        super.new(name);
    endfunction

    // 采样允许 passive sequencer；未关联或 sequencer 没有 hub 时 fatal。
    protected function aip_mon_hub#(T) require_hub();
        aip_sample_sqr#(T) sqr;
        if (!$cast(sqr, get_sequencer()) || sqr == null) begin
            `uvm_fatal("AIP_SAMPLE_SQR", "associate an aip_sample_sqr with set_sequencer() before sampling")
            return null;
        end
        if (sqr.m_hub == null) begin
            `uvm_fatal("AIP_SAMPLE_HUB", {sqr.get_full_name(), " has no monitor hub"})
            return null;
        end
        return sqr.m_hub;
    endfunction

    function void subscribe(int unsigned portid = 0, int unsigned depth = 1024);
        aip_mon_hub#(T) hub = require_hub();
        if (hub != null) hub.subscribe(portid, depth);
    endfunction

    // timeout=0 无限等待；超时/取消返回 null（复位清队列但继续等待），调用者必须检查返回句柄。
    task mon_xaction(output T tr, input int unsigned portid = 0, input time timeout = 0);
        aip_mon_hub#(T) hub = require_hub();
        tr = null;
        if (hub != null) hub.mon_xaction(tr, portid, timeout);
    endtask

    // 发包结束不会自动取消持久订阅。
    function void unsubscribe(int unsigned portid = 0);
        aip_mon_hub#(T) hub = require_hub();
        if (hub != null) hub.unsubscribe(portid);
    endfunction

    function int unsigned pending(int unsigned portid = 0);
        aip_mon_hub#(T) hub = require_hub();
        return (hub == null) ? 0 : hub.pending(portid);
    endfunction

    function int unsigned reset_epoch();
        aip_mon_hub#(T) hub = require_hub();
        return (hub == null) ? 0 : hub.reset_epoch();
    endfunction

    task wait_reset(output aip_mon_reset_t notice);
        aip_mon_hub#(T) hub = require_hub();
        if (hub != null) hub.wait_reset(notice);
    endtask
endclass

`endif
