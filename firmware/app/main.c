#include "aip_cmd.h"
#include "aip_chip.h"

#ifdef AIP_USE_IRQ
#include "aip_cmd_c908.h"
#endif

extern void user_register(void);

int main(void) {
    cmd_init((volatile void *)MBOX_BASE);
    cmd_register_builtins();
    user_register();
#ifdef AIP_USE_IRQ
    cmd_irq_init();
#endif
#ifdef AIP_USE_MSIP
    cmd_msip_init();
#endif

    // Signal boot-ready to host (TCL `cpu_wait` polls this addr via backdoor)
    *(volatile unsigned int *)(MBOX_BASE + MBOX_BOOT_READY_OFF) = MBOX_BOOT_READY_MAGIC;

    cmd_loop();
    return 0;
}
