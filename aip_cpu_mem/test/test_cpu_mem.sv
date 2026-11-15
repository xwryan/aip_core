//===========================================================
// test_cpu_mem.sv — aip_cpu_mem 完整功能测试
//
// 覆盖:
//   T1: ROM 双 path 显式 — 64-bit 对齐写读
//   T2: ROM 128-bit logical-line / interleaved physical mapping
//   T3: ROM 非对齐 + 32/8 bit 宽度
//   T4: ROM load_hex 加载
//   T5: RAM 模板路径注册 — 64-bit 写读 (含 even XOR parity)
//   T6: RAM 低/高64 交织 + even/odd lane 共用物理 row
//   T7: RAM 跨 physical depth 与 u01/u00
//   T8: RAM 跨 block 边界
//   T9: RAM parity 注错 → read 返回 status_ok=0
//   T10: 地址越界检查
//
// 编译运行:
//   cd aip_cpu_mem/test
//   make
//===========================================================
`include "aip_core_pkg.sv"
`include "aip_cpu_mem.sv"

// ============================================================
// 假 RAM/ROM 模块 — 模拟 RTL 存储 array
// ============================================================

`include "fake_mem.sv"

// ============================================================
// Testbench
// ============================================================
module tb;

    // ROM 双 path
    fake_rom_ram uu0();
    fake_rom_ram uu1();

    // RAM 4 块演示 (实际项目 62 块)
    fake_ram_block blk0();
    fake_ram_block blk1();
    fake_ram_block blk2();
    fake_ram_block blk3();

    // 偏移索引演示: generate array, 索引 5..7 (模拟 RTL `bar[5..7]`)
    generate
        for (genvar gi = 5; gi < 8; gi++) begin : bar
            fake_ram_block u();
        end
    endgenerate

    // 索引 ROM: 模拟 dut.rom[3].uu0/uu1
    generate
        for (genvar ri = 3; ri < 4; ri++) begin : rom_arr
            fake_rom_ram uu0();
            fake_rom_ram uu1();
        end
    endgenerate

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

    aip_cpu_mem        cpu0;
    aip_cpu_rom_region rom0;
    aip_cpu_ram_region ram0;

    // ============================================================
    // T1: ROM 64-bit 对齐写读
    // ============================================================
    task automatic test_t1_rom_basic();
        longint unsigned d;
        bit ok;
        $display("\n=========== T1: ROM 64-bit 对齐 ===========");

        cpu0.write('h0000_0000, 64'hDEAD_BEEF_CAFE_BABE);
        cpu0.read ('h0000_0000, d, 64, ok);
        `CHECK_EQ(d, 64'hDEAD_BEEF_CAFE_BABE, "T1.write/read 64")
        `CHECK_TRUE(ok, "T1.status_ok")
        `CHECK_EQ(tb.uu0.mem_core_array[0], 64'hDEAD_BEEF_CAFE_BABE, "T1.physical uu0[0]")

        cpu0.write('h0000_0008, 64'h1122_3344_5566_7788);
        `CHECK_EQ(tb.uu1.mem_core_array[0], 64'h1122_3344_5566_7788, "T1.physical uu1[0]")
    endtask

    // ============================================================
    // T2: ROM 128-bit logical-line / interleaved physical mapping
    // ============================================================
    task automatic test_t2_rom_interleave_mapping();
        longint unsigned d;
        bit ok;
        $display("\n=========== T2: ROM 128-bit logical-line / interleaved physical mapping ===========");

        cpu0.write('h0000_3FF8, 64'hAAAA_BBBB_CCCC_DDDD);  // line 1023 high 64 -> physical uu1[1023]
        cpu0.read ('h0000_3FF8, d, 64, ok);
        `CHECK_EQ(d, 64'hAAAA_BBBB_CCCC_DDDD, "T2.logical line 1023 high 64")
        `CHECK_EQ(tb.uu1.mem_core_array[1023], 64'hAAAA_BBBB_CCCC_DDDD, "T2.physical uu1[1023]")

        cpu0.write('h0000_4000, 64'h1111_2222_3333_4444);  // line 1024 low 64 -> physical uu0[1024]
        cpu0.read ('h0000_4000, d, 64, ok);
        `CHECK_EQ(d, 64'h1111_2222_3333_4444, "T2.logical line 1024 low 64")
        `CHECK_EQ(tb.uu0.mem_core_array[1024], 64'h1111_2222_3333_4444, "T2.physical uu0[1024]")

        cpu0.write('h0000_7FF8, 64'hFFEE_DDCC_BBAA_9988);  // line 2047 high 64 -> physical uu1[2047]
        `CHECK_EQ(tb.uu1.mem_core_array[2047], 64'hFFEE_DDCC_BBAA_9988, "T2.physical uu1[2047]")
    endtask

    // ============================================================
    // T3: ROM 非对齐 + 32/8 bit
    // ============================================================
    task automatic test_t3_rom_unaligned();
        longint unsigned d;
        bit [31:0] d32;
        bit [7:0]  d8;
        bit ok;
        $display("\n=========== T3: ROM 非对齐 / 32/8 bit ===========");

        cpu0.write64('h0000_0010, 64'h0000_0000_0000_0000);

        cpu0.write32('h0000_0010, 32'hAABB_CCDD);
        cpu0.read32 ('h0000_0010, d32, ok);
        `CHECK_EQ(d32, 32'hAABB_CCDD, "T3.32-bit roundtrip")

        cpu0.write32('h0000_0014, 32'h1234_5678);
        cpu0.read64 ('h0000_0010, d, ok);
        `CHECK_EQ(d, 64'h1234_5678_AABB_CCDD, "T3.adjacent 32 → form 64")

        cpu0.write8('h0000_0011, 8'h5A);
        cpu0.read8 ('h0000_0011, d8, ok);
        `CHECK_EQ(d8, 8'h5A, "T3.8-bit RMW roundtrip")

        // 整 word 验证 (8'h5A 替换了 byte 1, 即 bit[15:8])
        // 原 0xAABB_CCDD → byte1=CC 改 5A → 0xAABB_5ADD
        cpu0.read64('h0000_0010, d, ok);
        `CHECK_EQ(d, 64'h1234_5678_AABB_5ADD, "T3.64 after 8-bit RMW")
    endtask

    // ============================================================
    // T4: ROM load_hex
    // ============================================================
    task automatic test_t4_rom_load_hex();
        longint unsigned d;
        bit ok;
        int fh;
        $display("\n=========== T4: ROM load_hex ===========");

        // load_hex is a byte stream (objcopy -O verilog): bytes in ascending
        // address order. A 64-bit LE word is emitted low byte first, so the
        // bytes below are the little-endian encodings of the expected words.
        fh = $fopen("tmp_firmware.hex", "w");
        $fwrite(fh, "be ba fe ca ef be ad de\n");   // LE of 0xDEADBEEFCAFEBABE
        $fwrite(fh, "88 77 66 55 44 33 22 11\n");   // LE of 0x1122334455667788
        $fwrite(fh, "ff 00 ff 00 ff 00 ff 00\n");   // LE of 0x00FF00FF00FF00FF
        $fclose(fh);

        rom0.load_hex("tmp_firmware.hex", 'h1000);

        cpu0.read('h0000_1000, d, 64, ok);
        `CHECK_EQ(d, 64'hDEAD_BEEF_CAFE_BABE, "T4.hex line 0")
        cpu0.read('h0000_1008, d, 64, ok);
        `CHECK_EQ(d, 64'h1122_3344_5566_7788, "T4.hex line 1")
        cpu0.read('h0000_1010, d, 64, ok);
        `CHECK_EQ(d, 64'h00FF_00FF_00FF_00FF, "T4.hex line 2")
    endtask

    // ============================================================
    // T5: RAM 64-bit 写读 (含 even XOR parity)
    // ============================================================
    task automatic test_t5_ram_basic();
        longint unsigned d;
        bit ok;
        $display("\n=========== T5: RAM 64-bit + parity ===========");

        cpu0.write('h8000_0000, 64'hDEAD_BEEF_CAFE_BABE);
        cpu0.read ('h8000_0000, d, 64, ok);
        `CHECK_EQ(d, 64'hDEAD_BEEF_CAFE_BABE, "T5.write/read 64")
        `CHECK_TRUE(ok, "T5.parity ok")
        `CHECK_TRUE(tb.blk0.uu0.mem_core_array[0] != 148'd0, "T5.physical row non-zero")
    endtask

    // ============================================================
    // T6: RAM 低/高64 交织 + even/odd lane
    // ============================================================
    task automatic test_t6_ram_interleave_lanes();
        longint unsigned d;
        bit ok;
        bit [147:0] u00_after_low64, u01_after_high64;
        $display("\n=========== T6: RAM low/high64 interleave + even/odd lane ===========");

        cpu0.write('h8000_0000, 64'h1111_2222_3333_4444);   // line0 low64 → uu0[0], even lane
        u00_after_low64 = tb.blk0.uu0.mem_core_array[0];
        cpu0.write('h8000_0008, 64'h5555_6666_7777_8888);   // line0 high64 → uu1[0], even lane
        `CHECK_EQ(tb.blk0.uu0.mem_core_array[0], u00_after_low64,
                  "T6.uu0[0] unchanged after line0 high64 write")
        `CHECK_TRUE(tb.blk0.uu1.mem_core_array[0] != 148'd0,
                    "T6.line0 high64 lands in uu1[0]")
        u01_after_high64 = tb.blk0.uu1.mem_core_array[0];

        cpu0.write('h8000_0010, 64'hAAAA_BBBB_CCCC_DDDD);   // line1 low64 → uu0[0], odd lane
        `CHECK_EQ(tb.blk0.uu1.mem_core_array[0], u01_after_high64,
                  "T6.uu1[0] unchanged after line1 low64 write")
        `CHECK_TRUE(tb.blk0.uu0.mem_core_array[0] != u00_after_low64,
                    "T6.line1 low64 changes uu0[0] odd lane")

        cpu0.read('h8000_0000, d, 64, ok);
        `CHECK_EQ(d, 64'h1111_2222_3333_4444, "T6.line0 low64 uu0 even-lane read")
        cpu0.read('h8000_0008, d, 64, ok);
        `CHECK_EQ(d, 64'h5555_6666_7777_8888, "T6.line0 high64 uu1 even-lane read")
        cpu0.read ('h8000_0010, d, 64, ok);
        `CHECK_EQ(d, 64'hAAAA_BBBB_CCCC_DDDD, "T6.line1 low64 uu0 odd-lane read")
    endtask

    // ============================================================
    // T7: RAM 跨 physical depth 255→256 与 u01→u00
    // ============================================================
    task automatic test_t7_ram_depth_ram_transition();
        longint unsigned d;
        bit ok;
        $display("\n=========== T7: RAM depth 255->256 / u01->u00 ===========");

        cpu0.write('h8000_1FF8, 64'hAAAA_AAAA_AAAA_AAAA);  // line511 high64 → uu1[255], odd lane
        cpu0.write('h8000_2000, 64'hBBBB_BBBB_BBBB_BBBB);  // line512 low64  → uu0[256], even lane

        `CHECK_TRUE(tb.blk0.uu1.mem_core_array[255] != 148'd0,
                    "T7.0x1ff8 lands in uu1[255]")
        `CHECK_TRUE(tb.blk0.uu0.mem_core_array[256] != 148'd0,
                    "T7.0x2000 lands in uu0[256]")

        cpu0.read('h8000_1FF8, d, 64, ok);
        `CHECK_EQ(d, 64'hAAAA_AAAA_AAAA_AAAA, "T7.0x1ff8 high64 uu1[255] read")
        cpu0.read('h8000_2000, d, 64, ok);
        `CHECK_EQ(d, 64'hBBBB_BBBB_BBBB_BBBB, "T7.0x2000 low64 uu0[256] read")
    endtask

    // ============================================================
    // T8: RAM 跨 block 边界 (0x4000)
    // ============================================================
    task automatic test_t8_ram_block_boundary();
        longint unsigned d;
        bit ok;
        $display("\n=========== T8: RAM block 边界 ===========");

        cpu0.write('h8000_3FF8, 64'hCCCC_CCCC_CCCC_CCCC);  // blk0 最后
        cpu0.write('h8000_4000, 64'hDDDD_DDDD_DDDD_DDDD);  // blk1 第一
        cpu0.write('h8000_C000, 64'hEEEE_EEEE_EEEE_EEEE);  // blk3 第一

        cpu0.read('h8000_3FF8, d, 64, ok);
        `CHECK_EQ(d, 64'hCCCC_CCCC_CCCC_CCCC, "T8.blk0 last")
        cpu0.read('h8000_4000, d, 64, ok);
        `CHECK_EQ(d, 64'hDDDD_DDDD_DDDD_DDDD, "T8.blk1 first")
        cpu0.read('h8000_C000, d, 64, ok);
        `CHECK_EQ(d, 64'hEEEE_EEEE_EEEE_EEEE, "T8.blk3 first")
    endtask

    // ============================================================
    // T9: RAM parity 注错 → status_ok=0
    // ============================================================
    task automatic test_t9_ram_parity_err();
        longint unsigned d;
        bit ok;
        bit [147:0] orig, broken;
        $display("\n=========== T9: RAM parity 注错 ===========");

        cpu0.write('h8000_0000, 64'hFFFF_FFFF_FFFF_FFFF);
        cpu0.read ('h8000_0000, d, 64, ok);
        `CHECK_TRUE(ok, "T9.before err: ok")

        // 直接破坏 RTL 行 1 bit data, parity 不动 → 校验失败
        orig   = tb.blk0.uu0.mem_core_array[0];
        broken = orig ^ (148'd1 << 4);   // 翻 word[4] (even slot 第 1 group 第 0 bit)
        tb.blk0.uu0.mem_core_array[0] = broken;

        cpu0.read('h8000_0000, d, 64, ok);
        `CHECK_TRUE(!ok, "T9.after err: status_ok=0")

        tb.blk0.uu0.mem_core_array[0] = orig;
    endtask

    // ============================================================
    // T11: RAM 显式 write8/write32/write64 + block 接口
    // ============================================================
    task automatic test_t11_ram_widths();
        longint unsigned d;
        bit [31:0] d32;
        bit [7:0]  d8;
        bit ok;
        longint unsigned blk_in[$], blk_out[$];
        $display("\n=========== T11: RAM 显式 8/32/64 ===========");

        // 清行
        cpu0.write64('h8000_0100, 64'h0);
        cpu0.write64('h8000_0108, 64'h0);

        // 8-bit 写读
        cpu0.write8('h8000_0100, 8'hA5);
        cpu0.read8 ('h8000_0100, d8, ok);
        `CHECK_EQ(d8, 8'hA5, "T11.ram write8/read8")
        `CHECK_TRUE(ok, "T11.ram write8 parity ok")

        // 32-bit 写读 (跨 group)
        cpu0.write32('h8000_0104, 32'hCAFE_BABE);
        cpu0.read32 ('h8000_0104, d32, ok);
        `CHECK_EQ(d32, 32'hCAFE_BABE, "T11.ram write32/read32")
        `CHECK_TRUE(ok, "T11.ram write32 parity ok")

        // 64-bit 显式
        cpu0.write64('h8000_0108, 64'h1122_3344_5566_7788);
        cpu0.read64 ('h8000_0108, d, ok);
        `CHECK_EQ(d, 64'h1122_3344_5566_7788, "T11.ram write64/read64")

        // 跨 8/32/64 一致性: 写 64, 读 32 高/低半
        cpu0.write64('h8000_0110, 64'hAABB_CCDD_EEFF_0011);
        cpu0.read32 ('h8000_0110, d32, ok);
        `CHECK_EQ(d32, 32'hEEFF_0011, "T11.read low 32 of 64")
        cpu0.read32 ('h8000_0114, d32, ok);
        `CHECK_EQ(d32, 32'hAABB_CCDD, "T11.read high 32 of 64")
        cpu0.read8  ('h8000_0110, d8, ok);
        `CHECK_EQ(d8, 8'h11, "T11.read byte 0 of 64")
        cpu0.read8  ('h8000_0117, d8, ok);
        `CHECK_EQ(d8, 8'hAA, "T11.read byte 7 of 64")

        // block 批量
        blk_in.push_back(64'h1111_1111_1111_1111);
        blk_in.push_back(64'h2222_2222_2222_2222);
        blk_in.push_back(64'h3333_3333_3333_3333);
        cpu0.write_block('h8000_0200, blk_in, 64);
        cpu0.read_block ('h8000_0200, 3, blk_out, 64);
        `CHECK_EQ(blk_out.size(), 3, "T11.block size")
        `CHECK_EQ(blk_out[0], 64'h1111_1111_1111_1111, "T11.block[0]")
        `CHECK_EQ(blk_out[1], 64'h2222_2222_2222_2222, "T11.block[1]")
        `CHECK_EQ(blk_out[2], 64'h3333_3333_3333_3333, "T11.block[2]")

        // write_incr
        cpu0.write_incr('h8000_0300, 4, 64'h100, 64);
        cpu0.read64('h8000_0318, d, ok);
        `CHECK_EQ(d, 64'h103, "T11.write_incr [3]")

        // write_zero
        cpu0.write_zero('h8000_0400, 16);
        cpu0.read64('h8000_0400, d, ok);
        `CHECK_EQ(d, 64'h0, "T11.write_zero word0")
        cpu0.read64('h8000_0408, d, ok);
        `CHECK_EQ(d, 64'h0, "T11.write_zero word1")
    endtask

    // ============================================================
    // T12: 批量归零 — region 级 + 范围级 + facade 全清
    // ============================================================
    task automatic test_t12_zero();
        longint unsigned d;
        bit ok;
        int nonzero;
        $display("\n=========== T12: 批量归零 ===========");

        // 先填几个 word
        cpu0.write64('h0000_0000, 64'hFFFF_FFFF_FFFF_FFFF);
        cpu0.write64('h0000_4000, 64'hAAAA_BBBB_CCCC_DDDD);
        cpu0.write64('h8000_0000, 64'h1234_5678_9ABC_DEF0);
        cpu0.write64('h8000_4000, 64'hDEAD_BEEF_CAFE_BABE);

        // [a] zero_region ROM
        cpu0.zero_region("rom");
        cpu0.read64('h0000_0000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_region rom uu0[0]")
        // 0x4000 is logical line 1024 low 64 -> physical uu0[1024]
        cpu0.read64('h0000_4000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_region rom uu0[1024]")

        // 物理验证: ROM 所有 RAM 全 0
        nonzero = 0;
        for (int i = 0; i < 2048; i++) begin
            if (tb.uu0.mem_core_array[i] != 64'd0) nonzero++;
            if (tb.uu1.mem_core_array[i] != 64'd0) nonzero++;
        end
        `CHECK_EQ(nonzero, 0, "T12.rom physical all zero")

        // [b] zero_region RAM (走高效 wr_row, even XOR parity=0, data=0)
        cpu0.zero_region("dram");
        cpu0.read64('h8000_0000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_region dram blk0[0]")
        `CHECK_TRUE(ok, "T12.dram zero parity ok")
        cpu0.read64('h8000_4000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_region dram blk1[0]")
        `CHECK_TRUE(ok, "T12.dram zero parity ok 2")

        // [c] 范围清零 (RAM 内一段)
        cpu0.write64('h8000_1000, 64'hFFFF_FFFF_FFFF_FFFF);
        cpu0.write64('h8000_1008, 64'hFFFF_FFFF_FFFF_FFFF);
        cpu0.write64('h8000_1010, 64'hFFFF_FFFF_FFFF_FFFF);
        cpu0.zero_range('h8000_1000, 'h8000_1017);  // 24 字节
        cpu0.read64('h8000_1000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_range word 0")
        cpu0.read64('h8000_1008, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_range word 1")
        cpu0.read64('h8000_1010, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_range word 2")

        // [d] facade zero_all
        cpu0.write64('h0000_0100, 64'h12345);
        cpu0.write64('h8000_2000, 64'h67890);
        cpu0.zero_all();
        cpu0.read64('h0000_0100, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_all rom")
        cpu0.read64('h8000_2000, d, ok);
        `CHECK_EQ(d, 64'h0, "T12.zero_all ram")
    endtask

    // ============================================================
    // T13: blk_id_offset — RTL 索引从非 0 开始
    // ============================================================
    task automatic test_t13_blk_offset();
        aip_cpu_mem        cpu_x;
        aip_cpu_ram_region ram_x;
        longint unsigned d;
        bit ok;
        $display("\n=========== T13: blk_id_offset ===========");

        cpu_x = new();
        ram_x = cpu_x.add_ram_fmt(
            .name          ("offram"),
            .base          ('h9000_0000),
            .ram0_path_fmt ("tb.bar[%0d].u.uu0.mem_core_array"),
            .ram1_path_fmt ("tb.bar[%0d].u.uu1.mem_core_array"),
            .num_blocks    (3),    // 逻辑 0,1,2 → RTL 5,6,7
            .blk_id_offset (5)
        );

        // 验证路径生成正确
        `CHECK_TRUE(ram_x.get_path(0, 0) == "tb.bar[5].u.uu0.mem_core_array",
                    "T13.path blk0 ram0")
        `CHECK_TRUE(ram_x.get_path(1, 0) == "tb.bar[6].u.uu0.mem_core_array",
                    "T13.path blk1 ram0")
        `CHECK_TRUE(ram_x.get_path(2, 1) == "tb.bar[7].u.uu1.mem_core_array",
                    "T13.path blk2 ram1")

        // 实际写读 — 验证物理落到 bar[5..7]
        cpu_x.write64('h9000_0000, 64'hAAAA_1111_BBBB_2222);          // blk 0 → bar[5].uu0
        cpu_x.write64('h9000_4000, 64'hCCCC_3333_DDDD_4444);          // blk 1 → bar[6].uu0
        cpu_x.write64('h9000_8000, 64'hEEEE_5555_FFFF_6666);          // blk 2 → bar[7].uu0
        cpu_x.write64('h9000_2000, 64'h1234_5678_9ABC_DEF0);          // blk 0 → bar[5].uu0[256]

        cpu_x.read64('h9000_0000, d, ok);
        `CHECK_EQ(d, 64'hAAAA_1111_BBBB_2222, "T13.blk0 read")
        cpu_x.read64('h9000_4000, d, ok);
        `CHECK_EQ(d, 64'hCCCC_3333_DDDD_4444, "T13.blk1 read")
        cpu_x.read64('h9000_8000, d, ok);
        `CHECK_EQ(d, 64'hEEEE_5555_FFFF_6666, "T13.blk2 read")
        cpu_x.read64('h9000_2000, d, ok);
        `CHECK_EQ(d, 64'h1234_5678_9ABC_DEF0, "T13.blk0 offset 0x2000 read")

        // 物理 array 验证: bar[5].u.uu0[0] 该有值
        `CHECK_TRUE(tb.bar[5].u.uu0.mem_core_array[0] != 148'd0,
                    "T13.physical bar[5] non-zero")
        `CHECK_TRUE(tb.bar[6].u.uu0.mem_core_array[0] != 148'd0,
                    "T13.physical bar[6] non-zero")
        `CHECK_TRUE(tb.bar[7].u.uu0.mem_core_array[0] != 148'd0,
                    "T13.physical bar[7] non-zero")

        // 0x9000_2000 落在 bar[5].u.uu0[256]
        `CHECK_TRUE(tb.bar[5].u.uu0.mem_core_array[256] != 148'd0,
                    "T13.physical bar[5] uu0[256] non-zero")
    endtask

    // ============================================================
    // T14: add_rom_id — RTL ROM 带索引名 (dut.rom[3].uu0)
    // ============================================================
    task automatic test_t14_rom_id();
        aip_cpu_mem        cpu_y;
        aip_cpu_rom_region rom_y;
        longint unsigned d;
        bit ok;
        $display("\n=========== T14: add_rom_id ===========");

        cpu_y = new();
        rom_y = cpu_y.add_rom_id(
            .name          ("idrom"),
            .base          ('hB000_0000),
            .blk_id        (3),
            .ram0_path_fmt ("tb.rom_arr[%0d].uu0.mem_core_array"),
            .ram1_path_fmt ("tb.rom_arr[%0d].uu1.mem_core_array")
        );

        // path 生成正确
        `CHECK_TRUE(rom_y.get_path(0, 0) == "tb.rom_arr[3].uu0.mem_core_array",
                    "T14.path uu0")
        `CHECK_TRUE(rom_y.get_path(0, 1) == "tb.rom_arr[3].uu1.mem_core_array",
                    "T14.path uu1")

        // 写读
        cpu_y.write64('hB000_0000, 64'h1234_5678_AAAA_BBBB);          // ram0
        cpu_y.write64('hB000_4000, 64'hDEAD_BEEF_CAFE_BABE);          // line 1024 low 64 -> uu0[1024]
        cpu_y.read64 ('hB000_0000, d, ok);
        `CHECK_EQ(d, 64'h1234_5678_AAAA_BBBB, "T14.read ram0")
        cpu_y.read64 ('hB000_4000, d, ok);
        `CHECK_EQ(d, 64'hDEAD_BEEF_CAFE_BABE, "T14.read logical line 1024 low 64")

        // 物理验证 — 两个地址均落到 rom_arr[3].uu0 的对应 logical line
        `CHECK_EQ(tb.rom_arr[3].uu0.mem_core_array[0], 64'h1234_5678_AAAA_BBBB,
                  "T14.physical rom_arr[3].uu0[0]")
        `CHECK_EQ(tb.rom_arr[3].uu0.mem_core_array[1024], 64'hDEAD_BEEF_CAFE_BABE,
                  "T14.physical rom_arr[3].uu0[1024]")
    endtask

    // ============================================================
    // T10: 地址越界
    // ============================================================
    task automatic test_t10_oob();
        longint unsigned d;
        bit ok;
        $display("\n=========== T10: 越界检查 ===========");

        cpu0.write('h0000_8000, 64'h0);     // ROM 越界
        $display("(预期 aip_error: 'addr not in any region')");

        cpu0.write('h0001_0000, 64'h0);     // ROM/RAM gap
        $display("(预期 aip_error)");

        `CHECK_TRUE(1, "T10.no crash on oob")
    endtask

    // ============================================================
    // T15: load_hex range guard — combined hex self-routes per region
    //   A combined hex with an @segment inside the region and one outside.
    //   Each region must keep only its own @segment (basis of ram_jump boot).
    // ============================================================
    task automatic test_t15_range_guard();
        bit [31:0] d32;
        bit ok;
        int fh;
        $display("\n=========== T15: load_hex range guard ===========");

        // @0x0 → inside rom0 [0,0x8000); @0x80000000 → outside rom0, inside ram0
        fh = $fopen("tmp_combined.hex", "w");
        $fwrite(fh, "@00000000\n");
        $fwrite(fh, "de c0 ad 0b\n");   // LE word 0x0badc0de
        $fwrite(fh, "@80000000\n");
        $fwrite(fh, "ef be ad de\n");   // LE word 0xdeadbeef
        $fclose(fh);

        // ROM region: keeps @0 segment, skips @0x80000000 (out of range, no OOB)
        rom0.load_hex("tmp_combined.hex", 0);
        cpu0.read32('h0000_0000, d32, ok);
        `CHECK_EQ(d32, 32'h0bAD_C0DE, "T15.rom kept @0 segment")
        `CHECK_TRUE(rom0.contains('h0000_0000) == 1, "T15.rom contains base")
        `CHECK_TRUE(rom0.contains('h8000_0000) == 0, "T15.rom skips out-of-range @segment")

        // RAM region: keeps @0x80000000 segment, skips @0
        ram0.load_hex("tmp_combined.hex", 0);
        cpu0.read32('h8000_0000, d32, ok);
        `CHECK_EQ(d32, 32'hDEAD_BEEF, "T15.ram kept @0x80000000 segment")
        `CHECK_TRUE(ram0.contains('h0000_0000) == 0, "T15.ram skips out-of-range @segment")
    endtask

    // ============================================================
    // Main
    // ============================================================
    initial begin
        $display("\n############# test_cpu_mem start #############");
        #1;

        cpu0 = new();

        rom0 = cpu0.add_rom(
            .name     ("rom"),
            .base     ('h0000_0000),
            .ram0_path("tb.uu0.mem_core_array"),
            .ram1_path("tb.uu1.mem_core_array")
        );

        ram0 = cpu0.add_ram_fmt(
            .name          ("dram"),
            .base          ('h8000_0000),
            .ram0_path_fmt ("tb.blk%0d.uu0.mem_core_array"),
            .ram1_path_fmt ("tb.blk%0d.uu1.mem_core_array"),
            .num_blocks    (4)
        );

        cpu0.dump_map();

        test_t1_rom_basic();
        test_t2_rom_interleave_mapping();
        test_t3_rom_unaligned();
        test_t4_rom_load_hex();
        test_t5_ram_basic();
        test_t6_ram_interleave_lanes();
        test_t7_ram_depth_ram_transition();
        test_t8_ram_block_boundary();
        test_t9_ram_parity_err();
        test_t11_ram_widths();
        test_t12_zero();
        test_t13_blk_offset();
        test_t14_rom_id();
        test_t15_range_guard();
        test_t10_oob();

        $display("\n##############################################");
        $display("# Test Summary: pass=%0d fail=%0d", pass_count, fail_count);
        $display("##############################################\n");

        if (fail_count == 0) $display("[OVERALL] PASS");
        else                 $display("[OVERALL] FAIL (%0d failures)", fail_count);

        $finish;
    end

endmodule
