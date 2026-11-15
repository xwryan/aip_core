/* aip_plugin.h — ABI for aip_soload runtime command plugins.
 * A plugin .so includes this, implements handlers + aip_plugin_init.
 * Build: gcc -fPIC -shared myplugin.c -I<aip_core> -o myplugin.so
 */
#ifndef AIP_PLUGIN_H
#define AIP_PLUGIN_H

/* Command handler: read args string, write resp (<= resp_max incl NUL). */
typedef void (*aip_plugin_fn)(const char *args, char *resp, int resp_max);

/* Register one command. Call inside aip_plugin_init. Implemented by the
 * resident stub (aip_soload.c); resolved at dlopen time via simv -rdynamic. */
void aip_plugin_register(void *ctx, const char *name, aip_plugin_fn fn);

/* Plugin MUST export this. Return 0 on success, non-zero => load fails. */
int aip_plugin_init(void *ctx);

#endif /* AIP_PLUGIN_H */
