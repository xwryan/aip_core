#ifndef AIP_CMD_C908_H
#define AIP_CMD_C908_H

// ============================================================
// aip_cmd_c908.h — C908 RISC-V interrupt setup reference
//
// PLIC_BASE and IRQ_NUM_MAILBOX must be defined by the
// including project (e.g. aip_chip.h) before including
// aip_cmd_c908.c.
//
// Usage:
//   #include "aip_cmd_c908.h"
//   cmd_irq_init();
//
// Or hook into existing ISR:
//   #include "aip_cmd.h"
//   cmd_irq_handler();  // call from your ISR
// ============================================================

#define read_csr(reg) ({ \
    unsigned long __v; \
    __asm__ volatile("csrr %0, " #reg : "=r"(__v)); \
    __v; \
})

#define write_csr(reg, val) ({ \
    __asm__ volatile("csrw " #reg ", %0" :: "r"((unsigned long)(val))); \
})

#define set_csr(reg, val) ({ \
    __asm__ volatile("csrs " #reg ", %0" :: "r"((unsigned long)(val))); \
})

#define clear_csr(reg, val) ({ \
    __asm__ volatile("csrc " #reg ", %0" :: "r"((unsigned long)(val))); \
})

#define MSTATUS_MIE     (1UL << 3)
#define MIE_MEIE        (1UL << 11)

// Initialize PLIC + global interrupts for mailbox (mtvec set by startup)
void cmd_irq_init(void);

#endif // AIP_CMD_C908_H
