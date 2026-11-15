/* aip_soload.c — resident DPI-C stub: runtime dlopen of command plugins.
 * Compiled into simv (add to vcs C sources, link -ldl). Holds a command
 * table name->fn and a .so handle table. SV imports the aip_so_* functions.
 */
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include "aip_plugin.h"

#define AIP_SO_MAX_CMD  256
#define AIP_SO_MAX_LIB  32
#define AIP_SO_NAME_MAX 128
#define AIP_SO_PATH_MAX 512

typedef struct {
    char          name[AIP_SO_NAME_MAX];
    aip_plugin_fn fn;      /* NULL = free slot */
    int           so_id;   /* owner index into so_tab */
} cmd_entry_t;

typedef struct {
    char  path[AIP_SO_PATH_MAX];
    void *handle;
    int   used;
} so_entry_t;

typedef struct { int so_id; } reg_ctx_t;

static cmd_entry_t cmd_tab[AIP_SO_MAX_CMD];
static so_entry_t  so_tab[AIP_SO_MAX_LIB];

static char last_loaded[AIP_SO_MAX_CMD][AIP_SO_NAME_MAX];
static int  last_loaded_n;
static char last_removed[AIP_SO_MAX_CMD][AIP_SO_NAME_MAX];
static int  last_removed_n;

static int cmd_find(const char *name) {
    int i;
    for (i = 0; i < AIP_SO_MAX_CMD; i++)
        if (cmd_tab[i].fn && strcmp(cmd_tab[i].name, name) == 0) return i;
    return -1;
}
static int cmd_alloc(void) {
    int i;
    for (i = 0; i < AIP_SO_MAX_CMD; i++)
        if (cmd_tab[i].fn == NULL) return i;
    return -1;
}
static int so_find(const char *path) {
    int i;
    for (i = 0; i < AIP_SO_MAX_LIB; i++)
        if (so_tab[i].used && strcmp(so_tab[i].path, path) == 0) return i;
    return -1;
}
static int so_alloc(void) {
    int i;
    for (i = 0; i < AIP_SO_MAX_LIB; i++)
        if (!so_tab[i].used) return i;
    return -1;
}

/* called by plugin inside aip_plugin_init */
void aip_plugin_register(void *ctx, const char *name, aip_plugin_fn fn) {
    reg_ctx_t *rc = (reg_ctx_t *)ctx;
    int slot;
    if (!name || !fn) return;
    if (cmd_find(name) >= 0) {
        fprintf(stderr, "[aip_soload] WARN: command '%s' exists, skip\n", name);
        return;
    }
    slot = cmd_alloc();
    if (slot < 0) { fprintf(stderr, "[aip_soload] ERR: cmd table full\n"); return; }
    strncpy(cmd_tab[slot].name, name, AIP_SO_NAME_MAX - 1);
    cmd_tab[slot].name[AIP_SO_NAME_MAX - 1] = 0;
    cmd_tab[slot].fn    = fn;
    cmd_tab[slot].so_id = rc->so_id;
    if (last_loaded_n < AIP_SO_MAX_CMD) {
        strncpy(last_loaded[last_loaded_n], cmd_tab[slot].name, AIP_SO_NAME_MAX - 1);
        last_loaded[last_loaded_n][AIP_SO_NAME_MAX - 1] = 0;
        last_loaded_n++;
    }
}

int aip_so_load(const char *path, char *err, int err_max) {
    typedef int (*init_fn)(void *);
    int sid, i, rv;
    void *h;
    init_fn init;
    const char *de;
    reg_ctx_t rc;

    last_loaded_n = 0;
    if (so_find(path) >= 0) { snprintf(err, err_max, "already loaded: %s", path); return -1; }
    sid = so_alloc();
    if (sid < 0) { snprintf(err, err_max, "so table full"); return -1; }

    h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { snprintf(err, err_max, "%s", dlerror()); return -1; }
    dlerror();
    init = (init_fn)dlsym(h, "aip_plugin_init");
    de = dlerror();
    if (de || !init) {
        snprintf(err, err_max, "no aip_plugin_init: %s", de ? de : "null");
        dlclose(h);
        return -1;
    }

    so_tab[sid].used = 1;
    strncpy(so_tab[sid].path, path, AIP_SO_PATH_MAX - 1);
    so_tab[sid].path[AIP_SO_PATH_MAX - 1] = 0;
    so_tab[sid].handle = h;

    rc.so_id = sid;
    rv = init(&rc);
    if (rv != 0) {
        for (i = 0; i < AIP_SO_MAX_CMD; i++)
            if (cmd_tab[i].fn && cmd_tab[i].so_id == sid) { cmd_tab[i].fn = NULL; }
        dlclose(h);
        so_tab[sid].used = 0;
        last_loaded_n = 0;
        snprintf(err, err_max, "aip_plugin_init returned %d", rv);
        return -1;
    }
    err[0] = 0;
    return last_loaded_n;
}

int aip_so_loaded_name(int i, char *name, int name_max) {
    if (i < 0 || i >= last_loaded_n) return -1;
    strncpy(name, last_loaded[i], name_max - 1);
    name[name_max - 1] = 0;
    return 0;
}

int aip_so_exec(const char *name, const char *args, char *resp, int resp_max) {
    int idx = cmd_find(name);
    if (idx < 0) { snprintf(resp, resp_max, "plugin cmd not found: %s", name); return -1; }
    resp[0] = 0;
    cmd_tab[idx].fn(args ? args : "", resp, resp_max);
    return 0;
}

int aip_so_unload(const char *path) {
    int sid = so_find(path);
    int i;
    last_removed_n = 0;
    if (sid < 0) return -1;
    for (i = 0; i < AIP_SO_MAX_CMD; i++) {
        if (cmd_tab[i].fn && cmd_tab[i].so_id == sid) {
            if (last_removed_n < AIP_SO_MAX_CMD) {
                strncpy(last_removed[last_removed_n], cmd_tab[i].name, AIP_SO_NAME_MAX - 1);
                last_removed[last_removed_n][AIP_SO_NAME_MAX - 1] = 0;
                last_removed_n++;
            }
            cmd_tab[i].fn = NULL;
        }
    }
    dlclose(so_tab[sid].handle);
    so_tab[sid].used = 0;
    return last_removed_n;
}

int aip_so_removed_name(int i, char *name, int name_max) {
    if (i < 0 || i >= last_removed_n) return -1;
    strncpy(name, last_removed[i], name_max - 1);
    name[name_max - 1] = 0;
    return 0;
}
