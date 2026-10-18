#!/usr/bin/env python3 -I
"""LithTech RezMgr v1 (.REZ) reader + DTX (LT2, version -5) inspector/converter. stdlib only.
  rezlist.py FILE.REZ                      list: path<TAB>size
  rezlist.py FILE.REZ --stats              ext counts; for DTX: bpp/format, mip counts, flags, size check
  rezlist.py FILE.REZ -x OUTDIR [--name S] extract (all, or paths containing S, case-insens.) keeping the path
  rezlist.py FILE.REZ --png OUTDIR [--name S] convert DTX level 0 to PNG (RGBA8, un-premultiplied as stored)
  --export TEXDIR [--force]  all DTX of TEXTURES/SPRITETEXTURES/SKINS.REZ (REZ given = the data dir or any one of them) ->
                TEXDIR/source/<lowercase/path>.png + source/index.tsv (idempotent; --force rewrites)
  --max N limit items. OUTDIR must be an empty/new dir outside the game folder (this tool never writes elsewhere).
REZ v1: 0x7f u32 ver(1), root dir pos/size/time, next_write_pos, time, largest key/dirname/rezname/comment; dir block =
entries {u32 type(1=dir,0=res), pos, size, time, ...} dir: name\\0; res: u32 id, char ext[4] (reversed), u32 nkeys,
name\\0, comment\\0, key data."""
import sys, struct, zlib, os

def read_rez(f):
    d = f.read(0x83 + 44)
    if d[:2] != b'\r\n' or b'RezMgr' not in d[:64]: raise ValueError('not a REZ')
    ver, rpos, rsize = struct.unpack_from('<III', d, 0x7f)
    ents = []
    def walk(pos, size, path):
        f.seek(pos); b = f.read(size); o = 0
        while o < size:
            typ, p, s, t = struct.unpack_from('<IIII', b, o); o += 16
            if typ == 1:
                e = b.index(b'\0', o); name = b[o:e].decode('latin1'); o = e + 1
                walk(p, s, path + name + '/')
            else:
                rid, ext, nk = struct.unpack_from('<I4sI', b, o); o += 12
                e = b.index(b'\0', o); name = b[o:e].decode('latin1'); o = e + 1
                e = b.index(b'\0', o); o = e + 1
                ext = ext[::-1].strip(b'\0').decode('latin1')
                o += 0  # key data absent in these archives (nkeys=0)
                ents.append((path + name + ('.' + ext if ext else ''), p, s, ext.lower(), rid))
    walk(rpos, rsize, '')
    return ents

BPP = {0: '32(extra[2]=0)', 1: '8', 2: '16', 3: '32', 4: 'DXT1', 5: 'DXT3', 6: 'DXT5', 7: '32P'}
def dtx_header(b):
    rt, ver = struct.unpack_from('<Ii', b, 0)
    w, h, mips, sec, flags, uflags = struct.unpack_from('<HHHHII', b, 8)
    ex = b[24:36]   # extra: [0]=texture group [1]=mips used [2]=BPP enum [3]=fullbright mip, [4..]=ambient colour/dark
    return dict(ver=ver, w=w, h=h, mips=mips, sec=sec, flags=flags, uflags=uflags, group=ex[0], mipsused=ex[1],
                bpp=ex[2], rawbpp=ex[2], extra=ex, cmd=b[36:164].split(b'\0')[0].decode('latin1'))
def lvl_size(bpp, w, h):
    if bpp in (4,): return max(1,(w+3)//4)*max(1,(h+3)//4)*8
    if bpp in (5,6): return max(1,(w+3)//4)*max(1,(h+3)//4)*16
    return w*h*{0:4,1:1,2:2,3:4,7:4}[bpp]
def dtx_expected(h):
    tot = 164; w, ht = h['w'], h['h']
    for i in range(h['mips']):
        tot += lvl_size(h['bpp'], max(1,w>>i), max(1,ht>>i))
    return tot
def decode_level0(b, h):
    # Alpha rule: a texture whose alpha channel is one constant value (e.g. 32-bit skins stored with A=0 everywhere, which the
    # engine ignores on opaque surfaces) is exported opaque (A=255); DXT1 punch-through texels (A=0) are kept as is.
    r = _decode_level0(b, h)
    if h['bpp'] != 4 and len(r) and min(r[3::4]) == max(r[3::4]) and r[3] != 255:
        r = bytearray(r); r[3::4] = b'\xff' * (len(r) // 4); r = bytes(r)
    return r
def _decode_level0(b, h):
    w, ht, bpp = h['w'], h['h'], h['bpp']; o = 164
    if bpp in (0, 3, 7):   # 0 = extra[2] unset: data is 32-bit BGRA (verified by size on all such files)
        px = b[o:o+w*ht*4]; out = bytearray(len(px))
        out[0::4] = px[2::4]; out[1::4] = px[1::4]; out[2::4] = px[0::4]; out[3::4] = px[3::4]
        return bytes(out)
    if bpp in (4, 5, 6):
        return dxt_decode(b[o:o+lvl_size(bpp, w, ht)], w, ht, bpp)
    raise ValueError('bpp %d unsupported for png' % bpp)
def c565(c): return (((c>>11)&31)*255//31, ((c>>5)&63)*255//63, (c&31)*255//31)
def dxt_decode(d, w, h, bpp):
    out = bytearray(w*h*4); bs = 8 if bpp == 4 else 16; bw = (w+3)//4; o = 0
    for by in range((h+3)//4):
        for bx in range(bw):
            blk = d[o:o+bs]; o += bs; cb = blk[bs-8:]
            c0, c1, bits = struct.unpack('<HHI', cb); p0, p1 = c565(c0), c565(c1)
            if c0 > c1 or bpp != 4:
                pal = [p0+(255,), p1+(255,), tuple((2*a+b)//3 for a,b in zip(p0,p1))+(255,), tuple((a+2*b)//3 for a,b in zip(p0,p1))+(255,)]
            else:
                pal = [p0+(255,), p1+(255,), tuple((a+b)//2 for a,b in zip(p0,p1))+(255,), (0,0,0,0)]
            if bpp == 5: al = [((struct.unpack_from('<Q', blk)[0] >> (4*i)) & 15)*17 for i in range(16)]
            elif bpp == 6:
                a0, a1 = blk[0], blk[1]; ab = int.from_bytes(blk[2:8], 'little')
                if a0 > a1: at = [a0, a1] + [((7-i)*a0 + i*a1)//7 for i in range(1,7)]
                else: at = [a0, a1] + [((5-i)*a0 + i*a1)//5 for i in range(1,5)] + [0, 255]
                al = [at[(ab >> (3*i)) & 7] for i in range(16)]
            for i in range(16):
                x, y = bx*4 + (i&3), by*4 + (i>>2)
                if x < w and y < h:
                    r, g, b, a = pal[(bits >> (2*i)) & 3]
                    if bpp != 4: a = al[i]
                    q = (y*w + x)*4; out[q:q+4] = bytes((r, g, b, a))
    return bytes(out)
def png(w, h, rgba):
    raw = b''.join(b'\0' + rgba[y*w*4:(y+1)*w*4] for y in range(h))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw, 6)) + ch(b'IEND', b'')

def export(a):
    import time
    t0 = time.time(); src = a[0]; td = a[a.index('--export') + 1]; force = '--force' in a
    d = src if os.path.isdir(src) else os.path.dirname(os.path.abspath(src))
    out = os.path.join(td, 'source'); os.makedirs(out, exist_ok=True)
    rows, nw, nskip, nbytes = [], 0, 0, 0
    for arc in ('TEXTURES', 'SPRITETEXTURES', 'SKINS'):
        f = open(os.path.join(d, arc + '.REZ'), 'rb')
        for e in read_rez(f):
            if e[3] != 'dtx' or e[2] < 164: continue
            f.seek(e[1]); b = f.read(e[2]); h = dtx_header(b)
            rel = e[0].lower().rsplit('.', 1)[0] + '.png'; p = os.path.join(out, rel)
            rgba = None
            if force or not os.path.exists(p):
                rgba = decode_level0(b, h)
                os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(png(h['w'], h['h'], rgba)); nw += 1
            else: nskip += 1
            if rgba is None: rgba = decode_level0(b, h)
            alpha = int(min(rgba[3::4]) < 255)   # has-alpha = any texel alpha < 255 (DXT1: punch-through texels; 32-bit: stored alpha)
            nbytes += os.path.getsize(p)
            rows.append((e[0].lower().replace('/', '/'), h['w'], h['h'], BPP.get(h['bpp'], h['bpp']), h['mips'], alpha, arc))
    with open(os.path.join(out, 'index.tsv'), 'w') as fo:
        fo.write('path\twidth\theight\tdtx_format\tmips\thas_alpha\tarchive\n')
        for r in rows: fo.write('\t'.join(str(x) for x in r) + '\n')
    print('export: %d textures (%d written, %d existing), %.1f MB png, %.1f s -> %s' % (len(rows), nw, nskip, nbytes / 1e6, time.time() - t0, out))
    return 0
def main(a):
    if not a or a[0] in ('-h', '--help'): print(__doc__); return 1
    if '--export' in a: return export(a)
    arg = lambda k: a[a.index(k)+1] if k in a else None
    name = (arg('--name') or '').lower(); mx = int(arg('--max') or 1 << 30)
    f = open(a[0], 'rb'); ents = [e for e in read_rez(f) if name in e[0].lower()]
    if '--stats' in a:
        from collections import Counter
        ce = Counter(e[3] for e in ents); print('files', len(ents), dict(ce))
        cb, cm, cf, bad, sizes, cs = Counter(), Counter(), Counter(), 0, Counter(), Counter()
        for e in ents:
            if e[3] != 'dtx': continue
            f.seek(e[1]); h = dtx_header(f.read(164))
            cb[BPP.get(h['bpp'], h['bpp'])] += 1; cs[h['sec']] += 1; cm[h['mips']] += 1; cf[(h['flags'], h['uflags'])] += 1
            sizes['%dx%d' % (h['w'], h['h'])] += 1
            if h['ver'] != -5 or (dtx_expected(h) != e[2] and not h['sec']) or dtx_expected(h) > e[2]: bad += 1
        if cb: print('format', dict(cb)); print('mips', dict(cm)); print('flags,uflags', dict(cf)); print('sections', dict(cs), 'size_mismatch', bad)
        if cb: print('sizes', sizes.most_common(12))
        return 0
    od = arg('-x') or arg('--png')
    if od is None:
        for e in ents[:mx]: print('%s\t%d' % (e[0], e[2]))
        return 0
    os.makedirs(od, exist_ok=True)
    for e in ents[:mx]:
        if e[2] == 0: continue
        f.seek(e[1]); b = f.read(e[2]); p = os.path.join(od, e[0])
        if '--png' in a:
            if e[3] != 'dtx': continue
            h = dtx_header(b); p = p.rsplit('.', 1)[0] + '.png'; b = png(h['w'], h['h'], decode_level0(b, h))
        os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(b)
        print(p)
    return 0
if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
