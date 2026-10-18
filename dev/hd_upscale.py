#!/usr/bin/env python3 -I
"""Batch AI-upscale of the exported MM9 textures (Real-ESRGAN ncnn-vulkan), stdlib only.
  hd_upscale.py --src ~/MM9-HD/source --out ~/MM9-HD/replace --tool ~/MM9-HD/tools/realesrgan
                [--only SUBSTR]... [--limit N] [--model realesrgan-x4plus] [--force] [--jobs-dir DIR]
                [--x2 down|anime] [--alpha-method auto|model|smooth] [--chunk N] [--procs N]
Plan "mixed" (by max(w,h)): <=128 -> 4x, <=256 -> 2x, larger -> 1x (png copied unchanged).
Seam-free: every image is padded by wrapping (max(8, w/8) px from the opposite edges, 4 sides) before upscaling and the centre is
cropped back to exactly (w*s, h*s) afterwards, so repeating textures tile without seams.
Alpha: RGB (transparent texels filled by dilation of opaque colours) and alpha (as grey image) are upscaled separately, then merged;
alpha method auto = model for crisp/edge alpha, bilinear for soft gradients (glows); alpha that only holds 0/255 is re-thresholded at 128 (stays crisp).
2x: --x2 down = run the x4 model and box-filter down by 2 (default), --x2 anime = realesr-animevideov3-x2 model.
Input  : <src>/<path>.png (+ index.tsv: path,width,height,dtx_format,mips,has_alpha,archive)   (path ends in .dtx)
Output : <out>/<path without .dtx>.png (RGBA8). Existing outputs are skipped unless --force. Textures are private: keep under ~/MM9-HD.
"""
import sys, os, struct, zlib, time, shutil, subprocess, argparse, multiprocessing

# ---------------------------------------------------------------- PNG (8-bit gray/RGB/gray+A/RGBA, non-interlaced)
def read_png(b):
    if b[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('not a PNG')
    o = 8; idat = []; hdr = None
    while o < len(b):
        n, t = struct.unpack_from('>I4s', b, o); d = b[o+8:o+8+n]; o += 12 + n
        if t == b'IHDR': hdr = struct.unpack('>IIBBBBB', d)
        elif t == b'IDAT': idat.append(d)
        elif t == b'IEND': break
    w, h, bd, ct, _, _, il = hdr
    if bd != 8 or il != 0 or ct not in (0, 2, 4, 6): raise ValueError('unsupported PNG (bd=%d ct=%d il=%d)' % (bd, ct, il))
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(b''.join(idat)); stride = w * nch
    out = bytearray(h * stride); prev = bytes(stride); pos = 0
    for y in range(h):
        ft = raw[pos]; ln = bytearray(raw[pos+1:pos+1+stride]); pos += 1 + stride
        if ft == 1:
            for i in range(nch, stride): ln[i] = (ln[i] + ln[i-nch]) & 255
        elif ft == 2:
            ln = bytearray([(a + c) & 255 for a, c in zip(ln, prev)])
        elif ft == 3:
            for i in range(stride):
                l = ln[i-nch] if i >= nch else 0
                ln[i] = (ln[i] + ((l + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                if i >= nch:
                    a = ln[i-nch]; c = prev[i-nch]
                else:
                    a = c = 0
                bb = prev[i]; p = a + bb - c
                pa = abs(p - a); pb = abs(p - bb); pc = abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (bb if pb <= pc else c)
                ln[i] = (ln[i] + pr) & 255
        elif ft != 0: raise ValueError('bad filter')
        out[y*stride:(y+1)*stride] = ln; prev = ln
    return w, h, nch, bytes(out)

def write_png(w, h, nch, data, level=6):
    ct = {1: 0, 3: 2, 4: 6}[nch]; s = w * nch
    if level > 1:   # Up filter (much smaller files for upscaled content)
        rows = [b'\0' + data[:s]] + [b'\2' + bytes([(a - b) & 255 for a, b in zip(data[y*s:(y+1)*s], data[(y-1)*s:y*s])]) for y in range(1, h)]
        raw = b''.join(rows)
    else:
        raw = b''.join(b'\0' + data[y*s:(y+1)*s] for y in range(h))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(raw, level)) + ch(b'IEND', b''))

# ---------------------------------------------------------------- pixel helpers (interleaved bytes, nch channels)
def split(nch, data):   # -> list of per-channel bytes
    return [data[c::nch] for c in range(nch)]
def join(chs):
    n = len(chs); out = bytearray(len(chs[0]) * n)
    for c, d in enumerate(chs): out[c::n] = d
    return bytes(out)

def wrap_pad(w, h, nch, data, p):
    """pad p px on all four sides by wrapping around -> (w+2p, h+2p)"""
    s = w * nch; reps = p // w + 1; st = reps * s - p * nch; ln = (w + 2 * p) * nch
    rows = []
    for y in range(-p, h + p):
        r = data[(y % h) * s:((y % h) + 1) * s]
        rows.append((r * (2 * reps + 1))[st:st + ln])
    return b''.join(rows)

def crop(w, h, nch, data, x0, y0, cw, ch_):
    s = w * nch
    return b''.join(data[(y0+y)*s + x0*nch:(y0+y)*s + (x0+cw)*nch] for y in range(ch_))

def box_down(w, h, nch, data, d):   # integer d x d box filter
    ow, oh = w // d, h // d; s = w * nch; out = bytearray(ow * oh * nch); n2 = d * d; half = n2 // 2
    for y in range(oh):
        rows = [data[(y*d+k)*s:(y*d+k+1)*s] for k in range(d)]
        line = bytearray(ow * nch)
        for c in range(nch):
            cols = [r[c::nch][i::d] for r in rows for i in range(d)]
            line[c::nch] = bytes([(sum(v) + half) // n2 for v in zip(*cols)])
        out[y*ow*nch:(y+1)*ow*nch] = line
    return ow, oh, bytes(out)

def smooth_up(w, h, data, s):   # gray bilinear x s (pixel-centre aligned), 1 channel
    def axis(n):
        t = []
        for i in range(n * s):
            f = (i + 0.5) / s - 0.5; i0 = int(f // 1); fr = f - i0
            t.append((min(max(i0, 0), n - 1), min(max(i0 + 1, 0), n - 1), fr))
        return t
    ax, ay = axis(w), axis(h); rows = []
    for y in range(h):
        r = data[y*w:(y+1)*w]
        rows.append([r[a] * (1 - f) + r[b] * f for a, b, f in ax])
    out = bytearray()
    for a, b, f in ay:
        ra, rb = rows[a], rows[b]
        out += bytes([min(255, int(p * (1 - f) + q * f + 0.5)) for p, q in zip(ra, rb)])
    return bytes(out)

def dilate_rgb(w, h, rgba, passes=12):
    """-> RGB bytes where alpha==0 texels get the mean of already-known 8-neighbours (a few passes), remaining = mean opaque colour"""
    rgb = bytearray(w * h * 3); known = bytearray(w * h); sr = sg = sb = nk = 0
    for i in range(w * h):
        rgb[i*3:i*3+3] = rgba[i*4:i*4+3]
        if rgba[i*4+3]:
            known[i] = 1; sr += rgba[i*4]; sg += rgba[i*4+1]; sb += rgba[i*4+2]; nk += 1
    if nk == w * h: return bytes(rgb)
    if nk == 0: return bytes(rgb)
    for _ in range(passes):
        new = []
        for y in range(h):
            for x in range(w):
                i = y * w + x
                if known[i]: continue
                r = g = b = n = 0
                for dy in (-1, 0, 1):
                    yy = y + dy
                    if yy < 0 or yy >= h: continue
                    for dx in (-1, 0, 1):
                        xx = x + dx
                        if 0 <= xx < w and known[yy*w+xx]:
                            j = (yy*w+xx) * 3; r += rgb[j]; g += rgb[j+1]; b += rgb[j+2]; n += 1
                if n: new.append((i, r // n, g // n, b // n))
        if not new: break
        for i, r, g, b in new: rgb[i*3:i*3+3] = bytes((r, g, b)); known[i] = 1
    mean = bytes((sr // nk, sg // nk, sb // nk))
    for i in range(w * h):
        if not known[i]: rgb[i*3:i*3+3] = mean
    return bytes(rgb)

# ---------------------------------------------------------------- plan
def plan_scale(w, h):
    m = max(w, h)
    return 4 if m <= 128 else (2 if m <= 256 else 1)

RUNS = {'x4': ('realesrgan-x4plus', 4), 'x2a': ('realesr-animevideov3-x2', 2)}   # run key -> (model, -s)

def pad_of(w, h): return max(8, max(w, h) // 8)

# ---------------------------------------------------------------- stage 1: prepare padded inputs (pool worker)
def prep(job):
    (idx, path, srcpng, scale, runkey, indir, alpha_method) = job
    w, h, nch, data = read_png(open(srcpng, 'rb').read())
    if nch == 3: data = join([data[0::3], data[1::3], data[2::3], b'\xff' * (w * h)]); nch = 4
    elif nch == 1: data = join([data, data, data, b'\xff' * (w * h)]); nch = 4
    elif nch == 2: g = data[0::2]; data = join([g, g, g, data[1::2]]); nch = 4
    a = data[3::4]; has_a = min(a) < 255
    binary = has_a and all(v in (0, 255) for v in set(a))
    rgb = dilate_rgb(w, h, data) if has_a else join([data[0::4], data[1::4], data[2::4]])
    p = pad_of(w, h)
    open(os.path.join(indir, '%06d_c.png' % idx), 'wb').write(write_png(w + 2*p, h + 2*p, 3, wrap_pad(w, h, 3, rgb, p), 1))
    am = alpha_method
    if am == 'auto':   # soft gradients (glows, smoke) get hallucinated detail from the model -> smooth resample; edges/binary -> model
        nz = sum(1 for v in a if v); mid = sum(1 for v in a if 8 < v < 248)
        am = 'model' if (binary or mid < 0.5 * max(1, nz)) else 'smooth'
    if has_a and am == 'model':
        g = wrap_pad(w, h, 1, a, p)
        open(os.path.join(indir, '%06d_a.png' % idx), 'wb').write(
            write_png(w + 2*p, h + 2*p, 3, join([g, g, g]), 1))
    return idx, (w, h, has_a, binary, p, am)

# ---------------------------------------------------------------- stage 3: crop / downsample / merge / write (pool worker)
def post(job):
    (idx, path, outpng, scale, runkey, outdir, meta, alpha_method, srcpng) = job
    w, h, has_a, binary, p, alpha_method = meta
    mscale = RUNS[runkey][1]; ds = mscale // scale if scale <= mscale else 1
    if mscale % scale: raise ValueError('scale mismatch')
    ds = mscale // scale
    def fetch(suffix):
        W, H, nch, d = read_png(open(os.path.join(outdir, '%06d_%s.png' % (idx, suffix)), 'rb').read())
        assert W == (w + 2*p) * mscale and H == (h + 2*p) * mscale, (W, H, w, h, p, mscale)
        d = crop(W, H, nch, d, p * mscale, p * mscale, w * mscale, h * mscale)
        if ds > 1: _, _, d = box_down(w * mscale, h * mscale, nch, d, ds)
        return nch, d
    ow, oh = w * scale, h * scale
    nch, c = fetch('c')
    rgb = split(nch, c)[:3]
    if has_a:
        if alpha_method == 'model':
            n2, ad = fetch('a'); al = ad[0::n2]
        else:
            a = split(4, read_png(open(srcpng, 'rb').read())[3])[3]
            up = smooth_up(w + 2*p, h + 2*p, wrap_pad(w, h, 1, a, p), scale)
            al = crop((w + 2*p) * scale, (h + 2*p) * scale, 1, up, p * scale, p * scale, ow, oh)
        if binary: al = al.translate(bytes([0] * 128 + [255] * 128))
    else:
        al = b'\xff' * (ow * oh)
    os.makedirs(os.path.dirname(outpng), exist_ok=True)
    tmp = outpng + '.tmp'
    open(tmp, 'wb').write(write_png(ow, oh, 4, join(rgb + [al])))
    os.replace(tmp, outpng)
    return idx, os.path.getsize(outpng)

def copy1x(job):
    src, dst = job
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst + '.tmp'); os.replace(dst + '.tmp', dst)
    return os.path.getsize(dst)

# ---------------------------------------------------------------- driver
def run_tool(tool, indir, outdir, model, s, tile):
    exe = os.path.join(tool, 'realesrgan-ncnn-vulkan')
    cmd = [exe, '-i', indir, '-o', outdir, '-n', model, '-s', str(s), '-m', os.path.join(tool, 'models'), '-f', 'png']
    if tile: cmd += ['-t', str(tile)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0: raise RuntimeError('realesrgan failed (%d): %s' % (r.returncode, r.stdout[-500:]))

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--src', default='~/MM9-HD/source'); ap.add_argument('--out', default='~/MM9-HD/replace')
    ap.add_argument('--tool', default='~/MM9-HD/tools/realesrgan')
    ap.add_argument('--only', action='append', default=[], help='substring of the texture path (repeatable, OR)')
    ap.add_argument('--limit', type=int, default=0); ap.add_argument('--model', default='realesrgan-x4plus')
    ap.add_argument('--force', action='store_true'); ap.add_argument('--jobs-dir', default='')
    ap.add_argument('--x2', choices=('down', 'anime'), default='down'); ap.add_argument('--alpha-method', choices=('auto', 'model', 'smooth'), default='auto')
    ap.add_argument('--chunk', type=int, default=200, help='textures per realesrgan run'); ap.add_argument('--tile', type=int, default=0)
    ap.add_argument('--procs', type=int, default=min(8, os.cpu_count() or 2))
    a = ap.parse_args()
    ex = os.path.expanduser; src, out, tool = ex(a.src), ex(a.out), ex(a.tool)
    jobs = ex(a.jobs_dir) if a.jobs_dir else os.path.join(os.path.dirname(os.path.abspath(out)), 'jobs')
    RUNS['x4'] = (a.model, 4)
    rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(src, 'index.tsv'))][1:]
    todo = []; skipped = 0
    for r in rows:
        path = r[0]
        if a.only and not any(k.lower() in path for k in a.only): continue
        stem = path[:-4] if path.endswith('.dtx') else path
        sp, op = os.path.join(src, stem + '.png'), os.path.join(out, stem + '.png')
        if not os.path.exists(sp): continue
        if a.limit and len(todo) + skipped >= a.limit: break
        if os.path.exists(op) and not a.force: skipped += 1; continue
        todo.append((path, sp, op, plan_scale(int(r[1]), int(r[2]))))
    t0 = time.time(); counts = {1: 0, 2: 0, 4: 0}; obytes = 0; done = 0; tgpu = 0.0
    print('%d to do, %d already present (skipped)' % (len(todo), skipped), flush=True)
    pool = multiprocessing.Pool(a.procs)
    try:
        for p_, sp, op, sc in [t for t in todo if t[3] == 1]:
            obytes += copy1x((sp, op)); counts[1] += 1; done += 1
        work = [t for t in todo if t[3] != 1]
        for c0 in range(0, len(work), a.chunk):
            chunk = work[c0:c0 + a.chunk]
            shutil.rmtree(jobs, ignore_errors=True)
            groups = {}   # runkey -> [(idx, item)]
            for i, t in enumerate(chunk):
                rk = 'x2a' if (t[3] == 2 and a.x2 == 'anime') else 'x4'
                groups.setdefault(rk, []).append((c0 + i, t))
            pj = []
            for rk, items in groups.items():
                os.makedirs(os.path.join(jobs, rk, 'in'), exist_ok=True); os.makedirs(os.path.join(jobs, rk, 'out'), exist_ok=True)
                pj += [(idx, t[0], t[1], t[3], rk, os.path.join(jobs, rk, 'in'), a.alpha_method) for idx, t in items]
            meta = dict(pool.map(prep, pj, chunksize=4))
            tg = time.time()
            for rk in groups:
                run_tool(tool, os.path.join(jobs, rk, 'in'), os.path.join(jobs, rk, 'out'), RUNS[rk][0], RUNS[rk][1], a.tile)
            tg = time.time() - tg; tgpu += tg
            pp = []
            for rk, items in groups.items():
                pp += [(idx, t[0], t[2], t[3], rk, os.path.join(jobs, rk, 'out'), meta[idx], a.alpha_method, t[1]) for idx, t in items]
            for idx, n in pool.map(post, pp, chunksize=4):
                obytes += n
            for idx, t in [x for v in groups.values() for x in v]: counts[t[3]] += 1
            done += len(chunk)
            print('[%d/%d] chunk of %d: tool %.1fs, elapsed %.1fs' % (done, len(todo), len(chunk), tg, time.time() - t0), flush=True)
        shutil.rmtree(jobs, ignore_errors=True)
    finally:
        pool.close()
    dt = time.time() - t0
    print('SUMMARY: 4x=%d 2x=%d 1x(copy)=%d skipped=%d | %.1fs total (%.2fs/texture, tool %.1fs) | output %.1f MB' %
          (counts[4], counts[2], counts[1], skipped, dt, dt / max(1, len(todo)), tgpu, obytes / 1e6))

if __name__ == '__main__':
    main()
