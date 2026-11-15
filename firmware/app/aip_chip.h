#ifndef AIP_CHIP_H
#define AIP_CHIP_H

/* Unified 0x80000000-based layout (ROM + RAM + MBOX all in 0x800x_xxxx). */
#define ROM_BASE          0x80000000UL        /* CPU reset PC */
#define ROM_SIZE          (32 * 1024)         /* 0x80000000-0x80007FFF */
#define RAM_BASE          0x80008000UL
#define RAM_SIZE          (864 * 1024)        /* 0x80008000-0x800DFFFF */
#define MBOX_BASE         0x800E0000UL        /* 0x800E0000-0x800E0FFF (4 KB) */
#define MBOX_SIZE         (4 * 1024)
/* 0x800E1000-0x800FFFFF reserved (124 KB) */

#define IRQ_NUM_MAILBOX   48        /* mailbox 中断接 PLIC source 48 */
#define PLIC_BASE         0x08000000UL        /* pad_cpu_apb_base (手册第10章) */
#define CLINT_BASE        0x0C000000UL        /* = PLIC_BASE + 0x4000000 */
#define MSIP0_ADDR        (CLINT_BASE)        /* 核0 M-mode 软件中断, MSIPn=+4*n */

#endif
