#!/bin/bash
# Make the shareable builder zip from native-builder/: build/native-builder/MM9-Native-Builder.zip.
# Runs the leak check against the game files first (needs the owner's local game copy) and refuses
# to zip if any packaged file holds game bytes. dev/ itself is not packaged.
#   dev/package.sh [game_dir]     (default: build/recomp-work/trace/game, an APFS clone of the install)
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$N/.." && pwd)"
OUT="$ROOT/build/native-builder"
GAME_DIR="${1:-$ROOT/build/recomp-work/trace/game}"
STAGE="$OUT/MM9-Native-Builder"
ZIP="$OUT/MM9-Native-Builder.zip"
rm -rf "$STAGE" "$ZIP"; mkdir -p "$STAGE"
cp "$N/README.txt" "$N/Build MM9 Native.command" "$STAGE/"
cp -R "$N/LICENSES" "$N/src" "$STAGE/"
find "$STAGE" \( -name '.DS_Store' -o -name '__pycache__' -o -name '.claude' -o -name '._*' \) -prune -exec rm -rf {} +
chmod +x "$STAGE/Build MM9 Native.command" "$STAGE/src/build.sh"
/usr/bin/python3 -I "$N/dev/leak_check.py" "$GAME_DIR" "$ROOT/build/recomp-work/m1/inputs" -- "$STAGE"
bash -n "$STAGE/src/build.sh"
(cd "$OUT" && /usr/bin/zip -qr -X "$(basename "$ZIP")" "$(basename "$STAGE")")
echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1), $(find "$STAGE" -type f | wc -l | tr -d ' ') files)"
