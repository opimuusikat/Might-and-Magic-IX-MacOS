#!/usr/bin/env python3
"""Pack an .iconset folder (icon_16x16.png ... icon_512x512@2x.png, as badge_icon writes it)
into an .icns file. Same result as `iconutil -c icns`, without needing iconutil.
    icns.py <in.iconset> <out.icns>
"""
import os
import struct
import sys

TYPES = [("icp4", "16x16"), ("icp5", "32x32"), ("ic11", "16x16@2x"), ("ic12", "32x32@2x"),
         ("ic07", "128x128"), ("ic13", "128x128@2x"), ("ic08", "256x256"), ("ic14", "256x256@2x"),
         ("ic09", "512x512"), ("ic10", "512x512@2x")]


def main():
    d, out = sys.argv[1], sys.argv[2]
    body = b""
    for t, n in TYPES:
        png = open(os.path.join(d, f"icon_{n}.png"), "rb").read()
        body += t.encode() + struct.pack(">I", 8 + len(png)) + png
    with open(out, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)


if __name__ == "__main__":
    main()
