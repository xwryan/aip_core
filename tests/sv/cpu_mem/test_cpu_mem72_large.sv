`include "aip_core_pkg.sv"
`include "aip_cpu_mem.sv"
`include "aip_cpu_loader.sv"
`include "fake_mem.sv"

// Large contiguous packed40 image regression: fills the whole 2048-row ROM, then ten RAM72 depths
// across all four banks and both u00/u01 arrays.  The image is generated at runtime.
module tb_large;
    localparam longint unsigned RAM_BASE      = 64'h8000_0000;
    localparam int              ROM_BYTES     = 32'h8000;
    localparam int              ROM_ENTRIES   = ROM_BYTES / 4;
    localparam int              RAM_DEPTHS    = 10;
    localparam int              RAM_BYTES     = RAM_DEPTHS * 4 * 2 * 8;
    localparam int              RAM_ENTRIES   = RAM_BYTES / 4;
    localparam int              TOTAL_ENTRIES = ROM_ENTRIES + RAM_ENTRIES;

    fake_rom_ram  rom0 ();
    fake_rom_ram  rom1 ();
    fake_ram72_block ram [0:0] ();

    aip_cpu_mem    cpu;
    aip_cpu_loader loader;
    int pass_count;
    int fail_count;

    function automatic bit [7:0] image_byte(input longint unsigned byte_addr);
        // Fold several address bytes so byte-order, bank/depth shifts and address-boundary
        // errors cannot hide behind a 256-byte repeating pattern.
        return byte_addr[7:0] ^ byte_addr[15:8] ^ byte_addr[23:16] ^
               byte_addr[31:24] ^ byte_addr[39:32] ^ 8'hA5;
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

    function automatic bit [63:0] expected_rom_word(input longint unsigned byte_addr);
        bit [63:0] w;
        w = '0;
        for (int i = 0; i < 8; i++)
            w[i*8 +: 8] = image_byte(byte_addr + i);
        return w;
    endfunction

    function automatic bit [71:0] expected_ram72_word(input longint unsigned byte_addr);
        bit [71:0] w;
        bit [7:0] b;
        w = '0;
        for (int i = 0; i < 8; i++) begin
            b = image_byte(byte_addr + i);
            w[i*9 +: 8] = b;
            w[i*9 + 8]  = aip_mem_ecc::xor_bits(b, 8);
        end
        return w;
    endfunction

    task automatic check_word(input bit condition, input string message);
        if (condition) begin
            pass_count++;
        end else begin
            fail_count++;
            if (fail_count <= 12)
                $display("[FAIL] %s", message);
        end
    endtask

    task automatic generate_image(input string filename);
        int fh;
        bit [39:0] source_word;
        fh = $fopen(filename, "w");
        if (fh == 0) $fatal(1, "cannot create %s", filename);
        for (int e = 0; e < TOTAL_ENTRIES; e++) begin
            source_word = packed40_word(
                image_byte(e*4 + 0), image_byte(e*4 + 1),
                image_byte(e*4 + 2), image_byte(e*4 + 3));
            $fwrite(fh, "@%08h %010h\n", e, source_word);
        end
        $fclose(fh);
        $display("[INFO] generated %0d packed40 entries (%0d bytes)",
                 TOTAL_ENTRIES, TOTAL_ENTRIES * 4);
    endtask

    task automatic verify_image();
        uvm_hdl_data_t actual;
        bit [63:0] expected64;
        bit [71:0] expected72;
        longint unsigned addr;
        string path;

        // Verify every ROM physical row in both 64-bit arrays.
        for (int row = 0; row < 2048; row++) begin
            addr = row * 16;
            expected64 = expected_rom_word(addr);
            path = $sformatf("tb_large.rom0.mem_core_array[%0d]", row);
            check_word(uvm_hdl_read(path, actual) && actual[63:0] === expected64,
                       $sformatf("ROM uu0 row=%0d path=%s got=0x%0h want=0x%0h",
                                 row, path, actual[63:0], expected64));
            expected64 = expected_rom_word(addr + 8);
            path = $sformatf("tb_large.rom1.mem_core_array[%0d]", row);
            check_word(uvm_hdl_read(path, actual) && actual[63:0] === expected64,
                       $sformatf("ROM uu1 row=%0d path=%s got=0x%0h want=0x%0h",
                                 row, path, actual[63:0], expected64));
        end

        // Verify all 10 depths x 4 banks x 2 arrays in RAM72.  The first
        // RAM byte follows the complete 32-KB ROM image.
        for (int depth = 0; depth < RAM_DEPTHS; depth++) begin
            for (int bank = 0; bank < 4; bank++) begin
                addr = ROM_BYTES + ((depth * 4 + bank) * 16);
                expected72 = expected_ram72_word(addr);
                path = $sformatf("tb_large.ram[0].u00_ram.mem[%0d][%0d]", depth, bank);
                check_word(uvm_hdl_read(path, actual) && actual[71:0] === expected72,
                           $sformatf("RAM u00 depth=%0d bank=%0d path=%s got=0x%0h want=0x%0h",
                                     depth, bank, path, actual[71:0], expected72));
                expected72 = expected_ram72_word(addr + 8);
                path = $sformatf("tb_large.ram[0].u01_ram.mem[%0d][%0d]", depth, bank);
                check_word(uvm_hdl_read(path, actual) && actual[71:0] === expected72,
                           $sformatf("RAM u01 depth=%0d bank=%0d path=%s got=0x%0h want=0x%0h",
                                     depth, bank, path, actual[71:0], expected72));
            end
        end
    endtask

    initial begin
        string image_file;
        image_file = "tmp_packed40_large.hex";
        pass_count = 0;
        fail_count = 0;
        #1;

        cpu = new();
        void'(cpu.add_rom("rom", 64'h0,
                          "tb_large.rom0.mem_core_array",
                          "tb_large.rom1.mem_core_array"));
        void'(cpu.add_ram72_fmt(
            .name("dram72"), .base(RAM_BASE),
            .u00_path_fmt("tb_large.ram[%0d].u00_ram.mem"),
            .u01_path_fmt("tb_large.ram[%0d].u01_ram.mem"),
            .num_blocks(1)));
        loader = new(cpu);

        generate_image(image_file);
        loader.load_image(image_file, 0, "packed40");
        if (loader.image_error)
            $fatal(1, "large packed40 load_image failed");
        verify_image();

        $display("[SUMMARY] pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1, "large packed40 mapping regression failed");
        $display("[OVERALL] LARGE_PACKED40_PASS");
        $finish;
    end
endmodule
