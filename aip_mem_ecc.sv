//===========================================================
// aip_mem_ecc.sv — ECC/Parity 后门 mem 读写 (SV 实现)
// 跟 aip_ucli_utils.tcl 的 mem_cfg / mem_write / mem_read 等价
// 复用 aip_cpu_bridge.sv 的 aip_mem_accessor 抽象 backdoor (32-bit word)
// 依赖: aip_log, aip_cpu_bridge (aip_mem_accessor 定义)
//===========================================================
`ifndef AIP_MEM_ECC_SV
`define AIP_MEM_ECC_SV

class aip_mem_ecc;

    typedef struct {
        aip_mem_accessor accessor;
        int              width;
        string           ecc_mode;
        int              parity_grain;
        string           parity_polarity;
        string           on_err;
        string           layout;
        aip_mem_accessor ecc_accessor;
        int              ecc_width;
    } cfg_t;

    static cfg_t cfgs[string];

    // ============ ECC primitives ============
    static function bit xor_bits(input longint unsigned val, input int width);
        bit x = 0;
        for (int i = 0; i < width; i++) x ^= (val >> i) & 1;
        return x;
    endfunction

    static function int parity_width(input int data_width, input int grain);
        if (grain == 0 || grain == data_width) return 1;
        return data_width / grain;
    endfunction

    static function longint unsigned parity_compute(input longint unsigned data,
                                                    input int width,
                                                    input int grain,
                                                    input string polarity);
        int num_groups, g_grain;
        longint unsigned p, group_val, mask;
        bit bit_p;
        g_grain = (grain == 0) ? width : grain;
        num_groups = width / g_grain;
        p = 0;
        mask = (g_grain == 64) ? {64{1'b1}} : ((64'h1 << g_grain) - 1);
        for (int g = 0; g < num_groups; g++) begin
            group_val = (data >> (g * g_grain)) & mask;
            bit_p = xor_bits(group_val, g_grain);
            if (polarity == "odd") bit_p ^= 1;
            if (bit_p) p |= (64'd1 << g);
        end
        return p;
    endfunction

    static function int secded_ecc_width(input int data_width);
        case (data_width)
            8:   return 5;
            16:  return 6;
            32:  return 7;
            64:  return 8;
            128: return 9;
            default: return 0;
        endcase
    endfunction

    static function longint unsigned hamming_encode(input longint unsigned data, input int data_width);
        int ecc_total, r, M, data_idx;
        longint unsigned syndrome, hamming;
        bit b, overall;
        ecc_total = secded_ecc_width(data_width);
        r = ecc_total - 1;
        M = data_width + r;
        syndrome = 0;
        data_idx = 0;
        for (int pos = 1; pos <= M; pos++) begin
            if ((pos & (pos - 1)) == 0) continue;
            b = (data >> data_idx) & 1;
            data_idx++;
            if (b) syndrome ^= pos;
        end
        hamming = 0;
        for (int i = 0; i < r; i++)
            if ((syndrome >> i) & 1) hamming |= (64'd1 << i);
        overall = xor_bits(data, data_width) ^ xor_bits(hamming, r);
        return (hamming << 1) | (overall ? 64'd1 : 64'd0);
    endfunction
    static task hamming_decode(input  longint unsigned data,
                               input  longint unsigned ecc,
                               input  int              data_width,
                               output longint unsigned corrected,
                               output string           status);
        int ecc_total, r, M, data_idx, err_pos, count, data_bit_idx;
        longint unsigned stored_hamming, recalc_hamming, syndrome, syndrome_diff;
        bit stored_overall, recalc_overall, overall_mismatch, b;
        ecc_total = secded_ecc_width(data_width);
        r = ecc_total - 1;
        M = data_width + r;
        stored_overall = ecc & 1;
        stored_hamming = ecc >> 1;
        syndrome = 0;
        data_idx = 0;
        for (int pos = 1; pos <= M; pos++) begin
            if ((pos & (pos - 1)) == 0) continue;
            b = (data >> data_idx) & 1;
            data_idx++;
            if (b) syndrome ^= pos;
        end
        recalc_hamming = 0;
        for (int i = 0; i < r; i++)
            if ((syndrome >> i) & 1) recalc_hamming |= (64'd1 << i);
        syndrome_diff = stored_hamming ^ recalc_hamming;
        err_pos = 0;
        for (int i = 0; i < r; i++) err_pos |= int'(((syndrome_diff >> i) & 1) << i);
        recalc_overall = xor_bits(data, data_width) ^ xor_bits(stored_hamming, r);
        overall_mismatch = (stored_overall != recalc_overall);

        corrected = data;
        if (err_pos == 0 && !overall_mismatch) begin
            status = "ok";
        end else if (err_pos != 0 && overall_mismatch) begin
            if ((err_pos & (err_pos - 1)) == 0) begin
                status = $sformatf("single_err_in_ecc pos=%0d", err_pos);
            end else begin
                data_bit_idx = 0;
                count = 0;
                for (int pos = 1; pos <= M; pos++) begin
                    if ((pos & (pos - 1)) == 0) continue;
                    if (pos == err_pos) begin
                        data_bit_idx = count;
                        break;
                    end
                    count++;
                end
                corrected = data ^ (64'd1 << data_bit_idx);
                status = $sformatf("single_err pos=%0d corrected", err_pos);
            end
        end else if (err_pos == 0 && overall_mismatch) begin
            status = "single_err_in_overall";
        end else begin
            status = "double_err_uncorrectable";
        end
    endtask

    static function bit [7:0] crc8(input longint unsigned data, input int data_width);
        bit [7:0] crc, byte_val;
        int bytes;
        crc = 0;
        bytes = (data_width + 7) / 8;
        for (int b = bytes - 1; b >= 0; b--) begin
            byte_val = (data >> (b * 8)) & 8'hFF;
            crc ^= byte_val;
            for (int i = 0; i < 8; i++) begin
                if (crc[7]) crc = (crc << 1) ^ 8'h07;
                else        crc = crc << 1;
            end
        end
        return crc;
    endfunction
    // ============ Config ============
    // 注: 函数名避开 SV 关键字 `config` (config block)
    static function void set_cfg(input string path,
                                 input aip_mem_accessor accessor,
                                 input int width = 32,
                                 input string ecc_mode = "none",
                                 input int parity_grain = 8,
                                 input string parity_polarity = "even",
                                 input string on_err = "warn",
                                 input string layout = "concat",
                                 input aip_mem_accessor ecc_accessor = null);
        cfg_t c;
        int ecc_w;
        c.accessor        = accessor;
        c.width           = width;
        c.ecc_mode        = ecc_mode;
        c.parity_grain    = parity_grain;
        c.parity_polarity = parity_polarity;
        c.on_err          = on_err;
        c.layout          = layout;
        c.ecc_accessor    = ecc_accessor;
        case (ecc_mode)
            "none":   ecc_w = 0;
            "parity": ecc_w = parity_width(width, parity_grain);
            "secded": ecc_w = secded_ecc_width(width);
            "crc8":   ecc_w = 8;
            default: begin
                `aip_error(("aip_mem_ecc::config: unknown ecc_mode '%s'", ecc_mode));
                return;
            end
        endcase
        c.ecc_width = ecc_w;
        cfgs[path] = c;
        `aip_info(("aip_mem_ecc: cfg %s width=%0d mode=%s ecc_w=%0d layout=%s",
                  path, width, ecc_mode, ecc_w, layout));
    endfunction

    static function void clear_cfg(input string path = "all");
        if (path == "all") begin
            cfgs.delete();
        end else if (cfgs.exists(path)) begin
            cfgs.delete(path);
        end
    endfunction

    // ============ ECC encode/decode dispatcher ============
    static function longint unsigned ecc_encode(input cfg_t c, input longint unsigned data);
        case (c.ecc_mode)
            "none":   return 0;
            "parity": return parity_compute(data, c.width, c.parity_grain, c.parity_polarity);
            "secded": return hamming_encode(data, c.width);
            "crc8":   return crc8(data, c.width);
        endcase
        return 0;
    endfunction

    static task ecc_decode(input cfg_t c,
                           input longint unsigned data,
                           input longint unsigned ecc,
                           output longint unsigned corrected,
                           output string status);
        longint unsigned p_recalc;
        bit [7:0] c_recalc;
        case (c.ecc_mode)
            "none": begin corrected = data; status = "ok"; end
            "parity": begin
                p_recalc = parity_compute(data, c.width, c.parity_grain, c.parity_polarity);
                corrected = data;
                status = (p_recalc == ecc) ? "ok" : "parity_err";
            end
            "secded": hamming_decode(data, ecc, c.width, corrected, status);
            "crc8": begin
                c_recalc = crc8(data, c.width);
                corrected = data;
                status = (c_recalc == ecc[7:0]) ? "ok" : "crc_err";
            end
            default: begin corrected = data; status = "ok"; end
        endcase
    endtask

    // ============ Public write_word / read_word / check ============
    static task write_word(input string path, input longint unsigned addr, input longint unsigned data);
        cfg_t c;
        longint unsigned ecc, stored, data_masked, data_mask;
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::write_word: path %s not configured", path));
            return;
        end
        c = cfgs[path];
        ecc = ecc_encode(c, data);
        data_mask = (c.width == 64) ? {64{1'b1}} : ((64'h1 << c.width) - 1);
        data_masked = data & data_mask;
        if (c.layout == "concat") begin
            int unsigned stored_32;
            stored = (ecc << c.width) | data_masked;
            stored_32 = stored;
            c.accessor.wr_mem(addr, stored_32);
        end else begin
            int unsigned data_32, ecc_32;
            data_32 = data_masked;
            ecc_32  = ecc;
            c.accessor.wr_mem(addr, data_32);
            if (c.ecc_width > 0 && c.ecc_accessor != null)
                c.ecc_accessor.wr_mem(addr, ecc_32);
        end
    endtask

    static task read_word(input string path,
                          input longint unsigned addr,
                          output longint unsigned data,
                          output string status);
        cfg_t c;
        longint unsigned raw_data, raw_ecc, corrected, data_mask;
        int unsigned tmp;
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::read_word: path %s not configured", path));
            data = 0; status = "no_config";
            return;
        end
        c = cfgs[path];
        data_mask = (c.width == 64) ? {64{1'b1}} : ((64'h1 << c.width) - 1);
        if (c.layout == "concat") begin
            longint unsigned tmp_w;
            c.accessor.rd_mem(addr, tmp);
            tmp_w = tmp;
            raw_data = tmp_w & data_mask;
            raw_ecc  = tmp_w >> c.width;
        end else begin
            c.accessor.rd_mem(addr, tmp);
            raw_data = tmp;
            if (c.ecc_width > 0 && c.ecc_accessor != null) begin
                c.ecc_accessor.rd_mem(addr, tmp);
                raw_ecc = tmp;
            end else raw_ecc = 0;
        end
        ecc_decode(c, raw_data, raw_ecc, corrected, status);
        data = corrected;
        if (status != "ok") begin
            if (c.on_err == "warn")
                `aip_warning(("aip_mem_ecc: %s[0x%0h] %s (data=0x%0h ecc=0x%0h)",
                             path, addr, status, raw_data, raw_ecc));
            else if (c.on_err == "error")
                `aip_error(("aip_mem_ecc: %s[0x%0h] %s", path, addr, status));
        end
    endtask

    static task check(input string path, input longint unsigned addr, output string status);
        cfg_t c;
        longint unsigned raw_data, raw_ecc, corrected, data_mask;
        int unsigned tmp;
        if (!cfgs.exists(path)) begin
            status = "no_config";
            return;
        end
        c = cfgs[path];
        data_mask = (c.width == 64) ? {64{1'b1}} : ((64'h1 << c.width) - 1);
        if (c.layout == "concat") begin
            longint unsigned tmp_w;
            c.accessor.rd_mem(addr, tmp);
            tmp_w = tmp;
            raw_data = tmp_w & data_mask;
            raw_ecc  = tmp_w >> c.width;
        end else begin
            c.accessor.rd_mem(addr, tmp);
            raw_data = tmp;
            if (c.ecc_width > 0 && c.ecc_accessor != null) begin
                c.ecc_accessor.rd_mem(addr, tmp);
                raw_ecc = tmp;
            end else raw_ecc = 0;
        end
        ecc_decode(c, raw_data, raw_ecc, corrected, status);
    endtask

    // ============ Fault injection ============
    static task inject_err(input string path, input longint unsigned addr, input int bit_pos);
        cfg_t c;
        int unsigned tmp;
        int b;
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::inject_err: path %s not configured", path));
            return;
        end
        c = cfgs[path];
        if (c.layout == "concat") begin
            c.accessor.rd_mem(addr, tmp);
            tmp = tmp ^ (32'd1 << bit_pos);
            c.accessor.wr_mem(addr, tmp);
        end else begin
            if (bit_pos < c.width) begin
                c.accessor.rd_mem(addr, tmp);
                tmp = tmp ^ (32'd1 << bit_pos);
                c.accessor.wr_mem(addr, tmp);
            end else if (c.ecc_accessor != null) begin
                b = bit_pos - c.width;
                c.ecc_accessor.rd_mem(addr, tmp);
                tmp = tmp ^ (32'd1 << b);
                c.ecc_accessor.wr_mem(addr, tmp);
            end
        end
        `aip_info(("aip_mem_ecc::inject_err: %s[0x%0h] bit %0d flipped", path, addr, bit_pos));
    endtask

    // ============ Block ops ============
    static task write_zero(input string path, input longint unsigned addr, input int count);
        for (int i = 0; i < count; i++) write_word(path, addr + i, 0);
    endtask

    static task write_incr(input string path, input longint unsigned addr, input int count, input longint unsigned start = 0);
        for (int i = 0; i < count; i++) write_word(path, addr + i, start + i);
    endtask

    // ============ Scrub ============
    static task scrub(input  string path,
                      input  longint unsigned addr_from,
                      input  longint unsigned addr_to,
                      input  bit do_fix = 0,
                      output int ok,
                      output int single,
                      output int double_err,
                      output int other);
        string status;
        longint unsigned corrected;
        ok = 0; single = 0; double_err = 0; other = 0;
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::scrub: path %s not configured", path));
            return;
        end
        for (longint unsigned a = addr_from; a <= addr_to; a++) begin
            check(path, a, status);
            if (status == "ok") begin
                ok++;
            end else if (status.len() >= 10 && status.substr(0, 9) == "single_err") begin
                single++;
                if (do_fix) begin
                    read_word(path, a, corrected, status);
                    write_word(path, a, corrected);
                end
            end else if (status.len() >= 10 && status.substr(0, 9) == "double_err") begin
                double_err++;
                `aip_error(("aip_mem_ecc::scrub UNCORRECTABLE: %s[0x%0h] %s", path, a, status));
            end else begin
                other++;
            end
        end
        `aip_info(("aip_mem_ecc::scrub: %s[0x%0h:0x%0h] ok=%0d single=%0d double=%0d other=%0d fix=%0d",
                  path, addr_from, addr_to, ok, single, double_err, other, do_fix));
    endtask

    // ============ Config introspection (跟 tcl mem_cfg_list / mem_cfg_get 对齐) ============
    static function void cfg_list();
        string keys[$];
        cfg_t  c;
        string detail;
        if (cfgs.size() == 0) begin
            $display("cfg_list: (no path configured)");
            return;
        end
        foreach (cfgs[k]) keys.push_back(k);
        keys.sort();
        $display("================================================================");
        $display(" %-40s %-7s %-8s %-14s %-7s", "PATH", "WIDTH", "ECC_MODE", "DETAIL", "LAYOUT");
        $display("----------------------------------------------------------------");
        foreach (keys[i]) begin
            c = cfgs[keys[i]];
            case (c.ecc_mode)
                "none":   detail = "-";
                "parity": detail = $sformatf("g=%0d,%s,+%0db", c.parity_grain, c.parity_polarity, c.ecc_width);
                "secded": detail = $sformatf("+%0db SECDED", c.ecc_width);
                "crc8":   detail = $sformatf("+%0db CRC-8", c.ecc_width);
                default:  detail = "?";
            endcase
            $display(" %-40s %-7d %-8s %-14s %-7s", keys[i], c.width, c.ecc_mode, detail, c.layout);
        end
        $display("================================================================");
    endfunction

    // 返回 0 = path 未配置, 1 = 成功
    static function bit cfg_get(input string path, output cfg_t c);
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::cfg_get: path %s not configured", path));
            return 0;
        end
        c = cfgs[path];
        return 1;
    endfunction

    // ============ Block ops (跟 tcl mem_write_block / mem_read_block / mem_write_random 对齐) ============
    static task write_block(input string path,
                            input longint unsigned addr,
                            input longint unsigned data[$]);
        foreach (data[i]) write_word(path, addr + i, data[i]);
        `aip_info(("aip_mem_ecc::write_block: %s[0x%0h..0x%0h] %0d entries",
                  path, addr, addr + data.size() - 1, data.size()));
    endtask

    static task read_block(input  string           path,
                           input  longint unsigned addr,
                           input  int              count,
                           output longint unsigned data[$]);
        longint unsigned v;
        string status;
        data = {};
        for (int i = 0; i < count; i++) begin
            read_word(path, addr + i, v, status);
            data.push_back(v);
        end
    endtask

    static task write_random(input string           path,
                             input longint unsigned addr,
                             input int              count,
                             input int              seed = -1);
        cfg_t c;
        longint unsigned mask, rval;
        int unsigned rlo, rhi;
        if (!cfgs.exists(path)) begin
            `aip_error(("aip_mem_ecc::write_random: path %s not configured", path));
            return;
        end
        c = cfgs[path];
        if (seed >= 0) begin
            // VCS: $urandom(seed) 可初始化 PRNG
            void'($urandom(seed));
        end
        mask = (c.width >= 64) ? {64{1'b1}} : ((64'h1 << c.width) - 1);
        for (int i = 0; i < count; i++) begin
            rlo = $urandom();
            rhi = $urandom();
            begin
                longint unsigned hi_w, lo_w;
                hi_w = rhi;
                lo_w = rlo;
                rval = ((hi_w << 32) | lo_w) & mask;
            end
            write_word(path, addr + i, rval);
        end
        `aip_info(("aip_mem_ecc::write_random: %s[0x%0h..0x%0h] count=%0d seed=%0d",
                  path, addr, addr + count - 1, count, seed));
    endtask

endclass

//===========================================================
// ============ RAL-Integrated Layer ============
// 新一层 backdoor 接 UVM RAL (uvm_reg / uvm_mem)。
// Codec 算法直接复用 aip_mem_ecc 的 static primitives。
// Accessor 子类家族负责异型拼装 (hdl/split/banked/sliced/scrambled),
// 用户使用 RAL 时调 `mem.read/write(.path(UVM_BACKDOOR))` 即可,
// 完全无感拼装。
//===========================================================

//-----------------------------------------------------------
// aip_mem_phy_accessor — 抽象物理 accessor (longint, width-aware)
//-----------------------------------------------------------
virtual class aip_mem_phy_accessor;
    string view = "RTL";
    pure virtual task wr(input  longint unsigned addr,
                        input  longint unsigned data,
                        input  int              width);
    pure virtual task rd(input  longint unsigned addr,
                        output longint unsigned data,
                        input  int              width);
endclass

//-----------------------------------------------------------
// aip_mem_acc_hdl — uvm_hdl_deposit / uvm_hdl_read
//   path 形式: "tb.dut.ram_array" (索引由 accessor 加)
//-----------------------------------------------------------
class aip_mem_acc_hdl extends aip_mem_phy_accessor;
    string path;
    function new(string p); path = p; endfunction
    virtual task wr(input longint unsigned addr, input longint unsigned data, input int width);
        uvm_hdl_data_t d = data;
        if (!uvm_hdl_deposit($sformatf("%s[%0d]", path, addr), d))
            `aip_warning(("aip_mem_acc_hdl: deposit fail @ %s[%0d]", path, addr));
    endtask
    virtual task rd(input longint unsigned addr, output longint unsigned data, input int width);
        uvm_hdl_data_t d;
        void'(uvm_hdl_read($sformatf("%s[%0d]", path, addr), d));
        data = d;
    endtask
endclass

//-----------------------------------------------------------
// aip_mem_acc_split — data + ecc 分两块 accessor
//   存储模型: 输入的 stored = (ecc << data_width) | data
//   wr: 拆开分别写 data_acc / ecc_acc
//   rd: 两路读, 重新拼回
//-----------------------------------------------------------
class aip_mem_acc_split extends aip_mem_phy_accessor;
    aip_mem_phy_accessor data_acc;
    aip_mem_phy_accessor ecc_acc;
    int data_width;
    int ecc_width;
    virtual task wr(input longint unsigned addr, input longint unsigned data, input int width);
        longint unsigned mask_d, d, e;
        mask_d = (data_width >= 64) ? {64{1'b1}} : ((64'h1 << data_width) - 1);
        d = data & mask_d;
        e = (ecc_width == 0) ? 0 : (data >> data_width);
        data_acc.wr(addr, d, data_width);
        if (ecc_width > 0 && ecc_acc != null) ecc_acc.wr(addr, e, ecc_width);
    endtask
    virtual task rd(input longint unsigned addr, output longint unsigned data, input int width);
        longint unsigned d, e;
        data_acc.rd(addr, d, data_width);
        if (ecc_width > 0 && ecc_acc != null) ecc_acc.rd(addr, e, ecc_width);
        else e = 0;
        data = (e << data_width) | d;
    endtask
endclass

//-----------------------------------------------------------
// aip_mem_acc_banked — 多 bank 交织
//   bank_id = addr % N, bank_addr = addr / N
//-----------------------------------------------------------
class aip_mem_acc_banked extends aip_mem_phy_accessor;
    aip_mem_phy_accessor banks[$];
    virtual task wr(input longint unsigned addr, input longint unsigned data, input int width);
        int bid;
        longint unsigned baddr;
        bid   = int'(addr) % banks.size();
        baddr = addr / banks.size();
        banks[bid].wr(baddr, data, width);
    endtask
    virtual task rd(input longint unsigned addr, output longint unsigned data, input int width);
        int bid;
        longint unsigned baddr;
        bid   = int'(addr) % banks.size();
        baddr = addr / banks.size();
        banks[bid].rd(baddr, data, width);
    endtask
endclass

//-----------------------------------------------------------
// aip_mem_acc_scrambled — addr/data XOR key
//-----------------------------------------------------------
class aip_mem_acc_scrambled extends aip_mem_phy_accessor;
    aip_mem_phy_accessor inner;
    longint unsigned addr_key = 0;
    longint unsigned data_key = 0;
    virtual task wr(input longint unsigned addr, input longint unsigned data, input int width);
        inner.wr(addr ^ addr_key, data ^ data_key, width);
    endtask
    virtual task rd(input longint unsigned addr, output longint unsigned data, input int width);
        longint unsigned d;
        inner.rd(addr ^ addr_key, d, width);
        data = d ^ data_key;
    endtask
endclass

//-----------------------------------------------------------
// aip_mem_acc_sliced — 逻辑 word 由多个 RTL 信号 slice 拼成
//   slice: {path, offset, size}
//-----------------------------------------------------------
class aip_mem_acc_sliced extends aip_mem_phy_accessor;
    typedef struct { string path; int offset; int size; } slice_t;
    slice_t slices[$];
    virtual task wr(input longint unsigned addr, input longint unsigned data, input int width);
        longint unsigned mask, part;
        uvm_hdl_data_t d;
        foreach (slices[i]) begin
            mask = (slices[i].size >= 64) ? {64{1'b1}} : ((64'h1 << slices[i].size) - 1);
            part = (data >> slices[i].offset) & mask;
            d    = part;
            if (!uvm_hdl_deposit($sformatf("%s[%0d]", slices[i].path, addr), d))
                `aip_warning(("aip_mem_acc_sliced: deposit fail %s[%0d]", slices[i].path, addr));
        end
    endtask
    virtual task rd(input longint unsigned addr, output longint unsigned data, input int width);
        longint unsigned val, part, mask;
        uvm_hdl_data_t d;
        val = 0;
        foreach (slices[i]) begin
            void'(uvm_hdl_read($sformatf("%s[%0d]", slices[i].path, addr), d));
            mask = (slices[i].size >= 64) ? {64{1'b1}} : ((64'h1 << slices[i].size) - 1);
            begin
                longint unsigned dw;
                dw = d;
                part = dw & mask;
            end
            val |= (part << slices[i].offset);
        end
        data = val;
    endtask
endclass

//-----------------------------------------------------------
// aip_mem_ecc_backdoor — UVM RAL backdoor
//   持有 codec 配置 + accessor 实例
//   read/write 自动 ECC 编解码
//-----------------------------------------------------------
class aip_mem_ecc_backdoor extends uvm_reg_backdoor;

    typedef struct {
        int    width;
        string ecc_mode;        // none | parity | secded | crc8
        int    parity_grain;
        string parity_polarity;
    } codec_cfg_t;

    codec_cfg_t          codec_cfg;
    aip_mem_phy_accessor acc;
    string               on_err = "warn";
    int                  ecc_width = 0;

    // 错误统计 (累积)
    int err_single  = 0;
    int err_double  = 0;
    int err_parity  = 0;
    int err_crc     = 0;
    longint unsigned err_addrs[$];

    `uvm_object_utils(aip_mem_ecc_backdoor)
    function new(string name = "aip_mem_ecc_backdoor"); super.new(name); endfunction

    function void set_codec(int width, string ecc_mode = "none",
                            int parity_grain = 8, string parity_polarity = "even");
        codec_cfg.width           = width;
        codec_cfg.ecc_mode        = ecc_mode;
        codec_cfg.parity_grain    = parity_grain;
        codec_cfg.parity_polarity = parity_polarity;
        case (ecc_mode)
            "none":   ecc_width = 0;
            "parity": ecc_width = aip_mem_ecc::parity_width(width, parity_grain);
            "secded": ecc_width = aip_mem_ecc::secded_ecc_width(width);
            "crc8":   ecc_width = 8;
            default: begin
                `aip_error(("aip_mem_ecc_backdoor: unknown ecc_mode '%s'", ecc_mode));
                ecc_width = 0;
            end
        endcase
    endfunction

    function longint unsigned _encode(longint unsigned data);
        case (codec_cfg.ecc_mode)
            "none":   return 0;
            "parity": return aip_mem_ecc::parity_compute(data, codec_cfg.width,
                                                        codec_cfg.parity_grain,
                                                        codec_cfg.parity_polarity);
            "secded": return aip_mem_ecc::hamming_encode(data, codec_cfg.width);
            "crc8":   return aip_mem_ecc::crc8(data, codec_cfg.width);
        endcase
        return 0;
    endfunction

    task _decode(longint unsigned data, ecc,
                 output longint unsigned corrected, output string status);
        longint unsigned p_recalc;
        bit [7:0] c_recalc;
        case (codec_cfg.ecc_mode)
            "none": begin corrected = data; status = "ok"; end
            "parity": begin
                p_recalc = aip_mem_ecc::parity_compute(data, codec_cfg.width,
                                                      codec_cfg.parity_grain,
                                                      codec_cfg.parity_polarity);
                corrected = data;
                status = (p_recalc == ecc) ? "ok" : "parity_err";
            end
            "secded": aip_mem_ecc::hamming_decode(data, ecc, codec_cfg.width, corrected, status);
            "crc8": begin
                c_recalc  = aip_mem_ecc::crc8(data, codec_cfg.width);
                corrected = data;
                status    = (c_recalc == ecc[7:0]) ? "ok" : "crc_err";
            end
            default: begin corrected = data; status = "ok"; end
        endcase
    endtask

    virtual task read(uvm_reg_item rw);
        longint unsigned raw, corrected;
        longint unsigned data_mask;
        longint unsigned data, ecc;
        string status;
        acc.rd(rw.offset, raw, codec_cfg.width + ecc_width);
        data_mask = (codec_cfg.width >= 64) ? {64{1'b1}} :
                                              ((64'h1 << codec_cfg.width) - 1);
        data = raw & data_mask;
        ecc  = (ecc_width == 0) ? 0 : (raw >> codec_cfg.width);
        _decode(data, ecc, corrected, status);
        rw.value = new[1];
        rw.value[0] = corrected;
        if (status == "ok") begin
            rw.status = UVM_IS_OK;
        end else if (status.len() >= 10 && status.substr(0, 9) == "single_err") begin
            err_single++;
            err_addrs.push_back(rw.offset);
            rw.status = UVM_IS_OK;
            if (on_err == "warn")
                `aip_warning(("aip_mem_ecc_backdoor: %s @ 0x%0h (data=0x%0h ecc=0x%0h)",
                              status, rw.offset, data, ecc));
        end else if (status.len() >= 10 && status.substr(0, 9) == "double_err") begin
            err_double++;
            err_addrs.push_back(rw.offset);
            rw.status = UVM_NOT_OK;
            if (on_err != "silent")
                `aip_error(("aip_mem_ecc_backdoor: %s @ 0x%0h", status, rw.offset));
        end else if (status == "parity_err") begin
            err_parity++;
            err_addrs.push_back(rw.offset);
            rw.status = UVM_NOT_OK;
            if (on_err != "silent")
                `aip_warning(("aip_mem_ecc_backdoor: parity_err @ 0x%0h", rw.offset));
        end else if (status == "crc_err") begin
            err_crc++;
            err_addrs.push_back(rw.offset);
            rw.status = UVM_NOT_OK;
            if (on_err != "silent")
                `aip_warning(("aip_mem_ecc_backdoor: crc_err @ 0x%0h", rw.offset));
        end else begin
            rw.status = UVM_NOT_OK;
        end
    endtask

    virtual task write(uvm_reg_item rw);
        longint unsigned data, ecc, stored, data_mask;
        data      = rw.value[0];
        data_mask = (codec_cfg.width >= 64) ? {64{1'b1}} :
                                              ((64'h1 << codec_cfg.width) - 1);
        ecc       = _encode(data);
        stored    = (ecc << codec_cfg.width) | (data & data_mask);
        acc.wr(rw.offset, stored, codec_cfg.width + ecc_width);
        rw.status = UVM_IS_OK;
    endtask

    virtual function bit is_auto_updated(uvm_reg_field f); return 1; endfunction

    task inject_err(longint unsigned addr, int bit_pos);
        longint unsigned raw;
        acc.rd(addr, raw, codec_cfg.width + ecc_width);
        raw = raw ^ (64'd1 << bit_pos);
        acc.wr(addr, raw, codec_cfg.width + ecc_width);
        `aip_info(("aip_mem_ecc_backdoor::inject_err addr=0x%0h bit=%0d", addr, bit_pos));
    endtask

    task scrub(longint unsigned addr_from, addr_to, bit do_fix,
               output int ok, output int single, output int dbl, output int other);
        longint unsigned raw, data, ecc, corrected, data_mask;
        longint unsigned new_ecc, new_raw;
        string status;
        ok = 0; single = 0; dbl = 0; other = 0;
        data_mask = (codec_cfg.width >= 64) ? {64{1'b1}} :
                                              ((64'h1 << codec_cfg.width) - 1);
        for (longint unsigned a = addr_from; a <= addr_to; a++) begin
            acc.rd(a, raw, codec_cfg.width + ecc_width);
            data = raw & data_mask;
            ecc  = (ecc_width == 0) ? 0 : (raw >> codec_cfg.width);
            _decode(data, ecc, corrected, status);
            if (status == "ok") ok++;
            else if (status.len() >= 10 && status.substr(0, 9) == "single_err") begin
                single++;
                if (do_fix) begin
                    new_ecc = _encode(corrected);
                    new_raw = (new_ecc << codec_cfg.width) | (corrected & data_mask);
                    acc.wr(a, new_raw, codec_cfg.width + ecc_width);
                end
            end else if (status.len() >= 10 && status.substr(0, 9) == "double_err") dbl++;
            else other++;
        end
        `aip_info(("aip_mem_ecc_backdoor::scrub [0x%0h..0x%0h] ok=%0d single=%0d double=%0d other=%0d fix=%0d",
                  addr_from, addr_to, ok, single, dbl, other, do_fix));
    endtask

    function void stats_dump();
        $display("aip_mem_ecc_backdoor stats: single=%0d double=%0d parity=%0d crc=%0d total_err_addrs=%0d",
                 err_single, err_double, err_parity, err_crc, err_addrs.size());
    endfunction

    function void stats_reset();
        err_single = 0; err_double = 0; err_parity = 0; err_crc = 0;
        err_addrs.delete();
    endfunction

endclass

//-----------------------------------------------------------
// aip_mem_ecc_factory — 工厂便利接口
//-----------------------------------------------------------
class aip_mem_ecc_factory;

    static function aip_mem_ecc_backdoor attach_concat(
        uvm_mem mem,
        string  path,
        int     width,
        string  ecc_mode        = "secded",
        string  on_err          = "warn",
        int     parity_grain    = 8,
        string  parity_polarity = "even"
    );
        aip_mem_ecc_backdoor bk;
        aip_mem_acc_hdl      h;
        bk = aip_mem_ecc_backdoor::type_id::create("bk");
        bk.set_codec(width, ecc_mode, parity_grain, parity_polarity);
        bk.on_err = on_err;
        h = new(path);
        bk.acc = h;
        mem.set_backdoor(bk);
        return bk;
    endfunction

    static function aip_mem_ecc_backdoor attach_split(
        uvm_mem mem,
        string  data_path,
        string  ecc_path,
        int     width,
        string  ecc_mode        = "secded",
        string  on_err          = "warn",
        int     parity_grain    = 8,
        string  parity_polarity = "even"
    );
        aip_mem_ecc_backdoor bk;
        aip_mem_acc_hdl      hd, he;
        aip_mem_acc_split    s;
        bk = aip_mem_ecc_backdoor::type_id::create("bk");
        bk.set_codec(width, ecc_mode, parity_grain, parity_polarity);
        bk.on_err = on_err;
        hd = new(data_path);
        he = new(ecc_path);
        s             = new();
        s.data_acc    = hd;
        s.ecc_acc     = he;
        s.data_width  = width;
        s.ecc_width   = bk.ecc_width;
        bk.acc = s;
        mem.set_backdoor(bk);
        return bk;
    endfunction

    static function aip_mem_ecc_backdoor attach_custom(
        uvm_mem              mem,
        aip_mem_phy_accessor acc,
        int                  width,
        string               ecc_mode        = "secded",
        string               on_err          = "warn",
        int                  parity_grain    = 8,
        string               parity_polarity = "even"
    );
        aip_mem_ecc_backdoor bk;
        bk = aip_mem_ecc_backdoor::type_id::create("bk");
        bk.set_codec(width, ecc_mode, parity_grain, parity_polarity);
        bk.on_err = on_err;
        bk.acc    = acc;
        mem.set_backdoor(bk);
        return bk;
    endfunction

endclass

`endif // AIP_MEM_ECC_SV
