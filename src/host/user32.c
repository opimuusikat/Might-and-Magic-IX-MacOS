// Headless user32 + gdi32 for MM9: a window that exists only as a handle plus a message queue that runs
// the game's WndProc, and GDI text objects that return sane metrics but draw nothing.
// The message queue and WndProc call are derived from Fallout-NV-MacOS recomp/host/shims_win.c (MIT).
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "shims.h"

#define FAKE_HWND 0x00010010u
#define DESKTOP_HWND 0x00010001u
static uint32_t wndproc;
static int screen_w = 800, screen_h = 600;

typedef struct { uint32_t hwnd, msg, wp, lp; } QMsg;
static QMsg mq[1024]; static int mq_h, mq_t;
static pthread_mutex_t mq_lk = PTHREAD_MUTEX_INITIALIZER;
static void post(uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp) {
    pthread_mutex_lock(&mq_lk);
    int n = (mq_t + 1) % 1024;
    if (n != mq_h) { mq[mq_t] = (QMsg){hwnd, msg, wp, lp}; mq_t = n; }
    pthread_mutex_unlock(&mq_lk);
}
static uint32_t call_wndproc(CPU *c, uint32_t proc, uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp) {
    if (!proc || proc >= 0xF0000000u) return 0;
    uint32_t a[4] = {hwnd, msg, wp, lp};
    return host_call(c, proc, 4, a);
}

SHIM(RegisterClassA) { wndproc = G32(ARG(c, 0) + 4); fprintf(stderr, "[user] RegisterClassA(\"%s\") wndproc %#x\n", GSTR(G32(ARG(c, 0) + 36)) ? GSTR(G32(ARG(c, 0) + 36)) : "", wndproc); RET(c, 0xC001, 1); }
SHIM(CreateWindowExA) {
    fprintf(stderr, "[user] CreateWindowExA(\"%s\", %dx%d) -> headless window\n", GSTR(ARG(c, 2)) ? GSTR(ARG(c, 2)) : "", (int)ARG(c, 6), (int)ARG(c, 7));
    uint32_t cs = gmalloc(48);       // CREATESTRUCTA for WM_CREATE
    P32(cs + 0, ARG(c, 10)); P32(cs + 4, ARG(c, 9)); P32(cs + 8, ARG(c, 8)); P32(cs + 12, ARG(c, 7));
    P32(cs + 16, ARG(c, 6)); P32(cs + 20, ARG(c, 5)); P32(cs + 24, ARG(c, 4)); P32(cs + 28, ARG(c, 3));
    P32(cs + 32, ARG(c, 2)); P32(cs + 36, ARG(c, 1)); P32(cs + 40, ARG(c, 0));
    uint32_t proc = wndproc, hwnd = FAKE_HWND;
    call_wndproc(c, proc, hwnd, 0x0001 /* WM_CREATE */, 0, cs);
    post(hwnd, 0x001C /* WM_ACTIVATEAPP */, 1, 0);
    post(hwnd, 0x0006 /* WM_ACTIVATE */, 1, 0);
    post(hwnd, 0x0007 /* WM_SETFOCUS */, 0, 0);
    RET(c, hwnd, 12);
}
SHIM(ShowWindow) { RET(c, 1, 2); }
SHIM(UpdateWindow) { RET(c, 1, 1); }
SHIM(SetWindowPos) { RET(c, 1, 7); }
SHIM(GetWindowLongA) { int32_t i = (int32_t)ARG(c, 1); RET(c, i == -4 ? wndproc : i == -16 ? 0x10000000u : 0, 2); }
SHIM(SetWindowLongA) {
    int32_t i = (int32_t)ARG(c, 1); uint32_t old = 0;
    if (i == -4) { old = wndproc; wndproc = ARG(c, 2); fprintf(stderr, "[user] SetWindowLongA(GWL_WNDPROC, %#x)\n", wndproc); }
    RET(c, old, 3);
}
SHIM(GetClassLongA) { RET(c, 0, 2); }
SHIM(CallWindowProcA) { uint32_t r = call_wndproc(c, ARG(c, 0), ARG(c, 1), ARG(c, 2), ARG(c, 3), ARG(c, 4)); RET(c, r, 5); }
// WM_CLOSE: what Windows' DefWindowProc does (DestroyWindow -> WM_DESTROY, where the game posts its quit).
SHIM(DefWindowProcA) {
    if (ARG(c, 1) == 0x0010) { fprintf(stderr, "[user] DefWindowProc(WM_CLOSE) -> WM_DESTROY\n"); call_wndproc(c, wndproc, ARG(c, 0), 0x0002, 0, 0); }
    RET(c, 0, 4);
}
SHIM(GetActiveWindow) { RET(c, FAKE_HWND, 0); }
SHIM(GetDesktopWindow) { RET(c, DESKTOP_HWND, 0); }
SHIM(SetFocus) { RET(c, FAKE_HWND, 1); }
SHIM(IsIconic) { RET(c, 0, 1); }
static void put_rect(uint32_t r, int l, int t, int rr, int b) { P32(r, (uint32_t)l); P32(r + 4, (uint32_t)t); P32(r + 8, (uint32_t)rr); P32(r + 12, (uint32_t)b); }
SHIM(GetClientRect) { put_rect(ARG(c, 1), 0, 0, screen_w, screen_h); RET(c, 1, 2); }
SHIM(GetWindowRect) { if (ARG(c, 0) == DESKTOP_HWND) put_rect(ARG(c, 1), 0, 0, 1920, 1080); else put_rect(ARG(c, 1), 0, 0, screen_w, screen_h); RET(c, 1, 2); }
SHIM(AdjustWindowRect) { RET(c, 1, 3); }
SHIM(ClientToScreen) { RET(c, 1, 2); }
SHIM(ScreenToClient) { RET(c, 1, 2); }
SHIM(ClipCursor) { RET(c, 1, 1); }
// ---- input as window messages: a virtual cursor in client (= screen) coordinates -----------------------
static int cur_x, cur_y; static uint32_t btn_flags;
static pthread_mutex_t cur_lk = PTHREAD_MUTEX_INITIALIZER;
static uint32_t cur_lparam(void) { return ((uint32_t)(cur_y & 0xFFFF) << 16) | (uint32_t)(cur_x & 0xFFFF); }
void host_input_mouse(int dx, int dy) {
    pthread_mutex_lock(&cur_lk);
    cur_x += dx; cur_y += dy;
    if (cur_x < 0) cur_x = 0; if (cur_x >= screen_w) cur_x = screen_w - 1;
    if (cur_y < 0) cur_y = 0; if (cur_y >= screen_h) cur_y = screen_h - 1;
    uint32_t lp = cur_lparam(), wp = btn_flags;
    pthread_mutex_unlock(&cur_lk);
    post(FAKE_HWND, 0x0200 /* WM_MOUSEMOVE */, wp, lp);
}
void host_input_button(int b, int down) {
    static const uint32_t mk[3] = {1, 2, 0x10};                    // MK_LBUTTON, MK_RBUTTON, MK_MBUTTON
    static const uint32_t dn[3] = {0x201, 0x204, 0x207};
    if (b < 0 || b > 2) return;
    pthread_mutex_lock(&cur_lk);
    if (down) btn_flags |= mk[b]; else btn_flags &= ~mk[b];
    uint32_t lp = cur_lparam(), wp = btn_flags;
    pthread_mutex_unlock(&cur_lk);
    post(FAKE_HWND, dn[b] + (down ? 0 : 1), wp, lp);
}
static uint8_t vk_down[256];
void host_input_vkey(int vk, int scan, int down) {
    if (vk <= 0 || vk > 255) return;
    uint32_t lp = 1u | ((uint32_t)(scan & 0xFF) << 16) | (vk_down[vk] && down ? 1u << 30 : 0) | (down ? 0 : 3u << 30);
    vk_down[vk] = down ? 1 : 0;
    post(FAKE_HWND, down ? 0x0100 : 0x0101, (uint32_t)vk, lp);
}
// A clean quit (window close button, Cmd+Q, M1_SCRIPT 'q'): WM_CLOSE to the game's window, as Windows
// sends it, so the engine shuts down its own way (which rewrites autoexec.cfg). Exits anyway if the game
// is still running 10 s later.
void host_request_quit(void) {
    static int once; if (once++) return;
    fprintf(stderr, "[user] quit requested: WM_CLOSE\n");
    post(FAKE_HWND, 0x0010, 0, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
        fprintf(stderr, "[user] still running 10 s after WM_CLOSE: exit\n"); _exit(0); });
}
void host_input_char(int ch) { if (ch > 0 && ch < 256) post(FAKE_HWND, 0x0102 /* WM_CHAR */, (uint32_t)ch, 1); }
SHIM(GetCursorPos) { pthread_mutex_lock(&cur_lk); P32(ARG(c, 0), (uint32_t)cur_x); P32(ARG(c, 0) + 4, (uint32_t)cur_y); pthread_mutex_unlock(&cur_lk); RET(c, 1, 1); }
SHIM(SetCursorPos) { pthread_mutex_lock(&cur_lk); cur_x = (int)ARG(c, 0); cur_y = (int)ARG(c, 1); pthread_mutex_unlock(&cur_lk); RET(c, 1, 2); }
SHIM(SetCursor) { RET(c, 0, 1); }
static int cursor_count;
SHIM(ShowCursor) { cursor_count += ARG(c, 0) ? 1 : -1; RET(c, (uint32_t)cursor_count, 1); }
SHIM(SetCapture) { RET(c, 0, 1); }
SHIM(ReleaseCapture) { RET(c, 1, 0); }
SHIM(GetCapture) { RET(c, 0, 0); }
SHIM(LoadIconA) { RET(c, 0x00020001, 2); }
SHIM(LoadCursorA) { RET(c, 0x00020002, 2); }
SHIM(LoadImageA) { RET(c, 0x00020003, 6); }
SHIM(GetDoubleClickTime) { RET(c, 500, 0); }
SHIM(GetAsyncKeyState) { uint32_t k = ARG(c, 0) & 255; RET(c, vk_down[k] ? 0x8000u : 0, 1); }
SHIM(GetKeyState) { uint32_t k = ARG(c, 0) & 255; RET(c, vk_down[k] ? 0xFF80u : 0, 1); }
SHIM(GetKeyboardState) { memset(MEM + ARG(c, 0), 0, 256); RET(c, 1, 1); }
SHIM(ToAscii) { RET(c, 0, 5); }
SHIM(OpenClipboard) { RET(c, 0, 1); }
SHIM(CloseClipboard) { RET(c, 1, 0); }
SHIM(IsClipboardFormatAvailable) { RET(c, 0, 1); }
SHIM(GetClipboardData) { RET(c, 0, 1); }
SHIM(BeginPaint) { uint32_t ps = ARG(c, 1); memset(MEM + ps, 0, 64); P32(ps, 0x00030001); RET(c, 0x00030001, 2); }
SHIM(EndPaint) { RET(c, 1, 2); }
SHIM(GetDC) { RET(c, 0x00030001, 1); }
SHIM(ReleaseDC) { RET(c, 1, 2); }
SHIM(MessageBoxA) {
    fprintf(stderr, "[user] MessageBoxA: \"%s\" — %s\n", GSTR(ARG(c, 2)) ? GSTR(ARG(c, 2)) : "", GSTR(ARG(c, 1)) ? GSTR(ARG(c, 1)) : "");
    RET(c, 1, 4);
}
SHIM(PostMessageA) { post(ARG(c, 0), ARG(c, 1), ARG(c, 2), ARG(c, 3)); RET(c, 1, 4); }
SHIM(PostQuitMessage) { fprintf(stderr, "[user] PostQuitMessage(%u)\n", ARG(c, 0)); post(0, 0x0012, ARG(c, 0), 0); RET(c, 0, 1); }
void host_pump_events(void);
SHIM(PeekMessageA) {
    host_pump_events();
    uint32_t m = ARG(c, 0), remove = ARG(c, 4) & 1;
    pthread_mutex_lock(&mq_lk);
    if (mq_h == mq_t) { pthread_mutex_unlock(&mq_lk); RET(c, 0, 5); return; }
    QMsg q = mq[mq_h];
    if (remove) mq_h = (mq_h + 1) % 1024;
    pthread_mutex_unlock(&mq_lk);
    P32(m, q.hwnd); P32(m + 4, q.msg); P32(m + 8, q.wp); P32(m + 12, q.lp);
    P32(m + 16, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000)); P32(m + 20, 400); P32(m + 24, 300);
    RET(c, 1, 5);
}
SHIM(TranslateMessage) { RET(c, 0, 1); }
SHIM(DispatchMessageA) {
    uint32_t m = ARG(c, 0);
    uint32_t r = G32(m + 4) == 0x0012 ? 0 : call_wndproc(c, wndproc, G32(m), G32(m + 4), G32(m + 8), G32(m + 12));
    RET(c, r, 1);
}

SHIM_TABLE(user_shims,
    E(RegisterClassA) E(CreateWindowExA) E(ShowWindow) E(UpdateWindow) E(SetWindowPos) E(GetWindowLongA)
    E(SetWindowLongA) E(GetClassLongA) E(CallWindowProcA) E(DefWindowProcA) E(GetActiveWindow) E(GetDesktopWindow)
    E(SetFocus) E(IsIconic) E(GetClientRect) E(GetWindowRect) E(AdjustWindowRect) E(ClientToScreen) E(ScreenToClient)
    E(ClipCursor) E(GetCursorPos) E(SetCursorPos) E(SetCursor) E(ShowCursor) E(SetCapture) E(ReleaseCapture)
    E(GetCapture) E(LoadIconA) E(LoadCursorA) E(LoadImageA) E(GetDoubleClickTime) E(GetAsyncKeyState) E(GetKeyState)
    E(GetKeyboardState) E(ToAscii) E(OpenClipboard) E(CloseClipboard) E(IsClipboardFormatAvailable)
    E(GetClipboardData) E(BeginPaint) E(EndPaint) E(GetDC) E(ReleaseDC) E(MessageBoxA) E(PostMessageA)
    E(PostQuitMessage) E(PeekMessageA) E(TranslateMessage) E(DispatchMessageA))

// ---- gdi32: fonts and DIB sections for the engine's text rendering ---------------------------------
#define GDI_BASE 0x00440000u
typedef struct { int type; int height, width; uint32_t bits; } GObj;   // type 1 font, 2 dc, 3 bitmap, 4 stock
static GObj gobj[4096]; static int ngobj;
static pthread_mutex_t g_lk = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gnew(int type) { pthread_mutex_lock(&g_lk); int i = ngobj < 4095 ? ++ngobj : 4095; gobj[i] = (GObj){type, 0, 0, 0}; pthread_mutex_unlock(&g_lk); return GDI_BASE + 4 * (uint32_t)i; }
static GObj *gget(uint32_t h) { uint32_t i = (h - GDI_BASE) / 4; return h >= GDI_BASE && i <= 4095 && i > 0 ? &gobj[i] : NULL; }
static uint32_t dc_font[4096];

SHIM(AddFontResourceA) { RET(c, 1, 1); }
SHIM(RemoveFontResourceA) { RET(c, 1, 1); }
SHIM(CreateCompatibleDC) { RET(c, gnew(2), 1); }
SHIM(DeleteDC) { RET(c, 1, 1); }
SHIM(DeleteObject) { RET(c, 1, 1); }
SHIM(GetStockObject) { RET(c, gnew(4), 1); }
SHIM(CreateFontA) {
    uint32_t h = gnew(1); GObj *o = gget(h);
    int32_t ht = (int32_t)ARG(c, 0), wd = (int32_t)ARG(c, 1);
    o->height = ht < 0 ? -ht : ht ? ht : 16; o->width = wd > 0 ? wd : (o->height + 1) / 2;
    RET(c, h, 14);
}
SHIM(CreateDIBSection) {
    uint32_t bmi = ARG(c, 1), ppv = ARG(c, 3);
    int32_t w = (int32_t)G32(bmi + 4), h = (int32_t)G32(bmi + 8); uint32_t bpp = G16(bmi + 14);
    if (h < 0) h = -h;
    uint32_t pitch = (((uint32_t)w * bpp + 31) / 32) * 4;
    uint32_t hb = gnew(3); GObj *o = gget(hb);
    o->bits = gmalloc(pitch * (uint32_t)h + 16); o->width = w; o->height = h;
    if (ppv) P32(ppv, o->bits);
    RET(c, hb, 6);
}
SHIM(SelectObject) {
    uint32_t dc = ARG(c, 0), h = ARG(c, 1); GObj *o = gget(h);
    uint32_t prev = 0, di = (dc - GDI_BASE) / 4;
    if (o && o->type == 1 && di < 4096) { prev = dc_font[di]; dc_font[di] = h; }
    RET(c, prev ? prev : gnew(4), 2);
}
SHIM(GetDeviceCaps) {
    uint32_t i = ARG(c, 1), r = 0;
    switch (i) { case 8: r = (uint32_t)screen_w; break; case 10: r = (uint32_t)screen_h; break; case 12: r = 32; break; case 14: r = 1; break;
                 case 88: case 90: r = 96; break; case 116: r = 60; break; default: r = 0; }
    RET(c, r, 2);
}
SHIM(GetTextExtentPoint32A) {
    uint32_t dc = ARG(c, 0), n = ARG(c, 2), sz = ARG(c, 3), di = (dc - GDI_BASE) / 4;
    GObj *f = di < 4096 ? gget(dc_font[di]) : NULL;
    int h = f ? f->height : 16, w = f ? f->width : 8;
    P32(sz, n * (uint32_t)w); P32(sz + 4, (uint32_t)h);
    RET(c, 1, 4);
}
SHIM(TextOutA) { RET(c, 1, 5); }
SHIM(Rectangle) { RET(c, 1, 5); }
SHIM(SetBkColor) { RET(c, 0, 2); }
SHIM(SetTextColor) { RET(c, 0xFFFFFF, 2); }
SHIM(SetBkMode) { RET(c, 1, 2); }
SHIM(GetTextCharacterExtra) { RET(c, 0, 1); }
SHIM(SetTextCharacterExtra) { RET(c, 0, 2); }

SHIM_TABLE(gdi_shims,
    E(AddFontResourceA) E(RemoveFontResourceA) E(CreateCompatibleDC) E(DeleteDC) E(DeleteObject) E(GetStockObject)
    E(CreateFontA) E(CreateDIBSection) E(SelectObject) E(GetDeviceCaps) E(GetTextExtentPoint32A) E(TextOutA)
    E(Rectangle) E(SetBkColor) E(SetTextColor) E(SetBkMode) E(GetTextCharacterExtra) E(SetTextCharacterExtra))
