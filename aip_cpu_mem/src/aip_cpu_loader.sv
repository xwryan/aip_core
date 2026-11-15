//===========================================================
// aip_cpu_loader.sv — firmware loader wrapper
// Modes: "rom_xip" | "ram" | "rom_boot" | "ram_jump"
//   BOOT=rom      → rom_xip / rom_boot (image in ROM, runs / copies from ROM)
//   BOOT=ram_copy → rom_boot  (image LMA=ROM; CPU copies to RAM at reset)
//   BOOT=ram_jump → ram_jump  (combined hex → ROM stub + RAM payload)
// Depends: aip_cpu_mem (aip_cpu_rom_region, aip_cpu_ram_region)
//===========================================================
`ifndef AIP_CPU_LOADER_SV
`define AIP_CPU_LOADER_SV

import uvm_pkg::*;

class aip_cpu_loader;
    aip_cpu_mem            cpu;
    aip_cpu_rom_region     rom;
    aip_cpu_ram_region     ram;
    string                 mode;            // "rom_xip" | "ram" | "rom_boot"
    string                 fw_path;
    string                 jump_stub_path;  // optional, for ram mode without reset_pc_sig
    longint unsigned       reset_pc;
    string                 reset_pc_sig;    // empty → use jump stub

    function new(aip_cpu_mem c);
        cpu             = c;
        mode            = "rom_xip";
        fw_path         = "";
        jump_stub_path  = "";
        reset_pc        = 0;
        reset_pc_sig    = "";
    endfunction

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

    function automatic bit packed40_is_ws(input byte ch);
        return (ch == " " || ch == 8'd9);
    endfunction

    task load_packed40(input string filename, output bit status_ok, output int loaded_entries);
        int fd;
        string line;
        int len, pos, nibble, digit_count, line_num;
        longint unsigned entry_index;
        longint unsigned rom_entries;
        longint unsigned max_entries;
        bit [39:0] source_word;
        bit [7:0] source_byte;
        bit write_ok;

        status_ok = 0;
        loaded_entries = 0;
        if (rom == null || ram == null) begin
            `aip_error(("aip_cpu_loader.packed40: rom and ram regions both required"));
            return;
        end
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            `aip_error(("aip_cpu_loader.packed40: cannot open %s", filename));
            return;
        end

        rom_entries = rom.size / 4;
        max_entries = rom_entries + ram.size / 4;
        line_num = 0;
        while (!$feof(fd)) begin
            line_num++;
            void'($fgets(line, fd));
            len = line.len();
            while (len > 0 && (line[len-1] == 8'd10 || line[len-1] == 8'd13))
                len--;

            pos = 0;
            while (pos < len && packed40_is_ws(line[pos])) pos++;
            if (pos == len) continue;
            if (line[pos] != "@") begin
                `aip_error(("aip_cpu_loader.packed40: malformed record at line %0d in %s",
                            line_num, filename));
                $fclose(fd);
                return;
            end

            pos++;
            entry_index = 0;
            digit_count = 0;
            while (pos < len && packed40_hex_nibble(line[pos], nibble)) begin
                if (entry_index > 64'h0FFF_FFFF_FFFF_FFFF) begin
                    `aip_error(("aip_cpu_loader.packed40: entry index overflow at line %0d in %s",
                                line_num, filename));
                    $fclose(fd);
                    return;
                end
                entry_index = (entry_index << 4) | nibble;
                pos++;
                digit_count++;
            end
            if (digit_count == 0 || pos == len || !packed40_is_ws(line[pos])) begin
                `aip_error(("aip_cpu_loader.packed40: malformed record at line %0d in %s",
                            line_num, filename));
                $fclose(fd);
                return;
            end
            while (pos < len && packed40_is_ws(line[pos])) pos++;

            source_word = '0;
            digit_count = 0;
            while (pos < len && packed40_hex_nibble(line[pos], nibble)) begin
                source_word = (source_word << 4) | nibble;
                pos++;
                digit_count++;
            end
            if (digit_count != 10) begin
                `aip_error(("aip_cpu_loader.packed40: malformed payload at line %0d in %s",
                            line_num, filename));
                $fclose(fd);
                return;
            end
            while (pos < len && packed40_is_ws(line[pos])) pos++;
            if (pos != len) begin
                `aip_error(("aip_cpu_loader.packed40: malformed record at line %0d in %s",
                            line_num, filename));
                $fclose(fd);
                return;
            end
            if (entry_index >= max_entries) begin
                `aip_error(("aip_cpu_loader.packed40: entry index 0x%0h out of range at line %0d in %s",
                            entry_index, line_num, filename));
                $fclose(fd);
                return;
            end

            for (int b = 0; b < 4; b++) begin
                case (b)
                    0: source_byte = source_word[38:31];
                    1: source_byte = source_word[29:22];
                    2: source_byte = source_word[20:13];
                    default: source_byte = source_word[11:4];
                endcase
                if (entry_index < rom_entries)
                    rom.write_byte_checked(entry_index * 4 + b, source_byte, write_ok);
                else
                    ram.write_byte_checked((entry_index - rom_entries) * 4 + b,
                                           source_byte, write_ok);
                if (!write_ok) begin
                    `aip_error(("aip_cpu_loader.packed40: backdoor write failed at line %0d entry 0x%0h in %s",
                                line_num, entry_index, filename));
                    $fclose(fd);
                    return;
                end
            end
            loaded_entries++;
        end
        $fclose(fd);
        status_ok = 1;
        `aip_info(("aip_cpu_loader.packed40: loaded %0d entries from %s",
                   loaded_entries, filename));
    endtask

    task load();
        case (mode)
            "rom_xip":  load_rom_xip();
            "ram":      load_ram_only();
            "rom_boot": load_rom_boot();
            "ram_jump": load_ram_jump();
            default:    `aip_error(("aip_cpu_loader: unknown mode '%s'", mode));
        endcase
    endtask

    task load_rom_xip();
        if (rom == null) begin
            `aip_error(("aip_cpu_loader.rom_xip: rom region not set"));
            return;
        end
        `aip_info(("aip_cpu_loader.rom_xip: file=%s", fw_path));
        rom.load_hex(fw_path, 0);
    endtask

    task load_ram_only();
        if (ram == null) begin
            `aip_error(("aip_cpu_loader.ram: ram region not set"));
            return;
        end
        `aip_info(("aip_cpu_loader.ram: file=%s reset_pc=0x%0h sig=%s",
                   fw_path, reset_pc, reset_pc_sig));
        ram.load_hex(fw_path, 0);
        if (reset_pc_sig != "") begin
            if (!uvm_hdl_force(reset_pc_sig, reset_pc)) begin
                `aip_warning(("aip_cpu_loader.ram: uvm_hdl_force(%s) failed", reset_pc_sig));
            end
        end else if (jump_stub_path != "") begin
            if (rom == null) begin
                `aip_error(("aip_cpu_loader.ram: jump_stub requested but rom is null"));
            end else begin
                `aip_info(("aip_cpu_loader.ram: loading jump stub %s into ROM", jump_stub_path));
                rom.load_hex(jump_stub_path, 0);
            end
        end else begin
            `aip_warning(("aip_cpu_loader.ram: no reset_pc_sig nor jump_stub_path; CPU may not enter RAM"));
        end
    endtask

    task load_rom_boot();
        if (rom == null) begin
            `aip_error(("aip_cpu_loader.rom_boot: rom region not set"));
            return;
        end
        `aip_info(("aip_cpu_loader.rom_boot: file=%s", fw_path));
        rom.load_hex(fw_path, 0);
    endtask

    // Combined single hex: stub @ROM + payload @RAM in one file.
    // Load into both regions; each region's range guard keeps only its @segments.
    task load_ram_jump();
        if (rom == null || ram == null) begin
            `aip_error(("aip_cpu_loader.ram_jump: rom and ram regions both required"));
            return;
        end
        `aip_info(("aip_cpu_loader.ram_jump: file=%s (stub->ROM, payload->RAM)", fw_path));
        rom.load_hex(fw_path, 0);
        ram.load_hex(fw_path, 0);
    endtask
endclass

//===========================================================
// aip_cpu_loader_default — static singleton facade for TCL/DPI command
// registration. TB calls aip_cpu_loader_default::set(loader_inst) once,
// then aip_core_pkg registers fw_reload / load_rom / load_ram / load_hex_at
// targeting these static methods. Library remains multi-instance capable
// via the underlying aip_cpu_loader class.
//===========================================================
class aip_cpu_loader_default;
    static aip_cpu_loader inst = null;

    // Bind the global default to a TB-owned loader instance.
    static task set(aip_cpu_loader L);
        inst = L;
    endtask

    // Validate inst non-null + populate result string. Returns 1 on ok.
    static function bit check(string ctx);
        if (inst == null) begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result =
                $sformatf("aip_cpu_loader_default: not set (call set() in TB); ctx=%s", ctx);
            return 0;
        end
        return 1;
    endfunction

    // fw_reload mode=X file=Y — change loader.mode/fw_path then call load()
    static task load(string mode_in, string file_in);
        if (!check("load")) return;
        if (mode_in != "") inst.mode    = mode_in;
        if (file_in != "") inst.fw_path = file_in;
        if (inst.mode == "packed40") begin
            load_packed40(inst.fw_path);
            return;
        end
        inst.load();
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result =
            $sformatf("loaded mode=%s file=%s", inst.mode, inst.fw_path);
    endtask

    // load_packed40 file=X — load a packed40 ROM-then-RAM image with status.
    static task load_packed40(string file);
        bit ok;
        int loaded;
        if (!check("load_packed40")) return;
        inst.load_packed40(file, ok, loaded);
        if (ok) begin
            aip_cmd::__aip_cmd_last_status = 0;
            aip_cmd::__aip_cmd_last_result =
                $sformatf("packed40 loaded %0d entries from %s", loaded, file);
        end else begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result =
                $sformatf("packed40 load failed for %s", file);
        end
    endtask

    // load_rom file=X offset=Y — direct ROM load_hex (offset accepts 32-bit int)
    static task load_rom_hex(string file, int offset);
        longint unsigned off_u;
        if (!check("load_rom_hex")) return;
        if (inst.rom == null) begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result = "rom region not set";
            return;
        end
        off_u = offset;
        inst.rom.load_hex(file, off_u);
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result =
            $sformatf("rom loaded %s @0x%0h", file, off_u);
    endtask

    // load_ram file=X offset=Y — direct RAM load_hex (RMW + parity)
    static task load_ram_hex(string file, int offset);
        longint unsigned off_u;
        if (!check("load_ram_hex")) return;
        if (inst.ram == null) begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result = "ram region not set";
            return;
        end
        off_u = offset;
        inst.ram.load_hex(file, off_u);
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result =
            $sformatf("ram loaded %s @0x%0h", file, off_u);
    endtask

    // cpu_wait addr=X expected=Y mask=M timeout_ns=N
    //   Backdoor poll: wait until (read32(addr) & mask) == (expected & mask).
    //   Independent of CPU mailbox state (uvm_hdl_read direct). Use for boot-ready
    //   handshake: C writes MBOX_BOOT_READY_MAGIC to MBOX_BASE+MBOX_BOOT_READY_OFF
    //   when init done; host waits via this task.
    static task wait_value(int addr, int expected, int mask, int timeout_ns);
        longint unsigned addr_u;
        bit [31:0] exp_u, mask_u, data;
        bit ok;
        int elapsed;
        if (!check("wait_value")) return;
        addr_u  = addr;
        exp_u   = expected;
        mask_u  = (mask == 0) ? 32'hFFFF_FFFF : mask;
        elapsed = 0;
        forever begin
            inst.cpu.read32(addr_u, data, ok);
            if (ok && ((data & mask_u) == (exp_u & mask_u))) begin
                aip_cmd::__aip_cmd_last_status = 0;
                aip_cmd::__aip_cmd_last_result =
                    $sformatf("ready @ %0t after %0d ns, val=0x%08h", $time, elapsed, data);
                return;
            end
            #100;
            elapsed += 100;
            if (elapsed >= timeout_ns) begin
                aip_cmd::__aip_cmd_last_status = -1;
                aip_cmd::__aip_cmd_last_result =
                    $sformatf("timeout %0d ns, last_val=0x%08h (expected 0x%08h mask 0x%08h)",
                              timeout_ns, data, exp_u, mask_u);
                return;
            end
        end
    endtask

    // load_hex_at addr=X file=Y — auto-route via facade (addr is absolute, 32-bit)
    static task load_hex_at(int addr, string file);
        aip_cpu_region     r;
        aip_cpu_rom_region rom_r;
        aip_cpu_ram_region ram_r;
        longint unsigned   addr_u;
        if (!check("load_hex_at")) return;
        if (inst.cpu == null) begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result = "cpu_mem facade not set on loader";
            return;
        end
        addr_u = addr;
        r = inst.cpu.find(addr_u);
        if (r == null) begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result =
                $sformatf("no region contains 0x%0h", addr_u);
            return;
        end
        if ($cast(rom_r, r)) begin
            rom_r.load_hex(file, addr_u - r.base);
        end else if ($cast(ram_r, r)) begin
            ram_r.load_hex(file, addr_u - r.base);
        end else begin
            aip_cmd::__aip_cmd_last_status = -1;
            aip_cmd::__aip_cmd_last_result =
                $sformatf("region '%s' type not supported", r.name);
            return;
        end
        aip_cmd::__aip_cmd_last_status = 0;
        aip_cmd::__aip_cmd_last_result =
            $sformatf("loaded %s @0x%0h (region=%s)", file, addr_u, r.name);
    endtask
endclass

`endif // AIP_CPU_LOADER_SV
