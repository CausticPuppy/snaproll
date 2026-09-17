#!/bin/sh
# Builds a release Snaproll.app bundle at .build/Snaproll.app and zips it for
# distribution at .build/Snaproll.zip.
#
# Optional code signing + notarization (to avoid the "unidentified developer"
# Gatekeeper warning on downloaded builds). Both require an Apple Developer
# Program membership. Leave the env vars unset for a plain unsigned build.
#
#   DEVELOPER_ID   Developer ID Application identity, e.g.
#                  "Developer ID Application: Jason Bruce (TEAMID1234)".
#                  When set, the .app is signed with the hardened runtime.
#   NOTARY_PROFILE notarytool keychain profile name (set up once with
#                  `xcrun notarytool store-credentials`). When set (and the
#                  app is signed), the zip is submitted for notarization and
#                  the ticket is stapled to the .app.
#   UNIVERSAL=1    Build a universal (arm64 + x86_64) binary instead of native.
#   VERSION        Marketing version for CFBundleShortVersionString (default
#                  0.1.0). Must be one to three period-separated integers —
#                  put any pre-release label (e.g. -beta.1) on the git tag, not
#                  here.
#   BUILD          Build number for CFBundleVersion (default 1).
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-1}"

# Keep in sync with `platforms:` in Package.swift.
MIN_MACOS="13.0"

# Stamp the real SDK version into the binary. Xcode 27's default SwiftPM build
# engine (swiftbuild) otherwise records the deployment target (13.0) as the SDK
# version, and AppKit gates newer behaviors and styling on that linked-SDK stamp.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_FLAGS="-c release -Xlinker -platform_version -Xlinker macos -Xlinker $MIN_MACOS -Xlinker $SDK_VERSION"
if [ "$UNIVERSAL" = "1" ]; then
    BUILD_FLAGS="$BUILD_FLAGS --arch arm64 --arch x86_64"
fi
swift build $BUILD_FLAGS
BIN_DIR="$(swift build $BUILD_FLAGS --show-bin-path)"

APP=".build/Snaproll.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Snaproll" "$APP/Contents/MacOS/Snaproll"

# Bundle the SwiftPM resources (so Bundle.module resolves inside the .app too).
if [ -d "$BIN_DIR/Snaproll_SnaprollApp.bundle" ]; then
    cp -R "$BIN_DIR/Snaproll_SnaprollApp.bundle" "$APP/Contents/Resources/"
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

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "Built $APP ($VERSION build $BUILD)"

# Strip extended attributes so the signature seals clean files and the zip
# doesn't carry ._ AppleDouble sidecars.
xattr -cr "$APP"

# Code signing — hardened runtime is required for notarization.
if [ -n "$DEVELOPER_ID" ]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$DEVELOPER_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed $APP with: $DEVELOPER_ID"
else
    # No Developer ID: ad-hoc sign so the bundle carries a valid, self-consistent
    # signature (seals resources + binds Info.plist). Without this the linker's
    # ad-hoc signature covers only the executable, leaving the bundle unverifiable
    # and, on Apple Silicon, prone to launch failures. This does NOT remove the
    # Gatekeeper "unidentified developer" warning — only notarization does.
    codesign --force --deep --sign - "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Ad-hoc signed $APP (no DEVELOPER_ID) — still trips Gatekeeper; use right-click > Open."
fi

# Zip for distribution (ditto preserves the bundle + any signature).
ZIP=".build/Snaproll.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "Zipped $ZIP"

# Notarization (optional) — requires a signed app and a notarytool profile.
if [ -n "$NOTARY_PROFILE" ]; then
    if [ -z "$DEVELOPER_ID" ]; then
        echo "NOTARY_PROFILE set but app is unsigned; skipping notarization." >&2
    else
        echo "Submitting to Apple notary service (this can take a few minutes)..."
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        # Re-zip so the distributed archive carries the stapled ticket.
        rm -f "$ZIP"
        /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarized + stapled; re-zipped $ZIP"
    fi
else
    echo "Skipping notarization (NOTARY_PROFILE not set)."
fi
