/* Tcl extension wrapper for the AIP Tcl command implementation.
 * The generated payload (the Tcl files under src/tcl, concatenated by
 * packaging/scripts/embed_tcl.py) is embedded in the shared object; no Tcl
 * source file is read at runtime.
 *
 * Load from a UCLI/Tcl script through dist/aip_init_so.tcl, or directly:
 *   load /path/to/dist/lib/libaip_tcl_bridge.so
 *
 * VCS embeds its Tcl interpreter inside libvcsucli.so and exports no Tcl_*
 * symbols, so the extension cannot call Tcl_Eval.  It evaluates the payload
 * through the UCLI API mhpi_ucliTclExecNoPrint(), which libvcsucli.so does
 * export and which runs in the UCLI interpreter (procs and globals persist).
 * No Tcl runtime is linked into this object.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <stdio.h>

typedef struct Tcl_Interp Tcl_Interp;

/* mhpi_ucliTclExecNoPrint: evaluate a Tcl script in the UCLI interpreter and
 * return its result string (no echo to the console). */
typedef char *(*aip_ucli_exec_fn)(const char *script);

static aip_ucli_exec_fn aip_resolve_ucli_exec(void) {
    return (aip_ucli_exec_fn)dlsym(RTLD_DEFAULT, "mhpi_ucliTclExecNoPrint");
}

#include "aip_tcl_payload.h"

/* Entry point Tcl derives from the file name libaip_tcl_bridge.so. */
int Aip_tcl_bridge_Init(Tcl_Interp *interp) {
    /* ::aip_tcl_embedded    — tells aip_cmd.tcl the checkpoint implementation is
     *                         already embedded (do not source it from disk).
     * ::_aip_bridge_started — suppresses the file-scope bridge start in
     *                         aip_cmd.tcl.  Its $stop handshake must not run
     *                         inside `load` (a nested evaluation there corrupts
     *                         the Tcl stack); dist/aip_init_so.tcl starts the
     *                         bridge after `load` returns. */
    static const char init_script[] =
        "unset -nocomplain ::_aip_payload_ok\n"
        "set ::aip_tcl_embedded 1\n"
        "set ::_aip_bridge_started 1\n";
    /* Undo the flags on failure so a fallback `source dist/aip_init.tcl` in the
     * same session still starts the bridge. */
    static const char undo_script[] =
        "unset -nocomplain ::aip_tcl_embedded ::_aip_bridge_started ::_aip_payload_ok\n";
    aip_ucli_exec_fn exec_tcl = aip_resolve_ucli_exec();
    char *probe;
    (void)interp;

    if (!exec_tcl) {
        fprintf(stderr, "[aip_tcl_bridge] mhpi_ucliTclExecNoPrint not found; "
                        "libaip_tcl_bridge.so only works inside a VCS UCLI session\n");
        return 1;
    }
    (void)exec_tcl(init_script);
    (void)exec_tcl(aip_tcl_payload);

    /* The UCLI API does not report Tcl errors and a Tcl error aborts the rest
     * of the payload string; embed_tcl.py appends `set ::_aip_payload_ok 1` as
     * the payload's last statement, so its presence proves full evaluation. */
    probe = exec_tcl("info exists ::_aip_payload_ok");
    if (!probe || probe[0] != '1') {
        fprintf(stderr, "[aip_tcl_bridge] embedded Tcl payload did not evaluate completely "
                        "(Tcl error inside the embedded scripts)\n");
        (void)exec_tcl(undo_script);
        return 1;
    }
    return 0;
}
