#!/bin/sh
# Wraps the SwiftPM-built binary in a minimal .app bundle at .build/aFrame Edit.app
set -e
cd "$(dirname "$0")/.."
swift build
APP=".build/aFrame Edit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/AFrameEdit "$APP/Contents/MacOS/AFrameEdit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.jasonbruce.aframe-edit</string>
    <key>CFBundleName</key><string>aFrame Edit</string>
    <key>CFBundleDisplayName</key><string>aFrame Edit</string>
    <key>CFBundleExecutable</key><string>AFrameEdit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "Built $APP"
