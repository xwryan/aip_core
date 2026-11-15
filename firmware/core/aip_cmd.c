#include "aip_cmd.h"

// ============================================================
// Internal state
// ============================================================

static aip_mailbox_t *g_mailbox = 0;
static cmd_entry_t    g_cmds[AIP_CMD_MAX];
static int            g_cmd_count = 0;
static volatile int   g_irq_pending = 0;

static char g_cmd_buf[AIP_CMD_DATA_MAX + 1];
static char g_rsp_buf[AIP_CMD_DATA_MAX + 1];
static char g_val_buf[AIP_CMD_DATA_MAX + 1];

// ============================================================
// WFI — wait for interrupt (RISC-V)
// In IRQ builds (AIP_USE_IRQ defined), real wfi halts the CPU until
// any interrupt. In poll-mode builds, downgrade to nop so cmd_loop
// busy-polls cmd_flag without halting (no IRQ source to wake wfi).
// ============================================================
static inline void wfi(void) {
#if defined(__riscv) && (defined(AIP_USE_IRQ) || defined(AIP_USE_MSIP))
    __asm__ volatile("wfi");
#else
    __asm__ volatile("nop");
#endif
}

// ============================================================
// Public API
// ============================================================

void cmd_init(volatile void *mailbox_base) {
    g_mailbox = (aip_mailbox_t *)mailbox_base;
    g_cmd_count = 0;
}

void cmd_register(const char *name, cmd_handler_t handler) {
    int i;
    if (g_cmd_count >= AIP_CMD_MAX) return;
    for (i = 0; i < AIP_CMD_NAME_MAX - 1 && name[i] != '\0'; i++) {
        g_cmds[g_cmd_count].name[i] = name[i];
    }
    g_cmds[g_cmd_count].name[i] = '\0';
    g_cmds[g_cmd_count].handler = handler;
    g_cmd_count++;
}

// ============================================================
// Argument parsing
// ============================================================

static int parse_int(const char *s) {
    int val = 0;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
        while (*s) {
            char c = *s++;
            if (c >= '0' && c <= '9')      val = (val << 4) | (c - '0');
            else if (c >= 'a' && c <= 'f') val = (val << 4) | (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') val = (val << 4) | (c - 'A' + 10);
            else break;
        }
    } else {
        while (*s >= '0' && *s <= '9') {
            val = val * 10 + (*s++ - '0');
        }
    }
    return neg ? -val : val;
}

static const char *find_key_value(const char *args, const char *key) {
    int klen = 0;
    const char *p;
    while (key[klen]) klen++;
    p = args;
    while (*p) {
        if (p != args && *(p - 1) != ' ' && *(p - 1) != '\t') {
            p++;
            continue;
        }
        int match = 1;
        int i;
        for (i = 0; i < klen; i++) {
            if (p[i] != key[i]) { match = 0; break; }
        }
        if (match && p[klen] == '=') {
            return p + klen + 1;
        }
        p++;
    }
    return 0;
}

static unsigned long long parse_long(const char *s) {
    unsigned long long val = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
        while (*s) {
            char c = *s++;
            if (c >= '0' && c <= '9')      val = (val << 4) | (c - '0');
            else if (c >= 'a' && c <= 'f') val = (val << 4) | (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') val = (val << 4) | (c - 'A' + 10);
            else break;
        }
    } else {
        while (*s >= '0' && *s <= '9') {
            val = val * 10 + (*s++ - '0');
        }
    }
    return val;
}

int cmd_get_int(const char *args, const char *key, int def) {
    const char *val;
    if (!args || !key) return def;
    val = find_key_value(args, key);
    if (!val) return def;
    return parse_int(val);
}

unsigned long long cmd_get_long(const char *args, const char *key, unsigned long long def) {
    const char *val;
    if (!args || !key) return def;
    val = find_key_value(args, key);
    if (!val) return def;
    return parse_long(val);
}

const char *cmd_get_str(const char *args, const char *key, const char *def) {
    const char *val;
    int i;
    if (!args || !key) return def;
    val = find_key_value(args, key);
    if (!val) return def;
    for (i = 0; i < AIP_CMD_DATA_MAX && val[i] && val[i] != ' ' && val[i] != '\t'; i++) {
        g_val_buf[i] = val[i];
    }
    g_val_buf[i] = '\0';
    return g_val_buf;
}

// ============================================================
// Response
// ============================================================

// Write a plain string response to mailbox
static void cmd_return_raw(const char *s, int len) {
    int i;
    if (!g_mailbox) return;
    if (len > AIP_CMD_DATA_MAX) len = AIP_CMD_DATA_MAX;
    for (i = 0; i < len; i++) {
        g_mailbox->rsp_data[i] = (unsigned int)(unsigned char)s[i];
    }
    g_mailbox->rsp_len = (unsigned int)len;
    g_mailbox->rsp_status = 0;
    g_mailbox->rsp_flag = 1;
}

// Minimal hex formatter (no libc)
static int fmt_hex(char *buf, unsigned int val, int width) {
    static const char hex[] = "0123456789abcdef";
    int i, len = 0;
    char tmp[16];
    if (val == 0) { tmp[len++] = '0'; }
    else { while (val) { tmp[len++] = hex[val & 0xF]; val >>= 4; } }
    while (len < width) tmp[len++] = '0';
    for (i = 0; i < len; i++) buf[i] = tmp[len - 1 - i];
    return len;
}

// Minimal decimal formatter (no libc)
static int fmt_int(char *buf, int val) {
    int i, len = 0, neg = 0;
    char tmp[16];
    unsigned int uv;
    if (val < 0) { neg = 1; uv = (unsigned int)(-val); } else { uv = (unsigned int)val; }
    if (uv == 0) { tmp[len++] = '0'; }
    else { while (uv) { tmp[len++] = '0' + (uv % 10); uv /= 10; } }
    if (neg) tmp[len++] = '-';
    for (i = 0; i < len; i++) buf[i] = tmp[len - 1 - i];
    return len;
}

// Simple formatted response: supports %x, %08x, %d, %s (no libc needed)
void cmd_return(const char *fmt, ...) {
    va_list ap;
    int pos = 0;
    const char *p = fmt;
    if (!g_mailbox) return;
    va_start(ap, fmt);
    while (*p && pos < AIP_CMD_DATA_MAX - 1) {
        if (*p == '%') {
            p++;
            int width = 0;
            if (*p == '0') { p++; }
            while (*p >= '0' && *p <= '9') { width = width * 10 + (*p - '0'); p++; }
            if (*p == 'x' || *p == 'X') {
                unsigned int v = va_arg(ap, unsigned int);
                pos += fmt_hex(g_rsp_buf + pos, v, width ? width : 1);
                p++;
            } else if (*p == 'd') {
                int v = va_arg(ap, int);
                pos += fmt_int(g_rsp_buf + pos, v);
                p++;
            } else if (*p == 's') {
                const char *s = va_arg(ap, const char *);
                while (*s && pos < AIP_CMD_DATA_MAX - 1) g_rsp_buf[pos++] = *s++;
                p++;
            } else {
                g_rsp_buf[pos++] = '%';
                if (*p) g_rsp_buf[pos++] = *p++;
            }
        } else {
            g_rsp_buf[pos++] = *p++;
        }
    }
    va_end(ap);
    g_rsp_buf[pos] = '\0';
    cmd_return_raw(g_rsp_buf, pos);
}

// ============================================================
// IRQ
// ============================================================

void cmd_irq_handler(void) {
    g_irq_pending = 1;
    if (g_mailbox) g_mailbox->irq_ack_flag = 1;
}

// ============================================================
// Dispatch
// ============================================================

static cmd_handler_t find_handler(const char *name) {
    int i;
    for (i = 0; i < g_cmd_count; i++) {
        const char *a = g_cmds[i].name;
        const char *b = name;
        while (*a && *b && *a == *b) { a++; b++; }
        if (*a == '\0' && *b == '\0') return g_cmds[i].handler;
    }
    return 0;
}

static void dispatch_cmd(void) {
    int len, i;
    char name[AIP_CMD_NAME_MAX];
    const char *args;
    cmd_handler_t handler;

    if (!g_mailbox) return;

    len = (int)g_mailbox->cmd_len;
    if (len > AIP_CMD_DATA_MAX) len = AIP_CMD_DATA_MAX;
    for (i = 0; i < len; i++) {
        g_cmd_buf[i] = (char)(g_mailbox->cmd_data[i] & 0xFF);
    }
    g_cmd_buf[len] = '\0';

    args = g_cmd_buf;
    for (i = 0; i < AIP_CMD_NAME_MAX - 1 && *args && *args != ' '; i++) {
        name[i] = *args++;
    }
    name[i] = '\0';
    while (*args == ' ') args++;

    handler = find_handler(name);
    if (handler) {
        handler(args);
    } else {
        g_mailbox->rsp_status = (unsigned int)(-1);
        g_mailbox->rsp_len = 0;
        g_mailbox->rsp_flag = 1;
    }

    g_mailbox->cmd_flag = 0;
}

// ============================================================
// Main loops
// ============================================================

void cmd_poll_once(void) {
    if (!g_mailbox) return;
    if (g_mailbox->cmd_flag == 1) {
        g_irq_pending = 0;
        dispatch_cmd();
    }
}

void cmd_loop(void) {
    while (1) {
        // Check exit request from SV (exit_flag == 1)
        if (g_mailbox->exit_flag == 1) {
            g_mailbox->exit_flag = 0;  // ACK
            return;
        }
        while (g_mailbox->cmd_flag != 1) {
            // Re-check exit during WFI wait
            if (g_mailbox->exit_flag == 1) {
                g_mailbox->exit_flag = 0;
                return;
            }
            wfi();
        }
        g_irq_pending = 0;
        dispatch_cmd();
    }
}

void cmd_exit(int code) {
    if (!g_mailbox) return;
    g_mailbox->exit_code = (unsigned int)code;
    g_mailbox->exit_flag = 2;  // 2 = C requests SV to exit
}

// ============================================================
// Built-in commands: cpu_read32, cpu_write32, cpu_read64, cpu_write64
// ============================================================

static void builtin_cpu_read32(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned int data = *(volatile unsigned int *)(unsigned long)addr;
    cmd_return("data=0x%08x", data);
}

static void builtin_cpu_write32(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned int data = (unsigned int)cmd_get_long(args, "data", 0);
    *(volatile unsigned int *)(unsigned long)addr = data;
    cmd_return("ok addr=0x%08x data=0x%08x", (unsigned int)addr, data);
}

static void builtin_cpu_read64(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned long long data = *(volatile unsigned long long *)(unsigned long)addr;
    unsigned int hi = (unsigned int)(data >> 32);
    unsigned int lo = (unsigned int)(data & 0xFFFFFFFF);
    cmd_return("data=0x%08x%08x", hi, lo);
}

static void builtin_cpu_write64(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned long long data = cmd_get_long(args, "data", 0);
    *(volatile unsigned long long *)(unsigned long)addr = data;
    unsigned int hi = (unsigned int)(data >> 32);
    unsigned int lo = (unsigned int)(data & 0xFFFFFFFF);
    cmd_return("ok addr=0x%08x data=0x%08x%08x", (unsigned int)addr, hi, lo);
}

// ============================================================
// Byte swap helpers
// ============================================================

static unsigned int swap32(unsigned int v) {
    return ((v & 0xFF000000) >> 24) |
           ((v & 0x00FF0000) >>  8) |
           ((v & 0x0000FF00) <<  8) |
           ((v & 0x000000FF) << 24);
}

static unsigned long long swap64(unsigned long long v) {
    return ((v & 0xFF00000000000000ULL) >> 56) |
           ((v & 0x00FF000000000000ULL) >> 40) |
           ((v & 0x0000FF0000000000ULL) >> 24) |
           ((v & 0x000000FF00000000ULL) >>  8) |
           ((v & 0x00000000FF000000ULL) <<  8) |
           ((v & 0x0000000000FF0000ULL) << 24) |
           ((v & 0x000000000000FF00ULL) << 40) |
           ((v & 0x00000000000000FFULL) << 56);
}

// ============================================================
// Swap commands: cpu_read32_swap, cpu_write32_swap, cpu_read64_swap, cpu_write64_swap
// ============================================================

static void builtin_cpu_read32_swap(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned int data = *(volatile unsigned int *)(unsigned long)addr;
    unsigned int swapped = swap32(data);
    cmd_return("data=0x%08x", swapped);
}

static void builtin_cpu_write32_swap(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned int data = (unsigned int)cmd_get_long(args, "data", 0);
    unsigned int swapped = swap32(data);
    *(volatile unsigned int *)(unsigned long)addr = swapped;
    cmd_return("ok addr=0x%08x data=0x%08x swapped=0x%08x", (unsigned int)addr, data, swapped);
}

static void builtin_cpu_read64_swap(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned long long data = *(volatile unsigned long long *)(unsigned long)addr;
    unsigned long long swapped = swap64(data);
    unsigned int hi = (unsigned int)(swapped >> 32);
    unsigned int lo = (unsigned int)(swapped & 0xFFFFFFFF);
    cmd_return("data=0x%08x%08x", hi, lo);
}

static void builtin_cpu_write64_swap(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned long long data = cmd_get_long(args, "data", 0);
    unsigned long long swapped = swap64(data);
    *(volatile unsigned long long *)(unsigned long)addr = swapped;
    unsigned int hi = (unsigned int)(swapped >> 32);
    unsigned int lo = (unsigned int)(swapped & 0xFFFFFFFF);
    cmd_return("ok addr=0x%08x swapped=0x%08x%08x", (unsigned int)addr, hi, lo);
}

// ============================================================
// Poll: cpu_poll32 — poll addr until (data & mask) == expect, with timeout
// Usage: cpu_poll32 addr=0x100 mask=0x1 expect=0x1 timeout=1000
//        timeout unit: poll iterations (not cycles)
// ============================================================

static void builtin_cpu_poll32(const char *args) {
    unsigned long long addr = cmd_get_long(args, "addr", 0);
    unsigned int mask = (unsigned int)cmd_get_long(args, "mask", 0xFFFFFFFF);
    unsigned int expect = (unsigned int)cmd_get_long(args, "expect", 0);
    int timeout = cmd_get_int(args, "timeout", 10000);
    volatile unsigned int *ptr = (volatile unsigned int *)(unsigned long)addr;
    unsigned int data = 0;
    int i;

    for (i = 0; i < timeout; i++) {
        data = *ptr;
        if ((data & mask) == (expect & mask)) {
            cmd_return("ok data=0x%08x iter=%d", data, i);
            return;
        }
    }
    cmd_return("timeout data=0x%08x mask=0x%08x expect=0x%08x iter=%d",
               data, mask, expect, timeout);
}

// ============================================================
// Register all built-in commands
// ============================================================

void cmd_register_builtins(void) {
    cmd_register("cpu_read32",       builtin_cpu_read32);
    cmd_register("cpu_write32",      builtin_cpu_write32);
    cmd_register("cpu_read64",       builtin_cpu_read64);
    cmd_register("cpu_write64",      builtin_cpu_write64);
    cmd_register("cpu_read32_swap",  builtin_cpu_read32_swap);
    cmd_register("cpu_write32_swap", builtin_cpu_write32_swap);
    cmd_register("cpu_read64_swap",  builtin_cpu_read64_swap);
    cmd_register("cpu_write64_swap", builtin_cpu_write64_swap);
    cmd_register("cpu_poll32",       builtin_cpu_poll32);
}
