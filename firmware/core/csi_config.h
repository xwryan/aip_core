#ifndef CSI_CONFIG_H
#define CSI_CONFIG_H
#define CONFIG_NR_CPUS              1
#define CONFIG_KERNEL_NONE          1
#define CONFIG_ARCH_INTERRUPTSTACK  4096
#define CONFIG_ARCH_MAINSTACK       8192
/* DO NOT define __NO_SYSTEM_INIT — SystemInit() must run to enable FP unit
 * (rv64gc 编译有 fp 指令, mstatus.FS 默认 0 → trap) + theadisaee XuanTie ext. */
#endif
