// In-game graphics rows on the game's own Options > Video Options screen (cshell.dll, OptionsMenus.cpp).
//
// Mechanism. The Video screen is a guest object (new 0x618, ctor FUN_1003ec60, vtable file 0x100c55d0 =
// cshell base+0xc55d0, used by this class only). Generated code calls most helpers directly, but the screen's
// virtual methods go through rt_call, so three slots of that vtable are pointed (in guest memory, once cshell
// is attached: optmenu_install, called from loader.c dll_attach) at spare dispatch-table addresses
// 0x108ffff0/4/8 (rt_register_fn in rt_dispatch_m1.c) whose host functions forward to the original:
//   slot 0x000 destructor   FUN_1003ed70 (g_1013ed70): forget the screen pointer so no stale control is touched
//   slot 0x05c OnCommand    FUN_1003fc60 (g_1013fc60): event id from event->vt[0x3c]; 0 Apply, 1 Cancel, 2 Restore
//                           Default, 6..0xe stock checkboxes; ours use ids 0x30..0x35
//   slot 0x0f8 SetFocus     FUN_10085050 (g_10185050): called once at the end of the stock build (FUN_1003ee90)
//                           with the adapter list; after the original runs we append our rows (once per object)
// Guest helpers called via host_call (runtime = file address + 0x100000; this-call = ECX set first):
//   0x1018d320 new(size,file)  0x1013ddb0 checkbox ctor(client,id)  checkbox vt[0xd0](x,y,img0..3,0)
//   0x10187d40 checkbox set state   0x10130b50 label(0x41,&rect,text,color,font,-1,1)   0x10132d30 button ctor(client,id)
//   0x10132d90 button set(x,y,w,h,text,font41,font42,font43) (renders 3 state images, ret 0x20)  screen vt[0xd0] AddChild
//   0x101a2050(gfx,0x41) colour, 0x101a1a70(gfx,0x16) font, gfx=0x101df8a8, client=[0x102735f4]
//   checkbox images are the screen's own handles at +0x1c0..+0x1cc.
// Rows (right column x=500, y=335+24n, 24px pitch so 8 rows fit above Cancel/Apply):
//   0 [ ] HD Textures (texreplace)   1 [ ] Sharp Textures (aniso 16x)   2 [ ] Smooth Mipmaps (trilinear)
//   3 [ ] Generated Mipmaps (set_one 7)   4 [ ] Alpha to Coverage (set_one 8)
//   5 Resolution: 1x/2x/3x/4x/Auto   6 Anti-aliasing: Off/2x/4x/8x   7 Frame Rate: 60/120 (next start)
// Rows 5..7 are text buttons that cycle on click; the 3 text surfaces per (row,value) are rendered once per screen
// and re-assigned to btn+0x48/0x4c/0x50 afterwards (no growth per click); at destroy the cached ones no button owns are
// released via [btn+0x44]->vt[8]. Every hook entry validates the screen (vtable) and that our controls are still in its
// child list (container head +0x38, nodes {obj,next,prev}), else the pointers are dropped. optmenu_tick (from the
// ddraw Flip shim, every 8th frame) and every OnCommand reload the rows if the host settings changed elsewhere (overlay).
// Apply (id 0) applies the changed rows via gpu_settings_set_one / host_maxfps_set before the original runs
// (the game then closes the screen); Cancel (1) re-reads the settings into the rows; Restore Default (2) sets
// the rows to scale 1 / MSAA off / aniso 1 / trilinear off / replace off / 60 fps (applied on Apply).
#include <stdio.h>
#include "host.h"
#include "d3d_int.h"

typedef void (*GuestFn)(CPU *);
extern void rt_register_fn(uint32_t a, GuestFn f);
extern int gpu_msaa_ok(int n);
extern void g_1013ed70(CPU *), g_1013fc60(CPU *), g_10185050(CPU *);

#define A_DTOR 0x108ffff0u
#define A_EV 0x108ffff4u
#define A_BUILD 0x108ffff8u
#define VT_FILE 0x100c55d0u
enum { ID_RES = 0x30, ID_AA, ID_FPS, ID_HD, ID_SHARP, ID_SMOOTH, ID_GEN, ID_A2C };
#define NCB 5                           // checkboxes: HD, Sharp, Smooth, Generated Mipmaps, Alpha to Coverage
#define ROW(n) (335 + 24 * (n))         // 8 rows (5 checkboxes, then 3 cycling buttons), 24 px pitch

static const int res_v[] = {1, 2, 3, 4, 0}, aa_v[] = {1, 2, 4, 8}, fps_v[] = {60, 120};
#define NRES 5
#define NAA 4
#define NFPS 2

static uint32_t scr;                    // current Video screen object (0: none)
static uint32_t cbx[NCB], btn[3];       // the checkboxes; Resolution, AA, FPS buttons
static int idx[3], on[NCB];              // current UI values (button option index; checkbox state)
static int sidx[3], son[NCB];            // snapshot of the values last applied/loaded
static uint32_t scratch, btext;         // guest scratch: rect (16 bytes), button text (3 x 64)
static uint32_t labstr[NCB];             // guest label strings (allocated once)
static uint32_t scache[3][5][3];        // per row, per option value: the 3 text surfaces (rendered once, reused)
static int ls[8];                       // settings last seen: scale, msaa, aniso, tri, replace, maxfps
static unsigned tickn;

static uint32_t hc(CPU *c, uint32_t ecx, uint32_t fn, int n, uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4, uint32_t a5, uint32_t a6) {
    uint32_t a[8] = {a0, a1, a2, a3, a4, a5, a6, 0};
    SETREG(c, R_ECX, ecx);
    return host_call(c, fn, n, a);
}
static void btn_text(CPU *c, int i) {
    char t[64];
    if (i == 0) { int v = res_v[idx[0]]; if (v) snprintf(t, sizeof t, "Resolution: %dx", v); else snprintf(t, sizeof t, "Resolution: Auto"); }
    else if (i == 1) { int v = aa_v[idx[1]]; if (v == 1) snprintf(t, sizeof t, "Anti-aliasing: Off"); else snprintf(t, sizeof t, "Anti-aliasing: %dx", v); }
    else snprintf(t, sizeof t, "Frame Rate: %d (next start)", fps_v[idx[2]]);
    uint32_t *sc = scache[i][idx[i]];
    if (sc[0]) {                                   // rendered before: reuse its 3 surfaces, no new allocation
        P32(btn[i] + 0x48, sc[0]); P32(btn[i] + 0x4c, sc[1]); P32(btn[i] + 0x50, sc[2]);
        return;
    }
    uint32_t g = btext + 64u * (uint32_t)i;
    snprintf((char *)MEM + g, 64, "%s", t);
    uint32_t gfx = 0x101df8a8u, a[8] = {500, (uint32_t)ROW(NCB + i) + 2, 245, 20, g,
        hc(c, gfx, 0x101a2050, 1, 0x41, 0, 0, 0, 0, 0, 0), hc(c, gfx, 0x101a2050, 1, 0x42, 0, 0, 0, 0, 0, 0), hc(c, gfx, 0x101a2050, 1, 0x43, 0, 0, 0, 0, 0, 0)};
    SETREG(c, R_ECX, btn[i]);
    host_call(c, 0x10132d90, 8, a);                // renders 3 new surfaces into btn+0x48/0x4c/0x50
    sc[0] = G32(btn[i] + 0x48); sc[1] = G32(btn[i] + 0x4c); sc[2] = G32(btn[i] + 0x50);
}
static void ui_apply_values(CPU *c) {
    for (int i = 0; i < NCB; i++) if (cbx[i]) P32(cbx[i] + 0x34, on[i] ? 1 : 0);
    for (int i = 0; i < 3; i++) btn_text(c, i);
}
static void drop_screen(void) { scr = 0; memset(cbx, 0, sizeof cbx); memset(btn, 0, sizeof btn); memset(scache, 0, sizeof scache); }
// is p still a child of screen s? (control list: head +0x38, circular nodes {obj, next, prev}, count +0x40)
static int in_children(uint32_t s, uint32_t p) {
    uint32_t head = G32(s + 0x38), node = head, n = G32(s + 0x40);
    for (uint32_t k = 0; k < n && k < 512 && node; k++) {
        if (G32(node) == p) return 1;
        node = G32(node + 4);
        if (node == head) break;
    }
    return 0;
}
// our screen pointer and all our controls are still alive; otherwise forget them (never touch freed memory)
static int valid(void) {
    if (!scr) return 0;
    if (G32(scr) != 0x101c55d0u) { drop_screen(); return 0; }
    for (int i = 0; i < NCB; i++) if (cbx[i] && !in_children(scr, cbx[i])) { drop_screen(); return 0; }
    for (int i = 0; i < 3; i++) if (btn[i] && !in_children(scr, btn[i])) { drop_screen(); return 0; }
    return 1;
}
static int find(const int *v, int n, int x) { for (int i = 0; i < n; i++) if (v[i] == x) return i; return 0; }
static void load_settings(void) {
    int sc, ms, an, tri, rep, dump, gm, a2, mf = host_maxfps_setting();
    gpu_settings_get(&sc, &ms, &an, &tri, &rep, &dump, NULL);
    gpu_settings_get2(&gm, &a2);
    idx[0] = find(res_v, NRES, sc); idx[1] = find(aa_v, NAA, ms); idx[2] = find(fps_v, NFPS, mf == 120 ? 120 : 60);
    on[0] = rep != 0; on[1] = an > 1; on[2] = tri != 0; on[3] = gm != 0; on[4] = a2 != 0;
}
static void snapshot(void) { for (int i = 0; i < 3; i++) sidx[i] = idx[i]; for (int i = 0; i < NCB; i++) son[i] = on[i]; }

static void cur_settings(int *o) {
    int dump; o[5] = host_maxfps_setting();
    gpu_settings_get(&o[0], &o[1], &o[2], &o[3], &o[4], &dump, NULL);
    gpu_settings_get2(&o[6], &o[7]);
}
static void note_seen(void) { cur_settings(ls); }
// settings changed elsewhere (Cmd+, overlay): reload the rows from them; not counted as pending changes
static void check_external(CPU *c) {
    int cur[8]; cur_settings(cur);
    if (!memcmp(cur, ls, sizeof cur)) return;
    memcpy(ls, cur, sizeof cur);
    load_settings(); snapshot(); ui_apply_values(c);
}

static uint32_t guest_label(CPU *c, uint32_t scrobj, int x, int y, int w, uint32_t gtext) {
    uint32_t gfx = 0x101df8a8u;
    P32(scratch, (uint32_t)x); P32(scratch + 4, (uint32_t)y); P32(scratch + 8, (uint32_t)w); P32(scratch + 12, 20);
    uint32_t col = hc(c, gfx, 0x101a2050, 1, 0x41, 0, 0, 0, 0, 0, 0);
    uint32_t font = hc(c, gfx, 0x101a1a70, 1, 0x16, 0, 0, 0, 0, 0, 0);
    uint32_t l = hc(c, 0, 0x10130b50, 7, 0x41, scratch, gtext, col, font, 0xffffffffu, 1);
    if (l) hc(c, scrobj, G32(G32(scrobj) + 0xd0), 1, l, 0, 0, 0, 0, 0, 0);
    return l;
}
static void add_rows(CPU *c, uint32_t s) {
    uint32_t client = G32(0x102735f4u);
    static const char *lab[NCB] = {"HD Textures", "Sharp Textures", "Smooth Mipmaps", "Generated Mipmaps", "Alpha to Coverage"};
    if (!scratch) { scratch = gmalloc(16); btext = gmalloc(192); for (int i = 0; i < NCB; i++) labstr[i] = gstrdup(lab[i]); }
    memset(scache, 0, sizeof scache);
    load_settings(); snapshot(); note_seen();
    for (int i = 0; i < NCB; i++) {
        int y = ROW(i);
        uint32_t p = hc(c, 0, 0x1018d320, 2, 0x5c, 0x101d378c, 0, 0, 0, 0, 0);
        if (p) p = hc(c, p, 0x1013ddb0, 2, client, ID_HD + (uint32_t)i, 0, 0, 0, 0, 0);
        if (!p) { cbx[i] = 0; continue; }
        hc(c, p, G32(G32(p) + 0xd0), 7, 500, (uint32_t)y, G32(s + 0x1c0), G32(s + 0x1c4), G32(s + 0x1c8), G32(s + 0x1cc), 0);
        hc(c, p, 0x10187d40, 1, on[i] ? 1 : 0, 0, 0, 0, 0, 0, 0);
        hc(c, s, G32(G32(s) + 0xd0), 1, p, 0, 0, 0, 0, 0, 0);
        cbx[i] = p;
        guest_label(c, s, 525, y + 2, 220, labstr[i]);
    }
    for (int i = 0; i < 3; i++) {
        uint32_t p = hc(c, 0, 0x1018d320, 2, 0x5c, 0x101d378c, 0, 0, 0, 0, 0);
        if (p) p = hc(c, p, 0x10132d30, 2, client, ID_RES + (uint32_t)i, 0, 0, 0, 0, 0);
        btn[i] = p;
        if (!p) continue;
        btn_text(c, i);
        hc(c, s, G32(G32(s) + 0xd0), 1, p, 0, 0, 0, 0, 0, 0);
    }
    fprintf(stderr, "[optmenu] rows added to Video Options screen %#x\n", s);
}
static void apply_ui(void) {
    if (idx[0] != sidx[0]) gpu_settings_set_one(1, res_v[idx[0]]);
    if (idx[1] != sidx[1]) gpu_settings_set_one(2, aa_v[idx[1]]);
    if (idx[2] != sidx[2]) host_maxfps_set(fps_v[idx[2]]);
    if (on[0] != son[0]) gpu_settings_set_one(5, on[0]);
    if (on[1] != son[1]) gpu_settings_set_one(3, on[1] ? 16 : 1);
    if (on[2] != son[2]) gpu_settings_set_one(4, on[2]);
    if (on[3] != son[3]) gpu_settings_set_one(7, on[3]);
    if (on[4] != son[4]) gpu_settings_set_one(8, on[4]);
    fprintf(stderr, "[optmenu] apply: res %d aa %d fps %d hd %d sharp %d smooth %d genmips %d a2c %d\n", res_v[idx[0]], aa_v[idx[1]], fps_v[idx[2]], on[0], on[1], on[2], on[3], on[4]);
    snapshot();
}
static void sync_checks(void) { for (int i = 0; i < NCB; i++) if (cbx[i]) on[i] = (G32(cbx[i] + 0x34) & 0xff) == 1 || (G32(cbx[i] + 0x34) & 0xff) == 3; }

static void hook_dtor(CPU *c) {
    uint32_t self = REG(c, R_ECX);
    if (self == scr && valid()) {
        // free the cached text surfaces that no button currently owns (the buttons' own destructors free the
        // current ones) through the same release call the button destructor uses: [btn+0x44]->vt[8](surface)
        for (int i = 0; i < 3; i++) {
            uint32_t mgr = G32(btn[i] + 0x44);
            for (int v = 0; v < 5; v++)
                for (int k = 0; k < 3; k++) {
                    uint32_t sf_ = scache[i][v][k];
                    if (!sf_ || sf_ == G32(btn[i] + 0x48) || sf_ == G32(btn[i] + 0x4c) || sf_ == G32(btn[i] + 0x50)) continue;
                    hc(c, mgr, G32(G32(mgr) + 8), 1, sf_, 0, 0, 0, 0, 0, 0);
                }
        }
    }
    if (self == scr) drop_screen();
    SETREG(c, R_ECX, self);
    g_1013ed70(c);
}
static void hook_build(CPU *c) {
    uint32_t self = REG(c, R_ECX);
    g_10185050(c);
    uint32_t eax = REG(c, R_EAX);
    if (scr && !valid()) scr = 0;
    if (G32(self) == 0x101c55d0u && self != scr && G32(self + 0x1c0)) { drop_screen(); scr = self; add_rows(c, self); }
    SETREG(c, R_EAX, eax);
}
static void hook_event(CPU *c) {
    uint32_t self = REG(c, R_ECX), e = ARG(c, 0);
    int id = -1, reinit = 0;
    if (self == scr && e && valid()) {
        id = (int)hc(c, e, G32(G32(e) + 0x3c), 0, 0, 0, 0, 0, 0, 0, 0);
        SETREG(c, R_ECX, self);
        check_external(c);
        if (id >= ID_RES && id <= ID_FPS) {
            int i = id - ID_RES, n = i == 0 ? NRES : i == 1 ? NAA : NFPS;
            idx[i] = (idx[i] + 1) % n;
            if (i == 1) for (int k = 0; k < n && !gpu_msaa_ok(aa_v[idx[1]]); k++) idx[1] = (idx[1] + 1) % n;
            btn_text(c, i);
            RET(c, 1, 1);
            return;
        }
        if (id == 0) { sync_checks(); apply_ui(); note_seen(); reinit = (G32(self + 0x614) & 0xff) == 1; }
    } else if (self == scr) id = -1;
    SETREG(c, R_ECX, self);
    g_1013fc60(c);
    if (reinit) memset(scache, 0, sizeof scache);     // stock Apply re-initialised the render mode: forget cached surfaces
    if (self == scr && valid()) {
        uint32_t eax = REG(c, R_EAX);
        if (id == 1) { load_settings(); snapshot(); note_seen(); ui_apply_values(c); }
        else if (id == 2) { idx[0] = 0; idx[1] = 0; idx[2] = 0; for (int k = 0; k < NCB; k++) on[k] = 0; sidx[2] = -1; ui_apply_values(c); }   // sidx -1: 60 fps is written on Apply even if the stored value reads as 60
        SETREG(c, R_EAX, eax);
    }
}
// called from the DirectDraw Flip shim on the guest thread (ddraw.c): refresh the rows when the settings
// changed elsewhere (overlay) while the screen is up
void optmenu_tick(CPU *c) {
    if (!scr || (++tickn & 7)) return;
    if (!valid()) return;
    check_external(c);
}

void optmenu_install(uint32_t base) {
    drop_screen();
    if (base != 0x10100000u) { fprintf(stderr, "[optmenu] cshell at %#x, expected 0x10100000: not installed\n", base); return; }
    uint32_t vt = base + (VT_FILE - 0x10000000u);
    if (G32(vt) != 0x1013ed70u || G32(vt + 0x5c) != 0x1013fc60u || G32(vt + 0xf8) != 0x10185050u) {
        fprintf(stderr, "[optmenu] video screen vtable mismatch: not installed\n"); return;
    }
    rt_register_fn(A_DTOR, hook_dtor); rt_register_fn(A_EV, hook_event); rt_register_fn(A_BUILD, hook_build);
    P32(vt, A_DTOR); P32(vt + 0x5c, A_EV); P32(vt + 0xf8, A_BUILD);
    fprintf(stderr, "[optmenu] Video Options hooks installed (vtable %#x)\n", vt);
}
