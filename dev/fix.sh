#!/bin/bash
# Publish in-game bug fixes as "variants" in fixes/, which the MM9 Native Updater lists and downloads.
# A variant is the full set of src/host/ files that differ from the committed baseline, so each variant stands alone
# and includes the earlier fixes. Never commit edits to src/host/ itself: they would change the builder, and every
# MM9 Native would then need a full builder update. Builder-level changes (recompiler, build.sh) still go to src/ and bump BUILDER_VERSION.
#
#   dev/fix.sh start                      copy the newest published variant into src/host/, so you edit on top of it
#   ... edit src/host/*.c *.m *.h, build and test ...
#   dev/fix.sh publish <id> "<title>" ["<note>" ...] [--stable]
#                                         save the changed files as fixes/<id>/host/, add it to fixes/index.json,
#                                         and put src/host/ back to the committed baseline
#   dev/fix.sh stable <id> | unstable <id>   mark a tested variant as stable (the installer picks the newest stable one)
#
# Then: git add fixes && git commit && git push. The updater reads fixes/ from the main branch on GitHub.
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"; cd "$N"
IDX="fixes/index.json"
VERSION="$(sed -n 's/^BUILDER_VERSION=//p' src/manifest.sh | head -1 | tr -d '"')"
cmd="${1:-}"; shift || true

case "$cmd" in
  start)
    id="$(/usr/bin/python3 -I src/tools/fixes.py list "$IDX" "$VERSION" | sed -n 's/^fix=\([^	]*\)	.*/\1/p' | head -1)"
    [ -n "$id" ] || { echo "No published variant yet: edit src/host/ directly."; exit 0; }
    [ -z "$(git status --porcelain -- src/host)" ] || { echo "src/host/ already has edits. Publish or discard them first."; exit 1; }
    /usr/bin/python3 -I src/tools/fixes.py files "$IDX" "$id" | while read -r rel _; do cp "fixes/$id/$rel" "src/$rel"; done
    echo "src/host/ now holds variant $id. Edit, test, then: dev/fix.sh publish <new-id> \"<title>\""
    ;;
  publish)
    id="${1:?id}"; title="${2:?title}"; shift 2
    stable=false; notes=()
    for a in "$@"; do if [ "$a" = --stable ]; then stable=true; else notes+=("$a"); fi; done
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || { echo "Bad id: use letters, digits . _ - only, up to 40 characters."; exit 1; }
    [ ! -e "fixes/$id" ] || { echo "fixes/$id already exists."; exit 1; }
    changed="$(git status --porcelain -- src/host)"
    [ -n "$changed" ] || { echo "src/host/ has no changes against the committed baseline."; exit 1; }
    echo "$changed" | grep -q '^ *D' && { echo "Deleting a host file is not supported by variants."; exit 1; }
    mkdir -p "fixes/$id/host"
    files=(); while IFS= read -r line; do f="${line:3}"; files+=("$f"); cp "$f" "fixes/$id/host/$(basename "$f")"; done <<< "$changed"
    /usr/bin/python3 -I - "$IDX" "$id" "$title" "$VERSION" "$stable" "fixes/$id/host" ${notes[@]+"${notes[@]}"} <<'PY'
import hashlib, json, os, sys, datetime
idx, id_, title, version, stable, d = sys.argv[1:7]; notes = sys.argv[7:]
data = json.load(open(idx))
files = {}
for n in sorted(os.listdir(d)):
    files["host/" + n] = hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest()
data["fixes"].append({"id": id_, "date": datetime.date.today().isoformat(), "title": title, "builder": version,
                      "stable": stable == "true", "notes": notes, "files": files})
json.dump(data, open(idx, "w"), indent=2); open(idx, "a").write("\n")
PY
    for f in "${files[@]}"; do git ls-files --error-unmatch "$f" >/dev/null 2>&1 && git checkout -- "$f" || rm -f "$f"; done
    echo "Published fixes/$id ($((${#files[@]})) files); src/host/ is back at the baseline."
    echo "Test it, then 'dev/fix.sh stable $id', and commit + push fixes/."
    ;;
  stable|unstable)
    id="${1:?id}"; want=true; [ "$cmd" = unstable ] && want=false
    /usr/bin/python3 -I - "$IDX" "$id" "$want" <<'PY'
import json, sys
idx, id_, want = sys.argv[1:4]
data = json.load(open(idx)); hit = [e for e in data["fixes"] if e["id"] == id_]
if not hit: sys.exit("No variant %s in %s" % (id_, idx))
hit[0]["stable"] = want == "true"
json.dump(data, open(idx, "w"), indent=2); open(idx, "a").write("\n")
PY
    echo "$id is now marked $cmd."
    ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
