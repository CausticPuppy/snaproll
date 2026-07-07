#!/bin/sh
# Wraps the SwiftPM-built binary in a minimal .app bundle at .build/Snaproll.app
set -e
cd "$(dirname "$0")/.."
swift build
APP=".build/Snaproll.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/Snaproll "$APP/Contents/MacOS/Snaproll"

# Bundle the SwiftPM resources (so Bundle.module resolves inside the .app too).
if [ -d ".build/debug/Snaproll_SnaprollApp.bundle" ]; then
    cp -R ".build/debug/Snaproll_SnaprollApp.bundle" "$APP/Contents/Resources/"
fi

# Build AppIcon.icns from the source logo for the Finder/Dock icon.
ICON_SRC="Sources/SnaprollApp/Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
                128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
                512:512x512 1024:512x512@2x; do
        px="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_${name}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.jasonbruce.snaproll</string>
    <key>CFBundleName</key><string>Snaproll</string>
    <key>CFBundleDisplayName</key><string>Snaproll</string>
    <key>CFBundleExecutable</key><string>Snaproll</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
