#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "com_m1.h"

extern _Thread_local const HostImport *host_cur_import;
static pthread_mutex_t tl = PTHREAD_MUTEX_INITIALIZER;

static void com_notimpl(CPU *c) {
    const char *nm = host_cur_import ? host_cur_import->name : "?";
    const char *at = strrchr(nm, '@');
    int nargs = at ? atoi(at + 1) : 0;
    static char seen[256][96]; static int ns;
    int i; for (i = 0; i < ns && strcmp(seen[i], nm); i++) {}
    if (i == ns && ns < 256) { snprintf(seen[ns++], 96, "%s", nm); fprintf(stderr, "[com] unimplemented %s -> E_NOTIMPL\n", nm); }
    RET(c, 0x80004001u, nargs + 1);
}

uint32_t com_vtable(const char *iface, const Method *m, int n) {
    uint32_t vt = gmalloc(4u * (uint32_t)n);
    pthread_mutex_lock(&tl);
    for (int i = 0; i < n; i++) {
        if (host_import_count >= MAX_IMPORTS) { fprintf(stderr, "[com] out of thunks\n"); abort(); }
        HostImport *hi = &host_imports[host_import_count];
        snprintf(hi->dll, sizeof hi->dll, "com");
        snprintf(hi->name, sizeof hi->name, "%s::%s@%d", iface, m[i].name, m[i].nargs);
        hi->fn = m[i].fn ? m[i].fn : com_notimpl;
        P32(vt + 4u * (uint32_t)i, IMPORT_THUNK_BASE + 4u * (uint32_t)host_import_count++);
    }
    pthread_mutex_unlock(&tl);
    return vt;
}

uint32_t com_obj(uint32_t vtbl, uint32_t idx, uint32_t kind) {
    uint32_t o = gmalloc(16);
    P32(o, vtbl); P32(o + 4, 1); P32(o + 8, idx); P32(o + 12, kind);
    return o;
}

void put_guid(uint32_t p, uint32_t d1, uint16_t d2, uint16_t d3, const uint8_t d4[8]) {
    P32(p, d1); P16(p + 4, d2); P16(p + 6, d3); memcpy(MEM + p + 8, d4, 8);
}
