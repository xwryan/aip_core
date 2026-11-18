// 整笔事务采样 hub：monitor 的 analysis port 是唯一数据源，每个 portid 订阅持有独立深拷贝队列。
// 没有订阅时不保留历史；复位清空队列但保留订阅和等待者，已被取走的事务由消费者按 epoch 处理。
`ifndef AIP_MON_HUB_SV
`define AIP_MON_HUB_SV

// 复位通知按值发布：asserted 为当前复位状态，epoch 在每次断言时加一。
typedef struct {
    bit          asserted;
    int unsigned epoch;
} aip_mon_reset_t;

// 槽独立成对象：取消后旧等待者仍引用旧槽，不会误取同编号新订阅的数据。
class aip_mon_slot #(type T = uvm_sequence_item);
    T            items[$];
    int unsigned depth;
    bit          active = 1;
    process      reader;

    function new(int unsigned depth);
        this.depth = depth;
    endfunction
endclass

class aip_mon_hub #(type T = uvm_sequence_item) extends uvm_component;
    `uvm_component_param_utils(aip_mon_hub#(T))

    uvm_analysis_imp#(T, aip_mon_hub#(T)) analysis_export;
    uvm_analysis_port#(aip_mon_reset_t)    reset_ap;

    protected aip_mon_slot#(T) m_slots[int unsigned];
    protected bit              m_reset_known;
    protected bit              m_in_reset;
    protected int unsigned     m_reset_epoch;
    protected aip_mon_reset_t  m_last_notice;
    protected event            m_reset_changed;

    function new(string name = "aip_mon_hub", uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        reset_ap = new("reset_ap", this);
    endfunction

    // 未订阅时报错，不隐式订阅。
    protected function aip_mon_slot#(T) get_slot(int unsigned portid);
        if (!m_slots.exists(portid)) begin
            `uvm_fatal("AIP_MON_SUB", $sformatf("%s: consumer %0d is not subscribed", get_full_name(), portid))
            return null;
        end
        return m_slots[portid];
    endfunction

    // 必须先订阅再产生流量；同编号重复订阅视为配置错误，不清空已有队列。
    function void subscribe(int unsigned portid = 0, int unsigned depth = 1024);
        if (depth == 0 || m_slots.exists(portid)) begin
            `uvm_fatal("AIP_MON_CFG", $sformatf("%s: subscription %0d needs a positive depth and an unused portid",
                                                 get_full_name(), portid))
            return;
        end
        m_slots[portid] = new(depth);
    endfunction

    // 清空队列并唤醒旧等待者（返回 null）；重复取消无副作用，重订阅建立新槽。
    function void unsubscribe(int unsigned portid = 0);
        aip_mon_slot#(T) slot;
        if (!m_slots.exists(portid)) return;
        slot = m_slots[portid];
        slot.active = 0;
        slot.items.delete();
        m_slots.delete(portid);
    endfunction

    function bit is_subscribed(int unsigned portid = 0);
        return m_slots.exists(portid);
    endfunction

    function int unsigned pending(int unsigned portid = 0);
        return m_slots.exists(portid) ? m_slots[portid].items.size() : 0;
    endfunction

    // 只表示所有订阅队列为空；结束测试还需核对数量和 driver/monitor/消费者在途状态。
    function bit is_idle();
        foreach (m_slots[p]) if (m_slots[p].items.size() != 0) return 0;
        return 1;
    endfunction

    // 有事务立即返回，否则阻塞到入队、取消或非零 timeout 到期（复位不重新计时）；取消/超时返回 null，超时报 ERROR。
    // 同一订阅同时只允许一个活跃读者；读者进程被 kill 后可由新读者接管。
    task mon_xaction(output T tr, input int unsigned portid = 0, input time timeout = 0);
        aip_mon_slot#(T) slot;
        time started, remaining;
        tr = null;
        slot = get_slot(portid);
        if (slot == null) return;
        if (slot.reader != null && !(slot.reader.status() inside {process::FINISHED, process::KILLED})) begin
            `uvm_fatal("AIP_MON_READER", $sformatf("%s: subscription %0d already has a live reader; use another portid",
                                                    get_full_name(), portid))
            return;
        end
        slot.reader = process::self();
        started = $time;
        forever begin
            if (!slot.active) begin
                slot.reader = null;
                return;
            end
            if (slot.items.size() != 0) begin
                tr = slot.items.pop_front();
                slot.reader = null;
                return;
            end
            if (timeout != 0 && $time - started >= timeout) begin
                slot.reader = null;
                `uvm_error("AIP_MON_TIMEOUT", $sformatf("%s: no transaction for consumer %0d within %0t",
                                                        get_full_name(), portid, timeout))
                return;
            end
            remaining = (timeout == 0) ? 0 : timeout - ($time - started);
            // 独立子进程限定 disable fork 的范围；唤醒后重新检查，同一时刻的复位可能已清掉刚入队的事务。
            fork
                begin
                    fork
                        wait (!slot.active || slot.items.size() != 0);
                        begin
                            if (timeout != 0) #(remaining);
                            else wait (1'b0);
                        end
                    join_any
                    disable fork;
                end
            join
        end
    endtask

    // 先检查全部订阅容量再复制：fatal 被 catcher 吞掉时也不会部分广播；复位期间到达的事务丢弃。
    function void write(T tr);
        T copy;
        if (tr == null) begin
            `uvm_fatal("AIP_MON_NULL", $sformatf("%s: monitor published a null transaction", get_full_name()))
            return;
        end
        if (m_reset_known && m_in_reset) return;
        foreach (m_slots[p]) begin
            if (m_slots[p].items.size() >= m_slots[p].depth) begin
                `uvm_fatal("AIP_MON_OVERFLOW", $sformatf("%s: consumer %0d exceeded %0d queued transactions",
                                                         get_full_name(), p, m_slots[p].depth))
                return;
            end
        end
        foreach (m_slots[p]) begin
            if (!$cast(copy, tr.clone())) begin
                `uvm_fatal("AIP_MON_CLONE", $sformatf("%s: clone() returned an unexpected type", get_full_name()))
                return;
            end
            m_slots[p].items.push_back(copy);
        end
    endfunction

    // agent 在复位沿调用：首次调用同步状态，之后只处理变化；断言时先清队列再通知。
    function void set_reset(bit asserted);
        if (m_reset_known && m_in_reset == asserted) return;
        m_reset_known = 1;
        m_in_reset = asserted;
        if (asserted) begin
            m_reset_epoch++;
            foreach (m_slots[p]) m_slots[p].items.delete();
        end
        m_last_notice.asserted = asserted;
        m_last_notice.epoch = m_reset_epoch;
        reset_ap.write(m_last_notice);
        -> m_reset_changed;
    endfunction

    function bit in_reset();
        return m_reset_known && m_in_reset;
    endfunction

    // 每次复位断言加一；消费者在处理前后比较，变化说明期间发生过复位，应丢弃旧结果。
    function int unsigned reset_epoch();
        return m_reset_epoch;
    endfunction

    // 阻塞到下一次复位状态变化并返回该次通知；供不想声明 analysis imp 的消费者使用。
    task wait_reset(output aip_mon_reset_t notice);
        @(m_reset_changed);
        notice = m_last_notice;
    endtask
endclass

`endif
