// src/sv/core：aip_cmd_reg/creg 共用的寄存器参数解析；由 aip_cmd.sv 包含。
// 依赖 aip_str 的宽整数解析，不启动 sequence、不改变命令注册或 Tcl 调度。
// 每次 launch 创建独立对象，字段/错误文本只属于本次访问；解析失败不得发总线请求。
// 同时支持 key=value 和位置 op addr len data [mask]；读位置格式为 op addr [len]。
// len 默认 4，mask 默认 0（PCIe 接入约定 1=屏蔽字节），框架只原样传递其值。
// check_read_data 是可选逐次读比较策略，默认1且仅接受0/1；实际支持由注册宏的可选映射声明。
class aip_reg_args;
    bit	                is_write;
    longint unsigned	  addr;
    int unsigned	      len;
    int unsigned	      mask;
    bit [127:0]	        wdata;
    string	             error_msg;
    bit	                check_read_data;
    bit	                check_read_data_present;

    // 统一记录可回传的参数错误；不使用 fatal，使 Tcl 可修正参数后继续运行。
    function bit reject(string reason);
        error_msg = reason;
        return 0;
    endfunction

    // 复用 AIP 1024 位解析器，限制实际值到目标宽度，禁止静默截断。
    // data/mask 允许负数字面量并按目标宽度取补码；addr/len 必须非负。
    function bit number(string token, int bits, bit allow_negative,
                        output bit [127:0] value);
        aip_vec_t	v;
        int	       literal_width;
        bit	       negative;

        value = '0;
        if (bits < 1 || bits > 128 ||
            !aip_str::str_to_vec(token, v, literal_width, negative)) return 0;
        if ((negative && !allow_negative) || (v >> bits) != 0) return 0;
        value = negative ? -v : v;
        value &= (128'hffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff >> (128-bits));
        return 1;
    endfunction

    // 解析一次命令；data_bits 来自注册 sequence 类型的 wdata 位宽，兼容旧 64 位类。
    // 位置参数可附加 mask=/check_read_data=，禁止混用 op=/addr=/len=/data=，避免参数错位。
    // 命名格式保留历史 data 缺省 0；位置 write 必须明确给出四个值。
    function bit parse(string args, int data_bits = 128);
        string_darray_t	  tokens;
        string	            positional[$];
        string	            named[string];
        string	            op;
        string	            key;
        string	            value;
        int	               equals;
        bit [127:0]	       parsed;

        is_write = 0;
        addr = 0;
        len = 4;
        mask = 0;
        wdata = '0;
        error_msg = "";
        check_read_data = 1;
        check_read_data_present = 0;
        if (data_bits < 1 || data_bits > 128)
            return reject("sequence wdata width must be 1..128 bits");
        // 历史 get_arg 接受逗号分隔；寄存器参数均为标量，不包含结构体或列表。
        tokens = aip_str::split(aip_str::replace(args, ",", " "));
        foreach (tokens[i]) begin
            equals = aip_str::str_find(tokens[i], "=");
            if (equals < 0) positional.push_back(tokens[i]);
            else begin
                if (equals == 0 || equals == tokens[i].len()-1)
                    return reject("empty parameter name/value");
                key = tokens[i].substr(0, equals-1);
                value = tokens[i].substr(equals+1, tokens[i].len()-1);
                if (!(key inside {"op", "addr", "len", "data", "mask", "check_read_data"}))
                    return reject({"unknown parameter: ", key});
                if (named.exists(key)) return reject({"duplicate parameter: ", key});
                named[key] = value;
            end
        end

        if (positional.size() != 0) begin
            foreach (named[k])
                if (!(k inside {"mask", "check_read_data"}))
                    return reject("do not mix positional and named op/addr/len/data");
            if (positional.size() < 2) return reject("missing op/addr");
            named["op"] = positional[0];
            named["addr"] = positional[1];
        end
        if (!named.exists("op") || !named.exists("addr")) return reject("missing op/addr");
        op = aip_str::lower(named["op"]);
        case (op)
            "write", "wr", "w", "1": is_write = 1;
            "read", "rd", "r", "0": is_write = 0;
            default: return reject("op must be read/write (rd/wr, r/w, 0/1)");
        endcase
        if (positional.size() != 0) begin
            if (is_write && !(positional.size() inside {4, 5}))
                return reject("write syntax: op addr len data [mask]");
            if (!is_write && !(positional.size() inside {2, 3}))
                return reject("read syntax: op addr [len] [mask=value]");
            if (positional.size() >= 3) named["len"] = positional[2];
            if (is_write) named["data"] = positional[3];
            if (positional.size() == 5) begin
                if (named.exists("mask")) return reject("duplicate parameter: mask");
                named["mask"] = positional[4];
            end
        end

        if (!number(named["addr"], 64, 0, parsed)) return reject("invalid or overflowing addr");
        addr = parsed[63:0];
        if (named.exists("len")) begin
            if (!number(named["len"], 32, 0, parsed)) return reject("invalid or overflowing len");
            len = parsed[31:0];
        end
        if (named.exists("mask")) begin
            if (!number(named["mask"], 32, 1, parsed)) return reject("invalid or overflowing mask");
            mask = parsed[31:0];
        end
        if (named.exists("data")) begin
            if (!number(named["data"], data_bits, 1, parsed))
                return reject("invalid data or data exceeds sequence wdata width");
            wdata = parsed;
        end
        if (named.exists("check_read_data")) begin
            if (!number(named["check_read_data"], 1, 0, parsed))
                return reject("check_read_data must be 0 or 1");
            check_read_data = parsed[0];
            check_read_data_present = 1;
        end
        return 1;
    endfunction
endclass
