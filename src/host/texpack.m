// HD texture pack, part 1: content hash of every texture the game uploads, and a dump mode that writes each
// distinct texture once as <hash>.png (non-premultiplied RGBA8, level 0) plus an index.tsv.
// Replacement (M1_TEXREPLACE=1): at upload, <TextureDir>/replace/<hash>.png|.dds (same hash as the dump names) is used
// instead of the original texture; see texpack_texture below.
//
// Env / defaults keys (env wins, then the key in domain local.mm9-native, then the default):
//   M1_TEXDUMP=1 (key TextureDump, bool, default off): hash + dump uploaded textures. Off: no hashing at all.
//   M1_TEXDIR=<path> (key TextureDir, string, default "HDTextures" relative to the game folder = cwd):
//     dump folder is <TextureDir>/dump (hash.png, index.tsv), replacement folder will be <TextureDir>/replace.
//
// Hash: 64-bit, 8 bytes per step (xxHash64-like multiply/rotate mix, own implementation) over the level-0
// pixel rows only (w*bytes-per-pixel per row, or the DXT block rows; pitch padding ignored), seeded with
// width, height, format code and (for colour-keyed non-DXT surfaces) the colour key. Name = 16 lowercase hex.
// Dynamic textures (content hash changed on more than 3 uploads of the same root surface: movies, render
// targets, animated lightmaps) are no longer hashed or dumped for the rest of the run.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "host.h"
#include "d3d_int.h"

#define PREF_DOMAIN_TP CFSTR("local.mm9-native")
enum { F_DXT1, F_DXT3, F_DXT5, F_ARGB8888, F_XRGB8888, F_RGB565, F_ARGB1555, F_XRGB1555, F_ARGB4444, F_XRGB4444, F_NFMT };
static const char *const fmt_name[F_NFMT] = {"DXT1", "DXT3", "DXT5", "ARGB8888", "XRGB8888", "RGB565", "ARGB1555", "XRGB1555", "ARGB4444", "XRGB4444"};

static int dump_on = -1;
static int rep_on;
static NSString *dump_dir;
static dispatch_queue_t q;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t *seen; static size_t seen_cap, seen_n;     // open-addressing set of dumped hashes (0 = empty)
typedef struct { uint64_t last; int changes; int dyn; } Track;
static Track *trk; static int trk_n;
static volatile uint64_t n_dumped, n_dyn, n_written, n_hashed;
static double last_log;

static int cf_bool_or_env(const char *env, CFStringRef key) {
    const char *e = getenv(env);
    if (e && *e) return atoi(e) != 0;
    Boolean valid = false;
    Boolean on = CFPreferencesGetAppBooleanValue(key, PREF_DOMAIN_TP, &valid);
    return valid && on;
}
static NSString *dir_setting(void) {
    const char *e = getenv("M1_TEXDIR");
    if (e && *e) return [NSString stringWithUTF8String:e];
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("TextureDir"), PREF_DOMAIN_TP);
    NSString *r = nil;
    if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetLength(v) > 0) r = [(__bridge NSString *)v copy];
    if (v) CFRelease(v);
    return r ? r : @"HDTextures";
}
static void summary(void) {
    if (q) dispatch_sync(q, ^{});       // drain pending writes
    { extern void texhook_stats(int *, int *, int *); int b, n, u; texhook_stats(&b, &n, &u); fprintf(stderr, "[texhook] %d BindTexture calls, %d without path, %d distinct paths\n", b, n, u); }
    fprintf(stderr, "[texpack] %llu textures dumped (%llu written), %llu dynamic skipped\n",
            (unsigned long long)n_dumped, (unsigned long long)n_written, (unsigned long long)n_dyn);
}
static NSString *rep_dir;
static NSMutableDictionary *rep_pkey;             // normalised path -> tagged key
static int n_pfiles, rep_atexit, n_bypath, n_byhash;
static NSMutableSet *rep_seen;
static NSMutableDictionary *rep_byid;
static void rep_summary(void) { fprintf(stderr, "[texpack] replace: %d by path, %d by hash\n", n_bypath, n_byhash); }
static NSMutableDictionary *rep_files, *rep_cache, *rep_opaque, *rep_ref;      // hash -> path; hash -> texture or NSNull (load failed); opaque views; refcounts
static int dump_atexit;
static void setup_dump(void) {
    NSString *base = dir_setting();
    dump_dir = [base stringByAppendingPathComponent:@"dump"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dump_dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (!q) q = dispatch_queue_create("texpack", DISPATCH_QUEUE_SERIAL);
    if (!seen) { seen_cap = 1 << 14; seen = calloc(seen_cap, 8); }
    fprintf(stderr, "[texpack] dump on -> %s\n", dump_dir.fileSystemRepresentation);
    if (!dump_atexit) { dump_atexit = 1; atexit(summary); }
}
static void setup_replace(void) {       // (re)scans <TextureDir>/replace
    NSString *base = dir_setting();
    rep_dir = [base stringByAppendingPathComponent:@"replace"];
    if (!rep_files) { rep_cache = [NSMutableDictionary dictionary]; rep_opaque = [NSMutableDictionary dictionary]; rep_ref = [NSMutableDictionary dictionary]; }
    rep_files = [NSMutableDictionary dictionary];
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:rep_dir error:nil]) {
        NSString *ext = n.pathExtension.lowercaseString, *b = n.stringByDeletingPathExtension;
        if (b.length != 16 || !([ext isEqualToString:@"png"] || [ext isEqualToString:@"dds"])) continue;
        unsigned long long h = 0; if (sscanf(b.UTF8String, "%16llx", &h) != 1 || !h) continue;
        NSNumber *k = @(h);
        if (rep_files[k] && [ext isEqualToString:@"png"]) continue;     // .dds wins over .png
        rep_files[k] = [rep_dir stringByAppendingPathComponent:n];
    }
    // by path: every <name>.png|.dds below replace/ (recursively) that is not a 16-hex hash file; key = lower-case path with '/'
    // and without extension (e.g. textures/a9jyrkavik/walls/wainscot-books-full), mapped to a tagged key (bit 63) in rep_files.
    rep_pkey = [NSMutableDictionary dictionary]; rep_byid = nil;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:rep_dir];
    for (NSString *rel in en) {
        NSString *ext = rel.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"png"] && ![ext isEqualToString:@"dds"]) continue;
        NSString *np = [[rel.stringByDeletingPathExtension stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lowercaseString];
        if (![np containsString:@"/"] && np.length == 16) continue;          // top-level hash file
        uint64_t hh = 1469598103934665603ull; for (const char *p = np.UTF8String; *p; p++) hh = (hh ^ (uint8_t)*p) * 1099511628211ull;
        NSNumber *k = @(hh | (1ull << 63));
        NSString *full = [rep_dir stringByAppendingPathComponent:rel];
        if (rep_files[k] && [ext isEqualToString:@"png"]) continue;
        rep_files[k] = full; rep_pkey[np] = k; n_pfiles++;
    }
    fprintf(stderr, "[texpack] replace: %lu files (%s), %d by path name\n", (unsigned long)rep_files.count - n_pfiles, rep_dir.fileSystemRepresentation, n_pfiles);
    if (!rep_atexit) { rep_atexit = 1; atexit(rep_summary); }
}
void texpack_init(void) {
    if (dump_on >= 0) return;
    dump_on = cf_bool_or_env("M1_TEXDUMP", CFSTR("TextureDump"));
    rep_on = cf_bool_or_env("M1_TEXREPLACE", CFSTR("TextureReplace"));
    if (dump_on) setup_dump();
    if (rep_on) setup_replace();
}
// Runtime switches (called under the Metal lock at a frame boundary). Safe to call before the first upload.
void texpack_set_dump(int on) {
    texpack_init(); on = on != 0;
    if (on == (dump_on > 0)) return;
    dump_on = on; if (on) setup_dump(); else if (q) dispatch_sync(q, ^{});
}
void texpack_set_replace(int on) {
    texpack_init(); on = on != 0;
    if (on == (rep_on != 0)) return;
    rep_on = on; if (on) setup_replace();
}
int texpack_dump_on(void) { texpack_init(); return dump_on > 0; }
int texpack_on(void) { if (dump_on < 0) texpack_init(); return dump_on > 0 || rep_on; }
int texpack_replace_on(void) { return rep_on; }

// ---- format / hash ---------------------------------------------------------------------------------
static int fmt_code(const Surf *s) {
    uint32_t fl = SDESC(s, 76), cc = SDESC(s, 80), bits = SDESC(s, 84), rm = SDESC(s, 88), am = SDESC(s, 100);
    int alpha = (fl & 1) && am;
    if (fl & 4) return cc == 0x31545844 ? F_DXT1 : cc == 0x33545844 ? F_DXT3 : cc == 0x35545844 ? F_DXT5 : -1;
    if (bits == 32) return alpha ? F_ARGB8888 : F_XRGB8888;
    if (bits == 16 && rm == 0xF800) return F_RGB565;
    if (bits == 16 && rm == 0x7C00) return alpha ? F_ARGB1555 : F_XRGB1555;
    if (bits == 16 && rm == 0x0F00) return alpha ? F_ARGB4444 : F_XRGB4444;
    return -1;
}
int texpack_noalpha(const Surf *s) { int fc = fmt_code(s); return fc == F_RGB565 || fc == F_XRGB1555 || fc == F_XRGB8888 || fc == F_XRGB4444; }
static int is_keyed(const Surf *s, int fc) { return fc >= F_ARGB8888 && (SDESC(s, 4) & 0x10000); }
#define P1 0x9E3779B185EBCA87ull
#define P2 0xC2B2AE3D27D4EB4Full
#define P3 0x165667B19E3779F9ull
#define P4 0x85EBCA77C2B2AE63ull
#define P5 0x27D4EB2F165667C5ull
static inline uint64_t rotl(uint64_t x, int r) { return x << r | x >> (64 - r); }
static inline uint64_t rnd(uint64_t k) { return rotl(k * P2, 31) * P1; }
static inline uint64_t step(uint64_t h, uint64_t k) { return rotl(h ^ rnd(k), 27) * P1 + P4; }
static uint64_t hash_rows(const uint8_t *p, size_t rowbytes, size_t pitch, uint32_t rows, uint64_t seed, uint64_t mask) {
    uint64_t h = seed + P5;
    for (uint32_t y = 0; y < rows; y++) {
        const uint8_t *r = p + (size_t)y * pitch; size_t i = 0;
        for (; i + 8 <= rowbytes; i += 8) { uint64_t k; memcpy(&k, r + i, 8); h = step(h, k & mask); }
        if (i < rowbytes) { uint64_t k = 0; memcpy(&k, r + i, rowbytes - i); k &= mask; h = step(h, k ^ ((uint64_t)(rowbytes - i) << 56)); }
    }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h ? h : 1;
}
// Level-0 geometry: rowbytes/rows/pitch of the data to hash. Returns 0 if unusable.
static int geom(const Surf *s, int fc, size_t *rowbytes, size_t *pitch, uint32_t *rows) {
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8);
    if (!w || !h || w > 8192 || h > 8192) return 0;
    if (fc <= F_DXT5) {
        size_t bw = (w + 3) / 4, bh = (h + 3) / 4, bs = fc == F_DXT1 ? 8 : 16;
        *rowbytes = *pitch = bw * bs; *rows = (uint32_t)bh;
    } else { *rowbytes = (size_t)w * (SDESC(s, 84) / 8); *pitch = SDESC(s, 16); *rows = h; if (*pitch < *rowbytes) return 0; }
    if ((uint64_t)s->mem + (uint64_t)*pitch * *rows > 0xFFFFFFFFull) return 0;
    return 1;
}
uint64_t texpack_hash(const Surf *s, int root) {
    if (!texpack_on() || !s->mem) return 0;
    if (root < trk_n && trk[root].dyn) return 0;
    int fc = fmt_code(s); size_t rb, pt; uint32_t rows;
    if (fc < 0 || !geom(s, fc, &rb, &pt, &rows)) return 0;
    uint64_t seed = (uint64_t)SDESC(s, 12) | (uint64_t)SDESC(s, 8) << 16 | (uint64_t)fc << 32;
    if (is_keyed(s, fc)) seed ^= (uint64_t)(SDESC(s, 64) | 0x1000000u) << 36 ^ 0xA5A5ull << 48;
    n_hashed++;
    // don't-care bits of formats without alpha are masked (they are not rendered, and may hold noise)
    uint64_t mask = fc == F_XRGB8888 ? 0x00FFFFFF00FFFFFFull : fc == F_XRGB1555 ? 0x7FFF7FFF7FFF7FFFull : fc == F_XRGB4444 ? 0x0FFF0FFF0FFF0FFFull : ~0ull;
    return hash_rows(MEM + s->mem, rb, pt, rows, seed, mask);
}
void texpack_forget(int root) { if (root < trk_n) memset(&trk[root], 0, sizeof(Track)); }

// ---- decoding --------------------------------------------------------------------------------------
static inline uint32_t rgba(uint32_t r, uint32_t g, uint32_t b, uint32_t a) { return r | g << 8 | b << 16 | a << 24; }
static inline void c565(uint32_t v, uint32_t *r, uint32_t *g, uint32_t *b) {
    uint32_t R = v >> 11 & 31, G = v >> 5 & 63, B = v & 31;
    *r = R << 3 | R >> 2; *g = G << 2 | G >> 4; *b = B << 3 | B >> 2;
}
static void decode_dxt(const uint8_t *src, uint32_t w, uint32_t h, int fc, uint32_t *out) {
    size_t bw = (w + 3) / 4, bh = (h + 3) / 4, bs = fc == F_DXT1 ? 8 : 16;
    for (size_t by = 0; by < bh; by++) for (size_t bx = 0; bx < bw; bx++) {
        const uint8_t *b = src + (by * bw + bx) * bs;
        const uint8_t *cb = fc == F_DXT1 ? b : b + 8;
        uint16_t c0 = (uint16_t)(cb[0] | cb[1] << 8), c1 = (uint16_t)(cb[2] | cb[3] << 8);
        uint32_t pal[4], r0, g0, b0, r1, g1, b1;
        c565(c0, &r0, &g0, &b0); c565(c1, &r1, &g1, &b1);
        pal[0] = rgba(r0, g0, b0, 255); pal[1] = rgba(r1, g1, b1, 255);
        if (c0 > c1 || fc != F_DXT1) {
            pal[2] = rgba((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3, 255);
            pal[3] = rgba((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3, 255);
        } else { pal[2] = rgba((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255); pal[3] = 0; }
        uint32_t idx = (uint32_t)(cb[4] | cb[5] << 8 | cb[6] << 16 | (uint32_t)cb[7] << 24);
        uint8_t al[8]; uint64_t abits = 0;
        if (fc == F_DXT5) {
            al[0] = b[0]; al[1] = b[1];
            if (al[0] > al[1]) for (int i = 1; i < 7; i++) al[1 + i] = (uint8_t)(((7 - i) * al[0] + i * al[1]) / 7);
            else { for (int i = 1; i < 5; i++) al[1 + i] = (uint8_t)(((5 - i) * al[0] + i * al[1]) / 5); al[6] = 0; al[7] = 255; }
            for (int i = 0; i < 6; i++) abits |= (uint64_t)b[2 + i] << (8 * i);
        }
        for (int py = 0; py < 4; py++) for (int px = 0; px < 4; px++) {
            uint32_t x = (uint32_t)bx * 4 + px, y = (uint32_t)by * 4 + py;
            if (x >= w || y >= h) continue;
            int n = py * 4 + px;
            uint32_t c = pal[idx >> (2 * n) & 3];
            if (fc == F_DXT3) { uint32_t a4 = (b[n / 2] >> (4 * (n & 1))) & 15; c = (c & 0xFFFFFF) | (a4 * 17) << 24; }
            else if (fc == F_DXT5) c = (c & 0xFFFFFF) | (uint32_t)al[abits >> (3 * n) & 7] << 24;
            out[(size_t)y * w + x] = c;
        }
    }
}
static void decode_raw(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, int fc, int keyed, uint32_t key, uint32_t *out) {
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
        uint32_t o;
        if (fc == F_ARGB8888 || fc == F_XRGB8888) {
            uint32_t v; memcpy(&v, src + y * pitch + x * 4, 4);
            uint32_t a = fc == F_ARGB8888 ? v >> 24 : 255;
            o = rgba(v >> 16 & 255, v >> 8 & 255, v & 255, a);
            if (keyed && (v & 0xFFFFFF) == (key & 0xFFFFFF)) o = 0;
        } else {
            uint16_t q16; memcpy(&q16, src + y * pitch + x * 2, 2); uint32_t v = q16, r, g, b, a = 255, cm = 0xFFFF;
            if (fc == F_RGB565) c565(v, &r, &g, &b);
            else if (fc == F_ARGB4444 || fc == F_XRGB4444) {
                r = (v >> 8 & 15) * 17; g = (v >> 4 & 15) * 17; b = (v & 15) * 17; cm = 0x0FFF;
                if (fc == F_ARGB4444) a = (v >> 12) * 17;
            } else {
                r = v >> 10 & 31; g = v >> 5 & 31; b = v & 31; r = r << 3 | r >> 2; g = g << 3 | g >> 2; b = b << 3 | b >> 2; cm = 0x7FFF;
                if (fc == F_ARGB1555) a = v >> 15 ? 255 : 0;
            }
            o = rgba(r, g, b, a);
            if (keyed && (v & cm) == (key & cm)) o = 0;
        }
        out[(size_t)y * w + x] = o;
    }
}

// ---- dump ------------------------------------------------------------------------------------------
static inline size_t seen_slot(uint64_t h, size_t cap) { return (size_t)((h * P1 >> 20) & (cap - 1)); }
static int seen_add(uint64_t h) {       // returns 1 if newly added
    if ((seen_n + 1) * 2 > seen_cap) {
        size_t nc = seen_cap * 2; uint64_t *ns = calloc(nc, 8);
        for (size_t i = 0; i < seen_cap; i++) if (seen[i]) { size_t j = seen_slot(seen[i], nc); while (ns[j]) j = (j + 1) & (nc - 1); ns[j] = seen[i]; }
        free(seen); seen = ns; seen_cap = nc;
    }
    size_t j = seen_slot(h, seen_cap);
    while (seen[j]) { if (seen[j] == h) return 0; j = (j + 1) & (seen_cap - 1); }
    seen[j] = h; seen_n++; return 1;
}
static void write_png(NSString *path, const uint32_t *px, uint32_t w, uint32_t h) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)px length:(NSUInteger)w * h * 4 freeWhenDone:NO];
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, kCGImageAlphaLast | kCGBitmapByteOrderDefault, dp, NULL, false, kCGRenderingIntentDefault);
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)tmp.fileSystemRepresentation, (CFIndex)strlen(tmp.fileSystemRepresentation), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    if (CGImageDestinationFinalize(dst)) rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
    CFRelease(dst); CFRelease(url); CGImageRelease(img); CGColorSpaceRelease(cs); CGDataProviderRelease(dp);
}
int texpack_on_upload(int root, const Surf *s, uint64_t hash, int mips, uint64_t frame) {
    if ((!dump_on && !rep_on) || !hash) return 0;
    pthread_mutex_lock(&mu);
    if (root >= trk_n) {
        int nn = root + 256; trk = realloc(trk, sizeof(Track) * nn); memset(trk + trk_n, 0, sizeof(Track) * (nn - trk_n)); trk_n = nn;
    }
    Track *t = &trk[root];
    if (t->last && t->last != hash && ++t->changes > 3) {
        t->dyn = 1; n_dyn++;
        fprintf(stderr, "[texpack] dynamic texture (root %d, %ux%u, %s): no longer dumped\n", root, SDESC(s, 12), SDESC(s, 8), fmt_name[fmt_code(s)]);
        pthread_mutex_unlock(&mu); return 0;
    }
    t->last = hash;
    int fresh = dump_on ? seen_add(hash) : 0;
    pthread_mutex_unlock(&mu);
    if (!dump_on) return 1;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - last_log > 5) { if (last_log) fprintf(stderr, "[texpack] %llu dumped, %llu dynamic skipped\n", (unsigned long long)n_dumped, (unsigned long long)n_dyn); last_log = now; }
    if (!fresh) return 1;
    n_dumped++;
    int fc = fmt_code(s); size_t rb, pt; uint32_t rows;
    if (!geom(s, fc, &rb, &pt, &rows)) return 1;
    uint32_t w = SDESC(s, 12), h = SDESC(s, 8), caps = SDESC(s, 104), key = SDESC(s, 64);
    int keyed = is_keyed(s, fc), hasalpha = fc == F_DXT3 || fc == F_DXT5 || fc == F_DXT1 || fc == F_ARGB8888 || fc == F_ARGB1555 || fc == F_ARGB4444;
    uint8_t *raw = malloc(rb * rows);                     // packed copy of level 0; decoding + PNG happen off-thread
    for (uint32_t y = 0; y < rows; y++) memcpy(raw + y * rb, MEM + s->mem + y * pt, rb);
    NSString *dir = dump_dir;
    const char *pstr = tex_path_str(s->path);       // interned for the life of the process
    dispatch_async(q, ^{
        @autoreleasepool {
            NSString *name = [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
            NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                uint32_t *px = calloc((size_t)w * h, 4);
                if (fc <= F_DXT5) decode_dxt(raw, w, h, fc, px); else decode_raw(raw, rb, w, h, fc, keyed, key, px);
                write_png(path, px, w, h);
                free(px);
                NSString *ip = [dir stringByAppendingPathComponent:@"index.tsv"];
                int isnew = ![[NSFileManager defaultManager] fileExistsAtPath:ip];
                FILE *f = fopen(ip.fileSystemRepresentation, "a");
                if (f) {
                    if (isnew) fprintf(f, "hash\twidth\theight\tformat\tmips\thas_alpha\tcolorkey\tfirst_frame\tcaps\tpath\n");
                    fprintf(f, "%s\t%u\t%u\t%s\t%d\t%d\t%d\t%llu\t%08x\t%s\n", name.UTF8String, w, h, fmt_name[fc], mips, hasalpha, keyed,
                            (unsigned long long)frame, caps, pstr ? pstr : "-");
                    fclose(f);
                }
                n_written++;
            }
            free(raw);
        }
    });
    return 1;
}

// ---- replacement textures --------------------------------------------------------------------------
// Swizzling is incompatible with RenderTarget usage (needed for mip generation), so it goes on a view.
static id<MTLTexture> one_alpha(id<MTLTexture> t) {
    return [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, t.mipmapLevelCount) slices:NSMakeRange(0, 1)
                                    swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne)];
}
static id<MTLTexture> load_png(NSString *path, id<MTLDevice> dev, id<MTLCommandQueue> cq, int noalpha) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (!w || !h || w > 8192 || h > 8192) { fprintf(stderr, "[texpack] %s: %zux%zu exceeds the 8192 limit\n", path.lastPathComponent.UTF8String, w, h); CGImageRelease(img); return nil; }
    uint8_t *px = calloc(w * h, 4);
    if (!px) { CGImageRelease(img); return nil; }
    // Preferred: the decoded data as ImageIO holds it, when it is straight (non-premultiplied) 8-bit RGBA/ARGB;
    // keeps the colour of alpha-0 texels (they matter for bilinear edges). Else draw + un-premultiply.
    CGBitmapInfo bi = CGImageGetBitmapInfo(img); CGImageAlphaInfo ai = (CGImageAlphaInfo)(bi & kCGBitmapAlphaInfoMask);
    int direct = 0;
    if (CGImageGetBitsPerComponent(img) == 8 && CGImageGetBitsPerPixel(img) == 32 && (ai == kCGImageAlphaLast || ai == kCGImageAlphaFirst) &&
        (bi & kCGBitmapByteOrderMask) == kCGBitmapByteOrderDefault) {
        CFDataRef dd = CGDataProviderCopyData(CGImageGetDataProvider(img));
        size_t bpr = CGImageGetBytesPerRow(img);
        if (dd && CFDataGetLength(dd) >= (CFIndex)(bpr * h)) {
            const uint8_t *sp = CFDataGetBytePtr(dd);
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
                const uint8_t *p = sp + y * bpr + x * 4; uint8_t *o = px + (y * w + x) * 4;
                if (ai == kCGImageAlphaLast) { o[0] = p[2]; o[1] = p[1]; o[2] = p[0]; o[3] = p[3]; }
                else { o[0] = p[3]; o[1] = p[2]; o[2] = p[1]; o[3] = p[0]; }
            }
            direct = 1;
        }
        if (dd) CFRelease(dd);
    }
    static int logged; if (!logged++) fprintf(stderr, "[texpack] PNG decode path: %s (alphaInfo %u)\n", direct ? "direct straight alpha" : "draw+unpremultiply", (unsigned)ai);
    if (!direct) {
        CGColorSpaceRef cs = CGImageGetColorSpace(img); int own = 0;
        if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) { cs = CGColorSpaceCreateDeviceRGB(); own = 1; }
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        CGContextRelease(ctx); if (own) CGColorSpaceRelease(cs);
        for (size_t i = 0; i < w * h; i++) {                     // un-premultiply (BGRA)
            uint8_t *p = px + i * 4, a = p[3];
            if (a == 0) p[0] = p[1] = p[2] = 0;
            else if (a < 255) for (int c = 0; c < 3; c++) { unsigned v = (p[c] * 255u + a / 2) / a; p[c] = (uint8_t)(v > 255 ? 255 : v); }
        }
    }
    CGImageRelease(img);
    int n = 1; for (size_t m = MAX(w, h); m > 1; m >>= 1) n++;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:n > 1];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (!t) { free(px); return nil; }
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    free(px);
    if (n > 1) {
        id<MTLCommandBuffer> cb = [cq commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b generateMipmapsForTexture:t]; [b endEncoding];
        [cb commit]; [cb waitUntilCompleted];
    }
    return t;
}
static id<MTLTexture> load_dds(NSString *path, id<MTLDevice> dev, id<MTLCommandQueue> cq, int noalpha, const char **err) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    const uint8_t *b = data.bytes; size_t len = data.length;
    if (len < 128 || memcmp(b, "DDS ", 4)) { *err = "not a DDS file"; return nil; }
    uint32_t hd[31]; memcpy(hd, b + 4, 124);        // hd[i] = dword at file offset 4 + 4*i
    uint32_t h = hd[2], w = hd[3], flags = hd[1], mc = (flags & 0x20000) && hd[6] ? hd[6] : 1;
    uint32_t pff = hd[19], cc = hd[20], bits = hd[21], rm = hd[22], gm = hd[23], bm = hd[24], am = hd[25];
    if (hd[0] != 124 || hd[18] != 32 || !w || !h || w > 8192 || h > 8192) { *err = "bad DDS header or size over 8192"; return nil; }
    MTLPixelFormat pf; size_t bs = 0; int raw = 0, forced = 0; (void)noalpha;
    if (pff & 4) {
        if (cc == 0x31545844) { pf = MTLPixelFormatBC1_RGBA; bs = 8; }
        else if (cc == 0x33545844) { pf = MTLPixelFormatBC2_RGBA; bs = 16; }
        else if (cc == 0x35545844) { pf = MTLPixelFormatBC3_RGBA; bs = 16; }
        else { *err = "unsupported DDS FourCC (only DXT1/3/5)"; return nil; }
    } else if ((pff & 0x40) && bits == 32 && rm == 0x00FF0000 && gm == 0xFF00 && bm == 0xFF) {
        pf = MTLPixelFormatBGRA8Unorm; raw = 1; if (!(pff & 1) || !am) forced = 1;   // BGRX file: always opaque
    } else { *err = "unsupported DDS pixel format (only DXT1/3/5, 32-bit BGRA/BGRX)"; return nil; }
    uint32_t maxl = 1; for (uint32_t m = MAX(w, h); m > 1; m >>= 1) maxl++;
    if (mc > maxl) mc = maxl;
    size_t off = 128; uint32_t n = 0;
    for (uint32_t l = 0; l < mc; l++) {
        uint32_t lw = MAX(1u, w >> l), lh = MAX(1u, h >> l);
        size_t sz = raw ? (size_t)lw * lh * 4 : (size_t)((lw + 3) / 4) * ((lh + 3) / 4) * bs;
        if (off + sz > len) break;
        off += sz; n++;
    }
    if (!n) { *err = "truncated DDS"; return nil; }
    int gen = 0;
    if (n == 1 && raw) { gen = 1; for (uint32_t m = MAX(w, h); m > 1; m >>= 1) n++; }
    else if (n == 1) fprintf(stderr, "[texpack] %s: single mip level (block-compressed, no mips)\n", path.lastPathComponent.UTF8String);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:n > 1];
    if (n > 1) d.mipmapLevelCount = n;
    d.usage = MTLTextureUsageShaderRead | (gen ? MTLTextureUsageRenderTarget : 0) | (forced ? MTLTextureUsagePixelFormatView : 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (!t) { *err = "texture creation failed"; return nil; }
    off = 128;
    for (uint32_t l = 0; l < (gen ? 1 : n); l++) {
        uint32_t lw = MAX(1u, w >> l), lh = MAX(1u, h >> l);
        size_t bpr = raw ? (size_t)lw * 4 : (size_t)((lw + 3) / 4) * bs, sz = bpr * (raw ? lh : (lh + 3) / 4);
        [t replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:l withBytes:b + off bytesPerRow:bpr];
        off += sz;
    }
    if (gen) {
        id<MTLCommandBuffer> cb = [cq commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be generateMipmapsForTexture:t]; [be endEncoding];
        [cb commit]; [cb waitUntilCompleted];
    }
    return forced ? one_alpha(t) : t;
}
// Which replacement (if any) applies to this uploaded root surface: the key of a path-named file (surface tagged by the
// BindTexture hook, tex_path_str) first, else the content hash when a <hash> file exists (hash_ok: hash valid / not dynamic).
// The key indexes texpack_texture/retain/release. 0: none.
uint64_t texpack_resolve(const Surf *s, uint64_t hash, int hash_ok) {
    if (!rep_on) return 0;
    uint64_t key = 0;
    const char *ps = tex_path_str(s->path);
    if (ps && rep_pkey.count) {
        if (!rep_byid) rep_byid = [NSMutableDictionary dictionary];      // interned path id -> key or NSNull (cleared on rescan)
        NSMutableDictionary *byid = rep_byid;
        NSNumber *idk = @(s->path), *hit = byid[idk];
        if (!hit) {
            NSString *np = [[[NSString stringWithUTF8String:ps] lowercaseString] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if ([np hasSuffix:@".dtx"]) np = [np substringToIndex:np.length - 4];
            hit = rep_pkey[np] ? rep_pkey[np] : (NSNumber *)[NSNull null]; byid[idk] = hit;
        }
        if (hit != (NSNumber *)[NSNull null]) key = hit.unsignedLongLongValue;
    }
    int bypath = key != 0;
    if (!key && hash_ok && hash && rep_files[@(hash)]) key = hash;
    if (key) {
        if (!rep_seen) rep_seen = [NSMutableSet set];
        NSNumber *kk = @(key);
        if (![rep_seen containsObject:kk]) { [rep_seen addObject:kk]; if (bypath) n_bypath++; else n_byhash++; }
    }
    return key;
}
// Replacement texture for a content hash (cached while a surface holds it, see texpack_retain/release), or nil.
// noalpha: return an opaque view (alpha reads as 1) for originals without alpha; 0: the file's own alpha
// (used for colour-keyed surfaces, where alpha 0 is the key).
id<MTLTexture> texpack_texture(uint64_t hash, id<MTLDevice> dev, id<MTLCommandQueue> cq, int noalpha) {
    if (!rep_on) return nil;
    NSNumber *k = @(hash);
    NSString *path = rep_files[k];
    if (!path) return nil;
    id c = rep_cache[k];
    if (c == [NSNull null]) return nil;
    if (!c) @autoreleasepool {
        const char *err = "cannot decode image";
        id<MTLTexture> t = [path.pathExtension.lowercaseString isEqualToString:@"dds"] ? load_dds(path, dev, cq, 0, &err) : load_png(path, dev, cq, 0);
        if (!t) fprintf(stderr, "[texpack] replacement %s rejected: %s\n", path.lastPathComponent.UTF8String, err);
        rep_cache[k] = c = t ? (id)t : (id)[NSNull null];
        if (!t) return nil;
    }
    if (!noalpha) return c;
    id v = rep_opaque[k];
    if (!v) { v = one_alpha(c); if (!v) return c; rep_opaque[k] = v; }
    return v;
}
// Reference counting by the surfaces that currently bind a replacement; the cache entry goes at zero.
void texpack_retain(uint64_t hash) { if (rep_on) { NSNumber *k = @(hash); rep_ref[k] = @([rep_ref[k] intValue] + 1); } }
void texpack_release(uint64_t hash) {
    if (!rep_on) return;
    NSNumber *k = @(hash); int n = [rep_ref[k] intValue] - 1;
    if (n > 0) { rep_ref[k] = @(n); return; }
    [rep_ref removeObjectForKey:k]; [rep_opaque removeObjectForKey:k];
    if (rep_cache[k] && rep_cache[k] != [NSNull null]) [rep_cache removeObjectForKey:k];
}
