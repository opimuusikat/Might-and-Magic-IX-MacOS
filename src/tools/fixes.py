#!/usr/bin/python3
"""Reads fixes/index.json for build.sh (which does the downloading with curl).

  fixes.py list  <index.json> <builder-version>   key=value lines: the last 5 variants made for this builder, newest first
  fixes.py files <index.json> <id>                one "<path> <sha256>" line per file of that variant
  fixes.py title <index.json> <id>                the variant's title

A variant is the full set of changed in-game (host) files, not a diff: it replaces files of src/host/ and can add new ones.
"""
import json, re, sys

KEEP = 5
ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}$")
FILE_RE = re.compile(r"^host/[A-Za-z0-9._-]+\.(c|m|h)$")   # only plain files directly inside host/
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def load(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    out = []
    for e in d.get("fixes", []):
        if not isinstance(e, dict) or not ID_RE.match(str(e.get("id", ""))):
            continue
        files = e.get("files", {})
        if not isinstance(files, dict) or not files:
            continue
        if not all(FILE_RE.match(str(p)) and SHA_RE.match(str(h)) for p, h in files.items()):
            continue
        out.append(e)
    return out


def clean(s):
    return re.sub(r"[\t\r\n]+", " ", str(s)).strip()


def main(argv):
    if len(argv) < 4:
        return 2
    cmd, index, arg = argv[1], argv[2], argv[3]
    fixes = load(index)
    if cmd == "list":
        mine = [e for e in fixes if str(e.get("builder", "")) == arg][-KEEP:][::-1]
        for e in mine:
            print("fix=%s\t%s\t%d\t%s" % (e["id"], clean(e.get("date", "")), 1 if e.get("stable") else 0, clean(e.get("title", e["id"]))))
            for n in e.get("notes", [])[:12]:
                print("fix_note=%s\t%s" % (e["id"], clean(n)))
        print("fix_default=%s" % next((e["id"] for e in mine if e.get("stable")), ""))
        return 0
    e = next((x for x in fixes if x["id"] == arg), None)
    if e is None:
        return 1
    if cmd == "files":
        for p, h in e["files"].items():
            print("%s %s" % (p, h))
        return 0
    if cmd == "title":
        print(clean(e.get("title", e["id"])))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
