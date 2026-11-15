// 固件镜像装载与 CPU 启动就绪轮询：镜像统一经 load_image() 按 start/format 自动处理 ROM/RAM/packed40，每个地址只允许
// 成功写一次，重叠即 fatal。loader 归 TB 所有（可多实例），set() 须在命令执行前完成，运行中不得重绑/销毁 loader 或 region。
`ifndef AIP_CPU_LOADER_SV
`define AIP_CPU_LOADER_SV

import uvm_pkg::*;

class aip_cpu_loader;
    aip_cpu_mem            cpu;

    // Unified image-loader bookkeeping.  Addresses are recorded only after a
    // complete file has been parsed and validated; a second load that touches
    // an address already written by this loader is a fatal configuration error.
    bit                  staged_bytes[longint unsigned];
    longint unsigned     staged_addr[$];
    bit [7:0]            staged_data[$];
    bit                  image_error;

    function new(aip_cpu_mem c);
        cpu             = c;
        image_error     = 0;
    endfunction

    // Return the region with the smallest base strictly above current.  The
    // public image API uses this order when a linear image crosses an address
    // gap between ROM and RAM; callers do not need to know region names.
    function aip_cpu_region next_region(aip_cpu_region current);
        aip_cpu_region candidate;
        candidate = null;
        if (cpu == null || current == null) return null;
        foreach (cpu.regions[i]) begin
            if (cpu.regions[i].base > current.base &&
                (candidate == null || cpu.regions[i].base < candidate.base))
                candidate = cpu.regions[i];
        end
        return candidate;
    endfunction

    // Map a byte offset in a linear image to the physical CPU address.  Once
    // one region is full, the next higher region is selected even when the
    // address map contains a gap (the common ROM@0/RAM@0x8000_0000 layout).
    function bit linear_address(input longint unsigned start_addr,
                                input longint unsigned distance,
                                output longint unsigned target_addr);
        aip_cpu_region current;
        longint unsigned cursor;
        longint unsigned remaining;
        longint unsigned room;

        target_addr = 0;
        if (cpu == null) return 0;
        current = cpu.find(start_addr);
        if (current == null) return 0;
        cursor = start_addr;
        remaining = distance;
        while (1) begin
            room = (current.base + current.size) - cursor;
            if (remaining < room) begin
                target_addr = cursor + remaining;
                return 1;
            end
            remaining = remaining - room;
            current = next_region(current);
            if (current == null) return 0;
            cursor = current.base;
        end
    endfunction

    task automatic stage_byte(input longint unsigned addr, input bit [7:0] data);
        if (cpu == null || cpu.find(addr) == null) begin
            `aip_fatal(("aip_cpu_loader.load_image: address 0x%0h is not in any CPU region", addr));
            image_error = 1;
            return;
        end
        if (cpu.image_loaded_bytes.exists(addr)) begin
            `aip_fatal(("aip_cpu_loader.load_image: address overlap at 0x%0h (previous image already loaded)", addr));
            image_error = 1;
            return;
        end
        if (staged_bytes.exists(addr)) begin
            `aip_fatal(("aip_cpu_loader.load_image: duplicate address 0x%0h in image", addr));
            image_error = 1;
            return;
        end
        staged_bytes[addr] = 1;
        staged_addr.push_back(addr);
        staged_data.push_back(data);
    endtask

    task automatic clear_staging();
        staged_bytes.delete();
        staged_addr.delete();
        staged_data.delete();
    endtask

    task automatic write_staged_byte(input longint unsigned addr,
                                     input bit [7:0] data);
        aip_cpu_region region;
        aip_cpu_ram_region ram_region;
        aip_cpu_rom_region rom_region;
        bit write_ok;

        region = cpu.find(addr);
        if (region == null) begin
            `aip_fatal(("aip_cpu_loader.load_image: target address 0x%0h disappeared from CPU map", addr));
            image_error = 1;
            return;
        end
        if ($cast(ram_region, region)) begin
            ram_region.write_byte_checked(addr - region.base, data, write_ok);
        end else if ($cast(rom_region, region)) begin
            rom_region.write_byte_checked(addr - region.base, data, write_ok);
        end else begin
            `aip_fatal(("aip_cpu_loader.load_image: unsupported region type '%s' at 0x%0h",
                        region.name, addr));
            image_error = 1;
            return;
        end
        if (!write_ok) begin
            `aip_fatal(("aip_cpu_loader.load_image: HDL write failed at address 0x%0h", addr));
            image_error = 1;
        end
    endtask

    // 非法字符返回 0，供行解析器识别字段边界。
    function automatic bit packed40_hex_nibble(input byte ch, output int nibble);
        if (ch >= "0" && ch <= "9") begin
            nibble = ch - "0";
            return 1;
        end
        if (ch >= "a" && ch <= "f") begin
            nibble = ch - "a" + 10;
            return 1;
        end
        if (ch >= "A" && ch <= "F") begin
            nibble = ch - "A" + 10;
            return 1;
        end
        nibble = 0;
        return 0;
    endfunction

    // packed40 字段分隔仅接受空格或 TAB；换行已由上层去除，其他字符不得跳过。
    function automatic bit packed40_is_ws(input byte ch);
        return (ch == " " || ch == 8'd9);
    endfunction

    // Parse a normal Verilog byte-hex image into the staging queues.  With no
    // @ directive, bytes are linear and automatically spill from one region
    // to the next.  @ADDR remains compatible with the old format: ADDR is
    // relative to start_addr and selects an absolute CPU address.
    task automatic parse_hex_image(input string filename,
                                   input longint unsigned start_addr);
        int fd;
        string line;
        int len, i, nibble;
        int have_high;
        bit has_at;
        longint unsigned cur_addr;
        longint unsigned linear_index;
        longint unsigned target_addr;
        bit ok;
        bit [7:0] byte_value;

        fd = $fopen(filename, "r");
        if (fd == 0) begin
            `aip_fatal(("aip_cpu_loader.load_image: cannot open %s", filename));
            image_error = 1;
            return;
        end
        has_at = 0;
        cur_addr = start_addr;
        linear_index = 0;
        while (!$feof(fd)) begin
            void'($fgets(line, fd));
            line = aip_str::strip(line);
            len = line.len();
            if (len == 0) continue;

            if (line[0] == "@") begin
                longint unsigned offset_addr;
                int address_digits;
                offset_addr = 0;
                address_digits = 0;
                for (i = 1; i < len; i++) begin
                    if (packed40_hex_nibble(line[i], nibble)) begin
                        offset_addr = (offset_addr << 4) | nibble;
                        address_digits++;
                    end else if (!packed40_is_ws(line[i])) begin
                        `aip_fatal(("aip_cpu_loader.load_image: malformed @ address in %s", filename));
                        image_error = 1;
                        $fclose(fd);
                        return;
                    end else begin
                        break;
                    end
                end
                if (address_digits == 0) begin
                    `aip_fatal(("aip_cpu_loader.load_image: empty @ address in %s", filename));
                    image_error = 1;
                    $fclose(fd);
                    return;
                end
                cur_addr = start_addr + offset_addr;
                has_at = 1;
                continue;
            end

            byte_value = 0;
            have_high = 0;
            for (i = 0; i < len; i++) begin
                if (packed40_is_ws(line[i])) continue;
                if (!packed40_hex_nibble(line[i], nibble)) begin
                    `aip_fatal(("aip_cpu_loader.load_image: malformed hex byte in %s", filename));
                    image_error = 1;
                    $fclose(fd);
                    return;
                end
                if (!have_high) begin
                    byte_value = byte'(nibble << 4);
                    have_high = 1;
                end else begin
                    byte_value = byte_value | byte'(nibble);
                    if (has_at) begin
                        target_addr = cur_addr;
                        cur_addr++;
                    end else begin
                        ok = linear_address(start_addr, linear_index, target_addr);
                        if (!ok) begin
                            `aip_fatal(("aip_cpu_loader.load_image: image exceeds configured ROM/RAM regions at linear byte %0d",
                                        linear_index));
                            image_error = 1;
                            $fclose(fd);
                            return;
                        end
                        linear_index++;
                    end
                    stage_byte(target_addr, byte_value);
                    if (image_error) begin
                        $fclose(fd);
                        return;
                    end
                    have_high = 0;
                end
            end
            if (have_high) begin
                `aip_fatal(("aip_cpu_loader.load_image: odd number of hex digits in %s", filename));
                image_error = 1;
                $fclose(fd);
                return;
            end
        end
        $fclose(fd);
    endtask

    // Parse packed40 records using the same linear region mapping.  The
    // record index is a four-byte entry offset from start_addr; therefore a
    // single image can naturally fill ROM and then RAM, while a later call
    // can start at an arbitrary RAM address.
    task automatic parse_packed40_image(input string filename,
                                        input longint unsigned start_addr);
        int fd;
        string line;
        int len, pos, nibble, digit_count;
        longint unsigned entry_index;
        longint unsigned byte_offset;
        longint unsigned target_addr;
        bit [39:0] source_word;
        bit [7:0] source_byte;
        bit ok;

        fd = $fopen(filename, "r");
        if (fd == 0) begin
            `aip_fatal(("aip_cpu_loader.load_image: cannot open %s", filename));
            image_error = 1;
            return;
        end
        while (!$feof(fd)) begin
            void'($fgets(line, fd));
            line = aip_str::strip(line);
            len = line.len();
            if (len == 0) continue;
            if (line[0] != "@") begin
                `aip_fatal(("aip_cpu_loader.load_image: packed40 record must start with @ in %s", filename));
                image_error = 1;
                $fclose(fd);
                return;
            end
            pos = 1;
            entry_index = 0;
            digit_count = 0;
            while (pos < len && packed40_hex_nibble(line[pos], nibble)) begin
                entry_index = (entry_index << 4) | nibble;
                digit_count++;
                pos++;
            end
            if (digit_count == 0 || pos >= len || !packed40_is_ws(line[pos])) begin
                `aip_fatal(("aip_cpu_loader.load_image: malformed packed40 index in %s", filename));
                image_error = 1;
                $fclose(fd);
                return;
            end
            while (pos < len && packed40_is_ws(line[pos])) pos++;
            source_word = '0;
            digit_count = 0;
            while (pos < len && packed40_hex_nibble(line[pos], nibble)) begin
                source_word = (source_word << 4) | nibble;
                digit_count++;
                pos++;
            end
            while (pos < len && packed40_is_ws(line[pos])) pos++;
            if (digit_count != 10 || pos != len) begin
                `aip_fatal(("aip_cpu_loader.load_image: malformed packed40 payload in %s", filename));
                image_error = 1;
                $fclose(fd);
                return;
            end
            if (entry_index > 64'h3FFF_FFFF_FFFF_FFFF) begin
                `aip_fatal(("aip_cpu_loader.load_image: packed40 entry index overflow in %s", filename));
                image_error = 1;
                $fclose(fd);
                return;
            end
            byte_offset = entry_index * 4;
            for (int b = 0; b < 4; b++) begin
                case (b)
                    0: source_byte = source_word[38:31];
                    1: source_byte = source_word[29:22];
                    2: source_byte = source_word[20:13];
                    default: source_byte = source_word[11:4];
                endcase
                ok = linear_address(start_addr, byte_offset + b, target_addr);
                if (!ok) begin
                    `aip_fatal(("aip_cpu_loader.load_image: packed40 image exceeds configured regions at entry 0x%0h",
                                entry_index));
                    image_error = 1;
                    $fclose(fd);
                    return;
                end
                stage_byte(target_addr, source_byte);
                if (image_error) begin
                    $fclose(fd);
                    return;
                end
            end
        end
        $fclose(fd);
    endtask

    // The single public SV image API.  Parsing is staged first so malformed
    // input, out-of-range addresses, and overlaps never leave a half-written
    // image in the DUT.  format is "hex" (default) or "packed40".
    task load_image(input string filename,
                    input longint unsigned start_addr = 0,
                    input string format = "hex");
        string image_format;
        aip_cpu_ram72_region ram72_region;
        aip_cpu_ram72_region bulk_regions[$];
        bit bulk_ok;
        clear_staging();
        image_error = 0;
        if (cpu == null) begin
            `aip_fatal(("aip_cpu_loader.load_image: cpu memory facade is not set"));
            image_error = 1;
            return;
        end
        cpu.image_load_lock.get(1);
        image_format = aip_str::lower(aip_str::strip(format));
        case (image_format)
            "hex", "verilog", "legacy": parse_hex_image(filename, start_addr);
            "packed40", "pack40":       parse_packed40_image(filename, start_addr);
            default: begin
                `aip_fatal(("aip_cpu_loader.load_image: unsupported format '%s' (use hex or packed40)", format));
                image_error = 1;
            end
        endcase
        if (image_error) begin
            clear_staging();
            cpu.image_load_lock.put(1);
            return;
        end

        // RAM72 is physically mem[depth][bank] with one 72-bit word per
        // location.  Keep one row cache per configured RAM72 region so the
        // byte-oriented parser still results in one HDL read/deposit per
        // touched physical word.
        foreach (cpu.regions[i]) begin
            if ($cast(ram72_region, cpu.regions[i])) begin
                bulk_regions.push_back(ram72_region);
                ram72_region.begin_bulk_load();
            end
        end
        foreach (staged_addr[i]) begin
            write_staged_byte(staged_addr[i], staged_data[i]);
            if (image_error) begin
                break;
            end
        end
        foreach (bulk_regions[i]) begin
            if (image_error)
                bulk_regions[i].bulk_status = 0;
            bulk_regions[i].end_bulk_load(bulk_ok);
            if (!bulk_ok)
                image_error = 1;
        end
        if (image_error) begin
            clear_staging();
            cpu.image_load_lock.put(1);
            return;
        end
        foreach (staged_addr[i])
            cpu.image_loaded_bytes[staged_addr[i]] = 1;
        `aip_info(("aip_cpu_loader.load_image: loaded %0d bytes file=%s start=0x%0h format=%s",
                   staged_addr.size(), filename, start_addr, image_format));
        clear_staging();
        cpu.image_load_lock.put(1);
    endtask

endclass

// 静态 facade：Tcl 注册与 SV 直接调用共用 load_image(file,start,format)；区域映射与地址占用表由 aip_cpu_mem 统一拥有，
// 共享同一 map 的多个 loader 也共用重叠检查。
class aip_cpu_loader_default;
    static aip_cpu_loader inst = null;

    // 借用 TB 所有的 loader 作为默认命令目标；只允许在没有活动命令时初始化/重绑。
    static task set(aip_cpu_loader L);
        inst = L;
    endtask

    // 失败向当前命令/直接调用 scope 写诊断并返回 0；成功时不创建 scope、不改写全局结果。
    static function bit check(string ctx);
        if (inst == null) begin
            aip_cmd_result_context result_scope;
            result_scope = aip_cmd::begin_compat_result_scope();
            aip_cmd::set_compat_result(-1,
                $sformatf("aip_cpu_loader_default: not set (call set() in TB); ctx=%s", ctx));
            aip_cmd::end_compat_result_scope(result_scope);
            return 0;
        end
        return 1;
    endfunction

    // Unified public image entry point.  start is a 64-bit CPU address and
    // format is "hex" or "packed40"; ROM/RAM selection is entirely inferred
    // from the loader's cpu region map.
    static task load_image(string file, longint unsigned start = 0,
                           string format = "hex");
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (!check("load_image")) begin
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        inst.load_image(file, start, format);
        if (!inst.image_error)
            aip_cmd::set_compat_result(0,
                $sformatf("image loaded file=%s start=0x%0h format=%s",
                          file, start, format));
        else
            aip_cmd::set_compat_result(-1,
                $sformatf("image load failed file=%s start=0x%0h format=%s",
                          file, start, format));
        aip_cmd::end_compat_result_scope(result_scope);
    endtask

    // backdoor 轮询 (read32(addr)&mask)==(expected&mask)（mask=0 表示全位），不依赖 mailbox，适用于 boot-ready magic；
    // 每 100 个当前时间单位采样（沿用 1ns 编译假设）。结果经逐调用上下文返回，typed 宏默认成功不得覆盖；wait=0 不关闭 timeout_ns。
    static task wait_value(int addr, int expected, int mask, int timeout_ns);
        longint unsigned addr_u;
        bit [31:0] exp_u, mask_u, data;
        bit ok;
        int elapsed;
        aip_cmd_result_context result_scope;
        result_scope = aip_cmd::begin_compat_result_scope();
        if (!check("wait_value")) begin
            aip_cmd::end_compat_result_scope(result_scope);
            return;
        end
        addr_u  = addr;
        exp_u   = expected;
        mask_u  = (mask == 0) ? 32'hFFFF_FFFF : mask;
        elapsed = 0;
        forever begin
            inst.cpu.read32(addr_u, data, ok);
            if (ok && ((data & mask_u) == (exp_u & mask_u))) begin
                aip_cmd::set_compat_result(0,
                    $sformatf("ready @ %0t after %0d ns, val=0x%08h", $time, elapsed, data));
                aip_cmd::end_compat_result_scope(result_scope);
                return;
            end
            #100;
            elapsed += 100;
            if (elapsed >= timeout_ns) begin
                aip_cmd::set_compat_result(-1,
                    $sformatf("timeout %0d ns, last_val=0x%08h (expected 0x%08h mask 0x%08h)",
                              timeout_ns, data, exp_u, mask_u));
                aip_cmd::end_compat_result_scope(result_scope);
                return;
            end
        end
    endtask

endclass

`endif // AIP_CPU_LOADER_SV
