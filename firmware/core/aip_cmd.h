#ifndef AIP_CMD_H
#define AIP_CMD_H

#include <stdarg.h>

// ============================================================
// aip_cmd.h — C-side command framework for CPU bridge
//
// Usage:
//   cmd_init((volatile void *)0xF0000000);
//   cmd_register("read_reg", do_read_reg);
//   cmd_loop();
//
// In handler:
//   void do_read_reg(const char *args) {
//       int addr = cmd_get_int(args, "addr", 0);
//       int data = *(volatile int *)addr;
//       cmd_return("data=0x%x", data);
//   }
// ============================================================

#define AIP_CMD_NAME_MAX   32
/* One 32-bit word per character.  128 words keep rsp_flag at +0x208 exactly
 * as the SV side (aip_cpu_bridge.sv OFF_* / CMD_DATA_MAX) expects. */
#define AIP_CMD_DATA_MAX   128
#define AIP_CMD_MAX        64

// Boot-ready handshake (CPU -> TCL/SV)
// CPU writes MBOX_BOOT_READY_MAGIC to MBOX_BASE + MBOX_BOOT_READY_OFF after init.
// SV-side `cpu_wait` (TCL) polls this addr via backdoor (no mbox protocol needed).
#define MBOX_BOOT_READY_OFF   0x0800u
#define MBOX_BOOT_READY_MAGIC 0xDEADBEEFu

// Mailbox memory layout (matches SV aip_cpu_bridge offsets)
typedef struct {
    volatile unsigned int cmd_flag;                        // +0x000
    volatile unsigned int cmd_len;                         // +0x004
    volatile unsigned int cmd_data[AIP_CMD_DATA_MAX];      // +0x008
    volatile unsigned int rsp_flag;                        // +0x208
    volatile unsigned int rsp_status;                      // +0x20C
    volatile unsigned int rsp_len;                         // +0x210
    volatile unsigned int rsp_data[AIP_CMD_DATA_MAX];      // +0x214
    volatile unsigned int async_flag;                      // +0x414
    volatile unsigned int exit_flag;                       // +0x418  1=SV请求退出 2=C请求退出
    volatile unsigned int exit_code;                       // +0x41C  0=正常 非0=异常
    volatile unsigned int irq_ack_flag;                    // +0x420  1=ISR entered, SV monitor drops IRQ
} aip_mailbox_t;

// Command handler function type
typedef void (*cmd_handler_t)(const char *args);

// Command table entry
typedef struct {
    char name[AIP_CMD_NAME_MAX];
    cmd_handler_t handler;
} cmd_entry_t;

// Initialize mailbox pointer
void cmd_init(volatile void *mailbox_base);

// Register a command handler
void cmd_register(const char *name, cmd_handler_t handler);

// Parse integer argument: "key=value" from args string, returns def if not found
int cmd_get_int(const char *args, const char *key, int def);

// Parse 64-bit integer argument (for addresses and large values)
unsigned long long cmd_get_long(const char *args, const char *key, unsigned long long def);

// Parse string argument: "key=value" from args string, returns def if not found
const char *cmd_get_str(const char *args, const char *key, const char *def);

// Write response back to mailbox (sync mode), snprintf-style format
void cmd_return(const char *fmt, ...);

// Blocking main loop: poll cmd_flag, dispatch, repeat (uses WFI between polls)
void cmd_loop(void);

// Single poll: check cmd_flag once, dispatch if pending
void cmd_poll_once(void);

// IRQ handler — call from your ISR when mailbox interrupt fires
void cmd_irq_handler(void);

// Register built-in commands
// Call after cmd_init(), before cmd_loop()
void cmd_register_builtins(void);

// Request exit — C notifies SV to stop simulation
// code=0: normal exit, code!=0: error exit
// After calling, cmd_loop() will return
void cmd_exit(int code);

// MSIP wake mode init (enable MSIE+MIE). Handler = Mtspend_Handler in aip_cmd_msip.c.
void cmd_msip_init(void);

#endif // AIP_CMD_H
