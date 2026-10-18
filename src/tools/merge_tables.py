#!/usr/bin/env python3
"""Merge the per-module table.c files from emit into one guest-address -> function table.
    merge_tables.py <out.c> <gen_dir>...
"""
import re, sys
addrs = set()
for d in sys.argv[2:]:
    t = open(d + "/table.c").read()
    body = t[t.index("rt_fn_addr[] = {"):t.index("};")]
    addrs.update(int(x, 16) for x in re.findall(r"0x([0-9a-f]+)u", body))
a = sorted(addrs)
with open(sys.argv[1], "w") as f:
    f.write('#include "rt.h"\n' + "".join(f"void g_{x:x}(CPU *);\n" for x in a))
    f.write("const uint32_t rt_fn_addr[] = {" + ",".join(f"0x{x:x}u" for x in a) + "};\n")
    f.write("const GuestFn rt_fn_ptr[] = {" + ",".join(f"g_{x:x}" for x in a) + "};\n")
    f.write(f"const int rt_fn_count = {len(a)};\n")
print(f"{len(a)} functions")
