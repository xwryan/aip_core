/* ram_jump: ROM reset stub at 0x80000000 — jumps to RAM-resident Reset_Handler.
 * Loaded via the same combined hex (its own @0x80000000 segment); the RAM
 * payload (everything else) is pre-deposited by the SV backdoor loader. */
    .section .boot_stub, "ax", @progbits
    .globl __boot_stub
    .type  __boot_stub, %function
__boot_stub:
    j   Reset_Handler
    .size __boot_stub, . - __boot_stub
