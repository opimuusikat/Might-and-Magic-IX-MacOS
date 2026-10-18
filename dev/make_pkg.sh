#!/bin/bash
# Make a classic macOS installer (.pkg) of the BUILDER (never of the game or the app it makes):
# build/native-builder/MM9-Native-Builder.pkg. It installs "MM9 Native Builder" into /Applications.
# Files installed by Installer carry no quarantine flag, so the player needs no xattr step.
# Runs dev/package.sh first, so the leak check against the owner's game copy gates the installer.
#   dev/make_pkg.sh [game_dir]
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$N/.." && pwd)"
OUT="$ROOT/build/native-builder"
VERSION="${MM9N_PKG_VERSION:-$(git -C "$N" describe --tags --always 2>/dev/null || echo 1)}"
bash "$N/dev/package.sh" "$@"
PKGROOT="$OUT/pkgroot"; RES="$OUT/pkgres"; COMP="$OUT/builder-component.pkg"; PKG="$OUT/MM9-Native-Builder.pkg"
rm -rf "$PKGROOT" "$RES" "$COMP" "$PKG"
mkdir -p "$PKGROOT/Applications" "$RES"
COPYFILE_DISABLE=1 cp -RX "$OUT/MM9-Native-Builder" "$PKGROOT/Applications/MM9 Native Builder"
xattr -cr "$PKGROOT" 2>/dev/null || true
cp "$N/LICENSE" "$RES/license.txt"
cat > "$RES/welcome.html" <<'H'
<html><body style="font-family:-apple-system,Helvetica,sans-serif">
<h2>MM9 Native Builder</h2>
<p>Builds a native Apple Silicon version of Might and Magic IX <b>from your own copy of the game</b>.</p>
<p><b>For educational and research purposes only.</b> This installer contains no game code, no game assets and
nothing derived from a game. You must bring your own legally purchased GOG 1.3 copy. Do not share the app the
builder makes.</p>
<p>You need: Apple Silicon, macOS 13 or later, Apple's Command Line Tools, about 4 GB free space and an internet
connection. If you start from the GOG installer (.exe), also run <code>brew install innoextract</code>.</p>
</body></html>
H
cat > "$RES/conclusion.html" <<'H'
<html><body style="font-family:-apple-system,Helvetica,sans-serif">
<h2>Installed</h2>
<p>Open the <b>Applications</b> folder, then <b>MM9 Native Builder</b>, and double-click
<b>Build MM9 Native.command</b>. When it says "Done", your game is in <code>~/Applications/MM9 Native.app</code>.</p>
<p>If macOS refuses to open the .command file, right-click it and choose Open. README.txt has the details.</p>
</body></html>
H
cat > "$OUT/pkg-distribution.xml" <<H
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MM9 Native Builder</title>
  <welcome file="welcome.html"/><license file="license.txt"/><conclusion file="conclusion.html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="MM9 Native Builder"><pkg-ref id="org.mm9native.builder"/></choice>
  <pkg-ref id="org.mm9native.builder" version="$VERSION">builder-component.pkg</pkg-ref>
</installer-gui-script>
H
COPYFILE_DISABLE=1 pkgbuild --root "$PKGROOT" --identifier org.mm9native.builder --version "$VERSION" --install-location / "$COMP"
productbuild --distribution "$OUT/pkg-distribution.xml" --resources "$RES" --package-path "$OUT" "$PKG"
rm -rf "$PKGROOT" "$RES" "$COMP" "$OUT/pkg-distribution.xml"
echo "installer: $PKG ($(du -h "$PKG" | cut -f1))"
