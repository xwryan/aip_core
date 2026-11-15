//===========================================================
// fake_mem.sv — synthetic memory modules for aip_cpu_mem tests
// Shared between test_cpu_mem.sv and test_cpu_mem72.sv
//===========================================================
`ifndef FAKE_MEM_SV
`define FAKE_MEM_SV

// ROM uu0/uu1: 2048 × 64-bit
module fake_rom_ram;
    reg [63:0] mem_core_array [0:2047];
    initial for (int i = 0; i < 2048; i++) mem_core_array[i] = 64'd0;
endmodule

// RAM uu0/uu1: 512 × 148-bit
module fake_ram_uu;
    reg [147:0] mem_core_array [0:511];
    initial for (int i = 0; i < 512; i++) mem_core_array[i] = 148'd0;
endmodule

module fake_ram_block;
    fake_ram_uu uu0();
    fake_ram_uu uu1();
endmodule

module fake_ram72_uu;
    reg [71:0] mem [255:0][3:0];
    initial begin
        for (int depth = 0; depth < 256; depth++)
            for (int bank = 0; bank < 4; bank++)
                mem[depth][bank] = 72'd0;
    end
endmodule

module fake_ram72_block;
    fake_ram72_uu u00_ram();
    fake_ram72_uu u01_ram();
endmodule

`endif // FAKE_MEM_SV
