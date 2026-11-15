// Negative regression: the unified image API must stop the simulation when a
// second image touches an address committed by an earlier image.
`include "aip_core_pkg.sv"
`include "aip_cpu_mem.sv"
`include "fake_mem.sv"

module tb;
    fake_rom_ram rom0 ();
    fake_rom_ram rom1 ();

    initial begin
        aip_cpu_mem cpu;
        aip_cpu_loader loader;
        int fd;

        cpu = new();
        void'(cpu.add_rom("rom", 64'h0,
                          "tb.rom0.mem_core_array",
                          "tb.rom1.mem_core_array"));
        loader = new(cpu);
        fd = $fopen("tmp_overlap.hex", "w");
        $fwrite(fd, "01 02 03 04\n");
        $fclose(fd);

        loader.load_image("tmp_overlap.hex", 64'h0, "hex");
        loader.load_image("tmp_overlap.hex", 64'h0, "hex");

        // Reaching this point means the fatal overlap guard is broken.
        $fatal(1, "EXPECTED_LOAD_IMAGE_OVERLAP_FATAL_MISSING");
    end
endmodule
