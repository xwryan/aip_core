// 公共 scoreboard 的表格报告：问题行汇总与定宽渲染，只读统计不改状态。
`ifndef AIP_SCB_REPORTER_SV
`define AIP_SCB_REPORTER_SV

class aip_scb_report_row;
    string cells[$];
endclass

class aip_scb_reporter;
    string m_headers[$];
    bit m_numeric[$];
    int m_widths[$];
    aip_scb_report_row m_rows[$];

    function void set_columns(input string headers[$], input bit numeric[$]);
        m_headers.delete();
        m_numeric.delete();
        m_widths.delete();
        m_rows.delete();
        if (headers.size() == 0 || headers.size() != numeric.size())
            return;
        m_headers = headers;
        m_numeric = numeric;
        foreach (m_headers[i]) m_widths.push_back(m_headers[i].len());
    endfunction

    function void add_row(input string cells[$]);
        aip_scb_report_row row;
        if (m_headers.size() == 0 || cells.size() != m_headers.size())
            return;
        row = new();
        row.cells = cells;
        foreach (cells[i])
            if (cells[i].len() > m_widths[i]) m_widths[i] = cells[i].len();
        m_rows.push_back(row);
    endfunction

    local function string repeat_char(string value, int count);
        string result = "";
        repeat (count) result = {result, value};
        return result;
    endfunction

    local function string format_cell(string value, int width, bit numeric);
        int padding = width - value.len();
        if (numeric) return {repeat_char(" ", padding), value};
        return {value, repeat_char(" ", padding)};
    endfunction

    local function string border();
        string line = "+";
        foreach (m_widths[i]) line = {line, repeat_char("-", m_widths[i]+2), "+"};
        return line;
    endfunction

    local function string render_cells(input string cells[$]);
        string line = "|";
        foreach (cells[i])
            line = {line, " ", format_cell(cells[i], m_widths[i], m_numeric[i]), " |"};
        return line;
    endfunction

    function string render();
        string text;
        if (m_headers.size() == 0) return "";
        text = {border(), "\n", render_cells(m_headers), "\n", border()};
        if (m_rows.size() == 0) return text;
        foreach (m_rows[i]) text = {text, "\n", render_cells(m_rows[i].cells)};
        return {text, "\n", border()};
    endfunction
endclass

`endif
