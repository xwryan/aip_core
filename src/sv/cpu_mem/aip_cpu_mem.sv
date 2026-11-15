//===========================================================
// aip_cpu_mem.sv — 多 CPU 多 region 内存抽象层
//
// 功能:
//   - 用户单接口 cpu.write(addr, data, width)
//   - 自动按地址路由 ROM / RAM / 其他 region
//   - RAM 写入自动加 even parity (每 8 bit 1 bit)
//   - 多 CPU 各自实例化, base_addr + path 互不影响
//   - 每 region 持有 paths[blk][ram_id] 二维表, 支持任意 RTL 命名
//
// 物理拓扑 (示例):
//   ROM    : 1 block × 2 ram × 2048 depth × 64-bit         = 32 KB
//   CPU RAM: 62 block × 2 ram × 512 depth × 148-bit
//            148-bit 行 = bits[3:0] 保留 + 72 even slot + 72 odd slot
//            每 slot = 8 group × (8 data + 1 even parity) = 72 bit
//            data 字节容量 = 62 × 0x4000 = 0xF8000 = 992 KB
//
// 依赖:
//   aip_log    — `aip_info / `aip_warning / `aip_error
//   aip_mem_ecc — xor_bits primitive
//   uvm_pkg    — uvm_hdl_deposit / uvm_hdl_read
//
// 用法见 docs/cpu_mem/README.md
//===========================================================
`ifndef AIP_CPU_MEM_SV
`define AIP_CPU_MEM_SV

import uvm_pkg::*;

//============================================================
// aip_cpu_region — 抽象基类
//   持有 base/size + paths[blk][ram_id] 二维路径表
//   子类实现 write_impl / read_impl
//============================================================
virtual class aip_cpu_region;
    string           name;
    longint unsigned base;
    longint unsigned size;
    string           paths[$][$];   // paths[blk_id][ram_id] = RTL path

    function bit contains(longint unsigned addr);
        return (addr >= base) && (addr < base + size);
    endfunction

    function void set_path(int blk, int ram_id, string p);
        while (paths.size() <= blk)         paths.push_back({});
        while (paths[blk].size() <= ram_id) paths[blk].push_back("");
        paths[blk][ram_id] = p;
    endfunction

    function string get_path(int blk, int ram_id);
        if (blk >= paths.size() ||
            ram_id >= paths[blk].size() ||
            paths[blk][ram_id].len() == 0) begin
            `aip_error(("aip_cpu_region '%s': path not set blk=%0d ram=%0d",
                        name, blk, ram_id));
            return "";
        end
        return paths[blk][ram_id];
    endfunction

    pure virtual task write_impl(input  longint unsigned off,
                                 input  longint unsigned data,
                                 input  int              width);

    pure virtual task read_impl (input  longint unsigned off,
                                 output longint unsigned data,
                                 input  int              width,
                                 output bit              status_ok);

    // 整 region 高效清零 (子类绕过 byte-RMW)
    pure virtual task zero_all();
endclass

//============================================================
// aip_cpu_ram_region — CPU 148-bit + even parity RAM
//
// 物理布局:
//   每 block = 2 ram；每个逻辑 128-bit 行的低64存 u00 (ram0)，高64存 u01 (ram1)。
//   每 ram = 512 row × 148 bit；偶/奇逻辑行共用一个物理 row。
//   148-bit 行: bits[3:0] 保留, even slot 写 [4,6,...,146], odd slot 写 [5,7,...,147]
//   每 slot 72 bit = 8 group × (parity[1] | data[7:0])
//
// 地址解码 (off = byte_addr - base):
//   bof          = off % BLOCK_BYTES
//   line_in_bank = bof / 16
//   byte_in_line = bof % 16
//   ram_id       = byte_in_line / 8  (0=ram0低64, 1=ram1高64)
//   group_id     = byte_in_line % 8
//   depth        = line_in_bank / 2
//   slot_sel     = line_in_bank % 2  (0=even, 1=odd)
//============================================================
class aip_cpu_ram_region extends aip_cpu_region;

    int num_blocks;

    parameter int BLOCK_BYTES = 'h4000;
    parameter int HALF_BLOCK  = 'h2000;
    parameter int ROW_BYTES   = 16;
    parameter int RAM_DEPTH   = 512;
    parameter int RAM_WIDTH   = 148;

    typedef bit [RAM_WIDTH-1:0] ram_word_t;

    function new(string name, longint unsigned base, int num_blocks);
        this.name       = name;
        this.base       = base;
        this.num_blocks = num_blocks;
        this.size       = num_blocks * BLOCK_BYTES;
    endfunction

    // ---- 解码 ----
    function void decode(input  longint unsigned off,
                         output int blk,
                         output int ram_id,
                         output int depth,
                         output int slot_sel,
                         output int group_id);
        longint unsigned bof;
        int line_in_bank, byte_in_line;
        // 128-bit 行交织: 低64→uu0(ram0), 高64→uu1(ram1).
        // 偶/奇行共用一个物理 row (addr[0] 选偶/奇 lane), addr[9:1] 选 row.
        blk          = off / BLOCK_BYTES;       // bank 0..num_blocks-1
        bof          = off % BLOCK_BYTES;
        line_in_bank = bof / ROW_BYTES;         // ROW_BYTES=16 → 128-bit 行号
        byte_in_line = bof % ROW_BYTES;         // 0..15
        ram_id       = byte_in_line / 8;        // 0=uu0(低64) 1=uu1(高64)
        group_id     = byte_in_line % 8;        // 64 位内第几字节
        depth        = line_in_bank / 2;        // 行号[9:1] → physical row 0..511
        slot_sel     = line_in_bank % 2;        // 行号[0]: 0=偶lane(4,6..146) 1=奇lane(5,7..147)
    endfunction

    // ---- 物理 row RMW ----
    task rd_row(input int blk, input int ram_id, input int depth,
                output ram_word_t w);
        uvm_hdl_data_t d;
        void'(uvm_hdl_read($sformatf("%s[%0d]", get_path(blk, ram_id), depth), d));
        w = d;
    endtask

    task wr_row(input int blk, input int ram_id, input int depth,
                input ram_word_t w);
        uvm_hdl_data_t d;
        d = w;
        if (!uvm_hdl_deposit($sformatf("%s[%0d]", get_path(blk, ram_id), depth), d))
            `aip_warning(("aip_cpu_ram_region '%s': deposit fail blk=%0d ram=%0d depth=%0d",
                          name, blk, ram_id, depth));
    endtask

    task rd_row_checked(input int blk, input int ram_id, input int depth,
                        output ram_word_t w, output bit status_ok);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d]", get_path(blk, ram_id), depth);
        status_ok = uvm_hdl_read(path, d);
        if (!status_ok) begin
            w = '0;
            `aip_error(("aip_cpu_ram_region '%s': read fail blk=%0d ram=%0d depth=%0d path=%s",
                        name, blk, ram_id, depth, path));
            return;
        end
        w = d;
    endtask

    task wr_row_checked(input int blk, input int ram_id, input int depth,
                        input ram_word_t w, output bit status_ok);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d]", get_path(blk, ram_id), depth);
        d = w;
        status_ok = uvm_hdl_deposit(path, d);
        if (!status_ok)
            `aip_warning(("aip_cpu_ram_region '%s': deposit fail blk=%0d ram=%0d depth=%0d",
                          name, blk, ram_id, depth));
    endtask

    // ---- 148-bit 行内 9-bit group 改写 ({even_parity, 8 data}) ----
    function ram_word_t splice_group(input ram_word_t w_in,
                                     input int slot_sel,
                                     input int group_id,
                                     input bit [7:0] b);
        ram_word_t w;
        bit p;
        int base_pos, start_i;
        w        = w_in;
        p        = aip_mem_ecc::xor_bits(b, 8);          // even parity
        base_pos = (slot_sel == 0) ? 4 : 5;
        start_i  = group_id * 9;
        for (int j = 0; j < 8; j++)
            w[base_pos + (start_i + j) * 2] = b[j];
        w[base_pos + (start_i + 8) * 2] = p;
        return w;
    endfunction

    function bit [7:0] extract_group(input ram_word_t w,
                                     input int slot_sel,
                                     input int group_id,
                                     output bit parity_ok);
        bit [7:0] b;
        bit p_stored, p_recalc;
        int base_pos, start_i;
        base_pos  = (slot_sel == 0) ? 4 : 5;
        start_i   = group_id * 9;
        for (int j = 0; j < 8; j++)
            b[j] = w[base_pos + (start_i + j) * 2];
        p_stored  = w[base_pos + (start_i + 8) * 2];
        p_recalc  = aip_mem_ecc::xor_bits(b, 8);
        parity_ok = (p_stored == p_recalc);
        return b;
    endfunction

    // ---- byte 级 ----
    virtual task write_byte(input longint unsigned off, input bit [7:0] b);
        int blk, ram_id, depth, slot_sel, group_id;
        ram_word_t w;
        decode(off, blk, ram_id, depth, slot_sel, group_id);
        rd_row(blk, ram_id, depth, w);
        w = splice_group(w, slot_sel, group_id, b);
        wr_row(blk, ram_id, depth, w);
    endtask

    virtual task write_byte_checked(input longint unsigned off, input bit [7:0] b,
                                    output bit status_ok);
        int blk, ram_id, depth, slot_sel, group_id;
        ram_word_t w;
        decode(off, blk, ram_id, depth, slot_sel, group_id);
        rd_row_checked(blk, ram_id, depth, w, status_ok);
        if (!status_ok) return;
        w = splice_group(w, slot_sel, group_id, b);
        wr_row_checked(blk, ram_id, depth, w, status_ok);
    endtask

    virtual task read_byte(input  longint unsigned off,
                           output bit [7:0]        b,
                           output bit              parity_ok);
        int blk, ram_id, depth, slot_sel, group_id;
        ram_word_t w;
        decode(off, blk, ram_id, depth, slot_sel, group_id);
        rd_row(blk, ram_id, depth, w);
        b = extract_group(w, slot_sel, group_id, parity_ok);
    endtask

    // ---- 多字节: 按字节展开 (跨 slot/depth 边界自动处理) ----
    virtual task write_impl(input  longint unsigned off,
                            input  longint unsigned data,
                            input  int              width);
        for (int i = 0; i < width/8; i++)
            write_byte(off + i, (data >> (i*8)) & 8'hFF);
    endtask

    virtual task read_impl(input  longint unsigned off,
                           output longint unsigned data,
                           input  int              width,
                           output bit              status_ok);
        bit [7:0] b;
        bit ok_i;
        data      = 0;
        status_ok = 1;
        for (int i = 0; i < width/8; i++) begin
            read_byte(off + i, b, ok_i);
            if (!ok_i) status_ok = 0;
            data |= (longint'(b) << (i*8));
        end
    endtask

    // Hooks used by load_hex().  Legacy RAM keeps the no-op implementation;
    // RAM72 overrides them to cache one physical 72-bit mem[depth][bank].
    virtual task begin_image_load();
    endtask

    virtual task end_image_load(output bit status_ok);
        status_ok = 1;
    endtask

    // ---- 高效整 region 清零 ----
    // 全 0 data 的 even parity = XOR(0) = 0 → 整行物理 148'd0
    function ram_word_t make_zero_row();
        ram_word_t w = 0;
        for (int slot = 0; slot < 2; slot++)
            for (int g = 0; g < 8; g++)
                w = splice_group(w, slot, g, 8'h00);
        return w;
    endfunction

    virtual task zero_all();
        ram_word_t zw;
        int total;
        zw    = make_zero_row();
        total = 0;
        for (int b = 0; b < num_blocks; b++)
            for (int rid = 0; rid < 2; rid++)
                for (int d = 0; d < RAM_DEPTH; d++) begin
                    wr_row(b, rid, d, zw);
                    total++;
                end
        `aip_info(("aip_cpu_ram_region '%s': zero_all done, %0d row written",
                   name, total));
    endtask

    // 按地址范围清零 (off 都是 region 内偏移). RMW 走 byte 路径
    task zero_range(input longint unsigned off_from, input longint unsigned off_to);
        for (longint unsigned a = off_from; a <= off_to; a++)
            write_byte(a, 8'h00);
        `aip_info(("aip_cpu_ram_region '%s': zero_range [0x%0h..0x%0h]",
                   name, off_from, off_to));
    endtask

    // Load Verilog hex (@ADDR / hex bytes) into RAM. Legacy RAM remains
    // byte-level RMW; RAM72 overrides the image-load hooks below so all bytes
    // targeting one mem[depth][bank] word are committed together.
    task load_hex(input string filename, input longint unsigned addr_off = 0);
        int fd;
        string line;
        longint unsigned cur_addr;
        int total_bytes;
        bit image_load_ok;
        cur_addr = addr_off;
        total_bytes = 0;
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            `aip_error(("aip_cpu_ram_region '%s'.load_hex: cannot open %s",
                        name, filename));
            return;
        end
        begin_image_load();
        while (!$feof(fd)) begin
            int len, i;
            byte ch;
            byte b;
            int   nibble;
            int   have_high;
            void'($fgets(line, fd));
            len = line.len();
            if (len == 0) continue;
            // Strip trailing CR/LF
            while (len > 0 && (line[len-1] == 8'd10 || line[len-1] == 8'd13))
                len--;
            if (len == 0) continue;
            // @ADDR line
            if (line[0] == "@") begin
                longint unsigned addr_val;
                addr_val = 0;
                for (i = 1; i < len; i++) begin
                    ch = line[i];
                    if      (ch >= "0" && ch <= "9") nibble = ch - "0";
                    else if (ch >= "a" && ch <= "f") nibble = ch - "a" + 10;
                    else if (ch >= "A" && ch <= "F") nibble = ch - "A" + 10;
                    else continue;
                    addr_val = (addr_val << 4) | nibble;
                end
                cur_addr = addr_off + addr_val;
                continue;
            end
            // Byte stream: pairs of hex chars separated by whitespace
            b = 0;
            have_high = 0;
            for (i = 0; i < len; i++) begin
                ch = line[i];
                if (ch == " " || ch == 8'd9) begin
                    have_high = 0;
                    continue;
                end
                if      (ch >= "0" && ch <= "9") nibble = ch - "0";
                else if (ch >= "a" && ch <= "f") nibble = ch - "a" + 10;
                else if (ch >= "A" && ch <= "F") nibble = ch - "A" + 10;
                else continue;
                if (have_high == 0) begin
                    b = byte'(nibble << 4);
                    have_high = 1;
                end else begin
                    b = b | byte'(nibble);
                    // Range guard: skip @segments outside this region so a
                    // combined hex (ROM stub + RAM payload) self-routes.
                    if (contains(cur_addr)) begin
                        write_byte(cur_addr - base, b);
                        total_bytes++;
                    end
                    cur_addr++;
                    have_high = 0;
                end
            end
        end
        $fclose(fd);
        end_image_load(image_load_ok);
        if (!image_load_ok)
            `aip_error(("aip_cpu_ram_region '%s'.load_hex: HDL bulk write failed", name));
        `aip_info(("aip_cpu_ram_region '%s'.load_hex: loaded %0d bytes from %s",
                   name, total_bytes, filename));
    endtask
endclass

class aip_cpu_ram72_region extends aip_cpu_ram_region;
    parameter int RAM72_DEPTH = 256;
    parameter int RAM72_BANKS = 4;
    parameter int RAM72_WIDTH = 72;
    typedef bit [RAM72_WIDTH-1:0] ram72_word_t;

    // A physical RAM72 location is one 72-bit word at mem[depth][bank].
    // The image loader uses this cache to combine all bytes targeting one
    // physical word before issuing a single HDL deposit.
    bit              bulk_active;
    bit              bulk_status;
    ram72_word_t     bulk_rows[string];
    int              bulk_blk[string];
    int              bulk_ram_id[string];
    int              bulk_depth[string];
    int              bulk_bank[string];
    string           bulk_keys[$];

    function new(string name, longint unsigned base, int num_blocks);
        super.new(name, base, num_blocks);
        bulk_active = 0;
        bulk_status = 1;
    endfunction

    function void decode72(input longint unsigned off,
                           output int blk, output int ram_id,
                           output int depth, output int bank, output int byte_id);
        longint unsigned bof;
        int line;
        blk     = off / BLOCK_BYTES;
        bof     = off % BLOCK_BYTES;
        line    = bof >> 4;
        // The RTL declaration is mem[depth][bank], but its physical address
        // interleave is bank-major: consecutive 16-byte logical lines use
        // mem[0][0], mem[0][1], mem[0][2], mem[0][3], then mem[1][0].
        bank    = line[1:0];
        depth   = line[9:2];
        ram_id  = bof[3];
        byte_id = bof[2:0];
    endfunction

    task begin_bulk_load();
        bulk_rows.delete();
        bulk_blk.delete();
        bulk_ram_id.delete();
        bulk_depth.delete();
        bulk_bank.delete();
        bulk_keys.delete();
        bulk_status = 1;
        bulk_active = 1;
    endtask

    task bulk_write_byte(input longint unsigned off, input bit [7:0] b,
                         output bit status_ok);
        int blk, ram_id, depth, bank, byte_id;
        bit success;
        string key;
        ram72_word_t row;

        status_ok = 0;
        if (!bulk_active) begin
            write_byte_checked(off, b, status_ok);
            return;
        end
        decode72(off, blk, ram_id, depth, bank, byte_id);
        key = $sformatf("%0d:%0d:%0d:%0d", blk, ram_id, depth, bank);
        if (!bulk_rows.exists(key)) begin
            rd_row72(blk, ram_id, depth, bank, row, success);
            if (!success) begin
                bulk_status = 0;
                return;
            end
            bulk_rows[key] = row;
            bulk_blk[key] = blk;
            bulk_ram_id[key] = ram_id;
            bulk_depth[key] = depth;
            bulk_bank[key] = bank;
            bulk_keys.push_back(key);
        end
        bulk_rows[key] = splice_group72(bulk_rows[key], byte_id, b);
        status_ok = 1;
    endtask

    task end_bulk_load(output bit status_ok);
        bit write_ok;

        status_ok = bulk_status;
        if (!bulk_active) return;
        foreach (bulk_keys[i]) begin
            if (!status_ok) break;
            wr_row72_checked(bulk_blk[bulk_keys[i]], bulk_ram_id[bulk_keys[i]],
                             bulk_depth[bulk_keys[i]], bulk_bank[bulk_keys[i]],
                             bulk_rows[bulk_keys[i]], write_ok);
            if (!write_ok) status_ok = 0;
        end
        bulk_active = 0;
        bulk_status = status_ok;
        bulk_rows.delete();
        bulk_blk.delete();
        bulk_ram_id.delete();
        bulk_depth.delete();
        bulk_bank.delete();
        bulk_keys.delete();
    endtask

    virtual task begin_image_load();
        begin_bulk_load();
    endtask

    virtual task end_image_load(output bit status_ok);
        end_bulk_load(status_ok);
    endtask

    task rd_row72(input int blk, input int ram_id, input int depth, input int bank,
                  output ram72_word_t w, output bit success);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d][%0d]", get_path(blk, ram_id), depth, bank);
        success = uvm_hdl_read(path, d);
        if (!success) begin
            w = 72'd0;
            `aip_error(("aip_cpu_ram72_region '%s': read fail blk=%0d ram=%0d depth=%0d bank=%0d path=%s",
                        name, blk, ram_id, depth, bank, path));
            return;
        end
        w = d;
    endtask

    task wr_row72(input int blk, input int ram_id, input int depth, input int bank,
                  input ram72_word_t w);
        uvm_hdl_data_t d;
        d = w;
        if (!uvm_hdl_deposit($sformatf("%s[%0d][%0d]",
                                       get_path(blk, ram_id), depth, bank), d))
            `aip_warning(("aip_cpu_ram72_region '%s': deposit fail blk=%0d ram=%0d depth=%0d bank=%0d",
                          name, blk, ram_id, depth, bank));
    endtask

    virtual task wr_row72_checked(input int blk, input int ram_id, input int depth, input int bank,
                                  input ram72_word_t w, output bit status_ok);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d][%0d]", get_path(blk, ram_id), depth, bank);
        d = w;
        status_ok = uvm_hdl_deposit(path, d);
        if (!status_ok)
            `aip_warning(("aip_cpu_ram72_region '%s': deposit fail blk=%0d ram=%0d depth=%0d bank=%0d",
                          name, blk, ram_id, depth, bank));
    endtask

    function ram72_word_t splice_group72(input ram72_word_t w_in,
                                          input int byte_id, input bit [7:0] b);
        ram72_word_t w;
        int group_base;
        w = w_in;
        group_base = byte_id * 9;
        w[group_base +: 8] = b;
        w[group_base + 8]  = aip_mem_ecc::xor_bits(b, 8);
        return w;
    endfunction

    function bit [7:0] extract_group72(input ram72_word_t w, input int byte_id,
                                        output bit parity_ok);
        bit [7:0] b;
        int group_base;
        group_base = byte_id * 9;
        b = w[group_base +: 8];
        parity_ok = (w[group_base + 8] == aip_mem_ecc::xor_bits(b, 8));
        return b;
    endfunction

    virtual task write_byte(input longint unsigned off, input bit [7:0] b);
        int blk, ram_id, depth, bank, byte_id;
        ram72_word_t w;
        bit success;
        bit bulk_ok;
        if (bulk_active) begin
            bulk_write_byte(off, b, bulk_ok);
            return;
        end
        decode72(off, blk, ram_id, depth, bank, byte_id);
        rd_row72(blk, ram_id, depth, bank, w, success);
        if (!success) return;
        w = splice_group72(w, byte_id, b);
        wr_row72(blk, ram_id, depth, bank, w);
    endtask

    virtual task write_byte_checked(input longint unsigned off, input bit [7:0] b,
                                    output bit status_ok);
        int blk, ram_id, depth, bank, byte_id;
        ram72_word_t w;
        if (bulk_active) begin
            bulk_write_byte(off, b, status_ok);
            return;
        end
        decode72(off, blk, ram_id, depth, bank, byte_id);
        rd_row72(blk, ram_id, depth, bank, w, status_ok);
        if (!status_ok) return;
        w = splice_group72(w, byte_id, b);
        wr_row72_checked(blk, ram_id, depth, bank, w, status_ok);
    endtask

    virtual task read_byte(input longint unsigned off, output bit [7:0] b,
                           output bit parity_ok);
        int blk, ram_id, depth, bank, byte_id;
        ram72_word_t w;
        bit success;
        decode72(off, blk, ram_id, depth, bank, byte_id);
        rd_row72(blk, ram_id, depth, bank, w, success);
        if (!success) begin
            b = 8'h00;
            parity_ok = 0;
            return;
        end
        b = extract_group72(w, byte_id, parity_ok);
    endtask

    virtual task zero_all();
        ram72_word_t zw;
        int total;
        zw = 72'd0;
        total = 0;
        for (int b = 0; b < num_blocks; b++)
            for (int rid = 0; rid < 2; rid++)
                for (int d = 0; d < RAM72_DEPTH; d++)
                    for (int bank = 0; bank < RAM72_BANKS; bank++) begin
                        wr_row72(b, rid, d, bank, zw);
                        total++;
                    end
        `aip_info(("aip_cpu_ram72_region '%s': zero_all done, %0d word written",
                   name, total));
    endtask
endclass

//============================================================
// aip_cpu_rom_region — 纯 64-bit ROM, 无 parity
//
// 物理布局:
//   每 block = 2 ram × 2048 row × 64-bit。
//   每条逻辑 128-bit 行的低64存 ram0/uu0，高64存 ram1/uu1。
//
// 地址解码 (off = byte_addr - base):
//   blk          = off / 0x8000
//   bof          = off % 0x8000
//   depth        = bof / 16
//   byte_in_line = bof % 16
//   ram_id       = byte_in_line / 8
//   byte_in_word = byte_in_line % 8
//============================================================
class aip_cpu_rom_region extends aip_cpu_region;

    int num_blocks;

    parameter int BLOCK_BYTES  = 'h8000;
    parameter int HALF_BLOCK_B = 'h4000;
    parameter int ROW_BYTES    = 8;
    parameter int ROM_DEPTH    = 2048;
    parameter int ROM_WIDTH    = 64;

    typedef bit [ROM_WIDTH-1:0] rom_word_t;

    function new(string name, longint unsigned base, int num_blocks = 1);
        this.name       = name;
        this.base       = base;
        this.num_blocks = num_blocks;
        this.size       = num_blocks * BLOCK_BYTES;
    endfunction

    function void decode(input  longint unsigned off,
                         output int blk,
                         output int ram_id,
                         output int depth,
                         output int byte_in_word);
        longint unsigned bof;
        int byte_in_line;
        // 128-bit 行交织: 低64→uu0(ram0), 高64→uu1(ram1). ROM 纯 64-bit, 一行=8字节.
        blk          = off / BLOCK_BYTES;        // 0x8000
        bof          = off % BLOCK_BYTES;
        depth        = bof / (ROW_BYTES*2);      // ROW_BYTES*2=16 → 128-bit 行号 0..2047
        byte_in_line = bof % (ROW_BYTES*2);      // 0..15
        ram_id       = byte_in_line / ROW_BYTES; // 0=uu0(低64) 1=uu1(高64)
        byte_in_word = byte_in_line % ROW_BYTES; // 0..7
    endfunction

    task rd_row(input int blk, input int ram_id, input int depth,
                output rom_word_t w);
        uvm_hdl_data_t d;
        void'(uvm_hdl_read($sformatf("%s[%0d]", get_path(blk, ram_id), depth), d));
        w = d;
    endtask

    task wr_row(input int blk, input int ram_id, input int depth,
                input rom_word_t w);
        uvm_hdl_data_t d;
        d = w;
        if (!uvm_hdl_deposit($sformatf("%s[%0d]", get_path(blk, ram_id), depth), d))
            `aip_warning(("aip_cpu_rom_region '%s': deposit fail blk=%0d ram=%0d depth=%0d",
                          name, blk, ram_id, depth));
    endtask

    task rd_row_checked(input int blk, input int ram_id, input int depth,
                        output rom_word_t w, output bit status_ok);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d]", get_path(blk, ram_id), depth);
        status_ok = uvm_hdl_read(path, d);
        if (!status_ok) begin
            w = '0;
            `aip_error(("aip_cpu_rom_region '%s': read fail blk=%0d ram=%0d depth=%0d path=%s",
                        name, blk, ram_id, depth, path));
            return;
        end
        w = d;
    endtask

    task wr_row_checked(input int blk, input int ram_id, input int depth,
                        input rom_word_t w, output bit status_ok);
        uvm_hdl_data_t d;
        string path;
        path = $sformatf("%s[%0d]", get_path(blk, ram_id), depth);
        d = w;
        status_ok = uvm_hdl_deposit(path, d);
        if (!status_ok)
            `aip_warning(("aip_cpu_rom_region '%s': deposit fail blk=%0d ram=%0d depth=%0d",
                          name, blk, ram_id, depth));
    endtask

    virtual task write_byte_checked(input longint unsigned off, input bit [7:0] b,
                                    output bit status_ok);
        int blk, ram_id, depth, byte_in_word;
        rom_word_t w;
        decode(off, blk, ram_id, depth, byte_in_word);
        rd_row_checked(blk, ram_id, depth, w, status_ok);
        if (!status_ok) return;
        w[byte_in_word*8 +: 8] = b;
        wr_row_checked(blk, ram_id, depth, w, status_ok);
    endtask

    virtual task write_impl(input  longint unsigned off,
                            input  longint unsigned data,
                            input  int              width);
        int blk, ram_id, depth, byte_in_word;
        rom_word_t w;

        // 64-bit 对齐快路径: 整行直接写
        if (width == 64 && (off % 8) == 0) begin
            decode(off, blk, ram_id, depth, byte_in_word);
            w = data;
            wr_row(blk, ram_id, depth, w);
        end else begin
            // 非对齐 / 小宽度: 走 RMW
            for (int i = 0; i < width/8; i++) begin
                decode(off + i, blk, ram_id, depth, byte_in_word);
                rd_row(blk, ram_id, depth, w);
                w[byte_in_word*8 +: 8] = (data >> (i*8)) & 8'hFF;
                wr_row(blk, ram_id, depth, w);
            end
        end
    endtask

    virtual task read_impl(input  longint unsigned off,
                           output longint unsigned data,
                           input  int              width,
                           output bit              status_ok);
        int blk, ram_id, depth, byte_in_word;
        rom_word_t w;
        status_ok = 1;     // ROM 无 parity, 永远 ok
        data      = 0;

        if (width == 64 && (off % 8) == 0) begin
            decode(off, blk, ram_id, depth, byte_in_word);
            rd_row(blk, ram_id, depth, w);
            data = w;
        end else begin
            for (int i = 0; i < width/8; i++) begin
                decode(off + i, blk, ram_id, depth, byte_in_word);
                rd_row(blk, ram_id, depth, w);
                data |= (longint'(w[byte_in_word*8 +: 8]) << (i*8));
            end
        end
    endtask

    // ---- 高效整 region 清零 ----
    virtual task zero_all();
        rom_word_t zw;
        int total;
        zw    = 64'd0;
        total = 0;
        for (int b = 0; b < num_blocks; b++)
            for (int rid = 0; rid < 2; rid++)
                for (int d = 0; d < ROM_DEPTH; d++) begin
                    wr_row(b, rid, d, zw);
                    total++;
                end
        `aip_info(("aip_cpu_rom_region '%s': zero_all done, %0d row written",
                   name, total));
    endtask

    task zero_range(input longint unsigned off_from, input longint unsigned off_to);
        int blk, ram_id, depth, byte_in_word;
        rom_word_t w;
        // 对齐快路径: 8-byte 对齐 + 8-byte 倍数 → 整行写 0
        if ((off_from % 8) == 0 && ((off_to + 1) % 8) == 0) begin
            for (longint unsigned a = off_from; a <= off_to; a += 8) begin
                decode(a, blk, ram_id, depth, byte_in_word);
                w = 64'd0;
                wr_row(blk, ram_id, depth, w);
            end
        end else begin
            for (longint unsigned a = off_from; a <= off_to; a++) begin
                decode(a, blk, ram_id, depth, byte_in_word);
                rd_row(blk, ram_id, depth, w);
                w[byte_in_word*8 +: 8] = 8'h00;
                wr_row(blk, ram_id, depth, w);
            end
        end
        `aip_info(("aip_cpu_rom_region '%s': zero_range [0x%0h..0x%0h]",
                   name, off_from, off_to));
    endtask

    // ---- 从 hex 文件加载 firmware ----
    // Supports Verilog hex format: @ADDR directives + whitespace-separated hex bytes.
    // Matches aip_cpu_ram_region::load_hex (compatible with objcopy -O verilog output).
    task load_hex(input string filename, input longint unsigned addr_off = 0);
        int fd;
        string line;
        longint unsigned cur_addr;
        int total_bytes;
        cur_addr = addr_off;
        total_bytes = 0;
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            `aip_error(("aip_cpu_rom_region '%s'.load_hex: cannot open %s",
                        name, filename));
            return;
        end
        while (!$feof(fd)) begin
            int len, i;
            byte ch;
            byte b;
            int   nibble;
            int   have_high;
            void'($fgets(line, fd));
            len = line.len();
            if (len == 0) continue;
            while (len > 0 && (line[len-1] == 8'd10 || line[len-1] == 8'd13))
                len--;
            if (len == 0) continue;
            if (line[0] == "@") begin
                longint unsigned addr_val;
                addr_val = 0;
                for (i = 1; i < len; i++) begin
                    ch = line[i];
                    if      (ch >= "0" && ch <= "9") nibble = ch - "0";
                    else if (ch >= "a" && ch <= "f") nibble = ch - "a" + 10;
                    else if (ch >= "A" && ch <= "F") nibble = ch - "A" + 10;
                    else continue;
                    addr_val = (addr_val << 4) | nibble;
                end
                cur_addr = addr_off + addr_val;
                continue;
            end
            b = 0;
            have_high = 0;
            for (i = 0; i < len; i++) begin
                ch = line[i];
                if (ch == " " || ch == 8'd9) begin
                    have_high = 0;
                    continue;
                end
                if      (ch >= "0" && ch <= "9") nibble = ch - "0";
                else if (ch >= "a" && ch <= "f") nibble = ch - "a" + 10;
                else if (ch >= "A" && ch <= "F") nibble = ch - "A" + 10;
                else continue;
                if (have_high == 0) begin
                    b = byte'(nibble << 4);
                    have_high = 1;
                end else begin
                    b = b | byte'(nibble);
                    // Range guard: skip @segments outside this region so a
                    // combined hex (ROM stub + RAM payload) self-routes.
                    if (contains(cur_addr)) begin
                        write_impl(cur_addr - base, b, 8);
                        total_bytes++;
                    end
                    cur_addr++;
                    have_high = 0;
                end
            end
        end
        $fclose(fd);
        `aip_info(("aip_cpu_rom_region '%s'.load_hex: loaded %0d bytes from %s",
                   name, total_bytes, filename));
    endtask
endclass

//============================================================
// aip_cpu_mem — facade
//   持有 regions[$], 按 addr 自动路由
//   提供注册便利方法 (单 path / 模板 / 显式)
//============================================================
class aip_cpu_mem;

    aip_cpu_region regions[$];
    // Addresses committed through the unified image loader.  Kept on the
    // memory facade (rather than on one loader object) so two loader handles
    // sharing the same CPU map cannot silently overwrite each other.
    bit image_loaded_bytes[longint unsigned];
    // Serialize parse/stage/commit across loaders sharing this map.  The
    // address table alone is insufficient when two SV tasks enter
    // load_image() in the same time slot.
    semaphore image_load_lock;

    function new();
        image_load_lock = new(1);
    endfunction

    // ---------- region 注册 ----------
    function void add_region(aip_cpu_region r);
        foreach (regions[i]) begin
            if (!(r.base + r.size <= regions[i].base ||
                  regions[i].base + regions[i].size <= r.base)) begin
                `aip_error(("aip_cpu_mem: region '%s' overlaps '%s'",
                            r.name, regions[i].name));
                return;
            end
        end
        regions.push_back(r);
        `aip_info(("aip_cpu_mem: added '%s' base=0x%0h size=0x%0h end=0x%0h",
                   r.name, r.base, r.size, r.base + r.size - 1));
    endfunction

    // ---------- ROM: 1 块, 显式 2 path ----------
    function aip_cpu_rom_region add_rom(
        input string           name,
        input longint unsigned base,
        input string           ram0_path,
        input string           ram1_path
    );
        aip_cpu_rom_region r = new(name, base, 1);
        r.set_path(0, 0, ram0_path);
        r.set_path(0, 1, ram1_path);
        add_region(r);
        return r;
    endfunction

    // ---------- ROM: 1 块, RTL 带索引名 (如 dut.rom[3].uu0) ----------
    // ram0/ram1_path_fmt 含 %0d, blk_id 注入
    function aip_cpu_rom_region add_rom_id(
        input string           name,
        input longint unsigned base,
        input int              blk_id,
        input string           ram0_path_fmt,
        input string           ram1_path_fmt
    );
        aip_cpu_rom_region r = new(name, base, 1);
        r.set_path(0, 0, $sformatf(ram0_path_fmt, blk_id));
        r.set_path(0, 1, $sformatf(ram1_path_fmt, blk_id));
        add_region(r);
        return r;
    endfunction

    // ---------- RAM: 多 block, 模板拼路径 ----------
    // blk_id_offset: RTL 索引起始值 (默认 0). 如 RTL 是 blk[2..63], offset=2
    function aip_cpu_ram_region add_ram_fmt(
        input string           name,
        input longint unsigned base,
        input string           ram0_path_fmt,
        input string           ram1_path_fmt,
        input int              num_blocks    = 62,
        input int              blk_id_offset = 0
    );
        aip_cpu_ram_region r = new(name, base, num_blocks);
        for (int b = 0; b < num_blocks; b++) begin
            r.set_path(b, 0, $sformatf(ram0_path_fmt, b + blk_id_offset));
            r.set_path(b, 1, $sformatf(ram1_path_fmt, b + blk_id_offset));
        end
        add_region(r);
        return r;
    endfunction

    function aip_cpu_ram72_region add_ram72_fmt(
        input string name, input longint unsigned base,
        input string u00_path_fmt, input string u01_path_fmt,
        input int num_blocks = 62, input int blk_id_offset = 0
    );
        aip_cpu_ram72_region r = new(name, base, num_blocks);
        for (int b = 0; b < num_blocks; b++) begin
            r.set_path(b, 0, $sformatf(u00_path_fmt, b + blk_id_offset));
            r.set_path(b, 1, $sformatf(u01_path_fmt, b + blk_id_offset));
        end
        add_region(r);
        return r;
    endfunction

    // ---------- RAM: 不规整命名, 空创建 + 用户手填 ----------
    function aip_cpu_ram_region add_ram_empty(
        input string           name,
        input longint unsigned base,
        input int              num_blocks = 62
    );
        aip_cpu_ram_region r = new(name, base, num_blocks);
        add_region(r);
        return r;
    endfunction

    // ---------- ROM 多块情况, 模板版 ----------
    function aip_cpu_rom_region add_rom_fmt(
        input string           name,
        input longint unsigned base,
        input string           ram0_path_fmt,
        input string           ram1_path_fmt,
        input int              num_blocks    = 1,
        input int              blk_id_offset = 0
    );
        aip_cpu_rom_region r = new(name, base, num_blocks);
        for (int b = 0; b < num_blocks; b++) begin
            r.set_path(b, 0, $sformatf(ram0_path_fmt, b + blk_id_offset));
            r.set_path(b, 1, $sformatf(ram1_path_fmt, b + blk_id_offset));
        end
        add_region(r);
        return r;
    endfunction

    // ---------- 路由 ----------
    function aip_cpu_region find(input longint unsigned addr);
        foreach (regions[i])
            if (regions[i].contains(addr)) return regions[i];
        return null;
    endfunction

    // ---------- 用户统一接口 ----------
    task write(input longint unsigned addr,
               input longint unsigned data,
               input int              width = 64);
        aip_cpu_region r;
        if (width != 8 && width != 32 && width != 64) begin
            `aip_error(("aip_cpu_mem::write width must be 8/32/64, got %0d", width));
            return;
        end
        r = find(addr);
        if (r == null) begin
            `aip_error(("aip_cpu_mem::write addr 0x%0h not in any region", addr));
            return;
        end
        r.write_impl(addr - r.base, data, width);
        `aip_info(("aip_cpu_mem::write [%s] addr=0x%0h width=%0d data=0x%0h",
                   r.name, addr, width, data));
    endtask

    task read(input  longint unsigned addr,
              output longint unsigned data,
              input  int              width = 64,
              output bit              status_ok);
        aip_cpu_region r;
        data      = 0;
        status_ok = 0;
        if (width != 8 && width != 32 && width != 64) begin
            `aip_error(("aip_cpu_mem::read width must be 8/32/64, got %0d", width));
            return;
        end
        r = find(addr);
        if (r == null) begin
            `aip_error(("aip_cpu_mem::read addr 0x%0h not in any region", addr));
            return;
        end
        r.read_impl(addr - r.base, data, width, status_ok);
    endtask

    // ---------- 便利接口: 显式 8/32/64 宽度 ----------
    task write8 (input longint unsigned addr, input bit [7:0]  data);
        write(addr, longint'(data),  8);
    endtask
    task write32(input longint unsigned addr, input bit [31:0] data);
        write(addr, longint'(data), 32);
    endtask
    task write64(input longint unsigned addr, input bit [63:0] data);
        write(addr, longint'(data), 64);
    endtask

    task read8 (input  longint unsigned addr,
                output bit [7:0]        data,
                output bit              status_ok);
        longint unsigned tmp;
        read(addr, tmp, 8, status_ok);
        data = tmp[7:0];
    endtask
    task read32(input  longint unsigned addr,
                output bit [31:0]       data,
                output bit              status_ok);
        longint unsigned tmp;
        read(addr, tmp, 32, status_ok);
        data = tmp[31:0];
    endtask
    task read64(input  longint unsigned addr,
                output bit [63:0]       data,
                output bit              status_ok);
        longint unsigned tmp;
        read(addr, tmp, 64, status_ok);
        data = tmp;
    endtask

    // ---------- 块批量 ----------
    task write_block(input longint unsigned addr,
                     input longint unsigned data[$],
                     input int              width = 64);
        int step = width / 8;
        foreach (data[i]) write(addr + i*step, data[i], width);
    endtask

    task read_block(input  longint unsigned addr,
                    input  int              count,
                    output longint unsigned data[$],
                    input  int              width = 64);
        longint unsigned v;
        bit ok;
        int step = width / 8;
        data = {};
        for (int i = 0; i < count; i++) begin
            read(addr + i*step, v, width, ok);
            data.push_back(v);
        end
    endtask

    task write_zero(input longint unsigned addr, input int nbytes);
        for (int i = 0; i < nbytes; i++) write8(addr + i, 8'h00);
    endtask

    // ---------- 整 region 清零 (调子类高效实现) ----------
    task zero_region(input string region_name);
        bit found = 0;
        foreach (regions[i]) begin
            if (regions[i].name == region_name) begin
                regions[i].zero_all();
                found = 1;
                break;
            end
        end
        if (!found)
            `aip_error(("aip_cpu_mem::zero_region: '%s' not found", region_name));
    endtask

    // ---------- 所有 region 清零 ----------
    task zero_all();
        foreach (regions[i]) regions[i].zero_all();
        `aip_info(("aip_cpu_mem::zero_all: %0d region cleared", regions.size()));
    endtask

    // ---------- 按地址范围清零 (跨 region 自动分段) ----------
    task zero_range(input longint unsigned addr_from, input longint unsigned addr_to);
        aip_cpu_region r;
        aip_cpu_ram_region rr;
        aip_cpu_rom_region ro;
        longint unsigned cur, end_in_r;
        cur = addr_from;
        while (cur <= addr_to) begin
            r = find(cur);
            if (r == null) begin
                `aip_error(("aip_cpu_mem::zero_range: addr 0x%0h not in any region", cur));
                return;
            end
            end_in_r = r.base + r.size - 1;
            if (end_in_r > addr_to) end_in_r = addr_to;
            if ($cast(rr, r))
                rr.zero_range(cur - r.base, end_in_r - r.base);
            else if ($cast(ro, r))
                ro.zero_range(cur - r.base, end_in_r - r.base);
            cur = end_in_r + 1;
        end
    endtask

    task write_incr(input longint unsigned addr,
                    input int              count,
                    input longint unsigned start_v = 0,
                    input int              width   = 64);
        int step = width / 8;
        for (int i = 0; i < count; i++) write(addr + i*step, start_v + i, width);
    endtask

    // ---------- 调试 ----------
    function void dump_map();
        $display("================ aip_cpu_mem map ================");
        $display(" %-12s %-12s %-12s %-12s", "NAME", "BASE", "SIZE", "END");
        $display("-------------------------------------------------");
        foreach (regions[i])
            $display(" %-12s 0x%010h 0x%010h 0x%010h",
                     regions[i].name,
                     regions[i].base,
                     regions[i].size,
                     regions[i].base + regions[i].size - 1);
        $display("=================================================");
    endfunction

endclass

`endif // AIP_CPU_MEM_SV
