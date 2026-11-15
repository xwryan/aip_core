/* MSIP wake: machine software interrupt (mcause=3) handler + init for C908.
 * SV backdoor deposits CLINT MSIP0; CPU wakes from wfi; this handler clears
 * MSIP synchronously (prevent storm) then flags pending for cmd_loop. */
#include "aip_cmd.h"
#include "aip_chip.h"

#define MIE_MSIE      (1UL << 3)   /* mie.MSIE: machine software interrupt enable */
#define MSTATUS_MIE   (1UL << 3)   /* mstatus.MIE: global machine interrupt enable */

void cmd_msip_init(void) {
    /* 不动 mtvec — XuanTie startup 已设向量模式 (mtvec=__Vectors|1) */
    asm volatile ("csrs mie, %0"     :: "r"((unsigned long)MIE_MSIE));
    asm volatile ("csrs mstatus, %0" :: "r"((unsigned long)MSTATUS_MIE));
}

/* __Vectors slot 3 = 机器软件中断. interrupt 属性: GCC 生成现场保存/恢复+mret. */
__attribute__((interrupt("machine")))
void Mtspend_Handler(void) {
    *(volatile unsigned int *)MSIP0_ADDR = 0;   /* 同步清 MSIP, 防中断风暴 */
    cmd_irq_handler();                          /* 置 g_irq_pending */
}
