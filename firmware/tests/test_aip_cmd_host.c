#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stddef.h>
#include "aip_cmd.h"

static aip_mailbox_t fake_mbox;

static void do_echo(const char *args) {
    const char *s = cmd_get_str(args, "s", "");
    cmd_return("echo=%s", s);
}

static void write_cmd(const char *cmd_str) {
    int i;
    int len = (int)strlen(cmd_str);
    memset((void *)fake_mbox.cmd_data, 0, sizeof(fake_mbox.cmd_data));
    for (i = 0; i < len; i++) fake_mbox.cmd_data[i] = (unsigned int)cmd_str[i];
    fake_mbox.cmd_len = (unsigned int)len;
    fake_mbox.rsp_flag = 0;
    fake_mbox.rsp_status = 0;
    fake_mbox.rsp_len = 0;
    fake_mbox.cmd_flag = 1;
}

static void read_rsp(char *buf, int max) {
    int i;
    int len = (int)fake_mbox.rsp_len;
    if (len >= max) len = max - 1;
    for (i = 0; i < len; i++) buf[i] = (char)(fake_mbox.rsp_data[i] & 0xFF);
    buf[len] = '\0';
}

int main(void) {
    char rsp[256];

    memset(&fake_mbox, 0, sizeof(fake_mbox));
    cmd_init(&fake_mbox);
    cmd_register("echo", do_echo);

    /* T1: sync dispatch clears cmd_flag */
    write_cmd("echo s=hello");
    cmd_poll_once();
    assert(fake_mbox.cmd_flag == 0);
    assert(fake_mbox.rsp_flag == 1);
    read_rsp(rsp, sizeof(rsp));
    assert(strcmp(rsp, "echo=hello") == 0);

    /* T2: unknown command returns rsp_status = -1 */
    write_cmd("no_such_cmd");
    cmd_poll_once();
    assert((int)fake_mbox.rsp_status == -1);
    assert(fake_mbox.cmd_flag == 0);

    /* T3: cmd_irq_handler writes irq_ack_flag */
    fake_mbox.irq_ack_flag = 0;
    cmd_irq_handler();
    assert(fake_mbox.irq_ack_flag == 1);

    /* T4: hex argument parsing */
    write_cmd("echo s=0x1A");
    cmd_poll_once();
    read_rsp(rsp, sizeof(rsp));
    assert(strcmp(rsp, "echo=0x1A") == 0);

    /* T5: async flag still clears cmd_flag */
    fake_mbox.async_flag = 1;
    write_cmd("echo s=async");
    cmd_poll_once();
    assert(fake_mbox.cmd_flag == 0);
    fake_mbox.async_flag = 0;

    /* T6: mailbox layout must match SV aip_cpu_bridge offsets (one 32-bit word
     * per character; rsp_flag at +0x208 means cmd_data holds 128 words). */
    assert(offsetof(aip_mailbox_t, cmd_data)     == 0x008);
    assert(offsetof(aip_mailbox_t, rsp_flag)     == 0x208);
    assert(offsetof(aip_mailbox_t, rsp_status)   == 0x20C);
    assert(offsetof(aip_mailbox_t, rsp_len)      == 0x210);
    assert(offsetof(aip_mailbox_t, rsp_data)     == 0x214);
    assert(offsetof(aip_mailbox_t, async_flag)   == 0x414);
    assert(offsetof(aip_mailbox_t, exit_flag)    == 0x418);
    assert(offsetof(aip_mailbox_t, exit_code)    == 0x41C);
    assert(offsetof(aip_mailbox_t, irq_ack_flag) == 0x420);
    assert(sizeof(aip_mailbox_t) <= MBOX_BOOT_READY_OFF);

    printf("L1 PASS: 6 tests\n");
    return 0;
}
