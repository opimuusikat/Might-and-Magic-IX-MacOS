#!/usr/bin/env python3
"""Fail if a folder that is meant for sharing holds bytes from the game.

    leak_check.py <game_dir> [<more game dirs>...] -- <package_dir>

Checks every file under <package_dir>:
  - it must not be a PE image (MZ header with a PE signature);
  - no 64-byte chunk of any game PE/resource file (taken at 64-byte-aligned offsets) may appear
    anywhere in it. So any copied run of 127 bytes or more is caught. Low-entropy chunks (fewer
    than 12 distinct byte values: padding, zero runs, fill patterns) are ignored.
Exit status 0 = clean, 1 = something found (listed), 2 = usage error.
"""
import os
import struct
import sys

CH = 64
GAME_EXT = (".exe", ".dll", ".ren", ".lto", ".fxd", ".m3d", ".asi", ".tsk", ".ico", ".flt")


def is_pe(d):
    if len(d) < 0x40 or d[:2] != b"MZ":
        return False
    e = struct.unpack_from("<I", d, 0x3C)[0]
    return e + 4 <= len(d) and d[e:e + 4] == b"PE\0\0"


def main():
    if "--" not in sys.argv:
        print(__doc__)
        return 2
    k = sys.argv.index("--")
    games, pkgs = sys.argv[1:k], sys.argv[k + 1:]
    chunks, nfiles = set(), 0
    for g in games:
        for root, _, files in os.walk(g):
            for f in files:
                if not f.lower().endswith(GAME_EXT):
                    continue
                d = open(os.path.join(root, f), "rb").read()
                nfiles += 1
                for i in range(0, len(d) - CH + 1, CH):
                    c = d[i:i + CH]
                    if len(set(c)) >= 12:
                        chunks.add(c)
    if not chunks:
        print("leak check: no game files found in", games)
        return 2
    bad, scanned = [], 0
    for p in pkgs:
        for root, _, files in os.walk(p):
            for f in files:
                path = os.path.join(root, f)
                d = open(path, "rb").read()
                scanned += 1
                if is_pe(d):
                    bad.append(f"{path}: is a PE image")
                    continue
                for i in range(len(d) - CH + 1):
                    if d[i:i + CH] in chunks:
                        bad.append(f"{path}: game bytes at offset {i}")
                        break
    print(f"leak check: {len(chunks)} chunks from {nfiles} game files; {scanned} package files scanned")
    for b in bad:
        print("  LEAK:", b)
    print("leak check:", "FAILED" if bad else "clean")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
