#ifndef AIP_CMD_C908_H
#define AIP_CMD_C908_H

// C908 interrupt setup reference: PLIC_BASE and IRQ_NUM_MAILBOX must be defined (e.g. in aip_chip.h)
// before including aip_cmd_c908.c; alternatively call cmd_irq_handler() from an existing ISR.

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

// PLIC + global interrupts for the mailbox; mtvec is set by startup.
void cmd_irq_init(void);

#endif // AIP_CMD_C908_H
