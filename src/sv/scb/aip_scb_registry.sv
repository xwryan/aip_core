// 公共 scoreboard 的名字登记表：按实例名查控制代理，供 Tcl 命令查询状态和报告。
`ifndef AIP_SCB_REGISTRY_SV
`define AIP_SCB_REGISTRY_SV

virtual class aip_scb_control_proxy extends uvm_object;
    function new(string name="aip_scb_control_proxy");
        super.new(name);
    endfunction
    pure virtual function string scoreboard_name();
    pure virtual function aip_scb_status_e status();
    pure virtual function string summary();
    pure virtual function void report(int limit=-2);
    pure virtual function bit set_report_limit(int limit, output string error);
endclass

class aip_scb_registry;
    local static aip_scb_control_proxy m_proxies[string];

    static function bit register_proxy(aip_scb_control_proxy proxy,
                                       output string error);
        string name;
        if (proxy == null) begin
            error = "cannot register a null scoreboard proxy";
            return 0;
        end
        name = proxy.scoreboard_name();
        if (name == "") begin
            error = "cannot register a scoreboard with an empty name";
            return 0;
        end
        if (m_proxies.exists(name)) begin
            error = $sformatf("scoreboard '%s' is already registered", name);
            return 0;
        end
        m_proxies[name] = proxy;
        error = "";
        return 1;
    endfunction

    static function aip_scb_control_proxy find(string name);
        if (!m_proxies.exists(name)) return null;
        return m_proxies[name];
    endfunction

    static function void get_names(ref string names[$]);
        names.delete();
        foreach (m_proxies[name]) names.push_back(name);
        names.sort();
    endfunction

    static function int size();
        return m_proxies.num();
    endfunction
endclass

`endif
