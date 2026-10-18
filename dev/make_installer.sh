#!/bin/bash
# Make the double-click installer: build/native-builder/MM9-Native-Installer.dmg holding
# "MM9 Native Installer.app" (a window where the player drops the GOG installer). The app bundles the
# builder and a static innoextract; it never holds game bytes. Runs the leak check first.
#   dev/make_installer.sh [game_dir]     (needs dev/build_innoextract.sh run once)
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$N/.." && pwd)"
GAME_DIR="${1:-$ROOT/build/recomp-work/trace/game}"
OUT="$ROOT/build/native-builder"; APP="$OUT/MM9 Native Installer.app"; DMGSTAGE="$OUT/dmg-stage"; DMG="$OUT/MM9-Native-Installer.dmg"
INNO="$ROOT/build/innoextract-build/innoextract-1.9/b/innoextract"
[ -x "$INNO" ] || { echo "run dev/build_innoextract.sh first"; exit 1; }
VERSION="$(grep -m1 BUILDER_VERSION "$N/src/manifest.sh" | sed -E 's/.*="?([^"]*)"?.*/\1/')"
rm -rf "$APP" "$DMGSTAGE" "$DMG"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/builder/bin"
B="$APP/Contents/Resources/builder"
cp -R "$N/src" "$N/LICENSES" "$N/README.txt" "$B/"
cp "$INNO" "$B/bin/innoextract"
cp "$N/installer/assets/logo.jpg" "$APP/Contents/Resources/logo.jpg"
find "$B" \( -name '.DS_Store' -o -name '__pycache__' -o -name '._*' \) -prune -exec rm -rf {} +
chmod +x "$B/src/build.sh"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MM9Installer</string>
<key>CFBundleIdentifier</key><string>org.mm9native.installer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>MM9 Native Installer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
# universal, so that on an Intel Mac the window opens and the builder explains that Apple Silicon is needed
SWT="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macos13.0" "$N/installer/MM9Installer.swift" -o "$SWT/MM9Installer-$arch"
done
lipo -create "$SWT"/MM9Installer-* -output "$APP/Contents/MacOS/MM9Installer"; rm -rf "$SWT"
# app icon: the logo on a rounded tile, rendered by the app itself, then made into an .icns
ICONTMP="$(mktemp -d)"; mkdir "$ICONTMP/AppIcon.iconset"
"$APP/Contents/MacOS/MM9Installer" --render-icon "$ICONTMP/icon.png"
for sz in 16 32 64 128 256 512; do
  sips -z $sz $sz "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}.png" > /dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" > /dev/null
done
iconutil -c icns "$ICONTMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$ICONTMP"
xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
# innoextract statically links xz's public CRC-64 table, which the game's ddraw.dll also holds: --known excludes it
/usr/bin/python3 -I "$N/dev/leak_check.py" "$GAME_DIR" "$ROOT/build/recomp-work/m1/inputs" --known=/opt/homebrew/opt/xz/lib/liblzma.a -- "$B"
mkdir -p "$DMGSTAGE"; cp -R "$APP" "$DMGSTAGE/"; ln -s /Applications "$DMGSTAGE/Applications"
cat > "$DMGSTAGE/READ ME FIRST.txt" <<'R'
1. Drag "MM9 Native Installer" to Applications (or just double-click it from here).
2. The first time, macOS says it cannot check the app (it is not notarised).
   macOS 14 and older: right-click the app, choose Open, then Open.
   macOS 15 and newer: double-click it once, then open System Settings > Privacy & Security, scroll down
   and click "Open Anyway" next to "MM9 Native Installer", then confirm.
3. Drop your GOG installer (setup_might_and_magic_9_writ_of_fate_1.3_...exe) on the window.
   It needs your own copy of the game (GOG version 1.3); nothing of the game is in this download.
Educational use only. Source and licences: https://github.com/opimuusikat/Might-and-Magic-IX-MacOS
R
hdiutil create -volname "MM9 Native Installer" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$DMGSTAGE"
echo "installer: $DMG ($(du -h "$DMG" | cut -f1))"
