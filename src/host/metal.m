// Metal backend for the Direct3D 7 subset MM9 uses (docs/recomp-m0.md section 8): pre-transformed
// XYZRHW vertices, two texture stages, alpha blend/test, Z, fog, DXT and 16/32-bit textures.
// Window setup, event pump, the macOS keycode table, the PNG dump and the 16-bit format mapping
// follow Fallout-NV-MacOS recomp/host/d3d9_metal.m (MIT, (c) 2026 thetheoryofR).
//
// Model: one render pass per frame into an 800x600 back buffer texture (+ Depth32Float). Every draw
// is converted on the CPU into a per-frame vertex ring (fans become lists), state comes from the
// D3D7 state the front end tracks (DevState), textures are (re)uploaded from guest memory when the
// game unlocked them. Flip copies the back buffer to the window's drawable.
//
// Env: M1_NULL=1 null device (headless gate), M1_OFFSCREEN=1 render without a window,
//      M1_DUMP=<frame,frame,...> save those frames as m1_frame_<n>.png, M1_NOVSYNC=1.
//      M1_NOCULL=1 ignore D3DRENDERSTATE_CULLMODE (always cull none), M1_NOCOLORKEY=1 ignore
//      D3DRENDERSTATE_COLORKEYENABLE (texture source colour keys stay opaque),
//      M1_TRACE_CK=1 print render-state / colour-key usage counters (every 50000 draws and at exit).
//      M1_TRACE_FILT=1 print which texture filter combos (mag/min/mip) the game binds, and how many are mipmapped.
//      M1_TEXDUMP=1 (key TextureDump): hash every uploaded texture and dump each distinct one once as
//        <TextureDir>/dump/<hash>.png + index.tsv. M1_TEXDIR=<path> (key TextureDir, default HDTextures in the
//        game folder). Details in texpack.m. Off by default: no hashing then.
//      M1_TEXREPLACE=1 (key TextureReplace): upload <TextureDir>/replace/<hash>.png|.dds instead of the original
//        texture when one exists for the texture's content hash (any size; PNG gets generated mips, DDS DXT1/3/5
//        or BGRA8 uses the file's mips). Alpha: a no-alpha original (565, XRGB*) stays opaque; for colour-keyed
//        originals the replacement's alpha 0 is the key. Dynamic textures are never replaced.
//      Settings overlay: Cmd+, (app menu "Settings...") opens a panel over the picture (overlay.m): Up/Down select,
//        Left/Right change (live, saved to the defaults), Esc/Return close. While open, keys and the mouse do not
//        reach the game. M1_SCRIPT_MS command `o` toggles it; scripted k (key down) then drives it.
//        M1_NO_PERSIST=1 keeps setting changes out of the defaults (tests).
// Image quality (each also a defaults key in local.mm9-native; the env var wins, then the key, then the default):
//      M1_SCALE=1..4|auto (key RenderScale, 0 = auto): internal render scale. Back buffer, depth and drawable
//        are W*S x H*S; vertex coordinates stay 800x600 (the `size` uniform), so 3D and 2D scale together. The game
//        still sees 800x600 (readback is box-filtered down); M1_DUMP png files have the full internal size.
//        auto = ceil(main screen backing pixel height / H), 1 offscreen. Default 1.
//      M1_MSAA=1|2|4|8 (key MSAA): multisample count (lowered to what the device supports). Default 1.
//      M1_ANISO=1..16 (key Anisotropy): max anisotropy for linear-min-filtered mipmapped textures. Default 1
//        (anisotropy 4 only when the game asks for it).
//      M1_TRILINEAR=0|1 (key Trilinear): mipmapped textures with a linear min filter blend between mip levels
//        even when the game asked for point/none mip filtering. Default 0.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "host.h"
#include "d3d_int.h"

void input_key(int dik, int down);
void input_mouse_move(int dx, int dy);
void input_mouse_button(int b, int down);
void input_mouse_wheel(int d);
void host_input_char(int ch);

static int on_ = -1;
int gpu_on(void) { if (on_ < 0) on_ = getenv("M1_NULL") == NULL; return on_; }

static id<MTLDevice> mdev;
static id<MTLCommandQueue> queue;
static CAMetalLayer *layer;
static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static id<MTLTexture> bb, depth;
static uint32_t W, H;
static int rt_surf = -1;
static dispatch_semaphore_t inflight;
#define RING (32u << 20)
static id<MTLBuffer> ring[3];
static uint32_t ring_i, ring_off;
static id<MTLFunction> vfn, ffn;
static MTLVertexDescriptor *vdesc;
static id<MTLRenderPipelineState> pso[512];
static id<MTLDepthStencilState> dss[64];
static id<MTLSamplerState> samp[4096];
static NSMutableArray *texs;
static NSMutableDictionary *ktex;           // root surface index -> keyed BGRA8 variant (nil entry: rebuild)
static id<MTLTexture> white;
static pthread_mutex_t lk;
static int pending_clear = 3; static uint32_t clear_color; static float clear_z = 1.0f;
static uint64_t frames;
static int ready;
static int SC = 1, MS = 1, ANI = 1, TRI = 0;    // render scale, MSAA samples, anisotropy, trilinear (fixed per run)
static int SCREQ;                                  // render scale as set (0 = auto)
static uint32_t BW, BH;                            // internal back buffer size = W*SC x H*SC
static id<MTLTexture> ms_col, ms_depth;            // multisample colour/depth (MS > 1); bb is then the resolve target
static id<MTLTexture> rb_tex;                      // W x H BGRA8 for the readback downsample
static id<MTLRenderPipelineState> down_pso, ov_pso;
static id<MTLTexture> ov_tex; static int ov_ver = -1, ov_sc;
static uint64_t rt_gen = 1;               // bumped by everything that changes the back buffer (see gpu_readback)

static void lk_init(void) { pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&lk, &a); }
static pthread_once_t lk_once = PTHREAD_ONCE_INIT;
#define LOCK pthread_once(&lk_once, lk_init); pthread_mutex_lock(&lk);
#define UNLOCK pthread_mutex_unlock(&lk);

typedef struct { float x, y, z, rhw; uint32_t diffuse, specular; float u0, v0, u1, v1; } GV;   // 40 bytes
typedef struct {
    int c0[4], a0[4], c1[4], a1[4];         // op, arg1, arg2, (arg0 unused) for colour/alpha of stage 0/1
    int atest, afunc; float aref; int spec;
    int fog, fogmode; float fogstart, fogend;
    float fogcolor[4]; float tfactor[4];
    int tex0, tex1, tci1, ckey;             // ckey: bit 0/1 = stage 0/1 samples a colour-keyed texture (alpha 0 = key)
} FU;

static const char *msl =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VIn { float4 p [[attribute(0)]]; float4 d [[attribute(1)]]; float4 s [[attribute(2)]]; float2 t0 [[attribute(3)]]; float2 t1 [[attribute(4)]]; };\n"
"struct VOut { float4 pos [[position]]; float4 d; float4 s; float2 t0; float2 t1; float w; };\n"
"vertex VOut vs(VIn in [[stage_in]], constant float2 &size [[buffer(1)]]) {\n"
"  VOut o; float w = in.p.w > 0.0 ? 1.0 / in.p.w : 1.0; if (!isfinite(w)) w = 1.0;\n"
"  float x = (in.p.x + 0.5) / size.x * 2.0 - 1.0, y = 1.0 - (in.p.y + 0.5) / size.y * 2.0;\n"
"  o.pos = float4(x * w, y * w, in.p.z * w, w); o.d = in.d; o.s = in.s; o.t0 = in.t0; o.t1 = in.t1; o.w = w; return o; }\n"
"struct FU { int4 c0, a0, c1, a1; int atest, afunc; float aref; int spec; int fog, fogmode; float fogstart, fogend;\n"
"  float4 fogcolor; float4 tfactor; int tex0, tex1, tci1, ckey; };\n"
"static float4 arg(int a, float4 dif, float4 cur, float4 tex, float4 tf, float4 spc) {\n"
"  int s = a & 15; float4 v = s == 0 ? dif : s == 1 ? cur : s == 2 ? tex : s == 3 ? tf : spc;\n"
"  if (a & 16) v = 1.0 - v; if (a & 32) v = v.aaaa; return v; }\n"
"static float4 op(int o, float4 x, float4 y, float4 dif, float4 tex, float4 cur, float4 tf) {\n"
"  switch (o) { case 2: return x; case 3: return y; case 4: return x * y; case 5: return x * y * 2.0; case 6: return x * y * 4.0;\n"
"  case 7: return x + y; case 8: return x + y - 0.5; case 9: return (x + y - 0.5) * 2.0; case 10: return x - y;\n"
"  case 11: return x + y - x * y; case 12: return mix(y, x, dif.a); case 13: return mix(y, x, tex.a); case 14: return mix(y, x, tf.a);\n"
"  case 15: return x + y * (1.0 - tex.a); case 16: return mix(y, x, cur.a); default: return x; } }\n"
"fragment float4 fs(VOut in [[stage_in]], constant FU &u [[buffer(0)]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],\n"
"                   sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]]) {\n"
"  float4 dif = in.d, spc = in.s, tf = u.tfactor, cur = dif;\n"
"  if (u.c0.x != 1) {\n"
"    float4 tx = u.tex0 ? t0.sample(s0, in.t0) : float4(1.0);\n"
"    if ((u.ckey & 1) && tx.a < 0.002) discard_fragment();\n"
"    float4 c = op(u.c0.x, arg(u.c0.y, dif, cur, tx, tf, spc), arg(u.c0.z, dif, cur, tx, tf, spc), dif, tx, cur, tf);\n"
"    float4 a = u.a0.x != 1 ? op(u.a0.x, arg(u.a0.y, dif, cur, tx, tf, spc), arg(u.a0.z, dif, cur, tx, tf, spc), dif, tx, cur, tf) : cur;\n"
"    cur = saturate(float4(c.rgb, a.a));\n"
"    if (u.c1.x != 1) {\n"
"      float4 tx1 = u.tex1 ? t1.sample(s1, u.tci1 ? in.t1 : in.t0) : float4(1.0);\n"
"      if ((u.ckey & 2) && tx1.a < 0.002) discard_fragment();\n"
"      float4 c1 = op(u.c1.x, arg(u.c1.y, dif, cur, tx1, tf, spc), arg(u.c1.z, dif, cur, tx1, tf, spc), dif, tx1, cur, tf);\n"
"      float4 a1 = u.a1.x != 1 ? op(u.a1.x, arg(u.a1.y, dif, cur, tx1, tf, spc), arg(u.a1.z, dif, cur, tx1, tf, spc), dif, tx1, cur, tf) : cur;\n"
"      cur = saturate(float4(c1.rgb, a1.a));\n"
"    }\n"
"  }\n"
"  if (u.spec) cur.rgb = saturate(cur.rgb + spc.rgb);\n"
"  if (u.fog) { float f = spc.a; if (u.fogmode == 3) f = saturate((u.fogend - in.w) / max(u.fogend - u.fogstart, 1e-6));\n"
"    cur.rgb = mix(u.fogcolor.rgb, cur.rgb, f); }\n"
"  if (u.atest) { float a = round(cur.a * 255.0), r = u.aref; bool pass;\n"
"    switch (u.afunc) { case 1: pass = false; break; case 2: pass = a < r; break; case 3: pass = a == r; break; case 4: pass = a <= r; break;\n"
"    case 5: pass = a > r; break; case 6: pass = a != r; break; case 7: pass = a >= r; break; default: pass = true; }\n"
"    if (!pass) discard_fragment(); }\n"
"  return cur; }\n"
// readback downsample: box average of SC x SC back buffer texels per logical pixel
"struct DOut { float4 pos [[position]]; };\n"
"vertex DOut dvs(uint vid [[vertex_id]]) { DOut o; float2 p = float2((vid << 1) & 2, vid & 2); o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
"fragment float4 dfs(DOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant int &sc [[buffer(0)]]) {\n"
"  uint2 b = uint2(in.pos.xy) * uint(sc); float4 sum = 0;\n"
"  for (int j = 0; j < sc; j++) for (int i = 0; i < sc; i++) sum += src.read(b + uint2(i, j));\n"
"  return sum / float(sc * sc); }\n"
// settings overlay panel: textured quad (premultiplied BGRA), rect = left, top, right, bottom in NDC
"struct OOut { float4 pos [[position]]; float2 uv; };\n"
"vertex OOut ovs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
"  float2 p = float2(vid & 1, vid >> 1); OOut o; o.pos = float4(mix(r.x, r.z, p.x), mix(r.y, r.w, p.y), 0.0, 1.0); o.uv = p; return o; }\n"
"fragment float4 ofs(OOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n";

// ---- window ----------------------------------------------------------------------------------------
// Native fullscreen (green button, Ctrl+Cmd+F or the Window menu): the 800x600 back buffer is scaled
// aspect-correct with black bars (kCAGravityResizeAspect). The last fullscreen state is remembered in the
// defaults domain local.mm9-native (StartFullscreen); M1_FULLSCREEN=1/0 overrides it for one start.
#define PREF_DOMAIN CFSTR("local.mm9-native")
static NSWindow *window;
static int start_fs;                       // fullscreen requested at start: not a user choice, not saved
@interface M1View : NSView
@end
@implementation M1View
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { (void)e; }  // Cmd+key without a menu item: no beep
@end
@interface M1WinDelegate : NSObject <NSWindowDelegate>
@end
static void save_fs(int on) {
    CFPreferencesSetAppValue(CFSTR("StartFullscreen"), on ? kCFBooleanTrue : kCFBooleanFalse, PREF_DOMAIN);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}
@implementation M1WinDelegate
- (BOOL)windowShouldClose:(NSWindow *)w { (void)w; fprintf(stderr, "[metal] window close button\n"); host_request_quit(); return NO; }
- (void)windowDidEnterFullScreen:(NSNotification *)n { (void)n; fprintf(stderr, "[metal] fullscreen\n"); if (start_fs) start_fs = 0; else save_fs(1); }
- (void)windowDidExitFullScreen:(NSNotification *)n { (void)n; fprintf(stderr, "[metal] windowed\n"); save_fs(0); }
- (void)quit:(id)sender { (void)sender; host_request_quit(); }
- (void)settings:(id)sender { (void)sender; overlay_toggle(); }
@end
static M1WinDelegate *wdel;
// Host frame-rate setting: M1_MAXFPS env, else CFPreferences key MaxFPS (integer) in PREF_DOMAIN; 0 = uncapped.
// Returns -1 if unset. (VSync: the layer syncs to the display unless M1_NOVSYNC is set.)
int host_maxfps_setting(void) {
    const char *e = getenv("M1_MAXFPS");
    if (e && *e) return atoi(e) < 0 ? 0 : atoi(e);
    Boolean valid = false;
    CFIndex v = CFPreferencesGetAppIntegerValue(CFSTR("MaxFPS"), PREF_DOMAIN, &valid);
    return valid ? (int)(v < 0 ? 0 : v) : -1;
}
// Integer setting: env var wins (the word "auto" reads as 0), then the defaults key in PREF_DOMAIN, else def.
static int setting_int(const char *env, CFStringRef key, int def) {
    const char *e = getenv(env);
    if (e && *e) return strcmp(e, "auto") == 0 ? 0 : atoi(e);
    Boolean valid = false;
    CFIndex v = CFPreferencesGetAppIntegerValue(key, PREF_DOMAIN, &valid);
    return valid ? (int)v : def;
}
static int want_fullscreen(void) {
    const char *e = getenv("M1_FULLSCREEN");
    if (e && *e) return atoi(e) != 0;
    Boolean valid = false;
    Boolean on = CFPreferencesGetAppBooleanValue(CFSTR("StartFullscreen"), PREF_DOMAIN, &valid);
    return valid && on;
}
// App menu (Hide, Quit) and Window menu (Minimize, fullscreen); Cmd+key events go to these menus only.
static void make_menus(void) {
    NSMenu *bar = [NSMenu new], *app = [NSMenu new], *win = [[NSMenu alloc] initWithTitle:@"Window"];
    NSMenuItem *ai = [NSMenuItem new], *wi = [NSMenuItem new];
    [bar addItem:ai]; [bar addItem:wi]; ai.submenu = app; wi.submenu = win;
    [app addItemWithTitle:@"Hide Might and Magic IX" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *st = [app addItemWithTitle:@"Settings\u2026" action:@selector(settings:) keyEquivalent:@","];
    st.target = wdel;
    [app addItem:[NSMenuItem separatorItem]];
    NSMenuItem *q = [app addItemWithTitle:@"Quit Might and Magic IX" action:@selector(quit:) keyEquivalent:@"q"];
    q.target = wdel;
    [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSMenuItem *fs = [win addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    NSApp.mainMenu = bar; NSApp.windowsMenu = win;
}

// Scale 0 = auto: backing pixel height of the main screen / H (1 offscreen); keep = value to use when auto cannot be resolved here.
static int auto_cache;                 // last auto scale computed on the main thread (NSScreen is main-thread only)
static int resolve_scale(int req, uint32_t h, int keep) {
    int sc = req;
    if (sc <= 0) {
        sc = 1;
        if (!getenv("M1_OFFSCREEN")) {
            if ([NSThread isMainThread]) { NSScreen *scr = [NSScreen mainScreen]; if (scr) sc = (int)ceil(scr.frame.size.height * scr.backingScaleFactor / h); auto_cache = sc; }
            else sc = auto_cache > 0 ? auto_cache : keep;
        }
    }
    return sc < 1 ? 1 : sc > 4 ? 4 : sc;
}
static int resolve_msaa(int m) {
    m = m >= 8 ? 8 : m >= 4 ? 4 : m >= 2 ? 2 : 1;
    while (m > 1 && ![mdev supportsTextureSampleCount:(NSUInteger)m]) m /= 2;
    return m;
}
static void make_targets(void);
void gpu_init(uint32_t w, uint32_t h, int rt) {
    if (!gpu_on()) return;
    LOCK
    rt_surf = rt;
    if (ready && w == W && h == H) { UNLOCK return; }
    W = w; H = h;
    if (!mdev) {
        mdev = MTLCreateSystemDefaultDevice();
        queue = [mdev newCommandQueue];
        NSError *err = nil;
        MTLCompileOptions *co = [MTLCompileOptions new];
        id<MTLLibrary> lib = [mdev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:co error:&err];
        if (!lib) { fprintf(stderr, "[metal] shader compile failed: %s\n", err.localizedDescription.UTF8String); abort(); }
        vfn = [lib newFunctionWithName:@"vs"]; ffn = [lib newFunctionWithName:@"fs"];
        vdesc = [MTLVertexDescriptor vertexDescriptor];
        MTLVertexFormat f[5] = {MTLVertexFormatFloat4, MTLVertexFormatUChar4Normalized_BGRA, MTLVertexFormatUChar4Normalized_BGRA, MTLVertexFormatFloat2, MTLVertexFormatFloat2};
        NSUInteger o[5] = {0, 16, 20, 24, 32};
        for (int i = 0; i < 5; i++) { vdesc.attributes[i].format = f[i]; vdesc.attributes[i].offset = o[i]; vdesc.attributes[i].bufferIndex = 0; }
        vdesc.layouts[0].stride = sizeof(GV);
        for (int i = 0; i < 3; i++) ring[i] = [mdev newBufferWithLength:RING options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        inflight = dispatch_semaphore_create(3);
        SCREQ = setting_int("M1_SCALE", CFSTR("RenderScale"), 1);
        SC = resolve_scale(SCREQ, h, 1);
        MS = resolve_msaa(setting_int("M1_MSAA", CFSTR("MSAA"), 1));
        ANI = setting_int("M1_ANISO", CFSTR("Anisotropy"), 1); ANI = ANI < 1 ? 1 : ANI > 16 ? 16 : ANI;
        TRI = setting_int("M1_TRILINEAR", CFSTR("Trilinear"), 0) != 0;
        fprintf(stderr, "[metal] render scale %d, MSAA %d, aniso %d, trilinear %d\n", SC, MS, ANI, TRI);
        MTLRenderPipelineDescriptor *dd = [MTLRenderPipelineDescriptor new];
        dd.vertexFunction = [lib newFunctionWithName:@"dvs"]; dd.fragmentFunction = [lib newFunctionWithName:@"dfs"];
        dd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        down_pso = [mdev newRenderPipelineStateWithDescriptor:dd error:&err];
        MTLRenderPipelineDescriptor *od = [MTLRenderPipelineDescriptor new];
        od.vertexFunction = [lib newFunctionWithName:@"ovs"]; od.fragmentFunction = [lib newFunctionWithName:@"ofs"];
        od.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; od.colorAttachments[0].blendingEnabled = YES;
        od.colorAttachments[0].sourceRGBBlendFactor = od.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        od.colorAttachments[0].destinationRGBBlendFactor = od.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ov_pso = [mdev newRenderPipelineStateWithDescriptor:od error:&err];
        if (!ov_pso) fprintf(stderr, "[metal] overlay pipeline failed: %s\n", err.localizedDescription.UTF8String);
        if (!down_pso) { fprintf(stderr, "[metal] downsample pipeline failed: %s\n", err.localizedDescription.UTF8String); abort(); }
        texs = [NSMutableArray array];
        MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
        white = [mdev newTextureWithDescriptor:wd];
        uint32_t px = 0xFFFFFFFFu; [white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&px bytesPerRow:4];
    }
    make_targets();
    if (!getenv("M1_OFFSCREEN") && !layer) {
        if (![NSThread isMainThread]) fprintf(stderr, "[metal] gpu_init off the main thread: no window\n");
        else {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            const char *icon = getenv("M1_ICON");       // the launcher's icon (the process runs from m1/bin, not the .app)
            NSImage *im = icon ? [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:icon]] : nil;
            if (im) NSApp.applicationIconImage = im;
            NSRect vis = [NSScreen mainScreen].visibleFrame;
            CGFloat fit = MIN(vis.size.width * 0.9 / w, (vis.size.height - 28) * 0.9 / h);
            NSRect r = NSMakeRect(0, 0, floor(w * fit), floor(h * fit));
            window = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
            window.title = @"Might and Magic IX (native)";
            window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
            window.contentAspectRatio = NSMakeSize(w, h);
            window.contentMinSize = NSMakeSize(w / 2, h / 2);
            window.backgroundColor = NSColor.blackColor;
            wdel = [M1WinDelegate new]; window.delegate = wdel;
            make_menus();
            M1View *v = [[M1View alloc] initWithFrame:r];
            v.wantsLayer = YES;
            window.contentView = v;
            layer = (CAMetalLayer *)v.layer;
            layer.device = mdev; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.framebufferOnly = NO;
            layer.displaySyncEnabled = getenv("M1_NOVSYNC") ? NO : YES;
            layer.maximumDrawableCount = 3;
            layer.contentsGravity = kCAGravityResizeAspect;
            layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            [window center];
            [window makeKeyAndOrderFront:nil];
            [NSApp finishLaunching];
            [NSApp activateIgnoringOtherApps:YES];
            if (want_fullscreen()) { start_fs = 1; [window toggleFullScreen:nil]; }
        }
    }
    if (layer) layer.drawableSize = CGSizeMake(BW, BH);
    fprintf(stderr, "[metal] %s, back buffer %ux%u (internal %ux%u)%s\n", mdev.name.UTF8String, w, h, BW, BH, layer ? ", window" : ", offscreen");
    ready = 1;
    UNLOCK
}

static void make_targets(void) {
    uint32_t w = W, h = H;
    BW = w * (uint32_t)SC; BH = h * (uint32_t)SC;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:BW height:BH mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    bb = [mdev newTextureWithDescriptor:d];
    d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:BW height:BH mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
    depth = [mdev newTextureWithDescriptor:d];
    ms_col = ms_depth = nil;
    if (MS > 1) {
        d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:BW height:BH mipmapped:NO];
        d.textureType = MTLTextureType2DMultisample; d.sampleCount = (NSUInteger)MS;
        d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
        ms_col = [mdev newTextureWithDescriptor:d];
        d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:BW height:BH mipmapped:NO];
        d.textureType = MTLTextureType2DMultisample; d.sampleCount = (NSUInteger)MS;
        d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
        ms_depth = [mdev newTextureWithDescriptor:d];
    }
    d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
    rb_tex = [mdev newTextureWithDescriptor:d];
    pending_clear = 3; clear_color = 0; clear_z = 1.0f; rt_gen++;
    if (layer) layer.drawableSize = CGSizeMake(BW, BH);
}

// ---- passes ----------------------------------------------------------------------------------------
static struct { __unsafe_unretained id pso, dss, t0, t1, s0, s1; FU fu; int fu_valid; MTLScissorRect sc; int sc_valid; int cull; } ec;
static void begin_pass(void) {
    if (enc) return;
    if (!cmd) cmd = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = MS > 1 ? ms_col : bb;
    rp.colorAttachments[0].loadAction = (pending_clear & 1) ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(((clear_color >> 16) & 255) / 255.0, ((clear_color >> 8) & 255) / 255.0, (clear_color & 255) / 255.0, (clear_color >> 24) / 255.0);
    if (MS > 1) { rp.colorAttachments[0].resolveTexture = bb; rp.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve; }
    else rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = MS > 1 ? ms_depth : depth;
    rp.depthAttachment.loadAction = (pending_clear & 2) ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.depthAttachment.clearDepth = clear_z;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    pending_clear = 0;
    enc = [cmd renderCommandEncoderWithDescriptor:rp];
    float size[2] = {(float)W, (float)H};
    [enc setVertexBytes:size length:8 atIndex:1];
    [enc setVertexBuffer:ring[ring_i] offset:0 atIndex:0];
    [enc setCullMode:MTLCullModeNone];
    [enc setDepthClipMode:MTLDepthClipModeClamp];
    memset(&ec, 0, sizeof ec); ec.cull = 1;          // 1 = none (D3DCULL_NONE), matches setCullMode above
}
static void end_pass(void) { if (enc) { [enc endEncoding]; enc = nil; } }

void gpu_clear(uint32_t flags, uint32_t color, float z) {
    if (!gpu_on() || !ready) return;
    LOCK
    end_pass();
    if (flags & 1) { pending_clear |= 1; clear_color = color; rt_gen++; }
    if (flags & 2) { pending_clear |= 2; clear_z = z; }
    UNLOCK
}
void gpu_colorfill(int s, uint32_t color) {
    if (!gpu_on() || !ready) return;
    if (s == rt_surf || (rt_surf >= 0 && surf_root(rt_surf) == surf_root(s))) gpu_clear(1, color, 1.0f);
}

// ---- state -----------------------------------------------------------------------------------------
static MTLBlendFactor bf(uint32_t b, int alpha) {
    switch (b) {
    case 1: return MTLBlendFactorZero; case 2: return MTLBlendFactorOne;
    case 3: return alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
    case 4: return alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
    case 5: case 12: return MTLBlendFactorSourceAlpha; case 6: case 13: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha; case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
    case 10: return alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    default: return MTLBlendFactorOne;
    }
}
static id<MTLRenderPipelineState> get_pso(void) {
    uint32_t en = dev.rs[27] ? 1 : 0, src = dev.rs[19] & 15, dst = dev.rs[20] & 15;
    if (dev.rs[19] == 12) { src = 5; dst = 6; }                  // BOTHSRCALPHA
    if (dev.rs[19] == 13) { src = 6; dst = 5; }                  // BOTHINVSRCALPHA
    uint32_t key = en ? (1 | src << 1 | dst << 5) : 0;
    if (pso[key]) return pso[key];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vfn; d.fragmentFunction = ffn; d.vertexDescriptor = vdesc;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    d.rasterSampleCount = (NSUInteger)MS;
    if (en) {
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = bf(src, 0); d.colorAttachments[0].destinationRGBBlendFactor = bf(dst, 0);
        d.colorAttachments[0].sourceAlphaBlendFactor = bf(src, 1); d.colorAttachments[0].destinationAlphaBlendFactor = bf(dst, 1);
    }
    NSError *err = nil;
    pso[key] = [mdev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso[key]) fprintf(stderr, "[metal] pipeline %#x failed: %s\n", key, err.localizedDescription.UTF8String);
    return pso[key];
}
static MTLCompareFunction cmpf(uint32_t f) {
    switch (f) { case 1: return MTLCompareFunctionNever; case 2: return MTLCompareFunctionLess; case 3: return MTLCompareFunctionEqual;
    case 4: return MTLCompareFunctionLessEqual; case 5: return MTLCompareFunctionGreater; case 6: return MTLCompareFunctionNotEqual;
    case 7: return MTLCompareFunctionGreaterEqual; default: return MTLCompareFunctionAlways; }
}
static id<MTLDepthStencilState> get_dss(void) {
    uint32_t zen = dev.rs[7] ? 1 : 0, zw = dev.rs[14] ? 1 : 0, zf = dev.rs[23] & 15;
    uint32_t key = zen | zw << 1 | zf << 2;
    if (dss[key]) return dss[key];
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = zen ? cmpf(zf) : MTLCompareFunctionAlways;
    d.depthWriteEnabled = zen && zw;
    dss[key] = [mdev newDepthStencilStateWithDescriptor:d];
    return dss[key];
}
static MTLSamplerAddressMode am(uint32_t a) {
    switch (a) { case 2: return MTLSamplerAddressModeMirrorRepeat; case 3: return MTLSamplerAddressModeClampToEdge;
    case 4: return MTLSamplerAddressModeClampToBorderColor; default: return MTLSamplerAddressModeRepeat; }
}
static id<MTLSamplerState> get_samp(int st, int mipmapped) {
    uint32_t *t = dev.tss[st];
    uint32_t mag = t[16] >= 2 ? 1 : 0, min = t[17] >= 2 ? 1 : 0, mip = mipmapped ? (t[18] == 3 ? 2 : t[18] == 2 ? 1 : 0) : 0;
    uint32_t aniso = (t[16] == 5 || t[17] == 3) ? 1 : 0;
    if (mipmapped && min && TRI) mip = 2;                         // fixed per run: not part of the key
    uint32_t key = mag | min << 1 | mip << 2 | (t[13] & 3) << 4 | (t[14] & 3) << 6 | aniso << 8 | (t[13] == 4) << 9 | (t[14] == 4) << 10 | (mipmapped ? 1u : 0u) << 11;
    if (samp[key]) return samp[key];
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.magFilter = mag ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = min ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = mip == 2 ? MTLSamplerMipFilterLinear : mip == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
    d.sAddressMode = am(t[13]); d.tAddressMode = am(t[14]);
    if (aniso) d.maxAnisotropy = 4;
    if (ANI > 1 && min && mipmapped) d.maxAnisotropy = (NSUInteger)ANI;
    samp[key] = [mdev newSamplerStateWithDescriptor:d];
    return samp[key];
}

// ---- textures --------------------------------------------------------------------------------------
typedef struct { MTLPixelFormat pf; MTLTextureSwizzleChannels sw; int has_sw, block, bpp; } Fmt;
static Fmt fmt_of(const Surf *s) {
    Fmt r = {MTLPixelFormatInvalid, MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha), 0, 0, 0};
#define SW(a, b, c_, d) do { r.sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzle##a, MTLTextureSwizzle##b, MTLTextureSwizzle##c_, MTLTextureSwizzle##d); r.has_sw = 1; } while (0)
    uint32_t fl = SDESC(s, 76), cc = SDESC(s, 80), bits = SDESC(s, 84), rm = SDESC(s, 88), am_ = SDESC(s, 100);
    int alpha = (fl & 1) && am_;
    if (fl & 4) {
        if (cc == 0x31545844) { r.pf = MTLPixelFormatBC1_RGBA; r.block = 8; }
        else if (cc == 0x33545844) { r.pf = MTLPixelFormatBC2_RGBA; r.block = 16; }
        else if (cc == 0x35545844) { r.pf = MTLPixelFormatBC3_RGBA; r.block = 16; }
        return r;
    }
    r.bpp = (int)bits / 8;
    if (bits == 32) { r.pf = MTLPixelFormatBGRA8Unorm; if (!alpha) SW(Red, Green, Blue, One); }
    else if (bits == 16 && rm == 0xF800) r.pf = MTLPixelFormatB5G6R5Unorm;
    // Metal packed formats name components from the least significant bit: D3D A1R5G5B5 (B in bits 0-4,
    // A in bit 15) is BGR5A1Unorm. (FNV maps it to A1BGR5Unorm, which puts alpha in bit 0.)
    else if (bits == 16 && rm == 0x7C00) { r.pf = MTLPixelFormatBGR5A1Unorm; if (!alpha) SW(Red, Green, Blue, One); }
    else if (bits == 16 && rm == 0x0F00) { r.pf = MTLPixelFormatABGR4Unorm; SW(Green, Blue, Alpha, Red); }
    return r;
}
static int chain(int root, int *lv, int max) {
    int n = 0, i = root;
    while (i >= 0 && n < max) {
        lv[n++] = i;
        int next = -1;
        for (int k = 0; k < sf[i].natt; k++) { int a = sf[i].att[k]; if (sf[a].owner == root && (SDESC(&sf[a], 104) & 0x400000)) { next = a; break; } }
        i = next;
    }
    return n;
}
id<MTLTexture> texpack_texture(uint64_t hash, id<MTLDevice> dev, id<MTLCommandQueue> cq, int noalpha);
static NSMutableDictionary *rtex, *rhash;   // root surface index -> bound replacement texture / its content hash (texpack)
static void rep_unbind(int root) {
    NSNumber *k = @(root), *h = rhash[k];
    if (h) { texpack_release(h.unsignedLongLongValue); [rhash removeObjectForKey:k]; }
    [rtex removeObjectForKey:k];
}
static id<MTLTexture> tex_of(uint32_t obj) {
    if (!obj) return nil;
    uint32_t idx = G32(obj + 8);
    if (idx >= (uint32_t)nsf) return nil;
    int root = surf_root((int)idx);
    Surf *s = &sf[root];
    if (!s->alive || !s->mem) return nil;
    if (s->gpu && !s->dirty) return texs[s->gpu - 1];
    [ktex removeObjectForKey:@(root)];
    Fmt f = fmt_of(s);
    if (f.pf == MTLPixelFormatInvalid) {
        static int warned; if (warned++ < 5) fprintf(stderr, "[metal] unsupported texture format flags %#x bits %u R %#x\n", SDESC(s, 76), SDESC(s, 84), SDESC(s, 88));
        return nil;
    }
    int lv[16], n = chain(root, lv, 16);
    if (texpack_on()) {
        uint64_t th = texpack_hash(s, root);
        int ok = th ? texpack_on_upload(root, s, th, n, frames) : 0;
        id<MTLTexture> rt = (ok && texpack_replace_on()) ? texpack_texture(th, mdev, queue, texpack_noalpha(s)) : nil;
        if (!rtex) { rtex = [NSMutableDictionary dictionary]; rhash = [NSMutableDictionary dictionary]; }
        if (rt) {
            NSNumber *oh = rhash[@(root)];
            if (!oh || oh.unsignedLongLongValue != th) { rep_unbind(root); texpack_retain(th); rhash[@(root)] = @(th); }
            rtex[@(root)] = rt;
            if (s->gpu) texs[s->gpu - 1] = rt; else { [texs addObject:rt]; s->gpu = (int)texs.count; }
            s->dirty = 0;
            return rt;
        }
        rep_unbind(root);
    }
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f.pf width:w height:h mipmapped:n > 1];
    if (n > 1) d.mipmapLevelCount = (NSUInteger)n;
    d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
    if (f.has_sw) d.swizzle = f.sw;
    id<MTLTexture> t = [mdev newTextureWithDescriptor:d];
    for (int l = 0; l < n; l++) {
        Surf *ls = &sf[lv[l]];
        uint32_t lw = SDESC(ls, 12), lh = SDESC(ls, 8);
        NSUInteger bpr = f.block ? ((lw + 3) / 4 ? (lw + 3) / 4 : 1) * (NSUInteger)f.block : SDESC(ls, 16);
        if (!ls->mem) continue;
        [t replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:(NSUInteger)l withBytes:MEM + ls->mem bytesPerRow:bpr];
    }
    if (s->gpu) texs[s->gpu - 1] = t;
    else { [texs addObject:t]; s->gpu = (int)texs.count; }
    s->dirty = 0;
    return t;
}
static int rb_last_s = -1; static uint64_t rb_last_gen;    // readback cache: surface last filled and rt_gen then
void gpu_surface_free(int i) {
    if (!gpu_on()) return;
    LOCK
    if (rb_last_s == i) rb_last_s = -1;          // the slot may be reused
    texpack_forget(i);
    rep_unbind(i);
    if (sf[i].gpu) { texs[sf[i].gpu - 1] = white; }
    [ktex removeObjectForKey:@(i)];
    UNLOCK
}

// ---- draws -----------------------------------------------------------------------------------------
static uint32_t fvf_stride(uint32_t fvf, int *odif, int *ospec, int *otex, int *ntex) {
    uint32_t s = (fvf & 0xE) == 0x4 ? 16 : (fvf & 0xE) == 0x2 ? 12 : 0;
    if (fvf & 0x10) s += 12;
    if (fvf & 0x20) s += 4;
    *odif = (fvf & 0x40) ? (int)s : -1; if (fvf & 0x40) s += 4;
    *ospec = (fvf & 0x80) ? (int)s : -1; if (fvf & 0x80) s += 4;
    *otex = (int)s; *ntex = (int)((fvf >> 8) & 0xF);
    for (int t = 0; t < *ntex; t++) { uint32_t f = (fvf >> (16 + 2 * t)) & 3; s += f == 0 ? 8 : f == 1 ? 12 : f == 2 ? 16 : 4; }
    return s;
}
static int ck_off(void) { static int v = -1; if (v < 0) v = getenv("M1_NOCOLORKEY") != NULL; return v; }
static int cull_off(void) { static int v = -1; if (v < 0) v = getenv("M1_NOCULL") != NULL; return v; }
static struct { uint64_t draws, cull[8], ckrs, ckrs_tex, keyed_bound; uint64_t fmt[8]; } trc;
static int trace_ck(void) { static int v = -1; if (v < 0) v = getenv("M1_TRACE_CK") != NULL; return v; }
static void trace_ck_dump(void) {
    fprintf(stderr, "[ck] draws %llu cull(none/cw/ccw/other) %llu/%llu/%llu/%llu colorkeyenable-draws %llu, with keyed tex bound %llu; "
            "bound keyed-capable textures (draw,stage) by fmt: 16bit565 %llu 16bit1555 %llu 16bit4444 %llu 32bit %llu dxt %llu other %llu\n",
            (unsigned long long)trc.draws, (unsigned long long)trc.cull[1], (unsigned long long)trc.cull[2], (unsigned long long)trc.cull[3],
            (unsigned long long)(trc.cull[0] + trc.cull[4] + trc.cull[5] + trc.cull[6] + trc.cull[7]), (unsigned long long)trc.ckrs,
            (unsigned long long)trc.ckrs_tex, (unsigned long long)trc.fmt[0], (unsigned long long)trc.fmt[1], (unsigned long long)trc.fmt[2],
            (unsigned long long)trc.fmt[3], (unsigned long long)trc.fmt[4], (unsigned long long)trc.fmt[5]);
}
// The keyed variant of a texture whose surface has DDSD_CKSRCBLT (non-DXT, 16/32 bit); nil otherwise.
static id<MTLTexture> keyed_of(uint32_t obj, int count_only);
static struct { uint64_t bound[2], combo[8][8][8][2], maxmip; } filt;
static void trace_filt_dump(void) {
    fprintf(stderr, "[filt] bound textures (draw,stage): non-mipmapped %llu mipmapped %llu, max mip levels %llu\n",
            (unsigned long long)filt.bound[0], (unsigned long long)filt.bound[1], (unsigned long long)filt.maxmip);
    for (int a = 0; a < 8; a++) for (int b = 0; b < 8; b++) for (int c = 0; c < 8; c++) for (int m = 0; m < 2; m++)
        if (filt.combo[a][b][c][m]) fprintf(stderr, "[filt] mag %d min %d mip %d mipmapped %d: %llu\n", a, b, c, m, (unsigned long long)filt.combo[a][b][c][m]);
}
static int trace_filt(void) {
    static int v = -1; if (v < 0) { v = getenv("M1_TRACE_FILT") != NULL; if (v) atexit(trace_filt_dump); }
    return v;
}
static void set_fu(void) {
    FU u; memset(&u, 0, sizeof u);
    uint32_t *t0 = dev.tss[0], *t1 = dev.tss[1];
    u.c0[0] = (int)t0[1]; u.c0[1] = (int)t0[2]; u.c0[2] = (int)t0[3];
    u.a0[0] = (int)t0[4]; u.a0[1] = (int)t0[5]; u.a0[2] = (int)t0[6];
    u.c1[0] = (int)t1[1]; u.c1[1] = (int)t1[2]; u.c1[2] = (int)t1[3];
    u.a1[0] = (int)t1[4]; u.a1[1] = (int)t1[5]; u.a1[2] = (int)t1[6];
    if (!u.c1[0]) u.c1[0] = 1;
    u.atest = dev.rs[15] != 0; u.afunc = (int)dev.rs[25]; u.aref = (float)(dev.rs[24] & 255);
    u.spec = dev.rs[29] != 0;
    u.fog = dev.rs[28] != 0; u.fogmode = (int)dev.rs[35];
    memcpy(&u.fogstart, &dev.rs[36], 4); memcpy(&u.fogend, &dev.rs[37], 4);
    uint32_t fc = dev.rs[34], tf = dev.rs[60];
    u.fogcolor[0] = ((fc >> 16) & 255) / 255.0f; u.fogcolor[1] = ((fc >> 8) & 255) / 255.0f; u.fogcolor[2] = (fc & 255) / 255.0f; u.fogcolor[3] = 1;
    u.tfactor[0] = ((tf >> 16) & 255) / 255.0f; u.tfactor[1] = ((tf >> 8) & 255) / 255.0f; u.tfactor[2] = (tf & 255) / 255.0f; u.tfactor[3] = (tf >> 24) / 255.0f;
    u.tci1 = (int)(t1[11] & 0xFFFF);
    id<MTLTexture> x0 = u.c0[0] != 1 ? tex_of(dev.tex[0]) : nil;
    id<MTLTexture> x1 = (u.c0[0] != 1 && u.c1[0] != 1) ? tex_of(dev.tex[1]) : nil;
    u.tex0 = x0 != nil; u.tex1 = x1 != nil;
    if (dev.rs[41] && !ck_off()) {
        id<MTLTexture> k0 = x0 ? keyed_of(dev.tex[0], 0) : nil, k1 = x1 ? keyed_of(dev.tex[1], 0) : nil;
        if (k0) { x0 = k0; u.ckey |= 1; }
        if (k1) { x1 = k1; u.ckey |= 2; }
    }
    id<MTLTexture> b0 = x0 ? x0 : white, b1 = x1 ? x1 : white;
    if (ec.t0 != b0) { [enc setFragmentTexture:b0 atIndex:0]; ec.t0 = b0; }
    if (ec.t1 != b1) { [enc setFragmentTexture:b1 atIndex:1]; ec.t1 = b1; }
    if (trace_filt()) for (int st = 0; st < 2; st++) {
        id<MTLTexture> x = st ? x1 : x0; if (!x) continue;
        uint32_t *t = dev.tss[st]; int mm = x.mipmapLevelCount > 1;
        filt.bound[mm]++; filt.combo[t[16] & 7][t[17] & 7][t[18] & 7][mm]++;
        filt.maxmip = MAX(filt.maxmip, (uint64_t)x.mipmapLevelCount);
    }
    id<MTLSamplerState> s0 = get_samp(0, x0 && x0.mipmapLevelCount > 1), s1 = get_samp(1, x1 && x1.mipmapLevelCount > 1);
    if (ec.s0 != s0) { [enc setFragmentSamplerState:s0 atIndex:0]; ec.s0 = s0; }
    if (ec.s1 != s1) { [enc setFragmentSamplerState:s1 atIndex:1]; ec.s1 = s1; }
    if (!ec.fu_valid || memcmp(&ec.fu, &u, sizeof u)) { [enc setFragmentBytes:&u length:sizeof u atIndex:0]; ec.fu = u; ec.fu_valid = 1; }
}
static uint64_t draws, skipped;
void gpu_draw(uint32_t prim, uint32_t fvf, uint32_t verts, uint32_t nverts, uint32_t idx, uint32_t nidx) {
    if (!gpu_on() || !ready) return;
    int odif, ospec, otex, ntex;
    uint32_t stride = fvf_stride(fvf, &odif, &ospec, &otex, &ntex);
    if ((fvf & 0xE) != 0x4) { if (skipped++ < 5) fprintf(stderr, "[metal] skipping non-XYZRHW draw (fvf %#x)\n", fvf); return; }
    uint32_t n = idx ? nidx : nverts, m;
    MTLPrimitiveType pt;
    switch (prim) {
    case 1: pt = MTLPrimitiveTypePoint; m = n; break;
    case 2: pt = MTLPrimitiveTypeLine; m = n; break;
    case 3: pt = MTLPrimitiveTypeLineStrip; m = n; break;
    case 4: pt = MTLPrimitiveTypeTriangle; m = n; break;
    case 5: pt = MTLPrimitiveTypeTriangleStrip; m = n; break;
    case 6: pt = MTLPrimitiveTypeTriangle; m = n >= 3 ? (n - 2) * 3 : 0; break;
    default: return;
    }
    if (!m) return;
    LOCK
    begin_pass();
    if (ring_off + m * sizeof(GV) > RING) { end_pass(); fprintf(stderr, "[metal] vertex ring full\n"); UNLOCK return; }
    GV *out = (GV *)((uint8_t *)ring[ring_i].contents + ring_off);
    for (uint32_t k = 0; k < m; k++) {
        uint32_t si = prim == 6 ? (k % 3 == 0 ? 0 : k / 3 + k % 3) : k;
        if (idx) si = G16(idx + 2 * si);
        if (si >= nverts) si = 0;
        const uint8_t *v = MEM + verts + si * stride;
        GV *o = &out[k];
        memcpy(&o->x, v, 16);
        uint32_t dif = 0xFFFFFFFFu, spc = 0xFF000000u;
        if (odif >= 0) memcpy(&dif, v + odif, 4);
        if (ospec >= 0) memcpy(&spc, v + ospec, 4);
        o->diffuse = dif; o->specular = spc;
        if (ntex >= 1) memcpy(&o->u0, v + otex, 8); else o->u0 = o->v0 = 0;
        if (ntex >= 2) memcpy(&o->u1, v + otex + 8, 8); else { o->u1 = o->u0; o->v1 = o->v0; }
    }
    id<MTLRenderPipelineState> p = get_pso();
    if (p && ec.pso != p) { [enc setRenderPipelineState:p]; ec.pso = p; }
    id<MTLDepthStencilState> ds = get_dss();
    if (ec.dss != ds) { [enc setDepthStencilState:ds]; ec.dss = ds; }
    uint32_t vx, vy, vw, vh; memcpy(&vx, dev.vp, 4); memcpy(&vy, dev.vp + 4, 4); memcpy(&vw, dev.vp + 8, 4); memcpy(&vh, dev.vp + 12, 4);
    MTLScissorRect sc = {0, 0, BW, BH};
    if (vw && vh && vx < W && vy < H) {
        sc.x = vx * SC; sc.y = vy * SC;
        sc.width = MIN(MIN(vw, W - vx) * SC, BW - sc.x); sc.height = MIN(MIN(vh, H - vy) * SC, BH - sc.y);
    }
    if (!ec.sc_valid || memcmp(&ec.sc, &sc, sizeof sc)) { [enc setScissorRect:sc]; ec.sc = sc; ec.sc_valid = 1; }
    set_fu();
    {   // D3DRENDERSTATE_CULLMODE: 1 none, 2 cw, 3 ccw (triangles only; the engine also culls on the CPU)
        int cm = (int)dev.rs[22]; if (cm < 1 || cm > 3 || cull_off()) cm = 1;
        if (pt != MTLPrimitiveTypeTriangle && pt != MTLPrimitiveTypeTriangleStrip) cm = 1;
        if (ec.cull != cm) {
            [enc setCullMode:cm == 1 ? MTLCullModeNone : cm == 2 ? MTLCullModeFront : MTLCullModeBack];
            ec.cull = cm;
        }
    }
    if (trace_ck()) {
        static int reg; if (!reg) { reg = 1; atexit(trace_ck_dump); }
        trc.draws++; trc.cull[dev.rs[22] & 7]++;
        if (dev.rs[41]) { trc.ckrs++; if (ec.fu_valid && (ec.fu.ckey)) trc.keyed_bound++; }
        for (int st = 0; st < 2; st++) if (dev.tex[st]) keyed_of(dev.tex[st], 1);
        if (dev.rs[41]) { int any = 0; for (int st = 0; st < 2; st++) if (dev.tex[st] && keyed_of(dev.tex[st], 2)) any = 1; trc.ckrs_tex += any; }
        if (trc.draws % 50000 == 0) trace_ck_dump();
    }
    if (p) [enc drawPrimitives:pt vertexStart:ring_off / sizeof(GV) vertexCount:m];
    ring_off += m * sizeof(GV);
    draws++; rt_gen++;
    UNLOCK
}

// Source colour key (DDBLT_KEYSRC): a BGRA copy of the surface whose key-coloured pixels get alpha 0,
// drawn with an alpha test. Only small sprites use it (the loading screen's animation, 44x36).
// Converts one level to BGRA8 with key-coloured pixels at 0. keep_alpha: other pixels keep the texture's
// own alpha (at least 1, so alpha 0 means "key"); otherwise they are opaque. Colour comparison ignores
// the alpha bits of the format.
static void key_convert(const Surf *s, uint32_t key, int keep_alpha, uint32_t *px) {
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8), bits = SDESC(s, 84), rm = SDESC(s, 88), pitch = SDESC(s, 16);
    int alpha = keep_alpha && (SDESC(s, 76) & 1) && SDESC(s, 100);
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
        const uint8_t *p = MEM + s->mem + y * pitch + x * (bits / 8);
        uint32_t v, o;
        if (bits == 32) {
            memcpy(&v, p, 4);
            uint32_t a = alpha ? (v >> 24) : 255; if (!a) a = 1;
            o = (v & 0xFFFFFF) == (key & 0xFFFFFF) ? 0 : (v & 0xFFFFFF) | a << 24;
        } else {
            uint16_t q; memcpy(&q, p, 2); v = q;
            uint32_t r, g, b, a = 255, cm = 0xFFFF;
            if (rm == 0xF800) { r = (v >> 11) & 31; g = (v >> 5) & 63; b = v & 31; r = r << 3 | r >> 2; g = g << 2 | g >> 4; b = b << 3 | b >> 2; }
            else if (rm == 0x0F00) { r = ((v >> 8) & 15) * 17; g = ((v >> 4) & 15) * 17; b = (v & 15) * 17; cm = 0x0FFF; if (alpha) { a = (v >> 12) * 17; if (!a) a = 1; } }
            else { r = (v >> 10) & 31; g = (v >> 5) & 31; b = v & 31; r = r << 3 | r >> 2; g = g << 3 | g >> 2; b = b << 3 | b >> 2; cm = 0x7FFF; if (alpha) { a = (v >> 15) ? 255 : 1; } }
            o = (v & cm) == (key & cm) ? 0 : a << 24 | r << 16 | g << 8 | b;
        }
        px[(size_t)y * w + x] = o;
    }
}
static id<MTLTexture> keyed_tex(const Surf *s) {
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8), bits = SDESC(s, 84);
    if (!s->mem || !w || !h || (bits != 32 && bits != 16) || (SDESC(s, 76) & 4)) return nil;
    uint32_t *px = malloc((size_t)w * h * 4);
    key_convert(s, SDESC(s, 64), 0, px);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [mdev newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    free(px);
    return t;
}
// count_only 0: build/fetch the keyed variant; 1: tally the texture's format in the trace; 2: just report applicability.
static id<MTLTexture> keyed_of(uint32_t obj, int count_only) {
    if (!obj) return nil;
    uint32_t idx = G32(obj + 8);
    if (idx >= (uint32_t)nsf) return nil;
    int root = surf_root((int)idx);
    Surf *s = &sf[root];
    if (!s->alive || !s->mem || !(SDESC(s, 4) & 0x10000)) return nil;
    if (rhash && rhash[@(root)] && !count_only) {          // replacement: its own alpha is the key
        id<MTLTexture> rk = texpack_texture(((NSNumber *)rhash[@(root)]).unsignedLongLongValue, mdev, queue, 0);
        if (rk) return rk;
    }
    uint32_t bits = SDESC(s, 84), rm = SDESC(s, 88);
    if ((SDESC(s, 76) & 4) || (bits != 32 && bits != 16)) { if (count_only == 1) trc.fmt[4]++; return nil; }
    if (bits == 16 && rm != 0xF800 && rm != 0x7C00 && rm != 0x0F00) { if (count_only == 1) trc.fmt[5]++; return nil; }
    if (count_only) { if (count_only == 1) trc.fmt[bits == 32 ? 3 : rm == 0xF800 ? 0 : rm == 0x7C00 ? 1 : 2]++; return (id<MTLTexture>)white; }
    if (!ktex) ktex = [NSMutableDictionary dictionary];
    id<MTLTexture> t = ktex[@(root)];
    if (t) return t;
    int lv[16], n = chain(root, lv, 16);
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8), key = SDESC(s, 64);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:n > 1];
    if (n > 1) d.mipmapLevelCount = (NSUInteger)n;
    d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
    t = [mdev newTextureWithDescriptor:d];
    for (int l = 0; l < n; l++) {
        Surf *ls = &sf[lv[l]];
        uint32_t lw = SDESC(ls, 12), lh = SDESC(ls, 8);
        if (!ls->mem || !lw || !lh) continue;
        uint32_t *px = malloc((size_t)lw * lh * 4);
        key_convert(ls, key, 1, px);
        [t replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:(NSUInteger)l withBytes:px bytesPerRow:lw * 4];
        free(px);
    }
    ktex[@(root)] = t;
    return t;
}
// 2D blit of a CPU surface onto the back buffer: a textured quad, no blending; with `keyed`, the
// source surface's colour key is transparent.
void gpu_blit(int src, int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1, int keyed) {
    if (!gpu_on() || !ready) return;
    LOCK
    begin_pass();
    id<MTLTexture> t = nil;
    if (keyed) {
        if (texpack_replace_on()) { tex_of(sf[surf_root(src)].o7); int rr = surf_root(src);          // binds/refreshes a replacement
            NSNumber *h = rhash[@(rr)]; if (h) t = texpack_texture(h.unsignedLongLongValue, mdev, queue, 0); }
        if (!t) t = keyed_tex(&sf[src]);
    } else t = tex_of(sf[src].o7);
    if (!t || ring_off + 6 * sizeof(GV) > RING) { UNLOCK return; }
    float tw = (float)SDESC(&sf[surf_root(src)], 12), th = (float)SDESC(&sf[surf_root(src)], 8);   // original size: a replacement texture may be larger
    float u0 = sx0 / tw, v0 = sy0 / th, u1 = sx1 / tw, v1 = sy1 / th;
    GV q[4] = {{dx0 - 0.5f, dy0 - 0.5f, 0, 1, 0xFFFFFFFFu, 0xFF000000u, u0, v0, u0, v0}, {dx1 - 0.5f, dy0 - 0.5f, 0, 1, 0xFFFFFFFFu, 0xFF000000u, u1, v0, u1, v0},
               {dx1 - 0.5f, dy1 - 0.5f, 0, 1, 0xFFFFFFFFu, 0xFF000000u, u1, v1, u1, v1}, {dx0 - 0.5f, dy1 - 0.5f, 0, 1, 0xFFFFFFFFu, 0xFF000000u, u0, v1, u0, v1}};
    GV *out = (GV *)((uint8_t *)ring[ring_i].contents + ring_off);
    out[0] = q[0]; out[1] = q[1]; out[2] = q[2]; out[3] = q[0]; out[4] = q[2]; out[5] = q[3];
    if (!pso[0]) { uint32_t b = dev.rs[27]; dev.rs[27] = 0; get_pso(); dev.rs[27] = b; }
    [enc setRenderPipelineState:pso[0]]; ec.pso = pso[0];
    if (ec.cull != 1) { [enc setCullMode:MTLCullModeNone]; ec.cull = 1; }
    uint32_t z0 = dev.rs[7]; dev.rs[7] = 0; id<MTLDepthStencilState> ds = get_dss(); dev.rs[7] = z0;
    [enc setDepthStencilState:ds]; ec.dss = ds;
    MTLScissorRect sc = {0, 0, BW, BH}; [enc setScissorRect:sc]; ec.sc = sc; ec.sc_valid = 1;
    FU u; memset(&u, 0, sizeof u);
    u.c0[0] = 2; u.c0[1] = 2; u.a0[0] = 2; u.a0[1] = 2; u.c1[0] = 1; u.tex0 = 1;
    if (keyed) { u.atest = 1; u.afunc = 5; u.aref = 0; }          // keep alpha > 0
    [enc setFragmentBytes:&u length:sizeof u atIndex:0]; ec.fu_valid = 0;
    [enc setFragmentTexture:t atIndex:0]; ec.t0 = nil;
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    static id<MTLSamplerState> point; if (!point) point = [mdev newSamplerStateWithDescriptor:sd];
    [enc setFragmentSamplerState:point atIndex:0]; ec.s0 = nil;
    [enc setFragmentTexture:white atIndex:1]; [enc setFragmentSamplerState:point atIndex:1]; ec.t1 = nil; ec.s1 = nil;   // fs reads index 1 in every draw
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:ring_off / sizeof(GV) vertexCount:6];
    ring_off += 6 * sizeof(GV);
    rt_gen++;
    UNLOCK
}

// ---- readback ----------------------------------------------------------------------------------------
// The game reads the back buffer on the CPU: it Locks the render target to build the save-game thumbnail
// (one Lock per thumbnail pixel: 30,000 for 200x150) and may Blt from it into system-memory surfaces.
// Copy the back buffer texture (with everything encoded so far) into the surface's guest memory,
// converted from BGRA8 to the surface's pixel format. One GPU round trip per change of the back buffer:
// rt_gen counts clears, draws and blits, and a repeat readback into the same surface is skipped.
static id<MTLBuffer> rb_buf;
void gpu_readback(int s) {
    if (!gpu_on() || !ready) return;
    LOCK
    Surf *d = &sf[s];
    if ((s == rb_last_s && rt_gen == rb_last_gen) || !d->mem || (SDESC(d, 76) & 4)) { UNLOCK return; }
    @autoreleasepool {
        if (pending_clear) begin_pass();
        end_pass();
        if (!cmd) cmd = [queue commandBuffer];
        if (!rb_buf || rb_buf.length < (NSUInteger)W * H * 4) rb_buf = [mdev newBufferWithLength:(NSUInteger)W * H * 4 options:MTLResourceStorageModeShared];
        id<MTLTexture> src_tex = bb;
        if (SC > 1) {      // box-filter the internal image down to the 800x600 the game expects
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rb_tex; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cmd renderCommandEncoderWithDescriptor:rp];
            int sc = SC;
            [re setRenderPipelineState:down_pso]; [re setFragmentTexture:bb atIndex:0]; [re setFragmentBytes:&sc length:4 atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            src_tex = rb_tex;
        }
        id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
        [b copyFromTexture:src_tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                  toBuffer:rb_buf destinationOffset:0 destinationBytesPerRow:(NSUInteger)W * 4 destinationBytesPerImage:(NSUInteger)W * H * 4];
        [b endEncoding];
        [cmd commit]; [cmd waitUntilCompleted]; cmd = nil;
    }
    uint32_t bits = SDESC(d, 84), rm = SDESC(d, 88), pitch = SDESC(d, 16);
    uint32_t w = MIN(SDESC(d, 12), W), h = MIN(SDESC(d, 8), H);
    const uint32_t *src = (const uint32_t *)rb_buf.contents;
    for (uint32_t y = 0; y < h; y++) {
        const uint32_t *in = src + (size_t)y * W;
        uint8_t *row = MEM + d->mem + (size_t)y * pitch;
        if (bits == 32) { uint32_t *o = (uint32_t *)row; for (uint32_t x = 0; x < w; x++) o[x] = in[x] | 0xFF000000u; }
        else if (bits == 16) {
            uint16_t *o = (uint16_t *)row;
            for (uint32_t x = 0; x < w; x++) {
                uint32_t p = in[x], r = (p >> 16) & 255, g = (p >> 8) & 255, bl = p & 255;
                o[x] = rm == 0xF800 ? (uint16_t)((r >> 3) << 11 | (g >> 2) << 5 | bl >> 3) : (uint16_t)(0x8000 | (r >> 3) << 10 | (g >> 3) << 5 | bl >> 3);
            }
        }
    }
    rb_last_s = s; rb_last_gen = rt_gen;
    static int n; if (n++ < 3) fprintf(stderr, "[metal] back buffer read back into surface #%d (%ux%u, %u bits)\n", s, w, h, bits);
    UNLOCK
}

// ---- present ---------------------------------------------------------------------------------------
static int in_list(const char *env, char *list, size_t n, int *init, uint64_t f) {
    if (!*init) { *init = 1; const char *e = getenv(env); if (e) snprintf(list, n, ",%s,", e); }
    if (!list[0]) return 0;
    char k[32]; snprintf(k, sizeof k, ",%llu,", (unsigned long long)f);
    return strstr(list, k) != NULL;
}
static int want_dump(uint64_t f) { static char l[1024]; static int i; return in_list("M1_DUMP", l, sizeof l, &i, f); }
static int want_dump_show(uint64_t f) { static char l[1024]; static int i; return in_list("M1_DUMP_SHOW", l, sizeof l, &i, f); }
static void overlay_draw(id<MTLCommandBuffer> cb, id<MTLTexture> target);
static void dump_png(const char *kind, uint64_t frame) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:BW height:BH mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [mdev newTextureWithDescriptor:d];
    id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
    [b copyFromTexture:bb toTexture:t]; [b endEncoding];
    overlay_draw(cmd, t);               // a dump taken while the overlay is open shows it
    [cmd commit]; [cmd waitUntilCompleted]; cmd = [queue commandBuffer];
    size_t bpr = BW * 4;
    uint8_t *px = malloc(bpr * BH);
    [t getBytes:px bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, BW, BH) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, BW, BH, 8, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    char path[256]; snprintf(path, sizeof path, kind[0] == 't' && !kind[1] ? "m1_%s%llu.png" : "m1_%s_%llu.png", kind, (unsigned long long)frame);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs); free(px);
    fprintf(stderr, "[metal] dumped %s (%ux%u)\n", path, BW, BH);
}
// Show the back buffer in the window. Flip does this once per frame. A Blt from the back buffer to the
// primary surface (gpu_show) does it too: the loading screen is drawn by cshell's loading thread with
// 2D Blts and copied to the front buffer that way, without Flip. Shows are not counted as frames;
// M1_DUMP_SHOW=<n,...> dumps the n-th one as m1_show_<n>.png.
// ---- runtime settings ----------------------------------------------------------------------------------
// gpu_settings_* store a request under LOCK; present() applies it after the frame is committed (no encoder or command
// buffer open). Scale/MSAA change recreates the render targets and flushes the pipeline cache (the back buffer content
// is lost for one frame); aniso/trilinear flush the sampler cache; texture replace/dump re-resolve every texture.
static struct { int has, scale, msaa, aniso, tri, rep, dump; } req;
static void persist_int(CFStringRef key, int v) {
    if (getenv("M1_NO_PERSIST")) return;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFPreferencesSetAppValue(key, n, PREF_DOMAIN); CFRelease(n);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}
static void persist_bool(CFStringRef key, int v) {
    if (getenv("M1_NO_PERSIST")) return;
    CFPreferencesSetAppValue(key, v ? kCFBooleanTrue : kCFBooleanFalse, PREF_DOMAIN);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}
static void req_fill(void) {      // start a pending request from the current values
    if (req.has) return;
    req.has = 1; req.scale = SCREQ; req.msaa = MS; req.aniso = ANI; req.tri = TRI; req.rep = texpack_replace_on(); req.dump = texpack_dump_on();
}
void gpu_settings_request(int scale, int msaa, int aniso, int tri, int texreplace, int texdump) {
    if (!gpu_on()) return;
    LOCK
    req.has = 1; req.scale = scale; req.msaa = msaa; req.aniso = aniso; req.tri = tri; req.rep = texreplace; req.dump = texdump;
    UNLOCK
}
void gpu_settings_set_one(int what, int value) {
    if (!gpu_on()) return;
    LOCK
    req_fill();
    switch (what) { case 1: req.scale = value; break; case 2: req.msaa = value; break; case 3: req.aniso = value; break;
    case 4: req.tri = value; break; case 5: req.rep = value; break; case 6: req.dump = value; break; }
    UNLOCK
}
void gpu_settings_get(int *scale, int *msaa, int *aniso, int *tri, int *texreplace, int *texdump, int *scale_effective) {
    if (!gpu_on()) { if (scale) *scale = 1; if (msaa) *msaa = 1; if (aniso) *aniso = 1; if (tri) *tri = 0; if (texreplace) *texreplace = 0; if (texdump) *texdump = 0; if (scale_effective) *scale_effective = 1; return; }
    LOCK
    if (scale) *scale = SCREQ; if (scale_effective) *scale_effective = SC;
    if (msaa) *msaa = MS; if (aniso) *aniso = ANI; if (tri) *tri = TRI;
    if (texreplace) *texreplace = texpack_replace_on(); if (texdump) *texdump = texpack_dump_on();
    UNLOCK
}
void host_maxfps_set(int fps) { persist_int(CFSTR("MaxFPS"), fps < 0 ? 0 : fps); }
static void apply_settings(void) {
    if (!req.has) return;
    if (layer && ![NSThread isMainThread]) return;      // layer.drawableSize / AppKit: stay pending until a main-thread present
    req.has = 0;
    int nsc = resolve_scale(req.scale, H, SC), nms = resolve_msaa(req.msaa);
    int nani = req.aniso < 1 ? 1 : req.aniso > 16 ? 16 : req.aniso, ntri = req.tri != 0, nrep = req.rep != 0, ndump = req.dump != 0;
    int ch_t = nsc != SC || nms != MS, ch_s = nani != ANI || ntri != TRI;
    int ch_r = nrep != (texpack_replace_on() != 0), ch_d = ndump != (texpack_dump_on() != 0);
    int ch_req = req.scale != SCREQ;
    if (!ch_t && !ch_s && !ch_r && !ch_d && !ch_req) return;
    if (ch_req) { SCREQ = req.scale; persist_int(CFSTR("RenderScale"), SCREQ); }
    if (nms != MS) persist_int(CFSTR("MSAA"), nms);
    if (nani != ANI) persist_int(CFSTR("Anisotropy"), nani);
    if (ntri != TRI) persist_int(CFSTR("Trilinear"), ntri);
    if (ch_t) { SC = nsc; MS = nms; make_targets(); for (int i = 0; i < 512; i++) pso[i] = nil; }
    if (ch_s) { ANI = nani; TRI = ntri; for (int i = 0; i < 4096; i++) samp[i] = nil; }
    if (ch_r || ch_d) {
        for (NSNumber *k in [rhash allKeys]) rep_unbind(k.intValue);      // before replace goes off: release needs it on
        if (ch_r) { texpack_set_replace(nrep); persist_bool(CFSTR("TextureReplace"), nrep); }
        if (ch_d) { texpack_set_dump(ndump); persist_bool(CFSTR("TextureDump"), ndump); }
        [ktex removeAllObjects];
        for (int i = 0; i < nsf; i++) if (sf[i].alive && sf[i].gpu && sf[i].owner < 0) sf[i].dirty = 1;   // re-hash / re-upload on next bind
    }
    fprintf(stderr, "[metal] settings applied: scale %d (%ux%u), MSAA %d, aniso %d, tri %d, replace %d, dump %d\n", SC, BW, BH, MS, ANI, TRI, texpack_replace_on() != 0, texpack_dump_on() != 0);
}
int gpu_msaa_ok(int n) { return n <= 1 || (mdev && [mdev supportsTextureSampleCount:(NSUInteger)n]); }
// Settings overlay: a second pass over the presented image (or over a dump copy), never into the back buffer.
static void overlay_draw(id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    if (!overlay_is_open() || !ov_pso || !cb) return;
    int ver = overlay_version();
    BOOL stale = !ov_tex || ov_ver != ver || ov_sc != SC;
    if (stale && layer && ![NSThread isMainThread]) { if (!ov_tex) return; stale = NO; }   // AppKit text only on the main thread; draw the old panel
    if (stale) {
        uint8_t *px = overlay_render(SC);
        if (!px) return;
        int lw, lh; overlay_size(&lw, &lh);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)lw * SC height:(NSUInteger)lh * SC mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
        ov_tex = [mdev newTextureWithDescriptor:d];
        [ov_tex replaceRegion:MTLRegionMake2D(0, 0, ov_tex.width, ov_tex.height) mipmapLevel:0 withBytes:px bytesPerRow:ov_tex.width * 4];
        free(px); ov_ver = ver; ov_sc = SC;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    float tw = (float)target.width, th = (float)target.height, pw = (float)ov_tex.width, ph = (float)ov_tex.height;
    float x0 = (tw - pw) / 2, y0 = (th - ph) / 2;
    float r[4] = {x0 / tw * 2 - 1, 1 - y0 / th * 2, (x0 + pw) / tw * 2 - 1, 1 - (y0 + ph) / th * 2};
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    static id<MTLSamplerState> lin; if (!lin) lin = [mdev newSamplerStateWithDescriptor:sd];
    [re setRenderPipelineState:ov_pso]; [re setVertexBytes:r length:sizeof r atIndex:0];
    [re setFragmentTexture:ov_tex atIndex:0]; [re setFragmentSamplerState:lin atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [re endEncoding];
}
static volatile long pending_tdump = -1;
void gpu_request_dump(unsigned long ms) { pending_tdump = (long)ms; }   // M1_SCRIPT_MS 'p': dumped at the next flip
static void present(int flip) {
    static uint64_t shows;
    @autoreleasepool {
        if (pending_clear) begin_pass();
        end_pass();
        if (!cmd) cmd = [queue commandBuffer];
        if (flip) { frames++; if (want_dump(frames)) dump_png("frame", frames);
                   if (pending_tdump >= 0) { long t = pending_tdump; pending_tdump = -1; dump_png("t", (uint64_t)t); } }
        else { shows++; if (want_dump_show(shows)) dump_png("show", shows); }
        id<CAMetalDrawable> drawable = layer ? [layer nextDrawable] : nil;
        if (drawable) {
            id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
            [b copyFromTexture:bb toTexture:drawable.texture]; [b endEncoding];
            overlay_draw(cmd, drawable.texture);
            [cmd presentDrawable:drawable];
        }
        dispatch_semaphore_t sem = inflight;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb; dispatch_semaphore_signal(sem); }];
        [cmd commit];
        cmd = nil;
        dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
        ring_i = (ring_i + 1) % 3; ring_off = 0;
        apply_settings();
    }
}
void gpu_present(void) {
    if (!gpu_on() || !ready) return;
    LOCK
    present(1);
    UNLOCK
    host_pump_events();
}
void gpu_show(void) {
    if (!gpu_on() || !ready) return;
    LOCK
    present(0);
    UNLOCK
    host_pump_events();
}

// ---- events ------------------------------------------------------------------------------------------
static const uint8_t mac2dik[128] = {
    [0x00] = 0x1E, [0x01] = 0x1F, [0x02] = 0x20, [0x03] = 0x21, [0x04] = 0x23, [0x05] = 0x22, [0x06] = 0x2C, [0x07] = 0x2D,
    [0x08] = 0x2E, [0x09] = 0x2F, [0x0B] = 0x30, [0x0C] = 0x10, [0x0D] = 0x11, [0x0E] = 0x12, [0x0F] = 0x13, [0x10] = 0x15,
    [0x11] = 0x14, [0x12] = 0x02, [0x13] = 0x03, [0x14] = 0x04, [0x15] = 0x05, [0x16] = 0x07, [0x17] = 0x06, [0x18] = 0x0D,
    [0x19] = 0x0A, [0x1A] = 0x08, [0x1B] = 0x0C, [0x1C] = 0x09, [0x1D] = 0x0B, [0x1E] = 0x1B, [0x1F] = 0x18, [0x20] = 0x16,
    [0x21] = 0x1A, [0x22] = 0x17, [0x23] = 0x19, [0x24] = 0x1C, [0x25] = 0x26, [0x26] = 0x24, [0x27] = 0x28, [0x28] = 0x25,
    [0x29] = 0x27, [0x2A] = 0x2B, [0x2B] = 0x33, [0x2C] = 0x35, [0x2D] = 0x31, [0x2E] = 0x32, [0x2F] = 0x34, [0x30] = 0x0F,
    [0x31] = 0x39, [0x32] = 0x29, [0x33] = 0x0E, [0x35] = 0x01, [0x37] = 0xDB, [0x38] = 0x2A, [0x39] = 0x3A, [0x3A] = 0x38,
    [0x3B] = 0x1D, [0x3C] = 0x36, [0x3D] = 0xB8, [0x3E] = 0x9D, [0x41] = 0x53, [0x43] = 0x37, [0x45] = 0x4E, [0x4B] = 0xB5,
    [0x4C] = 0x9C, [0x4E] = 0x4A, [0x52] = 0x52, [0x53] = 0x4F, [0x54] = 0x50, [0x55] = 0x51, [0x56] = 0x4B, [0x57] = 0x4C,
    [0x58] = 0x4D, [0x59] = 0x47, [0x5B] = 0x48, [0x5C] = 0x49, [0x60] = 0x3F, [0x61] = 0x40, [0x62] = 0x41, [0x63] = 0x3D,
    [0x64] = 0x42, [0x65] = 0x43, [0x67] = 0x57, [0x6D] = 0x44, [0x6F] = 0x58, [0x72] = 0xD2, [0x73] = 0xC7, [0x74] = 0xC9,
    [0x75] = 0xD3, [0x76] = 0x3E, [0x77] = 0xCF, [0x78] = 0x3C, [0x79] = 0xD1, [0x7A] = 0x3B, [0x7B] = 0xCB, [0x7C] = 0xCD,
    [0x7D] = 0xD0, [0x7E] = 0xC8,
};
// Mouse buttons: while the overlay is open presses are swallowed; a release is forwarded only if its press was.
static void mouse_btn(int b, int down) {
    static uint8_t fwd[8];
    if (b < 0 || b > 7) return;
    if (down) { if (overlay_is_open()) return; fwd[b] = 1; input_mouse_button(b, 1); }
    else if (fwd[b]) { fwd[b] = 0; input_mouse_button(b, 0); }
}
static int mod_pending;
static void sync_mods(NSEventModifierFlags f) {
    input_key(0x2A, (f & NSEventModifierFlagShift) != 0); input_key(0x1D, (f & NSEventModifierFlagControl) != 0);
    input_key(0x38, (f & NSEventModifierFlagOption) != 0);
}
static void handle_event(NSEvent *e) {
    switch (e.type) {
    case NSEventTypeKeyDown: case NSEventTypeKeyUp: {
        BOOL kd = e.type == NSEventTypeKeyDown;
        if (e.keyCode < 128 && overlay_filter_key(mac2dik[e.keyCode], kd, e.isARepeat)) return;     // the settings overlay owns it
        if (e.keyCode < 128 && !e.isARepeat) input_key(mac2dik[e.keyCode], kd);
        if (kd) {
            NSString *ch = e.characters;
            for (NSUInteger i = 0; i < ch.length; i++) { unichar u = [ch characterAtIndex:i]; if (u == 0x7F) u = 8; if (u >= 8 && u < 256 && u != 0x1B) host_input_char(u); }
        }
        return;
    }
    case NSEventTypeFlagsChanged: {
        NSEventModifierFlags f = e.modifierFlags;
        if (overlay_is_open()) { mod_pending = 1; return; }       // synced on close (host_pump_events)
        sync_mods(f);
        return;
    }
    case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
        if (overlay_is_open()) return;
        input_mouse_move((int)lround(e.deltaX), (int)lround(e.deltaY)); return;
    case NSEventTypeLeftMouseDown: mouse_btn(0, 1); return;
    case NSEventTypeLeftMouseUp: mouse_btn(0, 0); return;
    case NSEventTypeRightMouseDown: mouse_btn(1, 1); return;
    case NSEventTypeRightMouseUp: mouse_btn(1, 0); return;
    case NSEventTypeOtherMouseDown: mouse_btn((int)e.buttonNumber, 1); return;
    case NSEventTypeOtherMouseUp: mouse_btn((int)e.buttonNumber, 0); return;
    case NSEventTypeScrollWheel: if (overlay_is_open()) return; input_mouse_wheel((int)lround(e.scrollingDeltaY * 40)); return;
    default: return;
    }
}
void host_pump_events(void) {
    if (!layer || ![NSThread isMainThread]) return;
    @autoreleasepool {
        static BOOL captured, released;
        BOOL key = window.isKeyWindow && !released;
        if (key != captured) {          // relative mouse while the game window is active (the game draws its own cursor)
            captured = key;
            CGAssociateMouseAndMouseCursorPosition(!key);
            if (key) [NSCursor hide]; else [NSCursor unhide];
        }
        if (mod_pending && !overlay_is_open()) { mod_pending = 0; sync_mods([NSEvent modifierFlags]); }   // modifiers changed while the overlay was open
        NSEvent *e;
        while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])) {
            BOOL shortcut = e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand);
            if (shortcut && e.keyCode == 0x35) {          // Cmd+Esc releases the mouse
                CGAssociateMouseAndMouseCursorPosition(true); [NSCursor unhide]; captured = NO; released = YES;
                continue;
            }
            if (!shortcut && (e.window == window || e.type == NSEventTypeFlagsChanged)) handle_event(e);
            if (e.type == NSEventTypeLeftMouseDown && e.window == window) released = NO;
            if (shortcut || (e.type != NSEventTypeKeyDown && e.type != NSEventTypeKeyUp)) [NSApp sendEvent:e];   // Cmd+Q, Ctrl+Cmd+F, Cmd+H, Cmd+M
        }
    }
}
