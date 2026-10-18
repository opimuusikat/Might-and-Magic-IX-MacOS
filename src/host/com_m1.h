// Guest COM objects: [vtable][refcount][host index][kind]. The vtable lives in guest memory and holds
// import-thunk addresses, so the game's `call [vtbl+N]` lands in a native method. Unimplemented
// methods log once and return E_NOTIMPL with the right stdcall pop (the arg count is part of the name).
#pragma once
#include "shims.h"

typedef struct { const char *name; int nargs; ShimFn fn; } Method;   // nargs excludes `this`
uint32_t com_vtable(const char *iface, const Method *m, int n);
uint32_t com_obj(uint32_t vtbl, uint32_t idx, uint32_t kind);
#define THIS(c) ARG(c, 0)
#define OIDX(o) G32((o) + 8)
#define OKIND(o) G32((o) + 12)
#define OREFS(o) G32((o) + 4)
static inline uint32_t com_addref(uint32_t o) { uint32_t r = G32(o + 4) + 1; P32(o + 4, r); return r; }
static inline uint32_t com_release(uint32_t o) { uint32_t r = G32(o + 4); if (r) r--; P32(o + 4, r); return r; }
// GUID helpers
static inline int guid_is(uint32_t g, uint32_t d1, uint16_t d2, uint16_t d3) { return g && G32(g) == d1 && G16(g + 4) == d2 && G16(g + 6) == d3; }
void put_guid(uint32_t p, uint32_t d1, uint16_t d2, uint16_t d3, const uint8_t d4[8]);
