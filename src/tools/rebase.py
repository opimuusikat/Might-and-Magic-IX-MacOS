#!/usr/bin/env python3
"""Rebase the game DLLs to distinct fixed image bases (relocations applied at build time).
Only the IMAGE_REL_BASED_HIGHLOW sites and the ImageBase field change. Standard library only
(the same result as the pefile version in the M1 work tree; pefile.relocate_image cannot be used,
it also shifts import-lookup-table entries and corrupts the imports).
    rebase.py <game_dir> <dst_dir>
Reads lithtech.exe, d3d.ren, clientfx.fxd and data/cshell.dll, data/object.lto from <game_dir>;
writes all five, flat, to <dst_dir> (lithtech.exe and d3d.ren unchanged: they keep their bases).
"""
import os
import struct
import sys

BASES = {"d3d.ren": 0x10000000, "cshell.dll": 0x10100000, "object.lto": 0x10300000,
         "clientfx.fxd": 0x10700000}
SOURCES = {"lithtech.exe": "lithtech.exe", "d3d.ren": "d3d.ren", "clientfx.fxd": "clientfx.fxd",
           "cshell.dll": "data/cshell.dll", "object.lto": "data/object.lto"}


def rebase(data, base):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE file")
    nsec, = struct.unpack_from("<H", data, pe + 6)
    optsz, = struct.unpack_from("<H", data, pe + 20)
    opt = pe + 24
    if struct.unpack_from("<H", data, opt)[0] != 0x10B:
        raise ValueError("not a 32-bit PE")
    old, = struct.unpack_from("<I", data, opt + 28)
    rel_rva, rel_size = struct.unpack_from("<II", data, opt + 96 + 5 * 8)
    secs = []
    for i in range(nsec):
        s = opt + optsz + 40 * i
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, s + 8)
        secs.append((va, max(vsize, rawsize), rawptr))

    def off(rva):
        for va, size, rawptr in secs:
            if va <= rva < va + size:
                return rva - va + rawptr
        raise ValueError(f"rva {rva:#x} outside the sections")

    delta = (base - old) & 0xFFFFFFFF
    n = 0
    p, end = off(rel_rva), off(rel_rva) + rel_size
    while p + 8 <= end:
        page, size = struct.unpack_from("<II", data, p)
        if size < 8:
            break
        for k in range(8, size, 2):
            e, = struct.unpack_from("<H", data, p + k)
            t, o = e >> 12, e & 0xFFF
            if t == 0:
                continue
            if t != 3:
                raise ValueError(f"relocation type {t}")
            fo = off(page + o)
            v, = struct.unpack_from("<I", data, fo)
            struct.pack_into("<I", data, fo, (v + delta) & 0xFFFFFFFF)
            n += 1
        p += size
    struct.pack_into("<I", data, opt + 28, base)
    return old, n


def main():
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for name, rel in SOURCES.items():
        data = bytearray(open(os.path.join(src, rel), "rb").read())
        if name in BASES and BASES[name] != 0x10000000:
            old, n = rebase(data, BASES[name])
            print(f"{name}: {old:#x} -> {BASES[name]:#x}, {n} relocations")
        with open(os.path.join(dst, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    main()
