// MM9 M1 headless host. Derived from Fallout-NV-MacOS recomp/host (MIT, (c) 2026 thetheoryofR).
#pragma once
#include <stdint.h>
#include <string.h>
#include "rt.h"

#define MAX_IMPORTS 8192
#define IMPORT_THUNK_BASE 0xFEE00000u   // import slot i -> IMPORT_THUNK_BASE + 4*i
#define HOST_EXIT_THUNK  0xFEDF0000u    // return address of a host->guest call
enum { TRAP_IMPORT = 8 };

typedef void (*ShimFn)(CPU *c);
typedef struct { char dll[64]; char name[96]; ShimFn fn; } HostImport;
extern HostImport host_imports[MAX_IMPORTS];
extern int host_import_count;
extern uint32_t host_image_base;        // lithtech.exe

ShimFn host_find_shim(const char *dll, const char *name);
void host_init_args(int argc, char **argv);
void host_thread_init(CPU *c, uint32_t stack_size);
void rt_import_call(CPU *c, uint32_t addr);
int host_run_guest(CPU *c, uint32_t entry);
// call a guest function from a shim: stdcall or cdecl, args pushed right to left; restores ESP and the
// callee-saved registers, returns EAX
uint32_t host_call(CPU *c, uint32_t fn, int nargs, const uint32_t *args);
extern int host_is_main_thread(void);

// guest memory helpers
extern uint8_t *host_tls_template;
extern uint32_t host_tls_template_size, host_tls_block_size;
static inline uint32_t G32(uint32_t a) { uint32_t v; memcpy(&v, MEM + a, 4); return v; }
static inline uint16_t G16(uint32_t a) { uint16_t v; memcpy(&v, MEM + a, 2); return v; }
static inline void P32(uint32_t a, uint32_t v) { memcpy(MEM + a, &v, 4); }
static inline void P16(uint32_t a, uint16_t v) { memcpy(MEM + a, &v, 2); }
static inline char *GSTR(uint32_t a) { return a ? (char *)MEM + a : NULL; }
static inline uint32_t REG(CPU *c, int off) { return (uint32_t)LD(c->r + off, 4); }
static inline void SETREG(CPU *c, int off, uint32_t v) { ST(c->r + off, v, 4); }
#define R_EAX 0
#define R_ECX 4
#define R_EDX 8
#define R_EBX 12
#define R_ESP 16
#define R_EBP 20
#define R_ESI 24
#define R_EDI 28
#define R_FS 272
static inline uint32_t ARG(CPU *c, int i) { return G32(REG(c, R_ESP) + 4 + 4 * i); }
static inline void RET(CPU *c, uint32_t eax, int stdcall_args) {
    SETREG(c, R_EAX, eax);
    SETREG(c, R_ESP, REG(c, R_ESP) + 4 + 4 * stdcall_args);
}

// guest heap
uint32_t gmalloc(uint32_t size);
void gfree(uint32_t p);
uint32_t gsize(uint32_t p);
uint32_t grealloc(uint32_t p, uint32_t size);
uint32_t gpages(uint32_t size);
uint32_t gstrdup(const char *s);

// modules (loader.c)
typedef struct {
    char name[32];          // lower-case file name
    char path[1024];        // host path of the (rebased) image
    uint32_t base, size, entry, timestamp, orig_size;
    uint8_t *pristine;      // image right after loading + import binding (reload resets data)
    int refs, code, attached;
} Module;
Module *mod_by_handle(uint32_t h);
uint32_t mod_load_all(const char *bindir);
uint32_t res_find(uint32_t base, uint32_t type, uint32_t name, uint32_t *size);   // -> data entry address
extern uint32_t mod_range_lo[8], mod_range_hi[8];
extern int mod_nranges;

// frame statistics (ddraw.c)
void stats_frame(void);
extern uint64_t st_draws, st_verts, st_scenes;
