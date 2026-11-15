/* Minimal CSI runtime + interrupt stubs for aip_core firmware on C907/C908 (replaces XuanTie chip_riscv_dummy).
 * SystemInit derives from the XuanTie SDK c908/system.c, keeping only the CSR setup needed to avoid traps. */

extern int main(void);

void Default_Handler(void)  { while (1) {} }
__attribute__((weak)) void Stspend_Handler(void) { Default_Handler(); }
__attribute__((weak)) void Mtspend_Handler(void) { Default_Handler(); }
__attribute__((weak)) void Scoret_Handler(void)  { Default_Handler(); }
__attribute__((weak)) void Mcoret_Handler(void)  { Default_Handler(); }
__attribute__((weak)) void Sirq_Handler(void)    { Default_Handler(); }
__attribute__((weak)) void Mirq_Handler(void)    { Default_Handler(); }
__attribute__((weak)) void ECC_L1_Handler(void)  { Default_Handler(); }

/* 必做 CSR 配置（与 XuanTie SDK / gdbinit 序列对齐，参考玄铁手册 p19 与 system.c::SystemInit），否则：
 * mstatus.FS=0 时 FP 指令 trap；theadisaee=0 时 XuanTie 扩展指令 trap；
 * mhcr cache=0 且 PMA 强制 cacheable 时访问未定义；复位后不 invalidate cache 可能取到垃圾。 */
__attribute__((weak)) void SystemInit(void) {
    unsigned long status;

    /* 1. mcor = 0x70013: invalidate I/D cache + BTB + BHT (复位时强制清, 不依赖硬件 auto-invalidate) */
    asm volatile ("csrw 0x7c2, %0" :: "r"((unsigned long)0x70013UL));

    /* 2. mxstatus = 0x638001: 启 theadisaee (bit 22, XuanTie ISA ext) + MAEE (bit 21, XMAE 页表扩展)
     *                       + MM (bit 15, 允许 misalign) + 其他 mode bits */
    asm volatile ("csrr %0, 0x7c0" : "=r"(status));
    status |= 0x638001UL;
    asm volatile ("csrw 0x7c0, %0" :: "r"(status));

    /* 3. mhcr = 0x10011bf: 启 L1 I/D cache (bit 0,1) + WA/WB (bit 2,3) + RS/BPE/BTB (bit 4,5,6) + IBPE 等 */
    asm volatile ("csrr %0, 0x7c1" : "=r"(status));
    status |= 0x10011bfUL;
    asm volatile ("csrw 0x7c1, %0" :: "r"(status));

    /* 4. mhint = 0x3a1aa10c: 性能 hints (data prefetch, branch fold, speculation control 等) */
    asm volatile ("csrw 0x7c5, %0" :: "r"((unsigned long)0x3a1aa10cUL));

    /* 5. mstatus.FS = 01 (initial) — 启 FP unit. rv64gc 编译有 fp 指令, FS=00 必 trap */
    asm volatile ("csrr %0, mstatus" : "=r"(status));
    status |= (1UL << 13);                            /* FS[14:13] = 01 */
#ifdef __riscv_vector
    status |= (1UL << 9);                             /* VS[10:9]  = 01 (vector ISA enable) */
#endif
    asm volatile ("csrw mstatus, %0" :: "r"(status));

    asm volatile ("fence.i");   /* 同步 icache invalidate */
}

/* BSS clearing: 标准 CSI 命名 (linker xiaohui.ld 用 __sbss / __ebss) */
extern int __sbss[], __ebss[];

__attribute__((weak)) void pre_main(void) {
    int *p;
    for (p = __sbss; p < __ebss; p++) *p = 0;
    (void)main();
    while (1) {}
}
