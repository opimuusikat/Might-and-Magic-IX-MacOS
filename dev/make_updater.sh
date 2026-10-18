#!/bin/bash
# Make the double-click updater: build/native-builder/MM9-Native-Updater.dmg holding "MM9 Native Updater.app"
# (a window that checks an installed MM9 Native and updates it with the bundled builder). The app bundles the
# builder only; it never holds game bytes and needs no innoextract. Runs the leak check first.
#   dev/make_updater.sh [game_dir]
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$N/.." && pwd)"
GAME_DIR="${1:-$ROOT/build/recomp-work/trace/game}"
OUT="$ROOT/build/native-builder"; APP="$OUT/MM9 Native Updater.app"; DMGSTAGE="$OUT/dmg-stage-updater"; DMG="$OUT/MM9-Native-Updater.dmg"
VERSION="$(grep -m1 BUILDER_VERSION "$N/src/manifest.sh" | sed -E 's/.*="?([^"]*)"?.*/\1/')"
rm -rf "$APP" "$DMGSTAGE" "$DMG"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/builder"
B="$APP/Contents/Resources/builder"
cp -R "$N/src" "$N/LICENSES" "$N/README.txt" "$B/"
cp "$N/installer/assets/logo.jpg" "$APP/Contents/Resources/logo.jpg"
find "$B" \( -name '.DS_Store' -o -name '__pycache__' -o -name '._*' \) -prune -exec rm -rf {} +
chmod +x "$B/src/build.sh"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MM9Updater</string>
<key>CFBundleIdentifier</key><string>org.mm9native.updater</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>MM9 Native Updater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
# universal, so that on an Intel Mac the window opens and says that Apple Silicon is needed
SWT="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macos13.0" "$N/installer/MM9Updater.swift" "$N/installer/XPKit.swift" -o "$SWT/MM9Updater-$arch"
done
lipo -create "$SWT"/MM9Updater-* -output "$APP/Contents/MacOS/MM9Updater"; rm -rf "$SWT"
# app icon: the logo tile with a green update badge, rendered by the app itself, then made into an .icns
ICONTMP="$(mktemp -d)"; mkdir "$ICONTMP/AppIcon.iconset"
"$APP/Contents/MacOS/MM9Updater" --render-icon "$ICONTMP/icon.png"
for sz in 16 32 64 128 256 512; do
  sips -z $sz $sz "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}.png" > /dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" > /dev/null
done
iconutil -c icns "$ICONTMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$ICONTMP"
xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/python3 -I "$N/dev/leak_check.py" "$GAME_DIR" "$ROOT/build/recomp-work/m1/inputs" -- "$B"
mkdir -p "$DMGSTAGE"; cp -R "$APP" "$DMGSTAGE/"; ln -s /Applications "$DMGSTAGE/Applications"
cat > "$DMGSTAGE/READ ME FIRST.txt" <<'R'
1. Drag "MM9 Native Updater" to Applications (or just double-click it from here).
2. The first time, macOS says it cannot check the app (it is not notarised).
   macOS 14 and older: right-click the app, choose Open, then Open.
   macOS 15 and newer: double-click it once, then open System Settings > Privacy & Security, scroll down
   and click "Open Anyway" next to "MM9 Native Updater", then confirm.
3. Open it; it checks your MM9 Native and updates it. Your saves are kept and backed up first.
   It works on the game copy that is already on your Mac; nothing of the game is in this download.
Educational use only. Source and licences: https://github.com/opimuusikat/Might-and-Magic-IX-MacOS
R
hdiutil create -volname "MM9 Native Updater" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$DMGSTAGE"
echo "updater: $DMG ($(du -h "$DMG" | cut -f1))"
