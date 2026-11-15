/* tests/plugins/hello_plugin.c — sample aip_soload plugin */
#include "aip_plugin.h"
#include <stdio.h>
#include <string.h>

static void do_hello(const char *args, char *resp, int max) {
    snprintf(resp, max, "hello %s", args);
}
static void do_upper(const char *args, char *resp, int max) {
    int i;
    for (i = 0; args[i] && i < max - 1; i++) {
        char c = args[i];
        resp[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
    }
    resp[i] = 0;
}

/* --- real functions wrapped as command handlers --- */

/* CRC-32 (reflected, poly 0xEDB88320, init/xorout 0xFFFFFFFF).
 * CRC32("123456789") == 0xCBF43926. Computed over the raw args string. */
static unsigned crc32_calc(const char *s, int n) {
    unsigned crc = 0xFFFFFFFFu;
    int i, b;
    for (i = 0; i < n; i++) {
        crc ^= (unsigned char)s[i];
        for (b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320u & (unsigned)(-(int)(crc & 1)));
    }
    return crc ^ 0xFFFFFFFFu;
}
static void do_crc(const char *args, char *resp, int max) {
    snprintf(resp, max, "crc=0x%08x", crc32_calc(args, (int)strlen(args)));
}

/* hex-encode ASCII -> lowercase hex pairs. "ABC" -> "414243" */
static void do_hex_enc(const char *args, char *resp, int max) {
    int i, p = 0;
    for (i = 0; args[i] && p + 2 < max - 1; i++)
        p += snprintf(resp + p, max - p, "%02x", (unsigned char)args[i]);
    resp[p] = 0;
}

/* hex-decode hex pairs -> ASCII. "414243" -> "ABC" (odd/invalid -> ERR) */
static void do_hex_dec(const char *args, char *resp, int max) {
    int n = (int)strlen(args), i, p = 0;
    unsigned v;
    if (n % 2 != 0) { snprintf(resp, max, "ERR: odd hex len"); return; }
    for (i = 0; i + 1 < n && p < max - 1; i += 2) {
        if (sscanf(args + i, "%2x", &v) != 1) { snprintf(resp, max, "ERR: bad hex"); return; }
        resp[p++] = (char)v;
    }
    resp[p] = 0;
}

int aip_plugin_init(void *ctx) {
    aip_plugin_register(ctx, "hello",   do_hello);
    aip_plugin_register(ctx, "upper",   do_upper);
    aip_plugin_register(ctx, "crc",     do_crc);
    aip_plugin_register(ctx, "hex_enc", do_hex_enc);
    aip_plugin_register(ctx, "hex_dec", do_hex_dec);
    return 0;
}
