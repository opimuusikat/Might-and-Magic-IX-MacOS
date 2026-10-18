#!/bin/bash
# Refresh the builder's copies of our own code from the M1 work tree (the host runtime, the
# patched emitter and docs/recomp-m0.md), then show what changed. Run before dev/package.sh when m1/host has moved on.
# Copies source code only; nothing from the game. The reference hashes in src/manifest.sh describe
# Ghidra's output and the function table; they change only if the analysis or emitter inputs change.
#   dev/sync_from_m1.sh
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"
W="$(cd "$N/.." && pwd)/build/recomp-work"
before=$(cd "$N/src" && find host recomp -type f -exec shasum {} + | sort)
cp "$W"/m1/host/*.c "$W"/m1/host/*.m "$W"/m1/host/*.h "$N/src/host/"
cp "$W/scripts/fnv-patched/emit_rc.py" "$W/scripts/fnv-patched/flaglive.py" "$N/src/recomp/"
# the engineering notes for the public repo: local absolute paths made relative, and the test
# machine's model/OS version and the build environment's sandbox notes left out
ROOT="$(cd "$N/.." && pwd)"
sed -e "s|$ROOT/||g" \
    -e 's/^| Machine | .*|$/| Machine | an Apple Silicon Mac |/' \
    -e 's/([^()]* measured; base M1 estimate)/(test Mac measured; base M1 estimate)/' \
    -e 's/^\(\*\*Final clean run, step by step\*\*\) ([^;]*; /\1 (test Mac; /' \
    -e '/SIGILL inside the [A-Za-z]* sandbox/d' \
    -e 's/ *# outside the sandbox.*$//' \
    -e 's/^Reproduce (outside the sandbox):/Reproduce:/' \
    -e 's/^Play it (outside the sandbox; /Play it (/' \
    "$ROOT/docs/recomp-m0.md" > "$N/docs/RECOMP-NOTES.md"
after=$(cd "$N/src" && find host recomp -type f -exec shasum {} + | sort)
diff <(echo "$before") <(echo "$after") | awk '/^[<>]/ {print $3}' | sort -u | sed 's/^/changed: /' || true
ls "$W"/m1/host/ | grep -v -E '\.(c|m|h)$' | sed 's/^/not copied (check): /' || true
