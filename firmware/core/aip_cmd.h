#ifndef AIP_CMD_H
#define AIP_CMD_H

#include <stdarg.h>

// C-side command framework for the CPU bridge: cmd_init(mailbox) -> cmd_register(name, handler) -> cmd_loop();
// handlers parse args with cmd_get_*() and reply with cmd_return().

#define AIP_CMD_NAME_MAX   32
/* One 32-bit word per character.  128 words keep rsp_flag at +0x208 exactly
 * as the SV side (aip_cpu_bridge.sv OFF_* / CMD_DATA_MAX) expects. */
#define AIP_CMD_DATA_MAX   128
#define AIP_CMD_MAX        64

// Boot-ready handshake: after init the CPU writes MBOX_BOOT_READY_MAGIC here; SV `cpu_wait` polls it via backdoor.
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

typedef void (*cmd_handler_t)(const char *args);

typedef struct {
    char name[AIP_CMD_NAME_MAX];
    cmd_handler_t handler;
} cmd_entry_t;

void cmd_init(volatile void *mailbox_base);

void cmd_register(const char *name, cmd_handler_t handler);

// "key=value" lookup in args; returns def if the key is absent.
int cmd_get_int(const char *args, const char *key, int def);

// 64-bit variant for addresses and large values.
unsigned long long cmd_get_long(const char *args, const char *key, unsigned long long def);

// String variant; returns def if the key is absent.
const char *cmd_get_str(const char *args, const char *key, const char *def);

// Sync-mode response; snprintf-style subset (%x %08x %d %s).
void cmd_return(const char *fmt, ...);

// Blocking main loop (WFI between polls).
void cmd_loop(void);

// Non-blocking single poll.
void cmd_poll_once(void);

// Call from your ISR when the mailbox interrupt fires.
void cmd_irq_handler(void);

// Call after cmd_init(), before cmd_loop().
void cmd_register_builtins(void);

// Ask SV to stop the simulation (code 0 = normal, else error); cmd_loop() then returns.
void cmd_exit(int code);

// MSIP wake mode init (enable MSIE+MIE). Handler = Mtspend_Handler in aip_cmd_msip.c.
void cmd_msip_init(void);

#endif // AIP_CMD_H
