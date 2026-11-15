/* Minimal VCS native-UCLI PLI smoke plugin. */
#include <stddef.h>
#include "mhpi_user.h"

static int ucli_pli_ping(void *data, int argc, char *argv[])
{
    char *result;
    (void)data;
    (void)argc;
    (void)argv;

    result = mhpi_ucliTclExecNoPrint(
        "set ::ucli_pli_embedded_value 42\n"
        "set ::ucli_pli_embedded_status pass\n"
    );
    if (result != NULL)
        mhpi_ucliSetResult(result);
    return 0;
}

/* Named explicitly by VCS -load <library>:aip_ucli_register. */
__attribute__((visibility("default")))
void aip_ucli_register(void)
{
    (void)mhpi_ucliCreateCommand(
        "ucli_pli_ping",
        ucli_pli_ping,
        NULL,
        NULL
    );
}
