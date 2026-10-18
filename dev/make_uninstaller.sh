#!/bin/bash
# Make the double-click uninstaller: build/native-builder/MM9-Native-Uninstaller.dmg holding "MM9 Native Uninstaller.app"
# (a red XP-style window that moves MM9 Native, its game copy, build tools and settings to the Trash; saves stay
# unless the player ticks them). The app holds no builder and no game bytes: only its own code and the logo.
#   dev/make_uninstaller.sh
set -euo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$N/.." && pwd)"
OUT="$ROOT/build/native-builder"; APP="$OUT/MM9 Native Uninstaller.app"; DMGSTAGE="$OUT/dmg-stage-uninstaller"; DMG="$OUT/MM9-Native-Uninstaller.dmg"
VERSION="$(grep -m1 BUILDER_VERSION "$N/src/manifest.sh" | sed -E 's/.*="?([^"]*)"?.*/\1/')"
rm -rf "$APP" "$DMGSTAGE" "$DMG"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$N/installer/assets/logo.jpg" "$APP/Contents/Resources/logo.jpg"
cp -R "$N/LICENSES" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MM9Uninstaller</string>
<key>CFBundleIdentifier</key><string>org.mm9native.uninstaller</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>MM9 Native Uninstaller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
# universal: MM9 Native itself needs Apple Silicon, but leftovers can be cleaned from any Mac
SWT="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macos13.0" "$N/installer/MM9Uninstaller.swift" "$N/installer/XPKit.swift" -o "$SWT/MM9Uninstaller-$arch"
done
lipo -create "$SWT"/MM9Uninstaller-* -output "$APP/Contents/MacOS/MM9Uninstaller"; rm -rf "$SWT"
# app icon: the logo tile with a red trash badge, rendered by the app itself, then made into an .icns
ICONTMP="$(mktemp -d)"; mkdir "$ICONTMP/AppIcon.iconset"
"$APP/Contents/MacOS/MM9Uninstaller" --render-icon "$ICONTMP/icon.png"
for sz in 16 32 64 128 256 512; do
  sips -z $sz $sz "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}.png" > /dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICONTMP/icon.png" --out "$ICONTMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" > /dev/null
done
iconutil -c icns "$ICONTMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$ICONTMP"
xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
mkdir -p "$DMGSTAGE"; cp -R "$APP" "$DMGSTAGE/"
cat > "$DMGSTAGE/READ ME FIRST.txt" <<'R'
1. Double-click "MM9 Native Uninstaller" from here (no need to copy it anywhere).
2. The first time, macOS says it cannot check the app (it is not notarised).
   macOS 14 and older: right-click the app, choose Open, then Open.
   macOS 15 and newer: double-click it once, then open System Settings > Privacy & Security, scroll down
   and click "Open Anyway" next to "MM9 Native Uninstaller", then confirm.
3. Tick what to remove. Everything goes to the Trash; your saved games stay unless you tick them too.
   The Wine version of the game (Might and Magic IX.app) is never touched.
Source and licences: https://github.com/opimuusikat/Might-and-Magic-IX-MacOS
R
hdiutil create -volname "MM9 Native Uninstaller" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$DMGSTAGE"
echo "uninstaller: $DMG ($(du -h "$DMG" | cut -f1))"
