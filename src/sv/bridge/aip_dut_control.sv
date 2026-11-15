// 为 Socket/Tcl 命令注册表提供受控的 DUT HDL 访问白名单（不求值任意 UCLI/Tcl 文本），结果属于当前调用。
// force 的 HDL 生命周期独立：显式 release 或 force_signal_time 正常完成才释放，取消后台调用不会回滚已生效的 force。
`ifndef AIP_DUT_CONTROL_SV
`define AIP_DUT_CONTROL_SV

// 静态 facade 保留旧 task 签名：命令内复用当前上下文，直接 SV 调用自建临时 scope 并在每条返回路径释放，
// legacy 用户 task 中保留即时全局返回语义。结果隔离不等于信号互斥：同一 HDL 对象的并发 force/release 由调用方排序。
class aip_dut_control_ops;
    // readmem 文件先完整解析到队列，再开始写 DUT；因此文件格式错误不会留下
    // 半装载状态。真正 backdoor 写失败时，之前已经 deposit 的元素无法回滚。
    typedef longint unsigned aip_dut_mem_addr_t;

    // 失败时输出零并返回 0。
    static function bit decode_value(string text, output uvm_hdl_data_t value);
        int width;
        longint unsigned parsed;
        if (text == "") begin
            value = '0;
            return 0;
        end
        parsed = aip_str::str_to_num(aip_str::strip(text), width);
        // 解析失败/显式位宽溢出以 width=0 和全一哨兵共同标识；合法的无尺寸
        // 全一值保留非零 width，不能只根据 parsed 判断失败。
        if (width == 0 && parsed == {64{1'b1}}) begin
            value = '0;
            return 0;
        end
        value = uvm_hdl_data_t'(parsed);
        return 1;
    endfunction

    static task force_signal(string path, string value_text);
        uvm_hdl_data_t value;
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (path == "" || !decode_value(value_text, value) ||
            !uvm_hdl_force(path, value)) begin
            aip_cmd::set_compat_result(1, "force failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_cmd::set_compat_result(0, $sformatf("forced %s=%s", path, value_text));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    // 后台模式只改变调用方等待，不缩短持续时间；调用被 kill 时不保证释放。
    static task force_signal_time(string path, string value_text, string time_text);
        uvm_hdl_data_t value;
        real duration_ns;
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (path == "" || !decode_value(value_text, value) ||
            !uvm_hdl_check_path(path)) begin
            aip_cmd::set_compat_result(1, "force-time failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        duration_ns = aip_cmd::parse_time_ns(time_text);
        if (duration_ns <= 0.0 || !uvm_hdl_force(path, value)) begin
            aip_cmd::set_compat_result(1, "force-time failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_time::delay_ns(duration_ns);
        if (!uvm_hdl_release_and_read(path, value)) begin
            aip_cmd::set_compat_result(1, "force-time release failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_cmd::set_compat_result(0, $sformatf(
            "forced %s=%s for %s, released", path, value_text, time_text));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    static task deposit_signal(string path, string value_text);
        uvm_hdl_data_t value;
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (path == "" || !decode_value(value_text, value) ||
            !uvm_hdl_deposit(path, value)) begin
            aip_cmd::set_compat_result(1, "deposit failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_cmd::set_compat_result(0, $sformatf("deposited %s=%s", path, value_text));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    // 读失败不伪造零值成功。
    static task get_signal(string path);
        uvm_hdl_data_t value;
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (path == "" || !uvm_hdl_read(path, value)) begin
            aip_cmd::set_compat_result(1, "get failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_cmd::set_compat_result(0, $sformatf("%0h", value));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    // 不假设该路径由哪条命令 force；失败显式返回。
    static task release_signal(string path);
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (path == "" || !uvm_hdl_release(path)) begin
            aip_cmd::set_compat_result(1, "release failed");
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        aip_cmd::set_compat_result(0, $sformatf("released %s", path));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    // offset 接受十进制、0x/0b/0o 及 SV 数值写法，但必须是非负 64-bit 值。
    local static function bit decode_offset(string text,
                                            output aip_dut_mem_addr_t offset);
        aip_vec_t wide_value;
        int explicit_width;
        bit is_negative;
        offset = 0;
        if (!aip_str::str_to_vec(aip_str::strip(text), wide_value,
                                 explicit_width, is_negative) ||
            is_negative || (wide_value >> 64) != 0)
            return 0;
        offset = wide_value[63:0];
        return 1;
    endfunction

    // 每个文件 token 的有效位宽，允许非字节对齐；上限由 UVM HDL backdoor
    // 的数据类型决定（通常为 UVM_HDL_MAX_WIDTH）。
    local static function bit decode_data_width(string text,
                                                output int data_width);
        aip_vec_t wide_value;
        int explicit_width;
        bit is_negative;
        data_width = 0;
        if (!aip_str::str_to_vec(aip_str::strip(text), wide_value,
                                 explicit_width, is_negative) ||
            is_negative || wide_value == 0 ||
            wide_value > $bits(uvm_hdl_data_t))
            return 0;
        data_width = int'(wide_value);
        return 1;
    endfunction

    local static function bit is_file_space(byte ch);
        return ch == 8'd32 || ch == 8'd9 || ch == 8'd10 || ch == 8'd13;
    endfunction

    // @ 地址始终按十六进制解释，与 IEEE readmem 文件格式一致。
    local static function bit decode_file_address(
        string token, output aip_dut_mem_addr_t address
    );
        int start;
        int digits;
        int nibble;
        byte ch;
        address = 0;
        digits = 0;
        if (token.len() < 2 || token[0] != "@") return 0;
        start = 1;
        if (token.len() >= 3 && token[1] == "0" &&
            (token[2] == "x" || token[2] == "X"))
            start = 3;
        for (int i = start; i < token.len(); i++) begin
            ch = token[i];
            if (ch == "_") continue;
            if      (ch >= "0" && ch <= "9") nibble = ch - "0";
            else if (ch >= "a" && ch <= "f") nibble = ch - "a" + 10;
            else if (ch >= "A" && ch <= "F") nibble = ch - "A" + 10;
            else return 0;
            if (address > 64'h0fff_ffff_ffff_ffff) return 0;
            address = (address << 4) | nibble;
            digits++;
        end
        return digits != 0;
    endfunction

    // 解析一个 readmem 数据 token。支持下划线、可选 0x/0b 前缀以及
    // x/z/? 四态数字；超出 uvm_hdl_data_t 可表达宽度时明确失败。
    local static function bit decode_file_value(
        string token, bit hex_mode, int data_width,
        output uvm_hdl_data_t value
    );
        int start;
        int digits;
        int bits_per_digit;
        int numeric;
        byte ch;
        value = '0;
        start = 0;
        digits = 0;
        bits_per_digit = hex_mode ? 4 : 1;
        if (token == "") return 0;
        if (token.len() >= 2 && token[0] == "0" &&
            ((hex_mode && (token[1] == "x" || token[1] == "X")) ||
             (!hex_mode && (token[1] == "b" || token[1] == "B"))))
            start = 2;
        for (int i = start; i < token.len(); i++) begin
            ch = token[i];
            if (ch == "_") continue;
            if ((digits + 1) * bits_per_digit > $bits(uvm_hdl_data_t))
                return 0;
            value = value << bits_per_digit;
            if (hex_mode) begin
                if      (ch >= "0" && ch <= "9") numeric = ch - "0";
                else if (ch >= "a" && ch <= "f") numeric = ch - "a" + 10;
                else if (ch >= "A" && ch <= "F") numeric = ch - "A" + 10;
                else if (ch == "x" || ch == "X") begin
                    value[3:0] = 4'hx;
                    digits++;
                    continue;
                end else if (ch == "z" || ch == "Z" || ch == "?") begin
                    value[3:0] = 4'hz;
                    digits++;
                    continue;
                end else return 0;
                value[3:0] = numeric[3:0];
            end else begin
                if (ch == "0" || ch == "1")
                    value[0] = ch - "0";
                else if (ch == "x" || ch == "X")
                    value[0] = 1'bx;
                else if (ch == "z" || ch == "Z" || ch == "?")
                    value[0] = 1'bz;
                else return 0;
            end
            digits++;
        end
        // 允许超过 width 的前导零，拒绝会被截掉的 1/x/z，避免静默损坏。
        if (data_width < $bits(uvm_hdl_data_t) &&
            (value >> data_width) !== '0)
            return 0;
        return digits != 0;
    endfunction

    // 将一个 token 加入预检队列；@ADDR 以 offset 为基址重新定位。
    local static task parse_file_token(
        input string token,
        input int line_number,
        input bit hex_mode,
        input int data_width,
        input aip_dut_mem_addr_t offset,
        ref aip_dut_mem_addr_t cursor,
        ref bit cursor_overflow,
        ref aip_dut_mem_addr_t addresses[$],
        ref uvm_hdl_data_t values[$],
        ref string error_text
    );
        aip_dut_mem_addr_t relative_address;
        uvm_hdl_data_t value;
        if (token == "" || error_text != "") return;
        if (token[0] == "@") begin
            if (!decode_file_address(token, relative_address)) begin
                error_text = $sformatf("line %0d: invalid address '%s'",
                                       line_number, token);
                return;
            end
            if (relative_address > {64{1'b1}} - offset) begin
                error_text = $sformatf("line %0d: address plus offset overflows",
                                       line_number);
                return;
            end
            cursor = offset + relative_address;
            cursor_overflow = 0;
            return;
        end
        if (cursor_overflow) begin
            error_text = $sformatf("line %0d: sequential address overflows",
                                   line_number);
            return;
        end
        if (!decode_file_value(token, hex_mode, data_width, value)) begin
            error_text = $sformatf("line %0d: invalid/overflowing %0d-bit %s data '%s'",
                                   line_number, data_width,
                                   hex_mode ? "hex" : "binary",
                                   token);
            return;
        end
        addresses.push_back(cursor);
        values.push_back(value);
        if (cursor == {64{1'b1}})
            cursor_overflow = 1;
        else
            cursor++;
    endtask

    local static task flush_file_token(
        ref string token,
        input int line_number,
        input bit hex_mode,
        input int data_width,
        input aip_dut_mem_addr_t offset,
        ref aip_dut_mem_addr_t cursor,
        ref bit cursor_overflow,
        ref aip_dut_mem_addr_t addresses[$],
        ref uvm_hdl_data_t values[$],
        ref string error_text
    );
        if (token != "")
            parse_file_token(token, line_number, hex_mode, data_width,
                             offset, cursor,
                             cursor_overflow, addresses, values, error_text);
        token = "";
    endtask

    // 动态字符串路径不能直接作为 $readmemh/$readmemb 的 memory 实参；这里
    // 解析同类文件并用 uvm_hdl_deposit 写 path[address]，供 Tcl/TCP/SV 共用。
    local static task load_memory_file(string filename, string path,
                                       string offset_text, string width_text,
                                       bit hex_mode);
        int fd;
        int line_number;
        int loaded;
        string line;
        string token;
        string error_text;
        string element_path;
        bit in_block_comment;
        bit cursor_overflow;
        int data_width;
        aip_dut_mem_addr_t offset;
        aip_dut_mem_addr_t cursor;
        aip_dut_mem_addr_t addresses[$];
        uvm_hdl_data_t values[$];

        if (filename == "" || path == "" ||
            !decode_offset(offset_text, offset) ||
            !decode_data_width(width_text, data_width)) begin
            aip_cmd::set_compat_result(1, $sformatf(
                "dut_readmem%s failed: invalid file/path/offset/width",
                hex_mode ? "h" : "b"));
            return;
        end
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            aip_cmd::set_compat_result(1, $sformatf(
                "dut_readmem%s failed: cannot open %s",
                hex_mode ? "h" : "b", filename));
            return;
        end

        line_number = 0;
        in_block_comment = 0;
        cursor_overflow = 0;
        cursor = offset;
        while (!$feof(fd) && error_text == "") begin
            void'($fgets(line, fd));
            line_number++;
            token = "";
            for (int i = 0; i < line.len(); i++) begin
                if (in_block_comment) begin
                    if (line[i] == "*" && i + 1 < line.len() &&
                        line[i+1] == "/") begin
                        in_block_comment = 0;
                        i++;
                    end
                    continue;
                end
                if (line[i] == "/" && i + 1 < line.len() &&
                    line[i+1] == "/") begin
                    flush_file_token(token, line_number, hex_mode, data_width,
                                     offset,
                                     cursor, cursor_overflow, addresses, values,
                                     error_text);
                    break;
                end
                if (line[i] == "/" && i + 1 < line.len() &&
                    line[i+1] == "*") begin
                    flush_file_token(token, line_number, hex_mode, data_width,
                                     offset,
                                     cursor, cursor_overflow, addresses, values,
                                     error_text);
                    in_block_comment = 1;
                    i++;
                    continue;
                end
                if (line[i] == "#") begin
                    flush_file_token(token, line_number, hex_mode, data_width,
                                     offset,
                                     cursor, cursor_overflow, addresses, values,
                                     error_text);
                    break;
                end
                if (is_file_space(line[i])) begin
                    flush_file_token(token, line_number, hex_mode, data_width,
                                     offset,
                                     cursor, cursor_overflow, addresses, values,
                                     error_text);
                end else begin
                    token = {token, line[i]};
                end
            end
            flush_file_token(token, line_number, hex_mode, data_width, offset,
                             cursor,
                             cursor_overflow, addresses, values, error_text);
        end
        $fclose(fd);
        if (error_text == "" && in_block_comment)
            error_text = "unterminated block comment";
        if (error_text != "") begin
            aip_cmd::set_compat_result(1, $sformatf(
                "dut_readmem%s failed: %s", hex_mode ? "h" : "b", error_text));
            return;
        end

        loaded = 0;
        foreach (values[i]) begin
            element_path = $sformatf("%s[%0d]", path, addresses[i]);
            if (!uvm_hdl_deposit(element_path, values[i])) begin
                aip_cmd::set_compat_result(1, $sformatf(
                    "dut_readmem%s failed: deposit %s after %0d words",
                    hex_mode ? "h" : "b", element_path, loaded));
                return;
            end
            loaded++;
        end
        aip_cmd::set_compat_result(0, $sformatf(
            "dut_readmem%s loaded %0d words from %s into %s offset=%0d width=%0d",
            hex_mode ? "h" : "b", loaded, filename, path, offset, data_width));
    endtask

    // width 为可选第四参数，省略时每个 token 默认按 8 bit 装载。
    static task readmemh(string filename, string path, string offset_text,
                         string width_text = "8");
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        load_memory_file(filename, path, offset_text, width_text, 1'b1);
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    static task readmemb(string filename, string path, string offset_text,
                         string width_text = "8");
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        load_memory_file(filename, path, offset_text, width_text, 1'b0);
        aip_cmd::end_compat_result_scope(result_scope);
    endtask
endclass

// 最后一个可选宏实参显式选择逐调用结果；命令名、业务参数和 time= 拼写不变。
`aip_cmd_str_2i_status(dut_force, aip_dut_control_ops::force_signal,
                      path, "", value, "", 1'b1)
`aip_cmd_str_3i_status_time(dut_force_time, aip_dut_control_ops::force_signal_time,
                            path, "", value, "", time_arg, "", 1'b1)
`aip_cmd_str_2i_status(dut_deposit, aip_dut_control_ops::deposit_signal,
                      path, "", value, "", 1'b1)
`aip_cmd_str_1i_status(dut_get, aip_dut_control_ops::get_signal, path, "", 1'b1)
`aip_cmd_str_1i_status(dut_release, aip_dut_control_ops::release_signal, path, "", 1'b1)
// readmem 命令比通用三字符串宏多一个可选 width=，定义留在 DUT include
// 内部，避免扩大公共宏表面。
`define AIP_DUT_READMEM_CMD(Ccmd, svtask) \
class \__aip_cmd_``Ccmd extends aip_cmd_legacy_result_task; \
    task cmd_exec(); \
        string file; string path; string offset; string width; \
        bit __aip_owns_scope; \
        __aip_owns_scope = begin_macro_result_scope(); \
        begin \
            string __file = aip_cmd::get_arg(this.args_in, "file"); \
            string __path = aip_cmd::get_arg(this.args_in, "path"); \
            string __offset = aip_cmd::get_arg(this.args_in, "offset"); \
            string __width = aip_cmd::get_arg(this.args_in, "width"); \
            file = __file; \
            path = __path; \
            offset = (__offset != "") ? __offset : "0"; \
            width = (__width != "") ? __width : "8"; \
        end \
        svtask(file, path, offset, width); \
        end_macro_result_scope(__aip_owns_scope); \
    endtask \
    function new(string name); super.new(name, 1'b1); endfunction \
    static \__aip_cmd_``Ccmd __inst = new(`"Ccmd`"); \
endclass

`AIP_DUT_READMEM_CMD(dut_readmemh, aip_dut_control_ops::readmemh)
`AIP_DUT_READMEM_CMD(dut_readmemb, aip_dut_control_ops::readmemb)
`undef AIP_DUT_READMEM_CMD

`endif
