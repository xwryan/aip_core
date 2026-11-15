#include "aip_cmd_c908.h"
#include "aip_cmd.h"
#include "aip_chip.h"

// PLIC register access (hart-parameterized for future multi-core).
static inline void plic_set_priority(unsigned int src, unsigned int prio) {
    *(volatile unsigned int *)(PLIC_BASE + src * 4) = prio;
}
static inline void plic_enable(unsigned int hart, unsigned int src) {
    volatile unsigned int *r =
        (volatile unsigned int *)(PLIC_BASE + 0x2000 + 0x100 * hart + (src / 32) * 4);
    *r |= (1U << (src % 32));
}
static inline void plic_set_threshold(unsigned int hart, unsigned int th) {
    *(volatile unsigned int *)(PLIC_BASE + 0x200000 + 0x2000 * hart) = th;
}
static inline unsigned int plic_claim(unsigned int hart) {
    return *(volatile unsigned int *)(PLIC_BASE + 0x200004 + 0x2000 * hart);
}
static inline void plic_complete(unsigned int hart, unsigned int src) {
    *(volatile unsigned int *)(PLIC_BASE + 0x200004 + 0x2000 * hart) = src;
}
static inline unsigned long current_hart(void) {
    unsigned long h;
    asm volatile ("csrr %0, mhartid" : "=r"(h));
    return h;
}

// Machine external interrupt (__Vectors slot 11, mcause=11): XuanTie vectored mtvec jumps here and the
// interrupt attribute saves context + mret. SV deposits PLIC_IP pending; claim clears it, complete = EOI.
__attribute__((interrupt("machine")))
void Mirq_Handler(void) {
    unsigned long hart = current_hart();
    unsigned int id = plic_claim(hart);
    if (id == IRQ_NUM_MAILBOX) cmd_irq_handler();
    plic_complete(hart, id);
}

// Does not touch mtvec: XuanTie startup owns it (vectored mode).
void cmd_irq_init(void) {
    unsigned long hart = current_hart();
    plic_set_priority(IRQ_NUM_MAILBOX, 1);   /* priority must be > 0 */
    plic_enable(hart, IRQ_NUM_MAILBOX);
    plic_set_threshold(hart, 0);             /* 0 = allow all */
    asm volatile ("csrs mie, %0"     :: "r"((unsigned long)MIE_MEIE));    /* MEIE bit11 */
    asm volatile ("csrs mstatus, %0" :: "r"((unsigned long)MSTATUS_MIE)); /* MIE  bit3  */
}
