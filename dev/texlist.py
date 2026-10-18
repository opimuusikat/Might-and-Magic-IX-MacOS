#!/usr/bin/env python3 -I
"""Usage: texlist.py <TextureDir> [--format F] [--min-size N] [--missing | --replaced] [--list] [--limit N]
Lists the textures dumped by the host (M1_TEXDUMP=1) from <TextureDir>/dump/index.tsv and shows which already
have a replacement (<hash>.png or <hash>.dds in <TextureDir>/replace/). --min-size keeps textures with
max(width, height) >= N. Without --list only the summary is printed."""
import argparse, collections, os, sys


def main():
    ap = argparse.ArgumentParser(usage=__doc__.split("\n")[0].replace("Usage: ", ""), description=__doc__.split("\n", 1)[1])
    ap.add_argument("dir")
    ap.add_argument("--format")
    ap.add_argument("--min-size", type=int, default=0)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--missing", action="store_true")
    g.add_argument("--replaced", action="store_true")
    ap.add_argument("--list", action="store_true", help="print one row per texture")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    idx = os.path.join(a.dir, "dump", "index.tsv")
    if not os.path.isfile(idx):
        sys.exit("no index: " + idx)
    rep = set()
    rd = os.path.join(a.dir, "replace")
    if os.path.isdir(rd):
        for n in os.listdir(rd):
            b, e = os.path.splitext(n)
            if e.lower() in (".png", ".dds"):
                rep.add(b.lower())
    rows, seen = [], set()
    with open(idx) as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            if len(r) != len(head) or r["hash"] in seen:
                continue
            seen.add(r["hash"])
            r["w"], r["h"] = int(r["width"]), int(r["height"])
            r["rep"] = r["hash"] in rep
            r["png"] = os.path.isfile(os.path.join(a.dir, "dump", r["hash"] + ".png"))
            rows.append(r)
    sel = [r for r in rows
           if (not a.format or r["format"].lower() == a.format.lower())
           and max(r["w"], r["h"]) >= a.min_size
           and not (a.missing and r["rep"]) and not (a.replaced and not r["rep"])]
    if a.list:
        print("hash\tsize\tformat\tmips\talpha\tkey\tframe\tcaps\treplaced")
        for r in sel[: a.limit or None]:
            print("\t".join([r["hash"], "%dx%d" % (r["w"], r["h"]), r["format"], r["mips"], r["has_alpha"], r["colorkey"],
                             r["first_frame"], r["caps"], "yes" if r["rep"] else "no"]))
    print("textures: %d selected of %d dumped; replaced %d, missing %d; png files missing for %d"
          % (len(sel), len(rows), sum(r["rep"] for r in sel), sum(not r["rep"] for r in sel), sum(not r["png"] for r in sel)))
    orph = sorted(h for h in rep if h not in seen)
    print("orphan replacement files (no dumped hash): %d%s" % (len(orph), " e.g. " + ", ".join(orph[:5]) if orph else ""))
    print("by format:")
    for k, v in sorted(collections.Counter(r["format"] for r in sel).items(), key=lambda x: -x[1]):
        print("  %-10s %6d" % (k, v))
    print("by size (max side):")
    for k, v in sorted(collections.Counter(max(r["w"], r["h"]) for r in sel).items()):
        print("  %5d %6d" % (k, v))
    print("by caps: " + ", ".join("%s:%d" % kv for kv in sorted(collections.Counter(r["caps"] for r in sel).items(), key=lambda x: -x[1])[:8]))


main()
