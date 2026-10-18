// Guest-address -> host-function dispatch for the five-module MM9 build.
// Derived from Fallout-NV-MacOS recomp/rt_dispatch.c (MIT): FNV's O(1) table covers one range
// (0x400000-0x1000000); MM9 has lithtech.exe at 0x400000 and the four rebased DLLs at 0x10000000+,
// so there is one dense table per range.
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include "rt.h"

extern const uint32_t rt_fn_addr[];
extern const GuestFn rt_fn_ptr[];
extern const int rt_fn_count;
void rt_import_call(CPU *c, uint32_t a);

static const struct { uint32_t lo, hi; } ranges[] = {
    {0x00400000u, 0x004B0000u},     // lithtech.exe
    {0x10000000u, 0x10900000u},     // d3d.ren, cshell.dll, object.lto, clientfx.fxd
};
#define NR (int)(sizeof ranges / sizeof *ranges)
static GuestFn *tab[NR];

__attribute__((constructor)) static void disp_build(void) {
    for (int r = 0; r < NR; r++) tab[r] = calloc(ranges[r].hi - ranges[r].lo, sizeof(GuestFn));
    int n = 0;
    for (int i = 0; i < rt_fn_count; i++) {
        uint32_t a = rt_fn_addr[i];
        for (int r = 0; r < NR; r++)
            if (a >= ranges[r].lo && a < ranges[r].hi) { tab[r][a - ranges[r].lo] = rt_fn_ptr[i]; n++; }
    }
    if (n != rt_fn_count) fprintf(stderr, "[dispatch] %d of %d functions outside the code ranges\n", rt_fn_count - n, rt_fn_count);
}

static inline GuestFn fn_lookup(uint32_t a) {
    if (a - 0x10000000u < 0x900000u) return tab[1][a - 0x10000000u];
    if (a - 0x00400000u < 0xB0000u) return tab[0][a - 0x00400000u];
    return NULL;
}

void rt_call(CPU *c, uint32_t a) {
    GuestFn f = fn_lookup(a);
    if (__builtin_expect(f != NULL, 1)) { f(c); return; }
    if (a >= 0xFEE00000u && a < 0xFEE00000u + 4 * 8192) { rt_import_call(c, a); return; }
    rt_fallback(c, a);
}

int rt_has_fn(uint32_t a) { return fn_lookup(a) != NULL; }

#ifdef RT_CALLTRACE
_Thread_local uint32_t rt_ct_ring[256];
_Thread_local uint32_t rt_ct_pos;
#endif
void rt_calltrace_dump(void) {
#ifdef RT_CALLTRACE
    fprintf(stderr, "[calltrace] last function entries on this thread (oldest first):\n");
    for (uint32_t i = rt_ct_pos > 64 ? rt_ct_pos - 64 : 0; i < rt_ct_pos; i++) fprintf(stderr, " %#x", rt_ct_ring[i & 255]);
    fprintf(stderr, "\n");
#endif
}

uint64_t rt_rdtsc(void) { return mach_absolute_time(); }
void rt_cpuid(CPU *c) { (void)c; }

static os_unfair_lock lock_prefix = OS_UNFAIR_LOCK_INIT;
void rt_lock(void) { os_unfair_lock_lock(&lock_prefix); }
void rt_unlock(void) { os_unfair_lock_unlock(&lock_prefix); }
