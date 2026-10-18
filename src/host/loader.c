// Loader shim over the statically recompiled modules: every code module's image is mapped into the
// guest space at its (rebased) fixed address at startup and its imports are bound once. LoadLibraryA
// matches the requested file to a module by PE timestamp + image size (the engine loads cshell.dll /
// object.lto from temp copies), restores the module's pristine image on a fresh load (d3d.ren is
// loaded, unloaded and reloaded) and runs its DllMain; FreeLibrary runs DLL_PROCESS_DETACH.
// Resource-only DLLs (CRes, SRes, ltmsg) are mapped as data. Resources: FindResource/LoadResource/
// LockResource/SizeofResource, LoadStringA, FormatMessageA (message tables / system text).
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "shims.h"

static Module mods[32];
static int nmods;
uint32_t mod_range_lo[8], mod_range_hi[8];
int mod_nranges;
static uint32_t next_data_base = 0x20000000u;

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

static uint8_t *slurp(const char *path, long *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc((size_t)*n);
    if (fread(d, 1, (size_t)*n, f) != (size_t)*n) { fclose(f); free(d); return NULL; }
    fclose(f);
    return d;
}

static void lower_base(const char *path, char *out, size_t n) {
    const char *b = path;
    for (const char *p = path; *p; p++) if (*p == '\\' || *p == '/') b = p + 1;
    size_t k = 0;
    for (; *b && k < n - 1; b++) out[k++] = (char)tolower((unsigned char)*b);
    out[k] = 0;
}

// map a PE file at `base` (headers + sections); returns entry RVA, fills size/timestamp
static int map_pe(const uint8_t *d, long n, uint32_t base, uint32_t *size, uint32_t *entry, uint32_t *ts) {
    if (n < 0x200 || d[0] != 'M' || d[1] != 'Z') return 0;
    uint32_t pe = rd32(d + 0x3C);
    uint16_t nsec = rd16(d + pe + 6), osz = rd16(d + pe + 20);
    *ts = rd32(d + pe + 8);
    *entry = rd32(d + pe + 24 + 16);
    *size = rd32(d + pe + 24 + 56);
    uint32_t soh = rd32(d + pe + 24 + 60);
    memset(MEM + base, 0, *size);
    memcpy(MEM + base, d, soh);
    for (int i = 0; i < nsec; i++) {
        const uint8_t *s = d + pe + 24 + osz + 40 * i;
        uint32_t vs = rd32(s + 8), va = rd32(s + 12), rs = rd32(s + 16), rp = rd32(s + 20);
        uint32_t take = rs < vs || !vs ? rs : vs;
        if (rp + take > (uint32_t)n) take = (uint32_t)n > rp ? (uint32_t)n - rp : 0;
        memcpy(MEM + base + va, d + rp, take);
    }
    return 1;
}

static void bind_imports(uint32_t base) {
    uint32_t pe = base + G32(base + 0x3C);
    uint32_t imp = G32(pe + 24 + 96 + 8);
    if (!imp) return;
    for (uint32_t d = base + imp; G32(d + 12); d += 20) {
        const char *dll = (const char *)MEM + base + G32(d + 12);
        uint32_t ilt = G32(d) ? base + G32(d) : base + G32(d + 16);
        uint32_t iat = base + G32(d + 16);
        for (; G32(ilt); ilt += 4, iat += 4) {
            uint32_t e = G32(ilt);
            HostImport *hi = &host_imports[host_import_count];
            snprintf(hi->dll, sizeof hi->dll, "%s", dll);
            if (e & 0x80000000u) snprintf(hi->name, sizeof hi->name, "#%u", e & 0xFFFF);
            else snprintf(hi->name, sizeof hi->name, "%s", (const char *)MEM + base + e + 2);
            hi->fn = host_find_shim(hi->dll, hi->name);
            P32(iat, IMPORT_THUNK_BASE + 4 * (uint32_t)host_import_count);
            host_import_count++;
        }
    }
}

int rt_has_fn_or_text(uint32_t v) {
    for (int i = 0; i < nmods; i++) if (mods[i].code && v >= mods[i].base + 0x1000 && v < mods[i].base + mods[i].size) return 1;
    return 0;
}

static const char *code_modules[] = {"lithtech.exe", "d3d.ren", "cshell.dll", "object.lto", "clientfx.fxd"};

uint32_t mod_load_all(const char *bindir) {
    uint32_t exe_entry = 0;
    for (size_t i = 0; i < sizeof code_modules / sizeof *code_modules; i++) {
        Module *m = &mods[nmods];
        snprintf(m->name, sizeof m->name, "%s", code_modules[i]);
        snprintf(m->path, sizeof m->path, "%s/%s", bindir, code_modules[i]);
        long n; uint8_t *d = slurp(m->path, &n);
        if (!d) { perror(m->path); exit(1); }
        uint32_t pe = rd32(d + 0x3C);
        m->base = rd32(d + pe + 24 + 28);
        if (!map_pe(d, n, m->base, &m->size, &m->entry, &m->timestamp)) { fprintf(stderr, "bad PE %s\n", m->path); exit(1); }
        free(d);
        bind_imports(m->base);
        m->pristine = malloc(m->size);
        memcpy(m->pristine, MEM + m->base, m->size);
        m->code = 1;
        if (i == 0) { host_image_base = m->base; exe_entry = m->base + m->entry; m->refs = 1; m->attached = 1; }
        mod_range_lo[mod_nranges] = m->base; mod_range_hi[mod_nranges] = m->base + m->size; mod_nranges++;
        fprintf(stderr, "[loader] %-13s @%#x-%#x entry %#x\n", m->name, m->base, m->base + m->size, m->base + m->entry);
        nmods++;
    }
    return exe_entry;
}

Module *mod_by_handle(uint32_t h) {
    for (int i = 0; i < nmods; i++) if (mods[i].base == h) return &mods[i];
    return NULL;
}

// ---- system DLL handles ------------------------------------------------------------------------
#define SYS_BASE 0x7F000000u
static const char *sys_mods[] = {"kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "ddraw.dll", "dinput.dll",
    "winmm.dll", "wsock32.dll", "ole32.dll", "version.dll", "mss32.dll", "dplayx.dll", "ntdll.dll", "shell32.dll", "binkw32.dll"};
int bink_available(void);
#define NSYS (sizeof sys_mods / sizeof *sys_mods)
static uint32_t sys_handle(const char *base) {
    char b[64]; snprintf(b, sizeof b, "%s", base);
    if (!strchr(b, '.')) strncat(b, ".dll", sizeof b - strlen(b) - 1);
    if (!strcmp(b, "binkw32.dll") && !bink_available()) return 0;     // bink.c needs the ffmpeg tool
    for (size_t i = 0; i < NSYS; i++) if (!strcmp(b, sys_mods[i])) return SYS_BASE + 0x10000u * (uint32_t)i;
    return 0;
}

static const char *data_dlls[] = {"cres.dll", "sres.dll", "ltmsg.dll", "de_msg.dll"};

static void dll_attach(CPU *c, Module *m) {
    if (m->refs++ > 0) return;
    if (!m->code) return;
    if (m->attached) {            // was loaded before and detached: start from the pristine image
        memcpy(MEM + m->base, m->pristine, m->size);
    }
    m->attached = 1;
    fprintf(stderr, "[loader] DllMain(%s, PROCESS_ATTACH)\n", m->name);
    uint32_t args[3] = {m->base, 1, 0};
    uint32_t r = host_call(c, m->base + m->entry, 3, args);
    if (!r) fprintf(stderr, "[loader]   DllMain(%s) returned FALSE\n", m->name);
    if (!strcmp(m->name, "d3d.ren") && m->base == 0x10000000u) { extern void texhook_install(void); texhook_install(); }
    if (!strcmp(m->name, "cshell.dll")) { extern void optmenu_install(uint32_t); optmenu_install(m->base); }
}

static uint32_t load_library(CPU *c, const char *winpath) {
    char base[256]; lower_base(winpath, base, sizeof base);
    uint32_t h = sys_handle(base);
    if (h) return h;
    for (int i = 0; i < nmods; i++)
        if (!strcmp(mods[i].name, base)) { dll_attach(c, &mods[i]); return mods[i].base; }
    // not by name: open the file and compare its PE header with the known modules
    char path[1024]; long n; uint8_t *d = host_path(winpath, path, sizeof path) ? slurp(path, &n) : NULL;
    if (!d && !strchr(winpath, '\\') && !strchr(winpath, '/')) {
        char p1[1024], p2[1024]; snprintf(p1, sizeof p1, "C:\\MM9\\data\\%s", winpath);
        if (host_path(p1, p2, sizeof p2)) d = slurp(p2, &n);
    }
    if (!d) return 0;
    uint32_t pe = n > 0x40 ? rd32(d + 0x3C) : 0;
    if (pe + 0x100 > (uint32_t)n || rd32(d + pe) != 0x4550) { free(d); return 0; }
    uint32_t ts = rd32(d + pe + 8), sz = rd32(d + pe + 24 + 56);
    for (int i = 0; i < nmods; i++)
        if (mods[i].code && mods[i].timestamp == ts && mods[i].size == sz) {
            free(d);
            fprintf(stderr, "[loader] %s is %s\n", winpath, mods[i].name);
            dll_attach(c, &mods[i]); return mods[i].base;
        }
    int data = 0;
    for (size_t i = 0; i < sizeof data_dlls / sizeof *data_dlls; i++) data |= !strcmp(base, data_dlls[i]);
    if (!data) { free(d); return 0; }
    for (int i = 0; i < nmods; i++)
        if (!mods[i].code && mods[i].timestamp == ts && !strcmp(mods[i].name, base)) { free(d); mods[i].refs++; return mods[i].base; }
    Module *m = &mods[nmods++];
    snprintf(m->name, sizeof m->name, "%s", base);
    snprintf(m->path, sizeof m->path, "%s", path);
    m->base = next_data_base;
    map_pe(d, n, m->base, &m->size, &m->entry, &m->timestamp);
    next_data_base += (m->size + 0xFFFFu) & ~0xFFFFu;
    m->refs = 1;
    free(d);
    fprintf(stderr, "[loader] %s mapped as data @%#x\n", base, m->base);
    return m->base;
}

SHIM(LoadLibraryA) {
    const char *nm = GSTR(ARG(c, 0));
    uint32_t h = load_library(c, nm);
    fprintf(stderr, "[loader] LoadLibraryA(%s) -> %#x\n", nm, h);
    if (!h) SETERR(126);
    RET(c, h, 1);
}
SHIM(FreeLibrary) {
    Module *m = mod_by_handle(ARG(c, 0));
    if (m && m->refs > 0 && --m->refs == 0 && m->code && m->base != host_image_base) {
        fprintf(stderr, "[loader] DllMain(%s, PROCESS_DETACH)\n", m->name);
        uint32_t args[3] = {m->base, 0, 0};
        host_call(c, m->base + m->entry, 3, args);
    }
    RET(c, 1, 1);
}
SHIM(GetModuleHandleA) {
    const char *nm = GSTR(ARG(c, 0));
    if (!nm) { RET(c, host_image_base, 1); return; }
    char base[256]; lower_base(nm, base, sizeof base);
    uint32_t h = sys_handle(base);
    for (int i = 0; !h && i < nmods; i++) if (!strcmp(mods[i].name, base) && mods[i].refs) h = mods[i].base;
    if (!h) SETERR(126);
    RET(c, h, 1);
}
SHIM(GetModuleFileNameA) {
    uint32_t h = ARG(c, 0), buf = ARG(c, 1), n = ARG(c, 2);
    Module *m = h ? mod_by_handle(h) : mod_by_handle(host_image_base);
    char name[300];
    snprintf(name, sizeof name, "C:\\MM9\\%s%s", m && m->code && m->base != host_image_base ? "data\\" : "", m ? m->name : "lithtech.exe");
    uint32_t l = (uint32_t)strlen(name);
    if (l >= n) l = n - 1;
    memcpy(MEM + buf, name, l); MEM[buf + l] = 0;
    RET(c, l, 3);
}

static uint32_t export_lookup(Module *m, const char *name, uint32_t ord) {
    uint32_t pe = m->base + G32(m->base + 0x3C);
    uint32_t ed = G32(pe + 24 + 96);
    if (!ed) return 0;
    ed += m->base;
    uint32_t nfun = G32(ed + 20), nnames = G32(ed + 24), obase = G32(ed + 16);
    uint32_t funs = m->base + G32(ed + 28), names = m->base + G32(ed + 32), ords = m->base + G32(ed + 36);
    if (!name) { uint32_t i = ord - obase; return i < nfun ? m->base + G32(funs + 4 * i) : 0; }
    for (uint32_t i = 0; i < nnames; i++)
        if (!strcmp((char *)MEM + m->base + G32(names + 4 * i), name)) return m->base + G32(funs + 4 * G16(ords + 2 * i));
    return 0;
}

SHIM(GetProcAddress) {
    uint32_t h = ARG(c, 0), pn = ARG(c, 1);
    char name[96];
    if (pn < 0x10000) snprintf(name, sizeof name, "#%u", pn); else snprintf(name, sizeof name, "%s", GSTR(pn));
    Module *m = mod_by_handle(h);
    if (m) {
        uint32_t a = m->code ? export_lookup(m, pn < 0x10000 ? NULL : name, pn) : 0;
        fprintf(stderr, "[loader] GetProcAddress(%s, %s) -> %#x\n", m->name, name, a);
        if (!a) SETERR(127);
        RET(c, a, 2);
        return;
    }
    const char *dll = h >= SYS_BASE && (h - SYS_BASE) / 0x10000u < NSYS ? sys_mods[(h - SYS_BASE) / 0x10000u] : "?";
    ShimFn fn = host_find_shim(dll, name);
    if (!fn) { fprintf(stderr, "[loader] GetProcAddress(%s, %s) -> 0 (no shim)\n", dll, name); SETERR(127); RET(c, 0, 2); return; }
    for (int i = 0; i < host_import_count; i++)
        if (host_imports[i].fn == fn) { RET(c, IMPORT_THUNK_BASE + 4u * (uint32_t)i, 2); return; }
    HostImport *hi = &host_imports[host_import_count];
    snprintf(hi->dll, sizeof hi->dll, "%s", dll); snprintf(hi->name, sizeof hi->name, "%s", name); hi->fn = fn;
    fprintf(stderr, "[loader] GetProcAddress(%s, %s) -> shim\n", dll, name);
    RET(c, IMPORT_THUNK_BASE + 4u * (uint32_t)host_import_count++, 2);
}

// ---- resources -----------------------------------------------------------------------------------
// resource directory entry match: integer id, or a string name (compared case-insensitively)
static int res_match(uint32_t root, uint32_t e, uint32_t want) {
    uint32_t nm = G32(e);
    if (want < 0x10000) return !(nm & 0x80000000u) && (nm & 0xFFFF) == want;
    if (!(nm & 0x80000000u)) return 0;
    const char *s = (const char *)MEM + want;
    if (s[0] == '#') return 0;
    uint32_t str = root + (nm & 0x7FFFFFFFu);
    uint16_t len = G16(str);
    for (uint16_t i = 0; i < len; i++) if (tolower(G16(str + 2 + 2 * i)) != tolower((unsigned char)s[i]) || !s[i]) return 0;
    return s[len] == 0;
}
static uint32_t res_sub(uint32_t root, uint32_t dir, uint32_t want, int any) {
    uint32_t n = G16(dir + 12) + G16(dir + 14);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t e = dir + 16 + 8 * i;
        if (any || res_match(root, e, want)) return G32(e + 4);
    }
    return 0xFFFFFFFFu;
}
uint32_t res_find(uint32_t base, uint32_t type, uint32_t name, uint32_t *size) {
    uint32_t pe = base + G32(base + 0x3C);
    uint32_t rva = G32(pe + 24 + 96 + 16);
    if (!rva) return 0;
    uint32_t root = base + rva;
    if (type >= 0x10000 && MEM[type] == '#') type = (uint32_t)atoi((char *)MEM + type + 1);
    if (name >= 0x10000 && MEM[name] == '#') name = (uint32_t)atoi((char *)MEM + name + 1);
    uint32_t t = res_sub(root, root, type, 0);
    if (t == 0xFFFFFFFFu || !(t & 0x80000000u)) return 0;
    uint32_t nm = res_sub(root, root + (t & 0x7FFFFFFFu), name, 0);
    if (nm == 0xFFFFFFFFu || !(nm & 0x80000000u)) return 0;
    uint32_t lang = res_sub(root, root + (nm & 0x7FFFFFFFu), 0, 1);
    if (lang == 0xFFFFFFFFu || (lang & 0x80000000u)) return 0;
    uint32_t de = root + lang;
    if (size) *size = G32(de + 4);
    return de;
}
static uint32_t hmod_or_exe(uint32_t h) { return h ? h : host_image_base; }
SHIM(FindResourceA) {
    uint32_t h = hmod_or_exe(ARG(c, 0));
    uint32_t r = mod_by_handle(h) ? res_find(h, ARG(c, 2), ARG(c, 1), NULL) : 0;
    if (!r) SETERR(1813);
    RET(c, r, 3);
}
SHIM(LoadResource) { uint32_t h = hmod_or_exe(ARG(c, 0)), r = ARG(c, 1); RET(c, r ? h + G32(r) : 0, 2); }
SHIM(LockResource) { RET(c, ARG(c, 0), 1); }
SHIM(SizeofResource) { uint32_t r = ARG(c, 1); RET(c, r ? G32(r + 4) : 0, 2); }

SHIM(LoadStringA) {
    uint32_t h = hmod_or_exe(ARG(c, 0)), id = ARG(c, 1), buf = ARG(c, 2); int32_t n = (int32_t)ARG(c, 3);
    uint32_t sz, de = mod_by_handle(h) ? res_find(h, 6, id / 16 + 1, &sz) : 0;
    if (!de || n <= 0) { if (n > 0) MEM[buf] = 0; RET(c, 0, 4); return; }
    uint32_t p = h + G32(de);
    for (uint32_t i = 0; i < id % 16; i++) p += 2 + 2u * G16(p);
    uint32_t len = G16(p), k = 0;
    for (; k < len && (int32_t)k < n - 1; k++) { uint16_t ch = G16(p + 2 + 2 * k); MEM[buf + k] = ch < 256 ? (uint8_t)ch : '?'; }
    MEM[buf + k] = 0;
    RET(c, k, 4);
}

// FormatMessageA: FROM_HMODULE message tables, FROM_STRING, FROM_SYSTEM (generic text)
static const char *msg_lookup(uint32_t hmod, uint32_t id, char *tmp, size_t n) {
    uint32_t de = res_find(hmod, 11, 1, NULL);
    if (!de) return NULL;
    uint32_t mt = hmod + G32(de), nb = G32(mt);
    for (uint32_t b = 0; b < nb; b++) {
        uint32_t lo = G32(mt + 4 + 12 * b), hi = G32(mt + 8 + 12 * b), off = G32(mt + 12 + 12 * b);
        if (id < lo || id > hi) continue;
        uint32_t e = mt + off;
        for (uint32_t i = lo; i < id; i++) e += G16(e);
        uint16_t len = G16(e), fl = G16(e + 2);
        size_t k = 0;
        if (fl & 1) { for (uint32_t i = 0; 4 + 2 * i < len && k < n - 1; i++) { uint16_t ch = G16(e + 4 + 2 * i); if (!ch) break; tmp[k++] = ch < 256 ? (char)ch : '?'; } }
        else { for (uint32_t i = 0; 4 + i < len && k < n - 1; i++) { char ch = (char)MEM[e + 4 + i]; if (!ch) break; tmp[k++] = ch; } }
        tmp[k] = 0;
        return tmp;
    }
    return NULL;
}
SHIM(FormatMessageA) {
    uint32_t fl = ARG(c, 0), src = ARG(c, 1), id = ARG(c, 2), buf = ARG(c, 4), n = ARG(c, 5), args = ARG(c, 6);
    char tmp[4096], out[8192]; const char *fmt = NULL;
    if (fl & 0x400) fmt = GSTR(src);
    else if (fl & 0x800) fmt = msg_lookup(src ? src : host_image_base, id, tmp, sizeof tmp);
    if (!fmt && (fl & 0x1000)) { snprintf(tmp, sizeof tmp, "Error %u.\r\n", id); fmt = tmp; }
    if (!fmt) { SETERR(317); RET(c, 0, 7); return; }
    size_t k = 0;
    for (const char *p = fmt; *p && k < sizeof out - 1; p++) {
        if (*p != '%' || (fl & 0x200)) { out[k++] = *p; continue; }
        p++;
        if (*p == '0') break;
        if (*p == 'n') { out[k++] = '\r'; if (k < sizeof out - 1) out[k++] = '\n'; continue; }
        if (!isdigit((unsigned char)*p)) { out[k++] = *p ? *p : '%'; if (!*p) break; continue; }
        int idx = 0; while (isdigit((unsigned char)*p)) idx = idx * 10 + (*p++ - '0');
        char spec[16] = "s";
        if (*p == '!') { const char *e = strchr(p + 1, '!'); if (e && e - p - 1 < 15) { memcpy(spec, p + 1, (size_t)(e - p - 1)); spec[e - p - 1] = 0; p = e; } else p--; }
        else p--;
        uint32_t av = 0;
        if (args) av = (fl & 0x2000) ? G32(args + 4 * (uint32_t)(idx - 1)) : G32(G32(args) + 4 * (uint32_t)(idx - 1));
        char piece[1024], f2[20];
        snprintf(f2, sizeof f2, "%%%s", spec);
        if (strchr(spec, 's')) snprintf(piece, sizeof piece, "%s", av ? (char *)MEM + av : "(null)");
        else snprintf(piece, sizeof piece, f2, av);
        for (char *q = piece; *q && k < sizeof out - 1; q++) out[k++] = *q;
    }
    out[k] = 0;
    if (fl & 0x100) { uint32_t p = gmalloc((uint32_t)k + 1); memcpy(MEM + p, out, k + 1); P32(buf, p); }
    else { if (k >= n) k = n ? n - 1 : 0; memcpy(MEM + buf, out, k); if (n) MEM[buf + k] = 0; }
    RET(c, (uint32_t)k, 7);
}

SHIM_TABLE(loader_shims,
    E(LoadLibraryA) E(FreeLibrary) E(GetModuleHandleA) E(GetModuleFileNameA) E(GetProcAddress)
    E(FindResourceA) E(LoadResource) E(LockResource) E(SizeofResource) E(LoadStringA) E(FormatMessageA))
