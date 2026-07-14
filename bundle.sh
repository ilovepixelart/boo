#!/bin/bash
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJ/zig-out/Boo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$PROJ/zig-out/Boo" "$MACOS/Boo"
cp "$PROJ/assets/boo.icns" "$RESOURCES/boo.icns"
# Metal shader + headers for GPU-accelerated whisper inference
cp "$PROJ/assets/ggml-metal.metal" "$RESOURCES/ggml-metal.metal" 2>/dev/null || true
cp "$PROJ/assets/ggml-common.h" "$RESOURCES/ggml-common.h" 2>/dev/null || true
# Themes — ThemeManager looks for Resources/themes in bundles
cp -R "$PROJ/themes" "$RESOURCES/themes"

cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Boo</string>
    <key>CFBundleDisplayName</key>
    <string>Boo</string>
    <key>CFBundleIdentifier</key>
    <string>com.boo.app</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>Boo</string>
    <key>CFBundleIconFile</key>
    <string>boo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Boo needs microphone access for speech-to-text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Boo sends dictated text to Ghostty through its scripting interface.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Code sign with stable identity so macOS remembers permissions across rebuilds.
# Defaults to ad-hoc; override with BOO_CODESIGN_IDENTITY env var, e.g.
#   BOO_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./bundle.sh
CODESIGN_IDENTITY="${BOO_CODESIGN_IDENTITY:--}"
codesign -s "$CODESIGN_IDENTITY" --force --deep \
    --entitlements "$PROJ/macos/Boo.entitlements" "$APP"

echo "Built: $APP"
echo "Run: open '$APP'"
