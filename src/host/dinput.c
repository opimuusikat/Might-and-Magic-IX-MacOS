// Null DirectInput (A interfaces): enumerates a keyboard and a mouse, devices accept every setting and
// never report input (headless: the player stands at the spawn point).
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "com_m1.h"

static uint32_t vt_di, vt_dev;
#define DI_OK 0
static const uint8_t kb_d4[8] = {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};

static void i_QueryInterface(CPU *c) { P32(ARG(c, 2), 0); RET(c, 0x80004002u, 3); }
static void i_AddRef(CPU *c) { RET(c, com_addref(THIS(c)), 1); }
static void i_Release(CPU *c) { RET(c, com_release(THIS(c)), 1); }
static void i_CreateDevice(CPU *c) {
    uint32_t g = ARG(c, 1), out = ARG(c, 2);
    uint32_t kind = G32(g) == 0x6f1d2b61 ? 1 : G32(g) == 0x6f1d2b60 ? 2 : 3;   // GUID_SysKeyboard / GUID_SysMouse
    fprintf(stderr, "[di] CreateDevice {%08x} -> %s\n", G32(g), kind == 1 ? "keyboard" : kind == 2 ? "mouse" : "other");
    P32(out, com_obj(vt_dev, 0, kind));
    RET(c, DI_OK, 4);
}
static void put_instance(uint32_t p, int kind) {
    memset(MEM + p, 0, 580);
    P32(p, 580);
    put_guid(p + 4, kind == 1 ? 0x6f1d2b61 : 0x6f1d2b60, 0xd5a0, 0x11cf, kb_d4);
    put_guid(p + 20, kind == 1 ? 0x6f1d2b61 : 0x6f1d2b60, 0xd5a0, 0x11cf, kb_d4);
    P32(p + 36, kind == 1 ? 0x0403 : 0x0202);
    strcpy((char *)MEM + p + 40, kind == 1 ? "Keyboard" : "Mouse");
    strcpy((char *)MEM + p + 300, kind == 1 ? "Keyboard" : "Mouse");
}
static void i_EnumDevices(CPU *c) {
    uint32_t type = ARG(c, 1), cb = ARG(c, 2), ref = ARG(c, 3);
    uint32_t p = gmalloc(580);
    for (int k = 1; k <= 2; k++) {
        if (type && type != (uint32_t)(k == 1 ? 3 : 2)) continue;
        put_instance(p, k);
        uint32_t a[2] = {p, ref};
        if (!host_call(c, cb, 2, a)) break;
    }
    gfree(p);
    RET(c, DI_OK, 5);
}
static void i_GetDeviceStatus(CPU *c) { RET(c, DI_OK, 2); }
static void i_Initialize(CPU *c) { RET(c, DI_OK, 3); }
static const Method di_m[] = {
    {"QueryInterface", 2, i_QueryInterface}, {"AddRef", 0, i_AddRef}, {"Release", 0, i_Release},
    {"CreateDevice", 3, i_CreateDevice}, {"EnumDevices", 4, i_EnumDevices}, {"GetDeviceStatus", 1, i_GetDeviceStatus},
    {"RunControlPanel", 2, NULL}, {"Initialize", 2, i_Initialize},
};

static void d_QueryInterface(CPU *c) {           // IDirectInputDevice2A etc.: same object (extra methods unimplemented)
    uint32_t o = THIS(c); com_addref(o); P32(ARG(c, 2), o); RET(c, 0, 3);
}
static void d_GetCapabilities(CPU *c) {
    uint32_t p = ARG(c, 1), k = OKIND(THIS(c));
    uint32_t n = G32(p); if (n < 8 || n > 44) n = 44;
    memset(MEM + p + 4, 0, n - 4);
    P32(p + 4, 0x5); P32(p + 8, k == 1 ? 0x0403 : 0x0202); P32(p + 12, k == 2 ? 3 : 0); P32(p + 16, k == 1 ? 128 : 3);
    RET(c, DI_OK, 2);
}
// EnumObjects: keyboard keys (offset = DIK code) and mouse axes/buttons, so the engine can bind actions
static const uint8_t di_d4[8] = {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};
static void d_EnumObjects(CPU *c) {
    uint32_t cb = ARG(c, 1), ref = ARG(c, 2), kind = OKIND(THIS(c));
    uint32_t p = gmalloc(316);
    int n = kind == 1 ? 256 : kind == 2 ? 7 : 0;
    for (int i = 0; i < n; i++) {
        memset(MEM + p, 0, 316); P32(p, 316);
        uint32_t ofs, type;
        if (kind == 1) {
            if (i == 0) continue;
            put_guid(p + 4, 0x55728220, 0xD33C, 0x11CF, di_d4); ofs = (uint32_t)i; type = 0x0C | ((uint32_t)i << 8);
            snprintf((char *)MEM + p + 32, 260, "%d", i);        // the name Wine reports (configs bind "##<code>")
        } else if (i < 3) {
            put_guid(p + 4, 0xA36D02E0 + (uint32_t)i, 0xC9F3, 0x11CF, di_d4); ofs = 4u * (uint32_t)i; type = 0x01 | ((uint32_t)i << 8);
            snprintf((char *)MEM + p + 32, 260, "%c-axis", "xyz"[i]);
        } else {
            put_guid(p + 4, 0xA36D02F0, 0xC9F3, 0x11CF, di_d4); ofs = 12u + (uint32_t)(i - 3); type = 0x0C | ((uint32_t)(i - 3) << 8);
            snprintf((char *)MEM + p + 32, 260, "Button %d", i - 3);
        }
        P32(p + 20, ofs); P32(p + 24, type);
        uint32_t a[2] = {p, ref};
        if (!host_call(c, cb, 2, a)) break;
    }
    gfree(p);
    RET(c, DI_OK, 4);
}
static void d_GetProperty(CPU *c) {
    uint32_t pr = ARG(c, 1), ph = ARG(c, 2);
    if (pr == 1 /* DIPROP_BUFFERSIZE */) P32(ph + 16, 64); else if (ph) P32(ph + 16, 0);
    RET(c, DI_OK, 3);
}
static void d_SetProperty(CPU *c) { RET(c, DI_OK, 3); }
static void d_Acquire(CPU *c) { RET(c, DI_OK, 1); }
static void d_Unacquire(CPU *c) { RET(c, DI_OK, 1); }
// ---- input state ----------------------------------------------------------------------------------
// Cocoa events (metal.m) arrive through input_key / input_mouse_*. Buffered reads (GetDeviceData) get
// them in order with the offsets of the game's own data format; immediate reads (GetDeviceState) get
// key states and the mouse movement accumulated since the last read.
#include <pthread.h>
static pthread_mutex_t il = PTHREAD_MUTEX_INITIALIZER;
typedef struct { uint8_t dev, obj; int32_t val; uint32_t t; } IEv;          // obj: DIK code, or 0-2 axis / 3+ button
static IEv q[2][512]; static int qh[2], qt[2];
static uint8_t kb_down[256];
static int32_t m_acc[3]; static uint8_t m_btn[8];
static uint32_t seq;
static int kb_fmt;     // the game set a keyboard data format
static int kb_ofs[256], m_axis_ofs[3] = {0, 4, 8}, m_btn_ofs[8] = {12, 13, 14, 15, 16, 17, 18, 19};
__attribute__((constructor)) static void kb_init(void) { for (int i = 0; i < 256; i++) kb_ofs[i] = -1; }
static uint32_t now_ms(void) { return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000ull); }
static void push(int d, int obj, int32_t val) {
    int n = (qt[d] + 1) % 512;
    if (d == 1 && obj < 3 && qh[d] != qt[d]) {               // coalesce consecutive moves on the same axis
        int last = (qt[d] + 511) % 512;
        if (q[d][last].obj == obj) { q[d][last].val += val; return; }
    }
    if (n == qh[d]) return;                                   // full: drop (DirectInput reports overflow)
    q[d][qt[d]] = (IEv){(uint8_t)d, (uint8_t)obj, val, now_ms()}; qt[d] = n;
}
void host_input_mouse(int dx, int dy);
void host_input_button(int b, int down);
void host_input_vkey(int vk, int scan, int down);
// DIK scan code -> Windows virtual-key code (the keys the UI uses)
static uint8_t dik2vk(int k) {
    static const uint8_t row1[] = {0, 0x1B, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 0xBD, 0xBB, 0x08, 0x09,
        'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 0xDB, 0xDD, 0x0D, 0x11, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 0xBA,
        0xDE, 0xC0, 0x10, 0xDC, 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 0xBC, 0xBE, 0xBF, 0x10, 0x6A, 0x12, 0x20, 0x14,
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79};
    if (k < (int)sizeof row1) return row1[k];
    switch (k) { case 0x57: return 0x7A; case 0x58: return 0x7B; case 0x9C: return 0x0D; case 0x9D: return 0x11; case 0xB8: return 0x12;
    case 0xC7: return 0x24; case 0xC8: return 0x26; case 0xC9: return 0x21; case 0xCB: return 0x25; case 0xCD: return 0x27;
    case 0xCF: return 0x23; case 0xD0: return 0x28; case 0xD1: return 0x22; case 0xD2: return 0x2D; case 0xD3: return 0x2E; }
    return 0;
}
void input_key(int dik, int down) {
    if (!dik || dik > 255) return;
    host_input_vkey(dik2vk(dik), dik, down);
    pthread_mutex_lock(&il);
    if (kb_down[dik] != (down ? 1 : 0)) { kb_down[dik] = down ? 1 : 0; push(0, dik, down ? 0x80 : 0); }
    pthread_mutex_unlock(&il);
}
void input_mouse_move(int dx, int dy) {
    host_input_mouse(dx, dy);
    pthread_mutex_lock(&il);
    if (dx) { m_acc[0] += dx; push(1, 0, dx); }
    if (dy) { m_acc[1] += dy; push(1, 1, dy); }
    pthread_mutex_unlock(&il);
}
void input_mouse_wheel(int d) { pthread_mutex_lock(&il); if (d) { m_acc[2] += d; push(1, 2, d); } pthread_mutex_unlock(&il); }
void input_mouse_button(int b, int down) {
    if (b < 0 || b > 7) return;
    host_input_button(b, down);
    pthread_mutex_lock(&il);
    m_btn[b] = down ? 1 : 0; push(1, 3 + b, down ? 0x80 : 0);
    pthread_mutex_unlock(&il);
}
// Test hooks. M1_SCRIPT="<frame>:<cmd>[,<a>[,<b>]];..." feeds input at given frames:
//   m,dx,dy mouse move   d,b / u,b mouse button down/up   k,dik / r,dik key down/up   q quit (= window close)
// M1_TURN_KEY=<DIK> (key goes down at frame M1_TURN_FRAME, default 300) is kept for the gate tests.
// M1_SCRIPT_MS: same syntax, times in ms since the first presented frame; extra command p = dump the back
// buffer at the next flip as m1_t<ms>.png. Each entry fires once, at the first poll at or after its time.
static void test_hooks_ms(void) {
    extern uint64_t host_frames(void);
    extern void gpu_request_dump(unsigned long ms);
    static int init; static char *script; static uint64_t t0; static unsigned char done[256];
    if (!init) { init = 1; if (getenv("M1_SCRIPT_MS")) script = strdup(getenv("M1_SCRIPT_MS")); }
    if (!script || host_frames() == 0) return;
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    if (!t0) t0 = now;
    int idx = 0;
    for (char *p = script; p && *p; idx++) {
        char *next = strchr(p, ';');
        long ms = strtol(p, NULL, 10);
        char *colon = strchr(p, ':');
        if (colon && (!next || colon < next) && idx < 256 && !done[idx] && (long)(now - t0) >= ms) {
            done[idx] = 1;
            char cmd = colon[1]; int a = 0, b = 0;
            char *c1 = strchr(colon, ','); if (c1 && (!next || c1 < next)) { a = atoi(c1 + 1); char *c2 = strchr(c1 + 1, ','); if (c2 && (!next || c2 < next)) b = atoi(c2 + 1); }
            if (cmd == 'm') input_mouse_move(a, b);
            else if (cmd == 'd') input_mouse_button(a, 1);
            else if (cmd == 'u') input_mouse_button(a, 0);
            else if (cmd == 'k') input_key(a, 1);
            else if (cmd == 'r') input_key(a, 0);
            else if (cmd == 'p') gpu_request_dump((unsigned long)ms);
            else if (cmd == 'q') { void host_request_quit(void); host_request_quit(); }
            fprintf(stderr, "[di] script_ms %ld (actual %lld, frame %llu): %c %d %d\n", ms, (long long)(now - t0), (unsigned long long)host_frames(), cmd, a, b);
        }
        p = next ? next + 1 : NULL;
    }
}
static void test_hooks(void) {
    test_hooks_ms();
    extern uint64_t host_frames(void);
    static int init; static char *script; static uint64_t last = ~0ull;
    static int key; static uint32_t at; static int key_done;
    if (!init) {
        init = 1;
        if (getenv("M1_SCRIPT")) script = strdup(getenv("M1_SCRIPT"));
        key = getenv("M1_TURN_KEY") ? atoi(getenv("M1_TURN_KEY")) : 0;
        at = getenv("M1_TURN_FRAME") ? (uint32_t)atol(getenv("M1_TURN_FRAME")) : 300;
    }
    uint64_t f = host_frames();
    if (key && !key_done && f >= at) { key_done = 1; input_key(key, 1); fprintf(stderr, "[di] test key %d down at frame %u\n", key, at); }
    if (!script || f == last) return;
    last = f;
    for (char *p = script; p && *p; ) {
        char *next = strchr(p, ';');
        long fr = strtol(p, NULL, 10);
        char *colon = strchr(p, ':');
        if (colon && (!next || colon < next) && (uint64_t)fr == f) {
            char cmd = colon[1]; int a = 0, b = 0;
            char *c1 = strchr(colon, ','); if (c1 && (!next || c1 < next)) { a = atoi(c1 + 1); char *c2 = strchr(c1 + 1, ','); if (c2 && (!next || c2 < next)) b = atoi(c2 + 1); }
            if (cmd == 'm') input_mouse_move(a, b);
            else if (cmd == 'd') input_mouse_button(a, 1);
            else if (cmd == 'u') input_mouse_button(a, 0);
            else if (cmd == 'k') input_key(a, 1);
            else if (cmd == 'r') input_key(a, 0);
            else if (cmd == 'q') { void host_request_quit(void); host_request_quit(); }
            fprintf(stderr, "[di] script frame %llu: %c %d %d\n", (unsigned long long)f, cmd, a, b);
        }
        p = next ? next + 1 : NULL;
    }
}
static int ofs_of(const IEv *e) {
    if (e->dev == 0) return kb_fmt ? kb_ofs[e->obj] : e->obj;
    return e->obj < 3 ? m_axis_ofs[e->obj] : m_btn_ofs[e->obj - 3];
}
static void d_GetDeviceState(CPU *c) {
    uint32_t n = ARG(c, 1), buf = ARG(c, 2); int d = OKIND(THIS(c)) == 1 ? 0 : 1;
    memset(MEM + buf, 0, n);
    test_hooks();
    pthread_mutex_lock(&il);
    if (d == 0) { for (int k = 1; k < 256; k++) if (kb_down[k]) { int o = kb_fmt ? kb_ofs[k] : k; if (o < 0) continue; if ((uint32_t)o < n) MEM[buf + (uint32_t)o] = 0x80; } }
    else {
        for (int a = 0; a < 3; a++) if (m_axis_ofs[a] >= 0 && (uint32_t)m_axis_ofs[a] + 4 <= n) P32(buf + (uint32_t)m_axis_ofs[a], (uint32_t)m_acc[a]);
        for (int b = 0; b < 8; b++) if (m_btn_ofs[b] >= 0 && (uint32_t)m_btn_ofs[b] < n && m_btn[b]) MEM[buf + (uint32_t)m_btn_ofs[b]] = 0x80;
        m_acc[0] = m_acc[1] = m_acc[2] = 0;
    }
    pthread_mutex_unlock(&il);
    RET(c, DI_OK, 3);
}
static void d_GetDeviceData(CPU *c) {
    uint32_t sz = ARG(c, 1), buf = ARG(c, 2), np = ARG(c, 3), fl = ARG(c, 4); int d = OKIND(THIS(c)) == 1 ? 0 : 1;
    test_hooks();
    uint32_t want = np ? G32(np) : 0, got = 0;
    pthread_mutex_lock(&il);
    int h = qh[d];
    while (h != qt[d] && got < want) {
        IEv *e = &q[d][h];
        if (ofs_of(e) < 0) { h = (h + 1) % 512; continue; }    // object not in the game's data format
        if (buf && sz >= 16) {
            uint32_t r = buf + got * sz;
            P32(r, (uint32_t)ofs_of(e)); P32(r + 4, (uint32_t)e->val); P32(r + 8, e->t); P32(r + 12, ++seq);
        }
        got++; h = (h + 1) % 512;
    }
    if (!(fl & 1)) qh[d] = h;                                  // DIGDD_PEEK keeps them
    if (d == 1 && !(fl & 1)) m_acc[0] = m_acc[1] = m_acc[2] = 0;
    pthread_mutex_unlock(&il);
    if (np) P32(np, got);
    RET(c, DI_OK, 5);
}
// the game's data format: object instance -> offset in its buffer
static void d_SetDataFormat(CPU *c) {
    uint32_t df = ARG(c, 1); int kind = (int)OKIND(THIS(c));
    if (df) {
        uint32_t n = G32(df + 16), objs = G32(df + 20), osz = G32(df + 4) ? G32(df + 4) : 16;
        if (kind == 1) { for (int i = 0; i < 256; i++) kb_ofs[i] = -1; kb_fmt = 1; }
        if (kind == 2) { for (int i = 0; i < 3; i++) m_axis_ofs[i] = -1; for (int i = 0; i < 8; i++) m_btn_ofs[i] = -1; }
        int nb = 0, na = 0;
        for (uint32_t k = 0; k < n; k++) {
            uint32_t o = objs + k * osz, g = G32(o), ofs = G32(o + 4), type = G32(o + 8), inst = (type >> 8) & 0xFFFF;
            if (kind == 1) { if (inst < 256) kb_ofs[inst] = (int)ofs; continue; }
            if (kind != 2) continue;
            uint32_t gd = g ? G32(g) : 0;
            if (getenv("M1_TRACE_DI")) fprintf(stderr, "[di] mouse format obj %u: guid %08x ofs %u type %#x flags %#x\n", k, gd, ofs, type, G32(o + 12));
            if (type & 3) {                                     // axis
                int a = inst < 3 ? (int)inst : gd >= 0xA36D02E0 && gd <= 0xA36D02E2 ? (int)(gd - 0xA36D02E0) : na;
                if (a < 3) m_axis_ofs[a] = (int)ofs;
                na++;
            } else if (type & 0xC) {                            // button
                int b = inst < 8 ? (int)inst : nb;
                if (b < 8) m_btn_ofs[b] = (int)ofs;
                nb++;
            }
        }
    }
    RET(c, DI_OK, 2);
}
static void d_SetEventNotification(CPU *c) { RET(c, DI_OK, 2); }
static void d_SetCooperativeLevel(CPU *c) { RET(c, DI_OK, 3); }
static void d_GetDeviceInfo(CPU *c) { put_instance(ARG(c, 1), (int)OKIND(THIS(c))); RET(c, DI_OK, 2); }
static void d_Poll(CPU *c) { RET(c, DI_OK, 1); }
static const Method dev_m[] = {
    {"QueryInterface", 2, d_QueryInterface}, {"AddRef", 0, i_AddRef}, {"Release", 0, i_Release},
    {"GetCapabilities", 1, d_GetCapabilities}, {"EnumObjects", 3, d_EnumObjects}, {"GetProperty", 2, d_GetProperty},
    {"SetProperty", 2, d_SetProperty}, {"Acquire", 0, d_Acquire}, {"Unacquire", 0, d_Unacquire},
    {"GetDeviceState", 2, d_GetDeviceState}, {"GetDeviceData", 4, d_GetDeviceData}, {"SetDataFormat", 1, d_SetDataFormat},
    {"SetEventNotification", 1, d_SetEventNotification}, {"SetCooperativeLevel", 2, d_SetCooperativeLevel},
    {"GetObjectInfo", 3, NULL}, {"GetDeviceInfo", 1, d_GetDeviceInfo}, {"RunControlPanel", 2, NULL}, {"Initialize", 3, NULL},
    // IDirectInputDevice2A
    {"CreateEffect", 4, NULL}, {"EnumEffects", 3, NULL}, {"GetEffectInfo", 2, NULL}, {"GetForceFeedbackState", 1, NULL},
    {"SendForceFeedbackCommand", 1, NULL}, {"EnumCreatedEffectObjects", 3, NULL}, {"Escape", 1, NULL}, {"Poll", 0, d_Poll},
    {"SendDeviceData", 4, NULL},
};

SHIM(DirectInputCreateA) {
    if (!vt_di) {
        vt_di = com_vtable("IDirectInputA", di_m, (int)(sizeof di_m / sizeof *di_m));
        vt_dev = com_vtable("IDirectInputDeviceA", dev_m, (int)(sizeof dev_m / sizeof *dev_m));
    }
    fprintf(stderr, "[di] DirectInputCreateA(version %#x)\n", ARG(c, 1));
    P32(ARG(c, 2), com_obj(vt_di, 0, 0));
    RET(c, DI_OK, 4);
}
SHIM_TABLE(dinput_shims, E(DirectInputCreateA))
