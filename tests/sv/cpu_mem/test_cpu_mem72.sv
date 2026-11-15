//===========================================================
// test_cpu_mem72.sv — RAM72 backdoor behavior specification
//===========================================================
`include "aip_core_pkg.sv"
`include "aip_cpu_mem.sv"
`include "fake_mem.sv"

module tb;

    localparam longint unsigned BASE     = 64'h8000_0000;
    localparam longint unsigned OFF_BASE = 64'h9000_0000;
    localparam longint unsigned BAD_BASE = 64'hA000_0000;

    fake_ram72_block cpu_ram        [0:3] ();
    fake_ram72_block cpu_ram_offset [5:7] ();
    fake_rom_ram packed40_rom0 ();
    fake_rom_ram packed40_rom1 ();

    int pass_count = 0;
    int fail_count = 0;

    `define CHECK_EQ(av, ev, mv) \
        if ((av) === (ev)) begin \
            pass_count++; \
            $display("[PASS] %s: got=0x%0h want=0x%0h", mv, av, ev); \
        end else begin \
            fail_count++; \
            $display("[FAIL] %s: got=0x%0h want=0x%0h", mv, av, ev); \
        end

    `define CHECK_TRUE(cv, mv) \
        if (cv) begin \
            pass_count++; \
            $display("[PASS] %s", mv); \
        end else begin \
            fail_count++; \
            $display("[FAIL] %s", mv); \
        end

    aip_cpu_mem          cpu;
    aip_cpu_ram72_region ram72;
    aip_cpu_ram_region   ram_as_legacy;
    aip_cpu_rom_region   rom_packed40;
    aip_cpu_loader       loader;

    // A RAM72 word holds eight contiguous {parity, data[7:0]} groups.
    function automatic bit [71:0] pack_word64(input bit [63:0] data);
        bit [71:0] word;
        word = '0;
        for (int group = 0; group < 8; group++) begin
            word[group * 9 +: 8] = data[group * 8 +: 8];
            word[group * 9 + 8] =
                aip_mem_ecc::xor_bits(data[group * 8 +: 8], 8);
        end
        return word;
    endfunction

    function automatic bit [39:0] packed40_word(input bit [7:0] b0,
                                                  input bit [7:0] b1,
                                                  input bit [7:0] b2,
                                                  input bit [7:0] b3);
        bit [39:0] w;
        w = '0;
        w[39] = 1'b1; w[38:31] = b0;
        w[30] = 1'b0; w[29:22] = b1;
        w[21] = 1'b1; w[20:13] = b2;
        w[12] = 1'b0; w[11:4] = b3;
        w[3:0] = 4'hf;
        return w;
    endfunction

    task automatic check_cross64(
        input longint unsigned addr,
        input bit [63:0]      expected,
        input string          msg
    );
        bit [63:0] actual;
        bit ok;
        cpu.write64(addr, expected);
        cpu.read64(addr, actual, ok);
        `CHECK_EQ(actual, expected, msg)
        `CHECK_TRUE(ok, $sformatf("%s parity ok", msg))
    endtask

    task automatic test_basic_u00_u01();
        bit [63:0] data;
        bit ok;
        $display("\n=========== RAM72 basic u00/u01 ===========");

        cpu.write64(BASE, 64'h1122_3344_5566_7788);
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][0][7:0], 8'h88,
                  "BASE u00 group0 data")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][0][8],
                  aip_mem_ecc::xor_bits(8'h88, 8), "BASE u00 group0 parity")
        `CHECK_EQ(cpu_ram[0].u01_ram.mem[0][0], 72'd0,
                  "BASE write leaves u01 zero")

        cpu.write64(BASE + 8, 64'hFFEE_DDCC_BBAA_0099);
        `CHECK_EQ(cpu_ram[0].u01_ram.mem[0][0][7:0], 8'h99,
                  "BASE+8 u01 group0 data")
        `CHECK_EQ(cpu_ram[0].u01_ram.mem[0][0][8],
                  aip_mem_ecc::xor_bits(8'h99, 8), "BASE+8 u01 group0 parity")

        cpu.read64(BASE, data, ok);
        `CHECK_EQ(data, 64'h1122_3344_5566_7788, "BASE read64")
        `CHECK_TRUE(ok, "BASE read64 parity ok")
        cpu.read64(BASE + 8, data, ok);
        `CHECK_EQ(data, 64'hFFEE_DDCC_BBAA_0099, "BASE+8 read64")
        `CHECK_TRUE(ok, "BASE+8 read64 parity ok")
    endtask

    task automatic test_contiguous_groups_and_ecc();
        bit [71:0] expected;
        bit [71:0] saved;
        bit [7:0] data;
        bit ok;
        $display("\n=========== RAM72 contiguous groups / ECC ===========");

        cpu.write64(BASE + 'h80, 64'd0);
        cpu.write64(BASE + 'h88, 64'd0);
        cpu.write8(BASE + 'h82, 8'hA5);

        expected = '0;
        expected[18 +: 8] = 8'hA5;
        expected[26] = aip_mem_ecc::xor_bits(8'hA5, 8);
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[2][0], expected,
                  "BASE+82 changes only contiguous u00 group2")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[2][0][18 +: 8], 8'hA5,
                  "BASE+82 group2 data")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[2][0][26],
                  aip_mem_ecc::xor_bits(8'hA5, 8), "BASE+82 group2 parity")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[2][0][7:0], 8'h00,
                  "BASE+82 leaves group0 data zero")

        saved = cpu_ram[0].u00_ram.mem[2][0];
        cpu_ram[0].u00_ram.mem[2][0][18] = ~saved[18];
        cpu.read8(BASE + 'h82, data, ok);
        // Detection-only parity returns the corrupted stored byte and bad status.
        `CHECK_EQ(data, 8'hA4, "parity data-bit fault returns corrupted stored byte")
        `CHECK_TRUE(!ok, "parity data-bit fault sets status_ok low")
        cpu_ram[0].u00_ram.mem[2][0] = saved;
    endtask

    task automatic test_mapping_and_boundaries();
        bit [63:0] data;
        bit ok;
        $display("\n=========== RAM72 mapping / boundaries ===========");

        // The real RTL is bank-major: the second logical 16-byte line in
        // one block is mem[0][1], not mem[1][0].
        cpu.write8(BASE + 'h10, 8'h5A);
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][1][7:0], 8'h5A,
                  "line1 maps to bank1 at depth0")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[1][0], 72'd0,
                  "line1 does not advance depth before bank")

        cpu.write64(BASE + 'h0ff0, 64'h1122_3344_5566_77A1);
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[63][3],
                  pack_word64(64'h1122_3344_5566_77A1),
                  "BASE+0ff0 maps to u00[63][3]")
        cpu.read64(BASE + 'h0ff0, data, ok);
        `CHECK_EQ(data, 64'h1122_3344_5566_77A1, "BASE+0ff0 read64")
        `CHECK_TRUE(ok, "BASE+0ff0 parity ok")

        cpu.write64(BASE + 'h1008, 64'h2233_4455_6677_88B2);
        `CHECK_EQ(cpu_ram[0].u01_ram.mem[64][0],
                  pack_word64(64'h2233_4455_6677_88B2),
                  "BASE+1008 maps to u01[64][0]")
        cpu.read64(BASE + 'h1008, data, ok);
        `CHECK_EQ(data, 64'h2233_4455_6677_88B2, "BASE+1008 read64")
        `CHECK_TRUE(ok, "BASE+1008 parity ok")

        cpu.write64(BASE + 'h2000, 64'h3344_5566_7788_99C3);
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[128][0],
                  pack_word64(64'h3344_5566_7788_99C3),
                  "BASE+2000 maps to u00[128][0]")
        cpu.read64(BASE + 'h2000, data, ok);
        `CHECK_EQ(data, 64'h3344_5566_7788_99C3, "BASE+2000 read64")
        `CHECK_TRUE(ok, "BASE+2000 parity ok")

        cpu.write64(BASE + 'h3008, 64'h4455_6677_8899_AAD4);
        `CHECK_EQ(cpu_ram[0].u01_ram.mem[192][0],
                  pack_word64(64'h4455_6677_8899_AAD4),
                  "BASE+3008 maps to u01[192][0]")
        cpu.read64(BASE + 'h3008, data, ok);
        `CHECK_EQ(data, 64'h4455_6677_8899_AAD4, "BASE+3008 read64")
        `CHECK_TRUE(ok, "BASE+3008 parity ok")

        check_cross64(BASE + 'h47,   64'hA1A2_A3A4_A5A6_A7A8,
                      "crosses u00/u01 boundary");
        check_cross64(BASE + 'h0ffc, 64'hB1B2_B3B4_B5B6_B7B8,
                      "crosses bank boundary");
        check_cross64(BASE + 'h3ffc, 64'hC1C2_C3C4_C5C6_C7C8,
                      "crosses block boundary");
    endtask

    task automatic test_offset_paths();
        aip_cpu_mem        cpu_offset;
        aip_cpu_ram_region ram72_offset;
        bit [7:0] data;
        bit ok;
        $display("\n=========== RAM72 block index offset ===========");

        cpu_offset = new();
        ram72_offset = cpu_offset.add_ram72_fmt(
            .name("dram72_offset"), .base(OFF_BASE),
            .u00_path_fmt("tb.cpu_ram_offset[%0d].u00_ram.mem"),
            .u01_path_fmt("tb.cpu_ram_offset[%0d].u01_ram.mem"),
            .num_blocks(3), .blk_id_offset(5));

        `CHECK_TRUE(ram72_offset.get_path(0, 0) ==
                    "tb.cpu_ram_offset[5].u00_ram.mem",
                    "offset path logical 0 resolves to index 5")
        `CHECK_TRUE(ram72_offset.get_path(2, 1) ==
                    "tb.cpu_ram_offset[7].u01_ram.mem",
                    "offset path logical 2 resolves to index 7")

        cpu_offset.write8(OFF_BASE + 'h4008, 8'h5A);
        `CHECK_EQ(cpu_ram_offset[6].u01_ram.mem[0][0][7:0], 8'h5A,
                  "offset write lands in physical block index 6")
        cpu_offset.read8(OFF_BASE + 'h4008, data, ok);
        `CHECK_EQ(data, 8'h5A, "offset read8")
        `CHECK_TRUE(ok, "offset read8 parity ok")
    endtask

    task automatic test_hdl_read_failure();
        aip_cpu_mem          cpu_bad;
        aip_cpu_ram72_region ram_bad;
        bit [7:0] data;
        bit ok;
        int errors_before_write;
        int warnings_before_write;
        $display("\n=========== RAM72 HDL read failure ===========");

        cpu_bad = new();
        ram_bad = cpu_bad.add_ram72_fmt(
            .name("dram72_bad"), .base(BAD_BASE),
            .u00_path_fmt("tb.missing_ram[%0d].u00_ram.mem"),
            .u01_path_fmt("tb.missing_ram[%0d].u01_ram.mem"),
            .num_blocks(1));

        cpu_bad.read8(BAD_BASE, data, ok);
        `CHECK_EQ(data, 8'h00, "bad HDL read8 returns zero data")
        `CHECK_TRUE(!ok, "bad HDL read8 sets status_ok low")

        errors_before_write   = aip_log::get_count(aip_log::ERROR);
        warnings_before_write = aip_log::get_count(aip_log::WARNING);
        cpu_bad.write8(BAD_BASE, 8'h5A);
        `CHECK_EQ(aip_log::get_count(aip_log::ERROR), errors_before_write + 1,
                  "bad HDL write8 reports its failed read")
        `CHECK_EQ(aip_log::get_count(aip_log::WARNING), warnings_before_write,
                  "bad HDL write8 skips deposit after failed read")
    endtask

    task automatic test_region_load_and_unified_loader();
        bit [31:0] data;
        bit ok;
        int fh;
        aip_cmd cmd;
        $display("\n=========== RAM72 region load / unified loader ===========");

        fh = $fopen("tmp_ram72.hex", "w");
        $fwrite(fh, "@80000040\n");
        $fwrite(fh, "ef be ad de\n");
        $fwrite(fh, "@80000048\n");
        $fwrite(fh, "78 56 34 12\n");
        $fclose(fh);

        ram_as_legacy = ram72;
        ram_as_legacy.load_hex("tmp_ram72.hex", 0);
        cpu.read32(BASE + 'h40, data, ok);
        `CHECK_EQ(data, 32'hDEAD_BEEF, "legacy load_hex @80000040")
        `CHECK_TRUE(ok, "legacy load_hex parity ok")

        ram_as_legacy.zero_range('h40, 'h43);
        cpu.read32(BASE + 'h40, data, ok);
        `CHECK_EQ(data, 32'h0000_0000, "facade zero_range")
        `CHECK_TRUE(ok, "facade zero_range parity ok")

        fh = $fopen("tmp_unified_ram.hex", "w");
        $fwrite(fh, "ef be ad de\n");
        $fclose(fh);
        loader = new(cpu);
        loader.load_image("tmp_unified_ram.hex", BASE + 'h48, "hex");
        cpu.read32(BASE + 'h48, data, ok);
        `CHECK_EQ(data, 32'hDEAD_BEEF, "unified load_image RAM address")
        `CHECK_TRUE(ok, "unified load_image RAM parity ok")

        // Tcl registration and direct SV facade use the same three arguments;
        // exercise the 64-bit start parser through the registered command.
        fh = $fopen("tmp_unified_cmd.hex", "w");
        $fwrite(fh, "78 56 34 12\n");
        $fclose(fh);
        aip_cpu_loader_default::set(loader);
        cmd = aip_cmd::get_handle("load_image");
        cmd.args_in = "file=tmp_unified_cmd.hex start=0x80000058 format=hex";
        cmd.cmd_exec();
        cpu.read32(BASE + 'h58, data, ok);
        `CHECK_EQ(data, 32'h1234_5678, "Tcl/SV unified load_image start")
        `CHECK_EQ(cmd.status, 0, "Tcl/SV unified load_image status")
    endtask

    task automatic test_packed40_loader();
        bit [31:0] data;
        bit ok;
        int fh;
        aip_cmd cmd;
        longint unsigned rom_entries;
        $display("\n=========== packed40 ROM-then-RAM loader ===========");

        rom_entries = rom_packed40.size / 4;
        fh = $fopen("tmp_packed40.hex", "w");
        $fwrite(fh, " \t@00000000 %010h\n", packed40_word(8'h12, 8'h34, 8'h56, 8'h78));
        $fwrite(fh, "@00000001 %010h\n", packed40_word(8'ha1, 8'hb2, 8'hc3, 8'hd4));
        $fwrite(fh, "@%08h %010h\n", rom_entries,
                packed40_word(8'h9a, 8'hbc, 8'hde, 8'hf0));
        $fwrite(fh, "@%08h %010h\n", rom_entries + 1,
                packed40_word(8'h11, 8'h22, 8'h33, 8'h44));
        $fwrite(fh, "@%08h %010h\n", rom_entries + 4,
                packed40_word(8'h01, 8'h23, 8'h45, 8'h67));
        $fclose(fh);

        // Earlier tests intentionally exercised these physical words.  Clear
        // them so the packed40 partial-word deposits are checked without
        // depending on pre-existing low groups.
        cpu_ram[0].u00_ram.mem[0][0] = 72'd0;
        cpu_ram[0].u00_ram.mem[0][1] = 72'd0;
        loader.load_image("tmp_packed40.hex", 0, "packed40");

        // Two packed40 entries fill one 64-bit ROM word.
        `CHECK_EQ(packed40_rom0.mem_core_array[0], 64'hd4c3_b2a1_7856_3412,
                  "packed40 ROM two-entry 64-bit word")

        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][0],
                  pack_word64(64'h4433_2211_f0de_bc9a),
                  "packed40 RAM two-entry 72-bit word")
        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][0][8],
                  aip_mem_ecc::xor_bits(8'h9a, 8),
                  "packed40 RAM first group parity")

        `CHECK_EQ(cpu_ram[0].u00_ram.mem[0][1],
                  pack_word64(64'h0000_0000_6745_2301),
                  "packed40 sparse RAM first four groups")

        aip_cpu_loader_default::set(loader);
        cmd = aip_cmd::get_handle("load_image");
        `CHECK_TRUE(cmd != null, "load_image is registered")
    endtask

    task automatic test_zero_region();
        bit [63:0] data;
        bit ok;
        uvm_hdl_data_t word;
        int nonzero;
        $display("\n=========== RAM72 zero_region ===========");

        cpu.zero_region("dram72");
        nonzero = 0;
        for (int block = 0; block < 4; block++)
            for (int depth = 0; depth < 256; depth++)
                for (int bank = 0; bank < 4; bank++) begin
                    if (!uvm_hdl_read($sformatf("tb.cpu_ram[%0d].u00_ram.mem[%0d][%0d]",
                                                block, depth, bank), word) ||
                        word[71:0] !== 72'd0)
                        nonzero++;
                    if (!uvm_hdl_read($sformatf("tb.cpu_ram[%0d].u01_ram.mem[%0d][%0d]",
                                                block, depth, bank), word) ||
                        word[71:0] !== 72'd0)
                        nonzero++;
                end
        `CHECK_EQ(nonzero, 0, "zero_region clears every physical RAM72 word")
        cpu.read64(BASE, data, ok);
        `CHECK_EQ(data, 64'd0, "zero_region BASE read64")
        `CHECK_TRUE(ok, "zero_region BASE parity ok")
    endtask

    initial begin
        $display("\n############# test_cpu_mem72 start #############");
        #1;

        cpu = new();
        rom_packed40 = cpu.add_rom("rom_packed40", 64'h0,
                                   "tb.packed40_rom0.mem_core_array",
                                   "tb.packed40_rom1.mem_core_array");
        ram72 = cpu.add_ram72_fmt(
          .name("dram72"), .base(BASE),
          .u00_path_fmt("tb.cpu_ram[%0d].u00_ram.mem"),
          .u01_path_fmt("tb.cpu_ram[%0d].u01_ram.mem"), .num_blocks(4));

        test_basic_u00_u01();
        test_contiguous_groups_and_ecc();
        test_mapping_and_boundaries();
        test_offset_paths();
        test_hdl_read_failure();
        test_region_load_and_unified_loader();
        test_packed40_loader();
        test_zero_region();

        $display("\n##############################################");
        $display("# Test Summary: pass=%0d fail=%0d", pass_count, fail_count);
        $display("##############################################\n");

        if (fail_count == 0) begin
            $display("[OVERALL] PASS");
        end else begin
            $display("[OVERALL] FAIL (%0d failures)", fail_count);
            $fatal(1, "RAM72 regression failures");
        end
        $finish;
    end

endmodule
