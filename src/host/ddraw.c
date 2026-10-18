// Null DirectDraw 7 / Direct3D 7 for the headless M1 gate. It accepts every call the game makes
// (build/recomp-work/trace/methods.txt), enumerates a believable HAL device (800x600 modes, the pixel
// formats of docs/recomp-m0.md section 8, 32-bit Z), backs every surface with real guest memory for
// Lock, keeps render/texture-stage state so Get* returns what was Set, copies DrawPrimitive vertices
// into a ring buffer (what a real backend's batching would cost) and rasterises nothing.
// Frames are counted at Flip; stats.c turns them into ms/frame.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "com_m1.h"
#include "d3d_int.h"

#define DD_OK 0
#define DDERR_NOTFOUND 0x887600FFu
#define DDERR_INVALIDPARAMS 0x80070057u
#define E_NOINTERFACE 0x80004002u
#define DDERR_UNSUPPORTED 0x80004001u

static int trace_dd(void) { static int t = -1; if (t < 0) t = getenv("M1_TRACE_DD") != NULL; return t; }

// ---- pixel formats ---------------------------------------------------------------------------
typedef struct { uint32_t flags, fourcc, bits, r, g, b, a; } PF;
static const PF pf_x8r8g8b8 = {0x40, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0};
static const PF tex_formats[] = {
    {0x41, 0, 16, 0x7C00, 0x03E0, 0x001F, 0x8000},      // A1R5G5B5
    {0x40, 0, 16, 0x7C00, 0x03E0, 0x001F, 0},           // X1R5G5B5
    {0x40, 0, 16, 0xF800, 0x07E0, 0x001F, 0},           // R5G6B5
    {0x41, 0, 16, 0x0F00, 0x00F0, 0x000F, 0xF000},      // A4R4G4B4
    {0x40, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0},           // X8R8G8B8
    {0x41, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000},  // A8R8G8B8
    {0x04, 0x31545844, 0, 0, 0, 0, 0},                  // DXT1
    {0x04, 0x33545844, 0, 0, 0, 0, 0},                  // DXT3
    {0x04, 0x35545844, 0, 0, 0, 0, 0},                  // DXT5
};
static void put_pf(uint32_t p, const PF *f) {
    memset(MEM + p, 0, 32);
    P32(p, 32); P32(p + 4, f->flags); P32(p + 8, f->fourcc); P32(p + 12, f->bits);
    P32(p + 16, f->r); P32(p + 20, f->g); P32(p + 24, f->b); P32(p + 28, f->a);
}
static uint32_t mode_w = 800, mode_h = 600, mode_bpp = 32;
static void put_mode_pf(uint32_t p) {
    if (mode_bpp == 16) { PF f = {0x40, 0, 16, 0xF800, 0x07E0, 0x001F, 0}; put_pf(p, &f); }
    else put_pf(p, &pf_x8r8g8b8);
}

// ---- surfaces ----------------------------------------------------------------------------------
#define DDSD_CAPS 0x1
#define DDSD_HEIGHT 0x2
#define DDSD_WIDTH 0x4
#define DDSD_PITCH 0x8
#define DDSD_BACKBUFFERCOUNT 0x20
#define DDSD_ZBUFFERBITDEPTH 0x40
#define DDSD_LPSURFACE 0x800
#define DDSD_PIXELFORMAT 0x1000
#define DDSD_CKSRCBLT 0x10000
#define DDSD_MIPMAPCOUNT 0x20000
#define DDSD_LINEARSIZE 0x80000
#define CAPS_BACKBUFFER 0x4
#define CAPS_COMPLEX 0x8
#define CAPS_FLIP 0x10
#define CAPS_FRONTBUFFER 0x20
#define CAPS_PRIMARY 0x200
#define CAPS_SYSMEM 0x800
#define CAPS_TEXTURE 0x1000
#define CAPS_3DDEVICE 0x2000
#define CAPS_VIDMEM 0x4000
#define CAPS_ZBUFFER 0x20000
#define CAPS_MIPMAP 0x400000
#define CAPS_LOCALVIDMEM 0x10000000

#define MAXSURF 65536
#define DEADSURF MAXSURF        // where the guest objects of freed surfaces point (alive 0, no memory): a stale pointer can't alias a reused slot
Surf *sf; int nsf;
static int *freel, nfree;       // freed slots, reused by new_surface
static pthread_mutex_t sl = PTHREAD_MUTEX_INITIALIZER;
static uint32_t vt_surf7, vt_surf1, vt_dd7, vt_dd1, vt_d3d7, vt_dev7, vt_vb7;
static uint32_t dd7_obj, d3d7_obj;
static uint64_t live_surface_bytes;

static uint32_t D(Surf *s, int off) { uint32_t v; memcpy(&v, s->d + off, 4); return v; }
static void SD(Surf *s, int off, uint32_t v) { memcpy(s->d + off, &v, 4); }
static Surf *SU(uint32_t obj) { uint32_t i = OIDX(obj); return i < (uint32_t)nsf || i == DEADSURF ? &sf[i] : NULL; }

static int new_surface(uint32_t w, uint32_t h, const uint8_t *pfsrc, uint32_t caps, uint32_t caps2, int owner) {
    pthread_mutex_lock(&sl);
    if (!sf) { sf = calloc(MAXSURF + 1, sizeof *sf); freel = malloc(MAXSURF * sizeof *freel); sf[DEADSURF].owner = -1; }
    int i;
    if (nfree) i = freel[--nfree];
    else if (nsf < MAXSURF) i = nsf++;
    else { fprintf(stderr, "[dd] out of surfaces\n"); abort(); }
    pthread_mutex_unlock(&sl);
    Surf *s = &sf[i];
    int gpu = s->gpu;           // a reused slot keeps its backend texture slot (re-uploaded: dirty)
    memset(s, 0, sizeof *s);
    s->owner = owner; s->alive = 1; s->dirty = 1; s->gpu = gpu;
    SD(s, 0, 124);
    SD(s, 8, h); SD(s, 12, w);
    memcpy(s->d + 72, pfsrc, 32);
    SD(s, 104, caps); SD(s, 108, caps2);
    uint32_t fl = D(s, 76), fourcc = D(s, 80), bits = D(s, 84), flags = DDSD_CAPS | DDSD_WIDTH | DDSD_HEIGHT | DDSD_PIXELFORMAT;
    if (fl & 0x4) {             // FOURCC (DXTn)
        uint32_t bs = fourcc == 0x31545844 ? 8 : 16, bw = (w + 3) / 4 ? (w + 3) / 4 : 1, bh = (h + 3) / 4 ? (h + 3) / 4 : 1;
        s->size = bw * bh * bs; SD(s, 16, s->size); flags |= DDSD_LINEARSIZE;
    } else {
        if (fl & 0x400) bits = D(s, 84);        // ZBUFFER: dwZBufferBitDepth in the same slot
        if (!bits) bits = 32;
        uint32_t pitch = ((w * bits / 8) + 7) & ~7u;
        s->size = pitch * h; SD(s, 16, pitch); flags |= DDSD_PITCH;
    }
    SD(s, 4, flags);
    s->mem = gmalloc(s->size ? s->size : 16);
    live_surface_bytes += s->size;
    s->o7 = com_obj(vt_surf7, (uint32_t)i, 7);
    return i;
}
static void attach(int parent, int child) { Surf *p = &sf[parent]; if (p->natt < 4) p->att[p->natt++] = child; }
static uint32_t surf_release(uint32_t o);
static void free_surface(int i) {
    Surf *s = &sf[i];
    if (!s->alive) return;
    s->alive = 0;
    for (int k = 0; k < s->natt; k++) if (sf[s->att[k]].owner == i) free_surface(s->att[k]);
    for (int k = 0; k < s->nadded; k++) surf_release(sf[s->added[k]].o7);
    gpu_surface_free(i);
    gfree(s->mem); live_surface_bytes -= s->size;
    s->mem = 0;
    // the guest objects are not freed (the game may still hold a pointer); they now name the dead slot
    P32(s->o7 + 8, DEADSURF);
    if (s->o1) P32(s->o1 + 8, DEADSURF);
    s->o7 = s->o1 = 0;
    pthread_mutex_lock(&sl);
    freel[nfree++] = i;
    pthread_mutex_unlock(&sl);
}
static uint32_t surf_release(uint32_t o) {
    Surf *s = SU(o);
    uint32_t r = com_release(o);
    static int no_free = -1; if (no_free < 0) no_free = getenv("M1_NO_FREE") != NULL;
    if (!r && s && s->owner < 0 && !no_free) free_surface((int)(s - sf));
    return r;
}

// DDSURFACEDESC2 (124) or DDSURFACEDESC (108) out
static void put_desc(uint32_t p, Surf *s, int v1) {
    uint32_t n = G32(p);
    if (n != 108 && n != 124) n = v1 ? 108 : 124;
    memcpy(MEM + p, s->d, n);
    P32(p, n);
}

static int create_chain(uint32_t desc) {
    uint32_t fl = G32(desc + 4), caps = G32(desc + 104), caps2 = G32(desc + 108);
    uint32_t w = G32(desc + 12), h = G32(desc + 8);
    uint8_t pf[32];
    if (caps & CAPS_PRIMARY) {
        w = mode_w; h = mode_h;
        uint32_t t = gmalloc(32); put_mode_pf(t); memcpy(pf, MEM + t, 32); gfree(t);
        uint32_t pc = caps | CAPS_FRONTBUFFER | CAPS_VIDMEM | CAPS_LOCALVIDMEM;
        int root = new_surface(w, h, pf, pc, caps2, -1);
        uint32_t nbb = (fl & DDSD_BACKBUFFERCOUNT) ? G32(desc + 20) : 0;
        int prev = root;
        for (uint32_t k = 0; k < nbb; k++) {
            uint32_t bc = (caps & ~(CAPS_PRIMARY | CAPS_FRONTBUFFER)) | CAPS_BACKBUFFER | CAPS_VIDMEM | CAPS_LOCALVIDMEM;
            int bb = new_surface(w, h, pf, bc, caps2, root);
            attach(prev, bb); prev = bb;
        }
        if (nbb) SD(&sf[root], 20, nbb), SD(&sf[root], 4, D(&sf[root], 4) | DDSD_BACKBUFFERCOUNT);
        return root;
    }
    if (fl & DDSD_PIXELFORMAT) memcpy(pf, MEM + desc + 72, 32);
    else if (caps & CAPS_ZBUFFER) { memset(pf, 0, 32); uint32_t v = 32, z = 0x400, m = 0xFFFFFFFFu; memcpy(pf, &v, 4); memcpy(pf + 4, &z, 4);
        uint32_t bd = (fl & DDSD_ZBUFFERBITDEPTH) ? G32(desc + 24) : 32; memcpy(pf + 12, &bd, 4); memcpy(pf + 20, &m, 4); }
    else { uint32_t t = gmalloc(32); put_mode_pf(t); memcpy(pf, MEM + t, 32); gfree(t); }
    if (!w) w = mode_w;
    if (!h) h = mode_h;
    if (!(caps & (CAPS_SYSMEM | CAPS_VIDMEM))) caps |= CAPS_VIDMEM | CAPS_LOCALVIDMEM;
    uint32_t levels = 1;
    if ((caps & CAPS_MIPMAP) && (caps & CAPS_COMPLEX)) {
        if (fl & DDSD_MIPMAPCOUNT) levels = G32(desc + 24);
        else { uint32_t m = w > h ? w : h; levels = 1; while (m > 1) { m >>= 1; levels++; } }
        if (!levels) levels = 1;
    }
    int root = new_surface(w, h, pf, caps, caps2, -1), prev = root;
    if (levels > 1) { SD(&sf[root], 24, levels); SD(&sf[root], 4, D(&sf[root], 4) | DDSD_MIPMAPCOUNT); }
    for (uint32_t l = 1; l < levels; l++) {
        uint32_t lw = w >> l ? w >> l : 1, lh = h >> l ? h >> l : 1;
        int s = new_surface(lw, lh, pf, caps, caps2 | 0x10000 /* MIPMAPSUBLEVEL */, root);
        SD(&sf[s], 24, levels - l); SD(&sf[s], 4, D(&sf[s], 4) | DDSD_MIPMAPCOUNT);
        attach(prev, s); prev = s;
    }
    if (fl & DDSD_CKSRCBLT) { memcpy(sf[root].d + 64, MEM + desc + 64, 8); SD(&sf[root], 4, D(&sf[root], 4) | DDSD_CKSRCBLT); }
    return root;
}

// ---- IDirectDrawSurface7 / IDirectDrawSurface -----------------------------------------------------
static uint32_t surf_v1(Surf *s) {
    if (!s->o1) s->o1 = com_obj(vt_surf1, (uint32_t)(s - sf), 1);
    return s->o1;
}
static void s_QueryInterface(CPU *c) {
    Surf *s = SU(THIS(c)); uint32_t iid = ARG(c, 1), out = ARG(c, 2);
    if (guid_is(iid, 0x06675a80, 0x3b9b, 0x11d2)) { com_addref(s->o7); P32(out, s->o7); RET(c, 0, 3); return; }
    if (guid_is(iid, 0x6C14DB81, 0xA733, 0x11CE)) { uint32_t o = surf_v1(s); com_addref(o); P32(out, o); RET(c, 0, 3); return; }
    fprintf(stderr, "[dd] surface QueryInterface {%08x-%04x} -> E_NOINTERFACE\n", G32(iid), G16(iid + 4));
    P32(out, 0); RET(c, E_NOINTERFACE, 3);
}
static void s_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void s_Release(CPU *c) { RET(c, surf_release(THIS(c)), 1); }
static void s_AddAttachedSurface(CPU *c) {
    Surf *s = SU(THIS(c)), *z = SU(ARG(c, 1));
    if (s && z && s->alive && z->alive) { attach((int)(s - sf), (int)(z - sf)); if (s->nadded < 4) s->added[s->nadded++] = (int)(z - sf); com_addref(z->o7); }
    RET(c, DD_OK, 2);
}
static void s_DeleteAttachedSurface(CPU *c) { RET(c, DD_OK, 3); }
// 2D blits run on the CPU between surface memories (then the destination is re-uploaded when used as a
// texture); colour fills of the render target become a GPU clear.
static int is_rt(Surf *s) { return (SDESC(s, 104) & (CAPS_PRIMARY | CAPS_BACKBUFFER | CAPS_3DDEVICE)) != 0; }
// Copy srect of s (whole surface if 0) to (dx,dy) in d, scaled to dw x dh (0: unscaled), nearest pixel.
static void cpu_blt(Surf *d, int dx, int dy, int dw_, int dh_, Surf *s, uint32_t srect, int keyed) {
    uint32_t sw = SDESC(s, 12), sh = SDESC(s, 8), bits = SDESC(s, 84);
    if ((SDESC(s, 76) & 4) || (SDESC(d, 76) & 4) || bits != SDESC(d, 84) || !bits || !s->mem || !d->mem) return;
    int x0 = 0, y0 = 0, x1 = (int)sw, y1 = (int)sh;
    if (srect) { x0 = (int)G32(srect); y0 = (int)G32(srect + 4); x1 = (int)G32(srect + 8); y1 = (int)G32(srect + 12); }
    int rw = x1 - x0, rh = y1 - y0;
    if (rw <= 0 || rh <= 0) return;
    int ow = dw_ > 0 ? dw_ : rw, oh = dh_ > 0 ? dh_ : rh;
    int bpp = (int)bits / 8, dw = (int)SDESC(d, 12), dh = (int)SDESC(d, 8);
    uint32_t sp = SDESC(s, 16), dp = SDESC(d, 16), key = D(s, 64);
    for (int j = 0; j < oh; j++) {
        int ty = dy + j, y = y0 + (int)((int64_t)j * rh / oh);
        if (ty < 0 || ty >= dh || y < 0 || y >= (int)sh) continue;
        for (int i = 0; i < ow; i++) {
            int tx = dx + i, x = x0 + (int)((int64_t)i * rw / ow);
            if (tx < 0 || tx >= dw || x < 0 || x >= (int)sw) continue;
            uint8_t *sp_ = MEM + s->mem + (uint32_t)y * sp + (uint32_t)(x * bpp), *dp_ = MEM + d->mem + (uint32_t)ty * dp + (uint32_t)(tx * bpp);
            if (keyed) { uint32_t v = 0; memcpy(&v, sp_, (size_t)bpp); if (v == key) continue; }
            memcpy(dp_, sp_, (size_t)bpp);
        }
    }
    sf[surf_root((int)(d - sf))].dirty = 1;
}
static void tr_surf(const char *what, Surf *s) {
    fprintf(stderr, "[dd] %s #%d %ux%u caps %#x bits %u R %#x%s", what, s ? (int)(s - sf) : -1, s ? SDESC(s, 12) : 0, s ? SDESC(s, 8) : 0,
            s ? SDESC(s, 104) : 0, s ? SDESC(s, 84) : 0, s ? SDESC(s, 88) : 0, s && is_rt(s) ? " (render target)" : "");
}
static void tr_rect(const char *what, uint32_t r) {
    if (r) fprintf(stderr, " %s (%d,%d)-(%d,%d)", what, (int)G32(r), (int)G32(r + 4), (int)G32(r + 8), (int)G32(r + 12));
}
static void s_Blt(CPU *c) {
    Surf *d = SU(THIS(c)); uint32_t drect = ARG(c, 1), src = ARG(c, 2), srect = ARG(c, 3), fl = ARG(c, 4), fx = ARG(c, 5);
    if (trace_dd()) { tr_surf("Blt to", d); tr_rect("drect", drect); if (src) { tr_surf(" from", SU(src)); tr_rect("srect", srect); } fprintf(stderr, " flags %#x\n", fl); }
    if (fl & 0x400) {                                   // DDBLT_COLORFILL
        uint32_t col = fx ? G32(fx + 80) : 0;
        if (is_rt(d)) gpu_colorfill((int)(d - sf), col);
        else if (d->mem && !(SDESC(d, 76) & 4)) {
            uint32_t bpp = SDESC(d, 84) / 8, w = SDESC(d, 12), h = SDESC(d, 8), p = SDESC(d, 16);
            for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) memcpy(MEM + d->mem + y * p + x * bpp, &col, bpp);
            sf[surf_root((int)(d - sf))].dirty = 1;
        }
    } else if (src && !is_rt(d)) {                      // CPU copy; from the render target after a GPU readback
        int dx = drect ? (int)G32(drect) : 0, dy = drect ? (int)G32(drect + 4) : 0;
        int dw = drect ? (int)G32(drect + 8) - dx : 0, dh = drect ? (int)G32(drect + 12) - dy : 0;
        if (is_rt(SU(src))) gpu_readback((int)(SU(src) - sf));
        cpu_blt(d, dx, dy, dw, dh, SU(src), srect, (fl & 0x8000) != 0);
    } else if (src && !is_rt(SU(src))) {               // a CPU picture onto the back buffer
        Surf *ss = SU(src);
        int sx0 = 0, sy0 = 0, sx1 = (int)SDESC(ss, 12), sy1 = (int)SDESC(ss, 8), dx0 = 0, dy0 = 0, dx1 = (int)SDESC(d, 12), dy1 = (int)SDESC(d, 8);
        if (srect) { sx0 = (int)G32(srect); sy0 = (int)G32(srect + 4); sx1 = (int)G32(srect + 8); sy1 = (int)G32(srect + 12); }
        if (drect) { dx0 = (int)G32(drect); dy0 = (int)G32(drect + 4); dx1 = (int)G32(drect + 8); dy1 = (int)G32(drect + 12); }
        gpu_blit((int)(ss - sf), sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, (fl & 0x8000) != 0);   // DDBLT_KEYSRC
        if (SDESC(d, 104) & CAPS_PRIMARY) gpu_show();
    } else if (src && (SDESC(d, 104) & CAPS_PRIMARY)) {   // back buffer -> front buffer: shown without a Flip
        gpu_show();
    } else if (src && SU(src) != d && surf_root((int)(SU(src) - sf)) != surf_root((int)(d - sf))) {
        static int w; Surf *ss = SU(src);
        if (w++ < 3) fprintf(stderr, "[dd] Blt onto the render target not drawn yet: src #%d %ux%u caps %#x bits %u, dst rect %s (%d,%d), src rect %s, flags %#x\n",
            (int)(ss - sf), SDESC(ss, 12), SDESC(ss, 8), SDESC(ss, 104), SDESC(ss, 84), drect ? "yes" : "no", drect ? (int)G32(drect) : 0, drect ? (int)G32(drect + 4) : 0, srect ? "yes" : "no", fl);
    }
    RET(c, DD_OK, 6);
}
static void s_BltFast(CPU *c) {
    Surf *d = SU(THIS(c)); uint32_t x = ARG(c, 1), y = ARG(c, 2), src = ARG(c, 3), srect = ARG(c, 4), fl = ARG(c, 5);
    if (trace_dd()) { tr_surf("BltFast to", d); fprintf(stderr, " at (%u,%u)", x, y); tr_surf(" from", SU(src)); tr_rect("srect", srect); fprintf(stderr, " flags %#x\n", fl); }
    if (src && !is_rt(d)) { if (is_rt(SU(src))) gpu_readback((int)(SU(src) - sf)); cpu_blt(d, (int)x, (int)y, 0, 0, SU(src), srect, (fl & 1) != 0); }
    else if (src && !is_rt(SU(src))) {                 // a CPU picture onto the back buffer (Bink movie frames)
        Surf *ss = SU(src);
        int sx0 = 0, sy0 = 0, sx1 = (int)SDESC(ss, 12), sy1 = (int)SDESC(ss, 8);
        if (srect) { sx0 = (int)G32(srect); sy0 = (int)G32(srect + 4); sx1 = (int)G32(srect + 8); sy1 = (int)G32(srect + 12); }
        gpu_blit((int)(ss - sf), sx0, sy0, sx1, sy1, (int)x, (int)y, (int)x + sx1 - sx0, (int)y + sy1 - sy0, (fl & 1) != 0);   // SRCCOLORKEY
        if (SDESC(d, 104) & CAPS_PRIMARY) gpu_show();
    } else if (src && (SDESC(d, 104) & CAPS_PRIMARY)) gpu_show();
    else if (src) { static int w; if (w++ < 3) fprintf(stderr, "[dd] BltFast between render targets not drawn\n"); }
    RET(c, DD_OK, 6);
}
static void s_Flip(CPU *c) {
    extern void optmenu_tick(CPU *);
    static int t = -1; static unsigned fr; if (t < 0) t = getenv("M1_TRACE_SURF") != NULL;
    if (t && fr++ % 120 == 0) fprintf(stderr, "[dd] surface slots %d, free %d, live %d (%llu KB)\n", nsf, nfree, nsf - nfree, (unsigned long long)(live_surface_bytes >> 10));
    gpu_present(); stats_frame(); optmenu_tick(c); RET(c, DD_OK, 3);
}
static void get_attached(CPU *c, int v1) {
    Surf *s = SU(THIS(c)); uint32_t capsp = ARG(c, 1), out = ARG(c, 2);
    uint32_t want = G32(capsp), want2 = v1 ? 0 : G32(capsp + 4);
    for (int k = 0; s && k < s->natt; k++) {
        Surf *a = &sf[s->att[k]];
        if ((D(a, 104) & want) == want && (D(a, 108) & want2) == want2) {
            uint32_t o = v1 ? surf_v1(a) : a->o7;
            com_addref(o); P32(out, o); RET(c, DD_OK, 3); return;
        }
    }
    if (trace_dd()) fprintf(stderr, "[dd] GetAttachedSurface(caps %#x/%#x) on %#x -> NOTFOUND\n", want, want2, D(s, 104));
    P32(out, 0); RET(c, DDERR_NOTFOUND, 3);
}
static void s_GetAttachedSurface7(CPU *c) { get_attached(c, 0); }
static void s_GetAttachedSurface1(CPU *c) { get_attached(c, 1); }
static void s_EnumAttachedSurfaces(CPU *c) {
    Surf *s = SU(THIS(c)); uint32_t ctx = ARG(c, 1), cb = ARG(c, 2);
    int v1 = OKIND(THIS(c)) == 1;
    for (int k = 0; s && k < s->natt; k++) {
        Surf *a = &sf[s->att[k]];
        uint32_t o = v1 ? surf_v1(a) : a->o7;
        com_addref(o);
        uint32_t desc = gmalloc(124); P32(desc, v1 ? 108 : 124); put_desc(desc, a, v1);
        uint32_t args[3] = {o, desc, ctx};
        uint32_t r = host_call(c, cb, 3, args);
        gfree(desc);
        if (!r) break;
    }
    RET(c, DD_OK, 3);
}
static void s_GetCaps(CPU *c) { Surf *s = SU(THIS(c)); uint32_t p = ARG(c, 1); if (OKIND(THIS(c)) == 1) P32(p, D(s, 104)); else memcpy(MEM + p, s->d + 104, 16); RET(c, DD_OK, 2); }
static void s_GetColorKey(CPU *c) { Surf *s = SU(THIS(c)); memcpy(MEM + ARG(c, 2), s->d + 64, 8); RET(c, DD_OK, 3); }
static void s_SetColorKey(CPU *c) {
    Surf *s = SU(THIS(c)); uint32_t fl = ARG(c, 1), ck = ARG(c, 2);
    if ((fl & 8) && ck) { memcpy(s->d + 64, MEM + ck, 8); SD(s, 4, D(s, 4) | DDSD_CKSRCBLT); sf[surf_root((int)(s - sf))].dirty = 1; }
    RET(c, DD_OK, 3);
}
static void s_GetDC(CPU *c) { if (trace_dd()) { tr_surf("GetDC", SU(THIS(c))); fprintf(stderr, "\n"); } P32(ARG(c, 1), 0x00030002); RET(c, DD_OK, 2); }
static void s_ReleaseDC(CPU *c) { RET(c, DD_OK, 2); }
static void s_GetPixelFormat(CPU *c) { Surf *s = SU(THIS(c)); memcpy(MEM + ARG(c, 1), s->d + 72, 32); RET(c, DD_OK, 2); }
static void s_GetSurfaceDesc(CPU *c) { Surf *s = SU(THIS(c)); put_desc(ARG(c, 1), s, OKIND(THIS(c)) == 1); RET(c, DD_OK, 2); }
static void s_IsLost(CPU *c) { RET(c, DD_OK, 1); }
static void s_Restore(CPU *c) { RET(c, DD_OK, 1); }
static void s_Lock(CPU *c) {
    Surf *s = SU(THIS(c)); uint32_t rect = ARG(c, 1), desc = ARG(c, 2);
    if (trace_dd() && (is_rt(s) || !(SDESC(s, 104) & CAPS_TEXTURE))) { tr_surf("Lock", s); tr_rect("rect", rect); fprintf(stderr, " flags %#x\n", ARG(c, 3)); }
    put_desc(desc, s, OKIND(THIS(c)) == 1);
    if (is_rt(s)) gpu_readback((int)(s - sf));          // the CPU reads what the GPU drew (save thumbnails)
    uint32_t p = s->mem;
    if (rect && !(D(s, 76) & 4)) {
        uint32_t bits = D(s, 84) ? D(s, 84) : 32;
        p += G32(rect + 4) * D(s, 16) + G32(rect) * (bits / 8);
    }
    P32(desc + 36, p);
    P32(desc + 4, G32(desc + 4) | DDSD_LPSURFACE);
    RET(c, DD_OK, 5);
}
static void s_Unlock(CPU *c) { Surf *s = SU(THIS(c)); if (s) sf[surf_root((int)(s - sf))].dirty = 1; RET(c, DD_OK, 2); }
static void s_SetClipper(CPU *c) { RET(c, DD_OK, 2); }
static void s_SetPalette(CPU *c) { RET(c, DD_OK, 2); }
static void s_GetDDInterface(CPU *c) { com_addref(dd7_obj); P32(ARG(c, 1), dd7_obj); RET(c, DD_OK, 2); }
static void s_PageLock(CPU *c) { RET(c, DD_OK, 2); }
static void s_PageUnlock(CPU *c) { RET(c, DD_OK, 2); }
static uint32_t prio_dummy;
static void s_SetPriority(CPU *c) { prio_dummy = ARG(c, 1); RET(c, DD_OK, 2); }
static void s_GetPriority(CPU *c) { P32(ARG(c, 1), 0); RET(c, DD_OK, 2); }
static void s_SetLOD(CPU *c) { RET(c, DD_OK, 2); }
static void s_GetLOD(CPU *c) { P32(ARG(c, 1), 0); RET(c, DD_OK, 2); }
static void s_GetUniquenessValue(CPU *c) { P32(ARG(c, 1), 1); RET(c, DD_OK, 2); }
static void s_GetBltStatus(CPU *c) { RET(c, DD_OK, 2); }
static void s_GetFlipStatus(CPU *c) { RET(c, DD_OK, 2); }

#define M(n, a, f) {n, a, f}
static const Method surf7_m[] = {
    M("QueryInterface", 2, s_QueryInterface), M("AddRef", 0, s_AddRef), M("Release", 0, s_Release),
    M("AddAttachedSurface", 1, s_AddAttachedSurface), M("AddOverlayDirtyRect", 1, NULL), M("Blt", 5, s_Blt),
    M("BltBatch", 3, NULL), M("BltFast", 5, s_BltFast), M("DeleteAttachedSurface", 2, s_DeleteAttachedSurface),
    M("EnumAttachedSurfaces", 2, s_EnumAttachedSurfaces), M("EnumOverlayZOrders", 3, NULL), M("Flip", 2, s_Flip),
    M("GetAttachedSurface", 2, s_GetAttachedSurface7), M("GetBltStatus", 1, s_GetBltStatus), M("GetCaps", 1, s_GetCaps),
    M("GetClipper", 1, NULL), M("GetColorKey", 2, s_GetColorKey), M("GetDC", 1, s_GetDC), M("GetFlipStatus", 1, s_GetFlipStatus),
    M("GetOverlayPosition", 2, NULL), M("GetPalette", 1, NULL), M("GetPixelFormat", 1, s_GetPixelFormat),
    M("GetSurfaceDesc", 1, s_GetSurfaceDesc), M("Initialize", 2, NULL), M("IsLost", 0, s_IsLost), M("Lock", 4, s_Lock),
    M("ReleaseDC", 1, s_ReleaseDC), M("Restore", 0, s_Restore), M("SetClipper", 1, s_SetClipper),
    M("SetColorKey", 2, s_SetColorKey), M("SetOverlayPosition", 2, NULL), M("SetPalette", 1, s_SetPalette),
    M("Unlock", 1, s_Unlock), M("UpdateOverlay", 5, NULL), M("UpdateOverlayDisplay", 1, NULL),
    M("UpdateOverlayZOrder", 2, NULL), M("GetDDInterface", 1, s_GetDDInterface), M("PageLock", 1, s_PageLock),
    M("PageUnlock", 1, s_PageUnlock), M("SetSurfaceDesc", 2, NULL), M("SetPrivateData", 4, NULL),
    M("GetPrivateData", 3, NULL), M("FreePrivateData", 1, NULL), M("GetUniquenessValue", 1, s_GetUniquenessValue),
    M("ChangeUniquenessValue", 0, NULL), M("SetPriority", 1, s_SetPriority), M("GetPriority", 1, s_GetPriority),
    M("SetLOD", 1, s_SetLOD), M("GetLOD", 1, s_GetLOD),
};
// IDirectDrawSurface (v1): the first 36 slots, with v1 GetAttachedSurface
static Method surf1_m[36];

// ---- IDirectDraw7 / IDirectDraw -----------------------------------------------------------------
static uint32_t make_d3d7(void);
static void dd_QueryInterface(CPU *c) {
    uint32_t iid = ARG(c, 1), out = ARG(c, 2);
    if (guid_is(iid, 0xf5049e77, 0x4861, 0x11d2)) { uint32_t o = make_d3d7(); com_addref(o); P32(out, o); RET(c, 0, 3); return; }
    if (guid_is(iid, 0x15e65ec0, 0x3b9c, 0x11d2)) { com_addref(dd7_obj); P32(out, dd7_obj); RET(c, 0, 3); return; }
    fprintf(stderr, "[dd] IDirectDraw QueryInterface {%08x-%04x} -> E_NOINTERFACE\n", G32(iid), G16(iid + 4));
    P32(out, 0); RET(c, E_NOINTERFACE, 3);
}
static void dd_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void dd_Release(CPU *c) { RET(c, com_release(THIS(c)), 1); }
static void dd_CreateSurface(CPU *c) {
    uint32_t desc = ARG(c, 1), out = ARG(c, 2);
    int v1 = OKIND(THIS(c)) == 1;
    int i = create_chain(desc);
    if (trace_dd()) fprintf(stderr, "[dd] CreateSurface caps %#x %ux%u flags %#x -> #%d\n", G32(desc + 104), G32(desc + 12), G32(desc + 8), G32(desc + 4), i);
    P32(out, v1 ? surf_v1(&sf[i]) : sf[i].o7);
    RET(c, DD_OK, 4);
}
static void put_ddcaps(uint32_t p) {
    if (!p) return;
    uint32_t n = G32(p); if (n < 8 || n > 380) n = 380;
    memset(MEM + p + 4, 0, n - 4);
    P32(p + 4, 0x1 | 0x40 | 0x100 | 0x200 | 0x400000 | 0x800000 | 0x04000000 | 0x10000000 | 0x20000000 | 0x80000000u);
    P32(p + 8, 0x1000 | 0x20000 | 0x80000 | 0x200000 | 0x400000 | 0x800000 | 0x08000000);
    P32(p + 12, 0x200);
    P32(p + 56, 0x400 | 0x100);          // DDBD_16 | DDBD_32 Z depths
    P32(p + 60, 256u << 20); P32(p + 64, 200u << 20);
    P32(p + 76, 3);
    uint32_t sc = CAPS_3DDEVICE | CAPS_TEXTURE | CAPS_ZBUFFER | CAPS_FLIP | CAPS_PRIMARY | CAPS_BACKBUFFER | CAPS_VIDMEM |
                  CAPS_LOCALVIDMEM | CAPS_MIPMAP | 0x40 | CAPS_SYSMEM | CAPS_COMPLEX | CAPS_FRONTBUFFER;
    if (n >= 136) P32(p + 132, sc);
    if (n >= 380) P32(p + 364, sc);
}
static void dd_GetCaps(CPU *c) { put_ddcaps(ARG(c, 1)); put_ddcaps(ARG(c, 2)); RET(c, DD_OK, 3); }
static void put_mode_desc(uint32_t p, int v1, uint32_t w, uint32_t h, uint32_t bpp) {
    uint32_t n = v1 ? 108 : 124; memset(MEM + p, 0, n); P32(p, n);
    P32(p + 4, DDSD_WIDTH | DDSD_HEIGHT | DDSD_PITCH | DDSD_PIXELFORMAT | 0x40000 /* REFRESHRATE */);
    P32(p + 8, h); P32(p + 12, w); P32(p + 16, w * bpp / 8); P32(p + 24, 60);
    if (bpp == 16) { PF f = {0x40, 0, 16, 0xF800, 0x07E0, 0x001F, 0}; put_pf(p + 72, &f); } else put_pf(p + 72, &pf_x8r8g8b8);
}
static void dd_GetDisplayMode(CPU *c) { put_mode_desc(ARG(c, 1), OKIND(THIS(c)) == 1, mode_w, mode_h, mode_bpp); RET(c, DD_OK, 2); }
static void dd_EnumDisplayModes(CPU *c) {
    uint32_t ctx = ARG(c, 3), cb = ARG(c, 4); int v1 = OKIND(THIS(c)) == 1;
    static const uint32_t modes[][2] = {{640, 480}, {800, 600}, {1024, 768}};
    static const uint32_t bpps[] = {16, 32};
    uint32_t d = gmalloc(124);
    for (int b = 0; b < 2; b++) for (int m = 0; m < 3; m++) {
        put_mode_desc(d, v1, modes[m][0], modes[m][1], bpps[b]);
        uint32_t args[2] = {d, ctx};
        if (!host_call(c, cb, 2, args)) goto done;
    }
done:
    gfree(d);
    RET(c, DD_OK, 5);
}
static void dd_GetFourCCCodes(CPU *c) {
    uint32_t np = ARG(c, 1), codes = ARG(c, 2);
    static const uint32_t cc[] = {0x31545844, 0x33545844, 0x35545844};
    if (codes) for (uint32_t i = 0; i < 3 && i < G32(np); i++) P32(codes + 4 * i, cc[i]);
    P32(np, 3);
    RET(c, DD_OK, 3);
}
static void dd_Initialize(CPU *c) { RET(c, DD_OK, 2); }
static void dd_RestoreDisplayMode(CPU *c) { RET(c, DD_OK, 1); }
static void dd_SetCooperativeLevel(CPU *c) { RET(c, DD_OK, 3); }
static void dd_SetDisplayMode7(CPU *c) {
    mode_w = ARG(c, 1); mode_h = ARG(c, 2); mode_bpp = ARG(c, 3);
    fprintf(stderr, "[dd] SetDisplayMode(%u, %u, %u)\n", mode_w, mode_h, mode_bpp);
    RET(c, DD_OK, 6);
}
static void dd_SetDisplayMode1(CPU *c) { mode_w = ARG(c, 1); mode_h = ARG(c, 2); mode_bpp = ARG(c, 3); RET(c, DD_OK, 4); }
static void dd_WaitForVerticalBlank(CPU *c) { RET(c, DD_OK, 3); }
static void dd_GetAvailableVidMem(CPU *c) {
    if (ARG(c, 2)) P32(ARG(c, 2), 256u << 20);
    if (ARG(c, 3)) P32(ARG(c, 3), (uint32_t)((256ull << 20) - (live_surface_bytes > (200ull << 20) ? (200ull << 20) : live_surface_bytes)));
    RET(c, DD_OK, 4);
}
static void dd_GetMonitorFrequency(CPU *c) { P32(ARG(c, 1), 60); RET(c, DD_OK, 2); }
static void dd_GetScanLine(CPU *c) { P32(ARG(c, 1), 0); RET(c, DD_OK, 2); }
static void dd_GetVerticalBlankStatus(CPU *c) { P32(ARG(c, 1), 0); RET(c, DD_OK, 2); }
static void dd_TestCooperativeLevel(CPU *c) { RET(c, DD_OK, 1); }
static void dd_RestoreAllSurfaces(CPU *c) { RET(c, DD_OK, 1); }
static void dd_FlipToGDISurface(CPU *c) { RET(c, DD_OK, 1); }
static void dd_GetDeviceIdentifier(CPU *c) {
    uint32_t p = ARG(c, 1);
    memset(MEM + p, 0, 1072);
    strcpy((char *)MEM + p, "nv4_disp.dll");
    strcpy((char *)MEM + p + 512, "NVIDIA GeForce4 Ti 4600 (headless null device)");
    P32(p + 1024, 0x0000000Au); P32(p + 1028, 0x0006000E);       // driver 6.14.10.xxxx
    P32(p + 1032, 0x10DE); P32(p + 1036, 0x0250); P32(p + 1040, 0); P32(p + 1044, 0xA3);
    static const uint8_t g4[8] = {0x80, 0x5f, 0x00, 0xc0, 0x4f, 0xb9, 0x80, 0x99};
    put_guid(p + 1048, 0xd7b71ee2, 0x3110, 0x11cf, g4);
    P32(p + 1064, 1);
    RET(c, DD_OK, 3);
}

static const Method dd7_m[] = {
    M("QueryInterface", 2, dd_QueryInterface), M("AddRef", 0, dd_AddRef), M("Release", 0, dd_Release),
    M("Compact", 0, NULL), M("CreateClipper", 3, NULL), M("CreatePalette", 4, NULL), M("CreateSurface", 3, dd_CreateSurface),
    M("DuplicateSurface", 2, NULL), M("EnumDisplayModes", 4, dd_EnumDisplayModes), M("EnumSurfaces", 4, NULL),
    M("FlipToGDISurface", 0, dd_FlipToGDISurface), M("GetCaps", 2, dd_GetCaps), M("GetDisplayMode", 1, dd_GetDisplayMode),
    M("GetFourCCCodes", 2, dd_GetFourCCCodes), M("GetGDISurface", 1, NULL), M("GetMonitorFrequency", 1, dd_GetMonitorFrequency),
    M("GetScanLine", 1, dd_GetScanLine), M("GetVerticalBlankStatus", 1, dd_GetVerticalBlankStatus),
    M("Initialize", 1, dd_Initialize), M("RestoreDisplayMode", 0, dd_RestoreDisplayMode),
    M("SetCooperativeLevel", 2, dd_SetCooperativeLevel), M("SetDisplayMode", 5, dd_SetDisplayMode7),
    M("WaitForVerticalBlank", 2, dd_WaitForVerticalBlank), M("GetAvailableVidMem", 3, dd_GetAvailableVidMem),
    M("GetSurfaceFromDC", 2, NULL), M("RestoreAllSurfaces", 0, dd_RestoreAllSurfaces),
    M("TestCooperativeLevel", 0, dd_TestCooperativeLevel), M("GetDeviceIdentifier", 2, dd_GetDeviceIdentifier),
    M("StartModeTest", 3, NULL), M("EvaluateMode", 2, NULL),
};
static Method dd1_m[23];

// ---- IDirect3D7 ----------------------------------------------------------------------------------
static void d3d_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void d3d_Release(CPU *c) { RET(c, com_release(THIS(c)), 1); }
static void d3d_QueryInterface(CPU *c) { P32(ARG(c, 2), 0); RET(c, E_NOINTERFACE, 3); }
static const uint8_t hal_d4[8] = {0x81, 0x6f, 0x00, 0x00, 0xc0, 0x20, 0x15, 0x6e};
static const uint8_t tnl_d4[8] = {0xa4, 0x07, 0x00, 0xa0, 0xc9, 0x06, 0x29, 0xa8};
static void put_devdesc(uint32_t p, int tnl) {
    memset(MEM + p, 0, 236);
    P32(p, 0x00000010 | 0x00000020 | 0x00000040 | 0x00000080 | 0x00000200 | 0x00000400 | 0x00000800 | 0x00001000 |
           0x00002000 | 0x00004000 | 0x00008000 | (tnl ? 0x00010000 : 0) | 0x00080000);
    for (int t = 0; t < 2; t++) {             // line caps, triangle caps
        uint32_t q = p + 4 + 56 * (uint32_t)t;
        P32(q, 56); P32(q + 4, 0x2 | 0x10 | 0x20 | 0x40);                    // misc: maskz, cull none/cw/ccw
        P32(q + 8, 0x1 | 0x2 | 0x10 | 0x80 | 0x100 | 0x400 | 0x800 | 0x10000 | 0x100000);   // raster
        P32(q + 12, 0xFF); P32(q + 16, 0x1FFF); P32(q + 20, 0x1FFF); P32(q + 24, 0xFF);
        P32(q + 28, 0x1 | 0x2 | 0x8 | 0x200 | 0x1000 | 0x4000 | 0x40000 | 0x80000 | 0x200000);
        P32(q + 32, 0x1 | 0x2 | 0x4 | 0x8 | 0x800 | 0x1000);                  // texture caps: persp, pow2, alpha, transparency, cubemap, colorkeyblend (no SQUAREONLY)
        P32(q + 36, 0x3F | 0x100 | 0x200 | 0x10000 | 0x20000 | 0x1000000 | 0x2000000);   // filter caps
        P32(q + 40, 0xFF); P32(q + 44, 0x1F);
    }
    P32(p + 116, 0x400 | 0x100); P32(p + 120, 0x400 | 0x100);
    P32(p + 124, 1); P32(p + 128, 1); P32(p + 132, 2048); P32(p + 136, 2048);
    P32(p + 140, 8192); P32(p + 144, 2048); P32(p + 148, 1);
    float gb[5] = {-1e8f, -1e8f, 1e8f, 1e8f, 0.0f}; memcpy(MEM + p + 152, gb, 20);
    P32(p + 172, 0xFF); P32(p + 176, 0x00080008); P32(p + 180, 0x00FFFFFF);
    P16(p + 184, 8); P16(p + 186, 2); P32(p + 188, 8);
    float mw = 1e10f; memcpy(MEM + p + 192, &mw, 4);
    put_guid(p + 196, tnl ? 0xf5049e78 : 0x84E63dE0, tnl ? 0x4861 : 0x46AA, tnl ? 0x11d2 : 0x11CF, tnl ? tnl_d4 : hal_d4);
    P16(p + 212, 6); P16(p + 214, 4); P32(p + 216, 0x3F);
}
static void d3d_EnumDevices(CPU *c) {
    uint32_t cb = ARG(c, 1), ctx = ARG(c, 2);
    uint32_t dd = gmalloc(236), s1 = gstrdup("Direct3D HAL"), s2 = gstrdup("Direct3D T&L HAL"), n1 = gstrdup("HAL"), n2 = gstrdup("T&L HAL");
    put_devdesc(dd, 0);
    uint32_t a1[4] = {s1, n1, dd, ctx};
    if (host_call(c, cb, 4, a1)) { put_devdesc(dd, 1); uint32_t a2[4] = {s2, n2, dd, ctx}; host_call(c, cb, 4, a2); }
    RET(c, DD_OK, 3);
}
static uint32_t make_device(int rt);
static void d3d_CreateDevice(CPU *c) {
    uint32_t g = ARG(c, 1), surf = ARG(c, 2), out = ARG(c, 3);
    fprintf(stderr, "[dd] CreateDevice {%08x} on surface #%u\n", G32(g), OIDX(surf));
    gpu_init(mode_w, mode_h, (int)OIDX(surf));
    P32(out, make_device((int)OIDX(surf)));
    RET(c, DD_OK, 4);
}
typedef struct { uint32_t o, caps, fvf, n, stride, mem; } VB;
static VB vbs[4096]; static int nvb;
static uint32_t fvf_size(uint32_t fvf) {
    uint32_t s = 0;
    switch (fvf & 0xE) { case 0x2: s = 12; break; case 0x4: s = 16; break; case 0x6: s = 16; break; case 0x8: s = 20; break; case 0xA: s = 24; break; case 0xC: s = 28; break; case 0xE: s = 32; break; }
    if (fvf & 0x10) s += 12;
    if (fvf & 0x20) s += 4;      // RESERVED1
    if (fvf & 0x40) s += 4;
    if (fvf & 0x80) s += 4;
    uint32_t nt = (fvf >> 8) & 0xF;
    for (uint32_t t = 0; t < nt; t++) { uint32_t f = (fvf >> (16 + 2 * t)) & 3; s += f == 0 ? 8 : f == 1 ? 12 : f == 2 ? 16 : 4; }
    return s;
}
static void d3d_CreateVertexBuffer(CPU *c) {
    uint32_t desc = ARG(c, 1), out = ARG(c, 2);
    if (nvb >= 4096) { RET(c, 0x8007000Eu, 4); return; }
    VB *v = &vbs[nvb];
    v->caps = G32(desc + 4); v->fvf = G32(desc + 8); v->n = G32(desc + 12); v->stride = fvf_size(v->fvf);
    v->mem = gmalloc(v->n * v->stride + 16);
    v->o = com_obj(vt_vb7, (uint32_t)nvb, 0);
    nvb++;
    P32(out, v->o);
    RET(c, DD_OK, 4);
}
static void d3d_EnumZBufferFormats(CPU *c) {
    uint32_t cb = ARG(c, 2), ctx = ARG(c, 3), p = gmalloc(32);
    static const uint32_t z[][5] = {{0x400, 16, 0, 0xFFFF, 0}, {0x400, 32, 0, 0xFFFFFF, 0}, {0x400 | 0x4000, 32, 8, 0xFFFFFF, 0xFF000000u}, {0x400, 32, 0, 0xFFFFFFFFu, 0}};
    for (int i = 0; i < 4; i++) {
        memset(MEM + p, 0, 32);
        P32(p, 32); P32(p + 4, z[i][0]); P32(p + 12, z[i][1]); P32(p + 16, z[i][2]); P32(p + 20, z[i][3]); P32(p + 24, z[i][4]);
        uint32_t a[2] = {p, ctx};
        if (!host_call(c, cb, 2, a)) break;
    }
    gfree(p);
    RET(c, DD_OK, 4);
}
static void d3d_EvictManagedTextures(CPU *c) { RET(c, DD_OK, 1); }
static const Method d3d7_m[] = {
    M("QueryInterface", 2, d3d_QueryInterface), M("AddRef", 0, d3d_AddRef), M("Release", 0, d3d_Release),
    M("EnumDevices", 2, d3d_EnumDevices), M("CreateDevice", 3, d3d_CreateDevice), M("CreateVertexBuffer", 3, d3d_CreateVertexBuffer),
    M("EnumZBufferFormats", 3, d3d_EnumZBufferFormats), M("EvictManagedTextures", 0, d3d_EvictManagedTextures),
};
static uint32_t make_d3d7(void) { if (!d3d7_obj) d3d7_obj = com_obj(vt_d3d7, 0, 0); return d3d7_obj; }

// ---- IDirect3DDevice7 -----------------------------------------------------------------------------
DevState dev;
uint64_t st_draws, st_verts, st_scenes, st_vbytes;
static uint8_t *ring; static size_t ring_pos;
#define RING (8u << 20)
static uint32_t make_device(int rt) {
    if (!dev.o) {
        dev.o = com_obj(vt_dev7, 0, 0);
        ring = malloc(RING);
        // D3D7 defaults the game may read back before setting
        dev.rs[7] = 1; dev.rs[14] = 1; dev.rs[22] = 3; dev.rs[23] = 4; dev.rs[9] = 2; dev.rs[8] = 3; dev.rs[19] = 2; dev.rs[20] = 1;
        dev.rs[29] = 1; dev.rs[137] = 1; dev.rs[136] = 0;
        for (int s = 0; s < 8; s++) { dev.tss[s][1] = s ? 1 : 4; dev.tss[s][2] = 2; dev.tss[s][3] = 1; dev.tss[s][4] = s ? 1 : 2; dev.tss[s][5] = 2; dev.tss[s][6] = 1;
            dev.tss[s][11] = (uint32_t)s; dev.tss[s][12] = 1; dev.tss[s][13] = 1; dev.tss[s][16] = 1; dev.tss[s][17] = 1; dev.tss[s][18] = 1; }
    } else com_addref(dev.o);
    dev.rt = (uint32_t)rt;
    return dev.o;
}
static void v_QueryInterface(CPU *c) { P32(ARG(c, 2), 0); RET(c, E_NOINTERFACE, 3); }
static void v_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void v_Release(CPU *c) { RET(c, com_release(THIS(c)), 1); }
static void v_GetCaps(CPU *c) { put_devdesc(ARG(c, 1), 1); RET(c, DD_OK, 2); }
static void v_EnumTextureFormats(CPU *c) {
    uint32_t cb = ARG(c, 1), ctx = ARG(c, 2), p = gmalloc(32);
    for (size_t i = 0; i < sizeof tex_formats / sizeof *tex_formats; i++) {
        put_pf(p, &tex_formats[i]);
        uint32_t a[2] = {p, ctx};
        if (!host_call(c, cb, 2, a)) break;
    }
    gfree(p);
    RET(c, DD_OK, 3);
}
static void v_BeginScene(CPU *c) { st_scenes++; RET(c, DD_OK, 1); }
static void v_EndScene(CPU *c) { RET(c, DD_OK, 1); }
static void v_GetDirect3D(CPU *c) { uint32_t o = make_d3d7(); com_addref(o); P32(ARG(c, 1), o); RET(c, DD_OK, 2); }
static void v_SetRenderTarget(CPU *c) { dev.rt = OIDX(ARG(c, 1)); RET(c, DD_OK, 3); }
static void v_GetRenderTarget(CPU *c) { uint32_t o = sf[dev.rt].o7; com_addref(o); P32(ARG(c, 1), o); RET(c, DD_OK, 2); }
static void v_Clear(CPU *c) { float z; uint32_t zb = ARG(c, 5); memcpy(&z, &zb, 4); gpu_clear(ARG(c, 3), ARG(c, 4), z); RET(c, DD_OK, 7); }
static void v_SetTransform(CPU *c) { uint32_t t = ARG(c, 1); if (t < 32) memcpy(dev.xf[t], MEM + ARG(c, 2), 64); RET(c, DD_OK, 3); }
static void v_GetTransform(CPU *c) { uint32_t t = ARG(c, 1); if (t < 32) memcpy(MEM + ARG(c, 2), dev.xf[t], 64); RET(c, DD_OK, 3); }
static void v_MultiplyTransform(CPU *c) { RET(c, DD_OK, 3); }
static void v_SetViewport(CPU *c) { memcpy(dev.vp, MEM + ARG(c, 1), 24); RET(c, DD_OK, 2); }
static void v_GetViewport(CPU *c) { memcpy(MEM + ARG(c, 1), dev.vp, 24); RET(c, DD_OK, 2); }
static void v_SetMaterial(CPU *c) { RET(c, DD_OK, 2); }
static void v_GetMaterial(CPU *c) { memset(MEM + ARG(c, 1), 0, 68); RET(c, DD_OK, 2); }
static void v_SetLight(CPU *c) { RET(c, DD_OK, 3); }
static void v_LightEnable(CPU *c) { RET(c, DD_OK, 3); }
static void v_SetRenderState(CPU *c) { dev.rs[ARG(c, 1) & 255] = ARG(c, 2); RET(c, DD_OK, 3); }
static void v_GetRenderState(CPU *c) { P32(ARG(c, 2), dev.rs[ARG(c, 1) & 255]); RET(c, DD_OK, 3); }
static void v_PreLoad(CPU *c) { RET(c, DD_OK, 2); }
static void v_DrawPrimitive(CPU *c) {
    uint32_t fvf = ARG(c, 2), verts = ARG(c, 3), n = ARG(c, 4);
    size_t bytes = (size_t)n * fvf_size(fvf);
    if (bytes > RING) bytes = RING;
    if (ring_pos + bytes > RING) ring_pos = 0;
    memcpy(ring + ring_pos, MEM + verts, bytes); ring_pos += bytes;
    st_draws++; st_verts += n; st_vbytes += bytes;
    gpu_draw(ARG(c, 1), fvf, verts, n, 0, 0);
    RET(c, DD_OK, 6);
}
static void v_DrawIndexedPrimitive(CPU *c) {
    uint32_t fvf = ARG(c, 2), verts = ARG(c, 3), n = ARG(c, 4);
    size_t bytes = (size_t)n * fvf_size(fvf);
    if (bytes > RING) bytes = RING;
    if (ring_pos + bytes > RING) ring_pos = 0;
    memcpy(ring + ring_pos, MEM + verts, bytes); ring_pos += bytes;
    st_draws++; st_verts += n; st_vbytes += bytes;
    gpu_draw(ARG(c, 1), fvf, verts, n, ARG(c, 5), ARG(c, 6));
    RET(c, DD_OK, 8);
}
static VB *VBP(uint32_t o);
static void v_DrawPrimitiveVB(CPU *c) {
    VB *v = VBP(ARG(c, 2)); st_draws++; st_verts += ARG(c, 4);
    if (v) gpu_draw(ARG(c, 1), v->fvf, v->mem + ARG(c, 3) * v->stride, ARG(c, 4), 0, 0);
    RET(c, DD_OK, 6);
}
static void v_DrawIndexedPrimitiveVB(CPU *c) {
    VB *v = VBP(ARG(c, 2)); st_draws++; st_verts += ARG(c, 4);
    if (v) gpu_draw(ARG(c, 1), v->fvf, v->mem + ARG(c, 3) * v->stride, ARG(c, 4), ARG(c, 5), ARG(c, 6));
    RET(c, DD_OK, 8);
}
static void v_GetTexture(CPU *c) {
    uint32_t st = ARG(c, 1) & 7, o = dev.tex[st];
    if (o) com_addref(o);
    P32(ARG(c, 2), o);
    RET(c, DD_OK, 3);
}
static void v_SetTexture(CPU *c) {
    uint32_t st = ARG(c, 1) & 7, o = ARG(c, 2);
    if (o != dev.tex[st]) { if (o) com_addref(o); if (dev.tex[st]) surf_release(dev.tex[st]); dev.tex[st] = o; }
    RET(c, DD_OK, 3);
}
static void v_GetTextureStageState(CPU *c) { P32(ARG(c, 3), dev.tss[ARG(c, 1) & 7][ARG(c, 2) & 31]); RET(c, DD_OK, 4); }
static void v_SetTextureStageState(CPU *c) { dev.tss[ARG(c, 1) & 7][ARG(c, 2) & 31] = ARG(c, 3); RET(c, DD_OK, 4); }
static void v_ValidateDevice(CPU *c) { if (ARG(c, 1)) P32(ARG(c, 1), 1); RET(c, DD_OK, 2); }
static void v_SetClipStatus(CPU *c) { RET(c, DD_OK, 2); }
static void v_GetClipStatus(CPU *c) { memset(MEM + ARG(c, 1), 0, 24); RET(c, DD_OK, 2); }
static const Method dev7_m[] = {
    M("QueryInterface", 2, v_QueryInterface), M("AddRef", 0, v_AddRef), M("Release", 0, v_Release),
    M("GetCaps", 1, v_GetCaps), M("EnumTextureFormats", 2, v_EnumTextureFormats), M("BeginScene", 0, v_BeginScene),
    M("EndScene", 0, v_EndScene), M("GetDirect3D", 1, v_GetDirect3D), M("SetRenderTarget", 2, v_SetRenderTarget),
    M("GetRenderTarget", 1, v_GetRenderTarget), M("Clear", 6, v_Clear), M("SetTransform", 2, v_SetTransform),
    M("GetTransform", 2, v_GetTransform), M("SetViewport", 1, v_SetViewport), M("MultiplyTransform", 2, v_MultiplyTransform),
    M("GetViewport", 1, v_GetViewport), M("SetMaterial", 1, v_SetMaterial), M("GetMaterial", 1, v_GetMaterial),
    M("SetLight", 2, v_SetLight), M("GetLight", 2, NULL), M("SetRenderState", 2, v_SetRenderState),
    M("GetRenderState", 2, v_GetRenderState), M("BeginStateBlock", 0, NULL), M("EndStateBlock", 1, NULL),
    M("PreLoad", 1, v_PreLoad), M("DrawPrimitive", 5, v_DrawPrimitive), M("DrawIndexedPrimitive", 7, v_DrawIndexedPrimitive),
    M("SetClipStatus", 1, v_SetClipStatus), M("GetClipStatus", 1, v_GetClipStatus), M("DrawPrimitiveStrided", 5, NULL),
    M("DrawIndexedPrimitiveStrided", 7, NULL), M("DrawPrimitiveVB", 5, v_DrawPrimitiveVB),
    M("DrawIndexedPrimitiveVB", 7, v_DrawIndexedPrimitiveVB), M("ComputeSphereVisibility", 5, NULL),
    M("GetTexture", 2, v_GetTexture), M("SetTexture", 2, v_SetTexture), M("GetTextureStageState", 3, v_GetTextureStageState),
    M("SetTextureStageState", 3, v_SetTextureStageState), M("ValidateDevice", 1, v_ValidateDevice),
    M("ApplyStateBlock", 1, NULL), M("CaptureStateBlock", 1, NULL), M("DeleteStateBlock", 1, NULL),
    M("CreateStateBlock", 2, NULL), M("Load", 5, NULL), M("LightEnable", 2, v_LightEnable), M("GetLightEnable", 2, NULL),
    M("SetClipPlane", 2, NULL), M("GetClipPlane", 2, NULL), M("GetInfo", 3, NULL),
};

// ---- IDirect3DVertexBuffer7 ------------------------------------------------------------------------
static VB *VBP(uint32_t o) { uint32_t i = OIDX(o); return i < (uint32_t)nvb ? &vbs[i] : NULL; }
static void b_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void b_Release(CPU *c) { RET(c, com_release(THIS(c)), 1); }
static void b_Lock(CPU *c) { VB *v = VBP(THIS(c)); P32(ARG(c, 2), v->mem); if (ARG(c, 3)) P32(ARG(c, 3), v->n * v->stride); RET(c, DD_OK, 4); }
static void b_Unlock(CPU *c) { RET(c, DD_OK, 1); }
static void b_GetDesc(CPU *c) { VB *v = VBP(THIS(c)); uint32_t p = ARG(c, 1); P32(p, 16); P32(p + 4, v->caps); P32(p + 8, v->fvf); P32(p + 12, v->n); RET(c, DD_OK, 2); }
static void b_Optimize(CPU *c) { RET(c, DD_OK, 3); }
static const Method vb7_m[] = {
    M("QueryInterface", 2, NULL), M("AddRef", 0, b_AddRef), M("Release", 0, b_Release), M("Lock", 3, b_Lock),
    M("Unlock", 0, b_Unlock), M("ProcessVertices", 7, NULL), M("GetVertexBufferDesc", 1, b_GetDesc),
    M("Optimize", 2, b_Optimize), M("ProcessVerticesStrided", 7, NULL),
};

// ---- exports --------------------------------------------------------------------------------------
static void init_vtables(void) {
    if (vt_dd7) return;
    vt_surf7 = com_vtable("IDirectDrawSurface7", surf7_m, (int)(sizeof surf7_m / sizeof *surf7_m));
    for (int i = 0; i < 36; i++) surf1_m[i] = surf7_m[i];
    surf1_m[12].fn = s_GetAttachedSurface1;
    vt_surf1 = com_vtable("IDirectDrawSurface", surf1_m, 36);
    vt_dd7 = com_vtable("IDirectDraw7", dd7_m, (int)(sizeof dd7_m / sizeof *dd7_m));
    for (int i = 0; i < 23; i++) dd1_m[i] = dd7_m[i];
    dd1_m[21] = (Method)M("SetDisplayMode", 3, dd_SetDisplayMode1);
    vt_dd1 = com_vtable("IDirectDraw", dd1_m, 23);
    vt_d3d7 = com_vtable("IDirect3D7", d3d7_m, (int)(sizeof d3d7_m / sizeof *d3d7_m));
    vt_dev7 = com_vtable("IDirect3DDevice7", dev7_m, (int)(sizeof dev7_m / sizeof *dev7_m));
    vt_vb7 = com_vtable("IDirect3DVertexBuffer7", vb7_m, (int)(sizeof vb7_m / sizeof *vb7_m));
}
SHIM(DirectDrawCreate) {
    init_vtables();
    uint32_t o = com_obj(vt_dd1, 0, 1);
    P32(ARG(c, 1), o);
    fprintf(stderr, "[dd] DirectDrawCreate -> IDirectDraw %#x\n", o);
    RET(c, DD_OK, 3);
}
SHIM(DirectDrawCreateEx) {
    init_vtables();
    if (!dd7_obj || !OREFS(dd7_obj)) dd7_obj = com_obj(vt_dd7, 0, 7); else com_addref(dd7_obj);
    P32(ARG(c, 1), dd7_obj);
    fprintf(stderr, "[dd] DirectDrawCreateEx -> IDirectDraw7 %#x\n", dd7_obj);
    RET(c, DD_OK, 4);
}
static void enum_one(CPU *c, uint32_t cb, uint32_t ctx, int ex) {
    uint32_t d = gstrdup("Primary Display Driver"), n = gstrdup("display");
    uint32_t a[5] = {0, d, n, ctx, 0};
    host_call(c, cb, ex ? 5 : 4, a);
}
SHIM(DirectDrawEnumerateA) { enum_one(c, ARG(c, 0), ARG(c, 1), 0); RET(c, DD_OK, 2); }
SHIM(DirectDrawEnumerateExA) { enum_one(c, ARG(c, 0), ARG(c, 1), 1); RET(c, DD_OK, 3); }

SHIM_TABLE(ddraw_shims, E(DirectDrawCreate) E(DirectDrawCreateEx) E(DirectDrawEnumerateA) E(DirectDrawEnumerateExA))
