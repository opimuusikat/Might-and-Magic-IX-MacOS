// MM9 M1 headless host: maps the 4 GB guest space, loads lithtech.exe and the four rebased DLL images,
// binds their imports to native shims, builds the main thread and runs the recompiled entry point.
// Derived from Fallout-NV-MacOS recomp/host/host.c (MIT, (c) 2026 thetheoryofR).
//
//   mm9host <bindir> [game args...]      (run with the game directory as the current directory)
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include "host.h"
int rt_has_fn_or_text(uint32_t v);

uint8_t *MEM;
int64_t rt_budget = INT64_MAX;
static _Thread_local jmp_buf *trap_jb;
static _Thread_local int trap_code;
static _Thread_local uint32_t trap_addr;
static pthread_t main_thread;
int host_is_main_thread(void) { return pthread_equal(pthread_self(), main_thread); }

void rt_trap(CPU *c, int code, uint32_t addr) {
    (void)c;
    trap_code = code;
    trap_addr = addr;
    if (!trap_jb) { fprintf(stderr, "[host] trap %d at %#x with no guard\n", code, addr); abort(); }
    longjmp(*trap_jb, 1);
}

static const char *trap_name(int code) {
    switch (code) {
    case TRAP_BUDGET: return "budget";
    case TRAP_BRANCHIND: return "unresolved indirect branch";
    case TRAP_DIV0: return "divide by zero";
    case TRAP_FALLOUT: return "fell out of function";
    case TRAP_UNSUPPORTED: return "unsupported/not emitted";
    case TRAP_NOFN: return "no function at address";
    case TRAP_INT3: return "int3";
    case TRAP_IMPORT: return "unimplemented import";
    default: return "?";
    }
}

// ---- imports ---------------------------------------------------------------------------------
HostImport host_imports[MAX_IMPORTS];
int host_import_count;
_Thread_local const HostImport *host_cur_import;

volatile int host_trace_lines;     // >0: trace this many import calls (M1_TRACE_AT=<frame>,<lines> arms it from stats.c)
static int trace_imports(void) {
    static int t = -1; if (t < 0) t = getenv("M1_TRACE") != NULL;
    if (host_trace_lines > 0) { if (--host_trace_lines == 0) fprintf(stderr, "[imp] trace window over\n"); return 1; }
    return t;
}

void rt_import_call(CPU *c, uint32_t addr) {
    int i = (int)((addr - IMPORT_THUNK_BASE) / 4);
    if (i < 0 || i >= host_import_count) rt_trap(c, TRAP_NOFN, addr);
    HostImport *hi = &host_imports[i];
    if (!hi->fn) {
        fprintf(stderr, "[host] unimplemented import %s!%s (called from %#x)\n", hi->dll, hi->name, G32(REG(c, R_ESP)));
        rt_trap(c, TRAP_IMPORT, addr);
    }
    if (trace_imports()) fprintf(stderr, "[imp] %s!%s(%#x, %#x, %#x, %#x) ra=%#x\n", hi->dll, hi->name,
                       G32(REG(c, R_ESP) + 4), G32(REG(c, R_ESP) + 8), G32(REG(c, R_ESP) + 12), G32(REG(c, R_ESP) + 16), G32(REG(c, R_ESP)));
    extern _Thread_local volatile int *host_kill_flag; extern void host_thread_exit_now(uint32_t);
    if (__builtin_expect(host_kill_flag && *host_kill_flag, 0)) host_thread_exit_now(0);
    host_cur_import = hi;
    hi->fn(c);
    static int env_trace = -1; if (env_trace < 0) env_trace = getenv("M1_TRACE") != NULL;
    if (host_trace_lines > 0 || env_trace) fprintf(stderr, "[imp]   %s -> %#x\n", hi->name, REG(c, R_EAX));
}

uint32_t host_call(CPU *c, uint32_t fn, int nargs, const uint32_t *args) {
    uint32_t esp0 = REG(c, R_ESP);
    uint32_t save[4] = {REG(c, R_EBX), REG(c, R_EBP), REG(c, R_ESI), REG(c, R_EDI)};
    uint32_t sp = ((esp0 - 256) & ~15u) - 4 * (uint32_t)nargs - 4;
    P32(sp, HOST_EXIT_THUNK);
    for (int i = 0; i < nargs; i++) P32(sp + 4 + 4 * (uint32_t)i, args[i]);
    SETREG(c, R_ESP, sp);
    rt_call(c, fn);
    uint32_t r = REG(c, R_EAX);
    SETREG(c, R_ESP, esp0);
    SETREG(c, R_EBX, save[0]); SETREG(c, R_EBP, save[1]); SETREG(c, R_ESI, save[2]); SETREG(c, R_EDI, save[3]);
    return r;
}

uint32_t host_image_base;
uint8_t *host_tls_template;
uint32_t host_tls_template_size, host_tls_block_size;

#include <execinfo.h>
#include <sys/ucontext.h>
static void on_signal(int sig, siginfo_t *si, void *uc_) {
    ucontext_t *uc = uc_;
    fprintf(stderr, "[host] signal %d at pc %#llx addr %p lr %#llx\n", sig, (unsigned long long)uc->uc_mcontext->__ss.__pc, si->si_addr,
            (unsigned long long)uc->uc_mcontext->__ss.__lr);
    void *bt[64]; int n = backtrace(bt, 64);
    backtrace_symbols_fd(bt, n, 2);
    rt_calltrace_dump();
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bindir> [game args]\n", argv[0]); return 2; }
    void *p = mmap((void *)RT_MEM_BASE, (size_t)1 << 32, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) { perror("mmap 4GB"); return 1; }
    if (p != (void *)RT_MEM_BASE) { fprintf(stderr, "[host] guest space landed at %p, not %#llx\n", p, RT_MEM_BASE); return 1; }
    MEM = p;
    main_thread = pthread_self();
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_signal; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    stack_t ss = {.ss_sp = malloc(1 << 20), .ss_size = 1 << 20}; sigaltstack(&ss, NULL);
    int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE};
    for (int i = 0; i < 6; i++) sigaction(sigs[i], &sa, NULL);
    if (!getenv("M1_NO_QOS")) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    host_init_args(argc - 2, argv + 2);
    uint32_t entry = mod_load_all(argv[1]);
    int shimmed = 0;
    for (int i = 0; i < host_import_count; i++) shimmed += host_imports[i].fn != NULL;
    fprintf(stderr, "[host] exe @%#x entry %#x, %d import slots (%d shimmed)\n", host_image_base, entry, host_import_count, shimmed);
    if (getenv("M1_LIST_MISSING"))
        for (int i = 0; i < host_import_count; i++) if (!host_imports[i].fn) fprintf(stderr, "  missing %s!%s\n", host_imports[i].dll, host_imports[i].name);

    static CPU cpu;
    CPU *c = &cpu;
    host_thread_init(c, 8 << 20);
    ST(c->r + 4256, 0x027F, 2);
    uint32_t esp = REG(c, R_ESP) - 4;
    P32(esp, HOST_EXIT_THUNK);
    SETREG(c, R_ESP, esp);
    int rc = host_run_guest(c, entry);
    if (rc) return 3;
    fprintf(stderr, "[host] entry returned, EAX=%#x\n", REG(c, R_EAX));
    return 0;
}

int host_run_guest(CPU *c, uint32_t entry) {
    jmp_buf jb;
    jmp_buf *saved = trap_jb;
    trap_jb = &jb;
    if (setjmp(jb)) {
        fprintf(stderr, "[host] TRAP (thread %u): %s at %#x\n", G32(REG(c, R_FS) + 0x24), trap_name(trap_code), trap_addr);
        uint32_t sp = REG(c, R_ESP);
        fprintf(stderr, "[host]   ESP=%#x stack code words:", sp);
        for (int i = 0, n = 0; i < 2048 && n < 24; i++) {
            uint32_t v = G32(sp + 4 * (uint32_t)i);
            if (rt_has_fn_or_text(v)) { fprintf(stderr, " %#x", v); n++; }
        }
        fprintf(stderr, "\n");
        rt_calltrace_dump();
        trap_jb = saved;
        return trap_code;
    }
    rt_call(c, entry);
    trap_jb = saved;
    return 0;
}
