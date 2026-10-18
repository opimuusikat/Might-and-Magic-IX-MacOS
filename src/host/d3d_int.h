// Shared between the DirectDraw/D3D7 front end (ddraw.c) and the Metal backend (metal.m).
#pragma once
#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t o7, o1;            // guest objects: IDirectDrawSurface7 and (lazily) IDirectDrawSurface
    uint8_t d[124];             // DDSURFACEDESC2 as reported
    uint32_t mem, size;         // guest memory backing Lock
    int att[4], natt;           // attached surfaces (back buffer, next mip level, Z buffer)
    int owner;                  // complex root that owns this surface (-1: independent)
    int added[4], nadded;       // AddAttachedSurface targets (we hold a reference)
    int alive;
    int dirty;                  // on the root: CPU contents changed since the last GPU upload
    int gpu;                    // backend texture slot + 1 (0: none yet)
} Surf;
extern Surf *sf;
extern int nsf;

typedef struct {
    uint32_t o, rt;
    uint32_t rs[256];           // render states as last set
    uint32_t tss[8][32];        // texture-stage states as last set
    uint32_t tex[8];            // bound textures (guest IDirectDrawSurface7 objects)
    float xf[32][16];
    uint8_t vp[24];             // D3DVIEWPORT7
} DevState;
extern DevState dev;

static inline uint32_t SDESC(const Surf *s, int off) { uint32_t v; memcpy(&v, s->d + off, 4); return v; }
static inline int surf_root(int i) { return sf[i].owner >= 0 ? sf[i].owner : i; }

// backend (metal.m). With M1_NULL=1 every call is a no-op and the device is the null device.
int  gpu_on(void);
void gpu_init(uint32_t w, uint32_t h, int rt_surface);
void gpu_clear(uint32_t flags, uint32_t color, float z);
void gpu_draw(uint32_t prim, uint32_t fvf, uint32_t verts, uint32_t nverts, uint32_t idx, uint32_t nidx);
void gpu_colorfill(int surface, uint32_t color);
void gpu_blit(int src, int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1, int keyed);
void gpu_show(void);
void gpu_present(void);
void gpu_readback(int surface);
void gpu_surface_free(int i);
void host_pump_events(void);
void host_request_quit(void);

// HD texture pack (texpack.m): hash, dump and replacement of uploaded textures. texpack_on_upload returns 0 for dynamic textures.
// (the Metal-side loader texpack_texture is declared in metal.m). texpack_hash returns 0 when dump is off,
// the texture is dynamic or the format is unsupported (then nothing else is done).
int  texpack_on(void);                 // dump or replace is on
int  texpack_replace_on(void);
int  texpack_noalpha(const Surf *s);   // original format has no alpha (565, XRGB*)
void texpack_init(void);
uint64_t texpack_hash(const Surf *root_surface, int root);
int  texpack_on_upload(int root, const Surf *s, uint64_t hash, int mips, uint64_t frame);
void texpack_forget(int root);
void texpack_retain(uint64_t hash);    // refcount of surfaces binding a replacement (cache entry dropped at 0)
void texpack_release(uint64_t hash);
