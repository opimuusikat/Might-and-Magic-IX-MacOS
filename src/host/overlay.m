// In-game graphics settings overlay: state, key handling and the panel bitmap (text drawn with AppKit).
// metal.m owns the GPU side (texture + a second pass over the presented image). Opened with Cmd+, / app menu
// "Settings..." / M1_SCRIPT_MS command `o`; Up/Down select a row, Left/Right change it, Esc or Return close.
// Changes go through gpu_settings_set_one (applied at the next frame boundary, saved to the defaults unless
// M1_NO_PERSIST=1). While open the overlay swallows keys (overlay_filter_key) and metal.m swallows the mouse.
#import <AppKit/AppKit.h>
#include <stdio.h>
#include "d3d_int.h"

int gpu_msaa_ok(int n);

#define NROWS 8
static volatile int open_, sel, version = 1;
static int val[NROWS];                  // index into the option list of each row
static uint8_t swallowed[256];          // keys whose down went to the overlay: their up is swallowed too

static const char *const labels[NROWS] = {"Resolution", "Anti-aliasing", "Anisotropic filtering", "Trilinear filtering", "HD textures (replace)",
                                          "Dump textures", "Frame rate cap (after restart)", "Close"};
static int nopt(int row) { return row == 0 ? 5 : row == 1 ? 4 : row == 2 ? 5 : row == 6 ? 2 : row == 7 ? 0 : 2; }
static int optval(int row, int i) {     // the setting value of option i
    static const int res[] = {1, 2, 3, 4, 0}, aa[] = {1, 2, 4, 8}, an[] = {1, 2, 4, 8, 16}, fps[] = {60, 120};
    switch (row) { case 0: return res[i]; case 1: return aa[i]; case 2: return an[i]; case 6: return fps[i]; default: return i; }
}
static NSString *optname(int row, int i) {
    int v = optval(row, i);
    switch (row) {
    case 0: return v ? [NSString stringWithFormat:@"%dx", v] : @"Auto";
    case 1: return v == 1 ? @"Off" : [NSString stringWithFormat:@"%dx", v];
    case 2: return v == 1 ? @"Off" : [NSString stringWithFormat:@"%dx", v];
    case 6: return [NSString stringWithFormat:@"%d", v];
    default: return v ? @"On" : @"Off";
    }
}
static int find_opt(int row, int v) { for (int i = 0; i < nopt(row); i++) if (optval(row, i) == v) return i; return 0; }
static void load_values(void) {
    int sc, ms, an, tri, rep, dump;
    gpu_settings_get(&sc, &ms, &an, &tri, &rep, &dump, NULL);
    int mf = host_maxfps_setting();
    val[0] = find_opt(0, sc); val[1] = find_opt(1, ms); val[2] = find_opt(2, an);
    val[3] = tri ? 1 : 0; val[4] = rep ? 1 : 0; val[5] = dump ? 1 : 0; val[6] = find_opt(6, mf == 120 ? 120 : 60);
}
int overlay_is_open(void) { return open_; }
int overlay_version(void) { return version; }
void overlay_toggle(void) {
    if (!open_) { load_values(); sel = 0; }
    open_ = !open_; version++;
}
static void change(int dir) {
    int r = sel; if (r >= 7) return;
    int n = nopt(r); val[r] = (val[r] + dir + n) % n;
    int v = optval(r, val[r]);
    if (r == 1 && v > 1) {               // skip unsupported MSAA counts
        for (int k = 0; k < n && !gpu_msaa_ok(optval(1, val[1])); k++) val[1] = (val[1] + dir + n) % n;
        v = optval(1, val[1]);
    }
    switch (r) { case 0: gpu_settings_set_one(1, v); break; case 1: gpu_settings_set_one(2, v); break; case 2: gpu_settings_set_one(3, v); break;
    case 3: gpu_settings_set_one(4, v); break; case 4: gpu_settings_set_one(5, v); break; case 5: gpu_settings_set_one(6, v); break;
    case 6: host_maxfps_set(v); break; }
}
static void overlay_key(int dik) {
    switch (dik) {
    case 0xC8: sel = (sel + NROWS - 1) % NROWS; break;
    case 0xD0: sel = (sel + 1) % NROWS; break;
    case 0xCB: change(-1); break;
    case 0xCD: if (sel == 7) open_ = 0; else change(1); break;
    case 0x01: case 0x1C: case 0x9C: open_ = 0; break;
    default: return;
    }
    version++;
}
// Returns 1 if the key event belongs to the overlay (not for the game). repeat: auto-repeat of a held key.
int overlay_filter_key(int dik, int down, int repeat) {
    (void)repeat;
    if (dik < 0 || dik > 255) return 0;
    if (down) { if (!open_) return 0; swallowed[dik] = 1; overlay_key(dik); return 1; }
    if (swallowed[dik]) { swallowed[dik] = 0; return 1; }
    return 0;
}

// Panel bitmap: 420x300 logical units at `scale` pixels per unit, BGRA8 premultiplied. Caller frees *px.
void overlay_size(int *w, int *h) { *w = 420; *h = 300; }
uint8_t *overlay_render(int scale) {
    int lw = 420, lh = 300, pw = lw * scale, ph = lh * scale;
    uint8_t *px = calloc((size_t)pw * ph, 4);
    if (!px) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, pw, ph, 8, (size_t)pw * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    @autoreleasepool {
        CGContextTranslateCTM(c, 0, ph); CGContextScaleCTM(c, scale, -scale);      // top-left origin, logical units
        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:c flipped:YES];
        [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:g];
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1, lw - 2, lh - 2) xRadius:10 yRadius:10];
        [[NSColor colorWithCalibratedRed:0.04 green:0.05 blue:0.08 alpha:0.86] setFill]; [bg fill];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.35] setStroke]; bg.lineWidth = 1; [bg stroke];
        NSColor *fg = [NSColor colorWithCalibratedWhite:0.94 alpha:1], *dim = [NSColor colorWithCalibratedWhite:0.65 alpha:1];
        NSDictionary *tA = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:16], NSForegroundColorAttributeName: fg};
        [@"Graphics settings (Cmd+,)" drawAtPoint:NSMakePoint(22, 14) withAttributes:tA];
        NSFont *rf = [NSFont systemFontOfSize:14];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentRight;
        for (int r = 0; r < NROWS; r++) {
            CGFloat y = 48 + r * 26;
            if (r == sel) {
                NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(12, y - 2, lw - 24, 24) xRadius:5 yRadius:5];
                [[NSColor colorWithCalibratedRed:0.20 green:0.42 blue:0.85 alpha:0.75] setFill]; [hl fill];
            }
            NSColor *col = (r == 6 && r != sel) ? dim : fg;
            [@(labels[r]) drawAtPoint:NSMakePoint(24, y + 1) withAttributes:@{NSFontAttributeName: rf, NSForegroundColorAttributeName: col}];
            if (r < 7) {
                NSString *v = [NSString stringWithFormat:@"‹ %@ ›", optname(r, val[r])];
                [v drawInRect:NSMakeRect(lw / 2, y + 1, lw / 2 - 24, 20) withAttributes:@{NSFontAttributeName: rf, NSForegroundColorAttributeName: col, NSParagraphStyleAttributeName: ps}];
            }
        }
        NSMutableParagraphStyle *pc = [NSMutableParagraphStyle new]; pc.alignment = NSTextAlignmentCenter;
        [@"↑↓ select    ←→ change    Esc close" drawInRect:NSMakeRect(0, lh - 28, lw, 18)
            withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: dim, NSParagraphStyleAttributeName: pc}];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGContextRelease(c);
    return px;
}
