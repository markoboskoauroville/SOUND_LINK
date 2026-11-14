#!/bin/sh
# build.sh: Sound Link (Mantra).app, swiftc straight, no Xcode. Run by GitHub Actions only (compile-on-github.md):
# SIGN=- NO_INSTALL=1 ./build.sh. On the Mac the release zip is installed and re-signed "Mantra Apps" (TAKEOVER.md).
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Sound Link (Mantra)"
ID="community.auroville.soundlink"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/SoundLink" app/*.swift
[ -x "$APP/Contents/MacOS/SoundLink" ] || { echo "the app did not build"; exit 1; }
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>SoundLink</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Sound Link (Mantra) reads the two channels you choose (your mixer) and sends them to Manual Camera on the Wi-Fi. Nothing is recorded on the Mac.</string>
<key>NSLocalNetworkUsageDescription</key><string>Sound Link (Mantra) finds Manual Camera on your Wi-Fi and sends it the sound.</string>
<key>NSBonjourServices</key><array><string>_mantrasound._udp</string></array>
</dict></plist>
PL
I=build/AppIcon.iconset; rm -rf $I; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s icon/six_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/six_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
[ -n "$NO_INSTALL" ] && exit 0
echo "install from the release instead (TAKEOVER.md)"
