// kernel32 shims for MM9. Derived from Fallout-NV-MacOS recomp/host/shims_kernel32.c (MIT).
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <strings.h>
#include <unistd.h>
#include "shims.h"

static char saved_cmdline[4096];
_Thread_local uint32_t host_last_error;
#define last_error host_last_error
static uint32_t cmdline_a;

void host_init_args(int argc, char **argv) {
    snprintf(saved_cmdline, sizeof saved_cmdline, "\"C:\\MM9\\lithtech.exe\"");
    for (int i = 0; i < argc; i++) {
        strncat(saved_cmdline, " ", sizeof saved_cmdline - strlen(saved_cmdline) - 1);
        strncat(saved_cmdline, argv[i], sizeof saved_cmdline - strlen(saved_cmdline) - 1);
    }
    // Frame-rate setting (env M1_MAXFPS, else defaults key MaxFPS; 0 = uncapped). An explicit +MaxFPS in argv wins.
    extern int host_maxfps_setting(void);
    int mf = host_maxfps_setting(), explicit_mf = 0;
    for (int i = 0; i < argc; i++) if (!strcasecmp(argv[i], "+MaxFPS")) explicit_mf = 1;
    // Above ~120 fps the engine's world clock (time of day) runs fast: it advances at least ~1/120 s per
    // frame (measured: uncapped 6:00 -> 6:37 in 10 s, 120 fps -> 6:05 like 60 fps). Movement is unaffected.
    // So the setting is clamped to 1..120 (0 = uncapped becomes 120); M1_MAXFPS_FORCE=1 skips the clamp (benchmarks).
    if ((mf == 0 || mf > 120) && !getenv("M1_MAXFPS_FORCE")) {
        fprintf(stderr, "[host] MaxFPS %d clamped to 120 (the game's clock runs fast above 120 fps)\n", mf);
        mf = 120;
    }
    if (mf >= 0 && !explicit_mf) {
        char t[32]; snprintf(t, sizeof t, " +MaxFPS %d", mf);
        strncat(saved_cmdline, t, sizeof saved_cmdline - strlen(saved_cmdline) - 1);
        fprintf(stderr, "[host] MaxFPS override %d\n", mf);
    } else if (mf >= 0) fprintf(stderr, "[host] MaxFPS setting %d ignored: +MaxFPS given on the command line\n", mf);
    else fprintf(stderr, "[host] MaxFPS: no override (autoexec.cfg value applies)\n");
    fprintf(stderr, "[host] VSync %s (M1_NOVSYNC=1 disables)\n", getenv("M1_NOVSYNC") ? "off" : "on");
    fprintf(stderr, "[host] command line: %s\n", saved_cmdline);
}

uint32_t gstrdup(const char *s) { uint32_t n = (uint32_t)strlen(s) + 1, p = gmalloc(n); memcpy(MEM + p, s, n); return p; }

// ---- thread / TEB ----------------------------------------------------------------------------
#define TLS_SLOTS 64
void host_thread_init(CPU *c, uint32_t stack_size) {
    uint32_t stack = gpages(stack_size);
    uint32_t teb = gpages(0x2000);
    P32(teb + 0x00, 0xFFFFFFFFu);
    P32(teb + 0x04, stack + stack_size);
    P32(teb + 0x08, stack);
    P32(teb + 0x18, teb);
    P32(teb + 0x20, (uint32_t)getpid());
    static uint32_t next_tid = 1;
    P32(teb + 0x24, __atomic_fetch_add(&next_tid, 1, __ATOMIC_RELAXED));
    P32(teb + 0x2C, teb + 0x1000);
    P32(teb + 0x30, gpages(0x1000));
    SETREG(c, R_FS, teb);
    SETREG(c, R_ESP, stack + stack_size - 64);
}

SHIM(GetLastError) { RET(c, last_error, 0); }
SHIM(SetLastError) { last_error = ARG(c, 0); RET(c, 0, 1); }
SHIM(GetVersion) { RET(c, 0x0A280105u, 0); }            // Windows XP: 5.1 build 2600
SHIM(GetVersionExA) {
    uint32_t v = ARG(c, 0);
    P32(v + 4, 5); P32(v + 8, 1); P32(v + 12, 2600); P32(v + 16, 2);
    memset(MEM + v + 20, 0, 128); strcpy((char *)MEM + v + 20, "Service Pack 2");
    RET(c, 1, 1);
}
SHIM(GetCommandLineA) { if (!cmdline_a) cmdline_a = gstrdup(saved_cmdline); RET(c, cmdline_a, 0); }
SHIM(GetCurrentProcess) { RET(c, 0xFFFFFFFFu, 0); }
SHIM(GetCurrentThread) { RET(c, 0xFFFFFFFEu, 0); }
SHIM(GetCurrentThreadId) { RET(c, G32(REG(c, R_FS) + 0x24), 0); }
SHIM(GetTickCount) { RET(c, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000ull), 0); }
SHIM(QueryPerformanceCounter) {
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;    // 1 MHz like a period HAL
    memcpy(MEM + ARG(c, 0), &t, 8); RET(c, 1, 1);
}
SHIM(QueryPerformanceFrequency) { uint64_t f = 1000000ull; memcpy(MEM + ARG(c, 0), &f, 8); RET(c, 1, 1); }
SHIM(IsBadReadPtr) { RET(c, ARG(c, 0) == 0 && ARG(c, 1) != 0, 2); }
SHIM(IsBadWritePtr) { RET(c, ARG(c, 0) == 0 && ARG(c, 1) != 0, 2); }
SHIM(IsBadCodePtr) { RET(c, ARG(c, 0) == 0, 1); }
SHIM(IsProcessorFeaturePresent) { RET(c, 0, 1); }
SHIM(MulDiv) {
    int64_t a = (int32_t)ARG(c, 0), b = (int32_t)ARG(c, 1), d = (int32_t)ARG(c, 2);
    if (!d) { RET(c, 0xFFFFFFFFu, 3); return; }
    int64_t r = a * b; r = (r >= 0) == (d > 0) ? (r + (d > 0 ? d : -d) / 2) / d : (r - (d > 0 ? d : -d) / 2) / d;
    RET(c, (uint32_t)(int32_t)r, 3);
}

// heaps: one guest heap backs all of them
SHIM(HeapCreate) { RET(c, 0x00F00000u, 3); }
SHIM(GetProcessHeap) { RET(c, 0x00F00000u, 0); }
SHIM(HeapDestroy) { RET(c, 1, 1); }
SHIM(HeapAlloc) { RET(c, gmalloc(ARG(c, 2)), 3); }
SHIM(HeapFree) { gfree(ARG(c, 2)); RET(c, 1, 3); }
SHIM(HeapReAlloc) {
    uint32_t fl = ARG(c, 1), p = ARG(c, 2), n = ARG(c, 3);
    if ((fl & 0x10) && gsize(p) < n) { RET(c, 0, 4); return; }     // HEAP_REALLOC_IN_PLACE_ONLY
    uint32_t old = gsize(p), q = grealloc(p, n);
    if (q && n > old) memset(MEM + q + old, 0, n - old);
    RET(c, q, 4);
}
SHIM(HeapSize) { RET(c, gsize(ARG(c, 2)), 3); }
SHIM(HeapValidate) { RET(c, 1, 3); }
SHIM(HeapCompact) { RET(c, 1 << 20, 2); }

// VirtualAlloc with reservations (see FNV): fixed-address reservations that overlap fail
#define MAXRES 4096
static struct { uint32_t lo, hi; } res[MAXRES];
static int nres;
static pthread_mutex_t va_lk = PTHREAD_MUTEX_INITIALIZER;
static int overlaps(uint32_t lo, uint32_t hi) { for (int i = 0; i < nres; i++) if (lo < res[i].hi && res[i].lo < hi) return i; return -1; }
static void reserve(uint32_t lo, uint32_t hi) { if (nres < MAXRES) { res[nres].lo = lo; res[nres].hi = hi; nres++; } }
SHIM(VirtualAlloc) {
    pthread_mutex_lock(&va_lk);
    uint32_t a = ARG(c, 0), n = ARG(c, 1), type = ARG(c, 2);
    if (!nres) {
        reserve(0, 0x10000);
        for (int i = 0; i < mod_nranges; i++) reserve(mod_range_lo[i], mod_range_hi[i]);
    }
    uint32_t r;
    if (!a) { r = gpages(n); reserve(r, r + ((n + 0xFFF) & ~0xFFFu)); }
    else {
        uint32_t lo = a & ~0xFFFu, hi = (a + n + 0xFFF) & ~0xFFFu;
        int i = overlaps(lo, hi);
        if ((type & 0x2000) && !(type & 0x1000) && i >= 0) { last_error = 487; r = 0; }
        else { if (i < 0) reserve(lo, hi); r = a; }
    }
    pthread_mutex_unlock(&va_lk);
    RET(c, r, 4);
}
SHIM(VirtualFree) { RET(c, 1, 3); }

// TLS (dynamic slots in the TEB's TlsSlots array at +0xE10)
static uint32_t tls_next;
SHIM(TlsAlloc) { RET(c, tls_next < TLS_SLOTS ? __atomic_fetch_add(&tls_next, 1, __ATOMIC_SEQ_CST) : 0xFFFFFFFFu, 0); }
SHIM(TlsFree) { RET(c, 1, 1); }
SHIM(TlsGetValue) { uint32_t i = ARG(c, 0); last_error = 0; RET(c, G32(REG(c, R_FS) + 0xE10 + 4 * i), 1); }
SHIM(TlsSetValue) { uint32_t i = ARG(c, 0); P32(REG(c, R_FS) + 0xE10 + 4 * i, ARG(c, 1)); RET(c, 1, 2); }

// environment / code pages / startup info
SHIM(GetEnvironmentStringsW) { RET(c, gmalloc(4), 0); }
SHIM(GetEnvironmentStrings) { RET(c, gmalloc(2), 0); }
SHIM(FreeEnvironmentStringsW) { RET(c, 1, 1); }
SHIM(FreeEnvironmentStringsA) { RET(c, 1, 1); }
SHIM(GetEnvironmentVariableA) { SETERR(203); RET(c, 0, 3); }
SHIM(GetACP) { RET(c, 1252, 0); }
SHIM(GetOEMCP) { RET(c, 437, 0); }
SHIM(GetCPInfo) { uint32_t p = ARG(c, 1); memset(MEM + p, 0, 20); P32(p, 1); MEM[p + 4] = '?'; RET(c, 1, 2); }
SHIM(IsValidCodePage) { RET(c, 1, 1); }
SHIM(GetStartupInfoA) { uint32_t p = ARG(c, 0); memset(MEM + p, 0, 68); P32(p, 68); RET(c, 0, 1); }
SHIM(GetStdHandle) { RET(c, 0x10 + (ARG(c, 0) & 3), 1); }
SHIM(GetFileType) { uint32_t h = ARG(c, 0); RET(c, h >= 0x10 && h <= 0x13 ? 2 : handle_type(h) == H_FILE ? 1 : 0, 1); }
SHIM(SetHandleCount) { RET(c, ARG(c, 0), 1); }
SHIM(SetUnhandledExceptionFilter) { RET(c, 0, 1); }
SHIM(UnhandledExceptionFilter) { RET(c, 0, 1); }
SHIM(SetConsoleCtrlHandler) { RET(c, 1, 2); }
SHIM(SetPriorityClass) { RET(c, 1, 2); }
SHIM(OutputDebugStringA) { static int q = -1; if (q < 0) q = getenv("M1_QUIET") != NULL; if (!q) fprintf(stderr, "[guest] %s", GSTR(ARG(c, 0))); RET(c, 0, 1); }
SHIM(Sleep) {
    uint32_t ms = ARG(c, 0);
    if (ms == 0xFFFFFFFFu) { fprintf(stderr, "[host] Sleep(INFINITE) on thread %u\n", G32(REG(c, R_FS) + 0x24)); for (;;) pause(); }
    if (ms) usleep((useconds_t)ms * 1000); else sched_yield();
    RET(c, 0, 1);
}
extern void stats_exit(void);
SHIM(ExitProcess) {
    fprintf(stderr, "[host] ExitProcess(%u)\n", ARG(c, 0));
    stats_exit();
    exit((int)ARG(c, 0));
}
SHIM(FatalAppExitA) { fprintf(stderr, "[host] FatalAppExitA: %s\n", GSTR(ARG(c, 1))); exit(5); }
SHIM(GetTempPathA) {
    const char *t = "C:\\MM9\\m1tmp\\"; mkdir("m1tmp", 0755);
    uint32_t n = ARG(c, 0), buf = ARG(c, 1), l = (uint32_t)strlen(t);
    if (n > l) memcpy(MEM + buf, t, l + 1);
    RET(c, l, 2);
}
SHIM(GetTempFileNameA) {
    static uint32_t ctr = 1;
    const char *dir = GSTR(ARG(c, 0)), *pre = GSTR(ARG(c, 1)); uint32_t uniq = ARG(c, 2), buf = ARG(c, 3);
    uint32_t u = uniq ? uniq : __atomic_fetch_add(&ctr, 1, __ATOMIC_SEQ_CST);
    char out[600]; size_t dl = strlen(dir);
    snprintf(out, sizeof out, "%s%s%.3s%X.tmp", dir, dl && dir[dl - 1] == '\\' ? "" : "\\", pre ? pre : "", u);
    strcpy((char *)MEM + buf, out);
    if (!uniq) { char p[1024]; FILE *f = host_path(out, p, sizeof p) ? fopen(p, "wb") : NULL; if (f) fclose(f); }
    RET(c, u, 4);
}

static const Shim kernel32[] = {
    E(GetLastError) E(SetLastError) E(GetVersion) E(GetVersionExA) E(GetCommandLineA)
    E(GetCurrentProcess) E(GetCurrentThread) E(GetCurrentThreadId) E(GetTickCount) E(QueryPerformanceCounter)
    E(QueryPerformanceFrequency) E(IsBadReadPtr) E(IsBadWritePtr) E(IsBadCodePtr) E(MulDiv) E(IsProcessorFeaturePresent)
    E(HeapCreate) E(GetProcessHeap) E(HeapDestroy) E(HeapAlloc) E(HeapFree) E(HeapReAlloc) E(HeapSize)
    E(HeapValidate) E(HeapCompact) E(VirtualAlloc) E(VirtualFree) E(TlsAlloc) E(TlsFree) E(TlsGetValue) E(TlsSetValue)
    E(GetEnvironmentStringsW) E(GetEnvironmentStrings) E(FreeEnvironmentStringsW) E(FreeEnvironmentStringsA)
    E(GetEnvironmentVariableA) E(GetACP) E(GetOEMCP) E(GetCPInfo) E(IsValidCodePage) E(GetStartupInfoA) E(GetStdHandle)
    E(GetFileType) E(SetHandleCount) E(SetUnhandledExceptionFilter) E(UnhandledExceptionFilter)
    E(SetConsoleCtrlHandler) E(SetPriorityClass) E(OutputDebugStringA) E(Sleep) E(ExitProcess)
    E(FatalAppExitA) E(GetTempPathA) E(GetTempFileNameA)
};

extern const ShimTable sync_shims, file_shims, text_shims, loader_shims, user_shims, gdi_shims, misc_shims, ddraw_shims, dinput_shims, mss_shims, bink_shims;
ShimFn host_find_shim(const char *dll, const char *name) {
    char key[160];
    if (name[0] == '#') {      // ordinal imports: "<dll basename, lowercase>#<n>"
        size_t k = 0;
        for (const char *p = dll; *p && *p != '.' && k < sizeof key - 1; p++) key[k++] = (char)(*p >= 'A' && *p <= 'Z' ? *p + 32 : *p);
        key[k] = 0;
        strncat(key, name, sizeof key - strlen(key) - 1);
        name = key;
    }
    for (size_t i = 0; i < sizeof kernel32 / sizeof *kernel32; i++)
        if (!strcmp(kernel32[i].name, name)) return kernel32[i].fn;
    const ShimTable *tabs[] = {&loader_shims, &sync_shims, &file_shims, &text_shims, &user_shims, &gdi_shims, &misc_shims, &ddraw_shims, &dinput_shims, &mss_shims, &bink_shims};
    for (size_t t = 0; t < sizeof tabs / sizeof *tabs; t++)
        for (int i = 0; i < tabs[t]->count; i++)
            if (!strcmp(tabs[t]->list[i].name, name)) return tabs[t]->list[i].fn;
    return NULL;
}
