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
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Code sign with stable identity so macOS remembers permissions across rebuilds
codesign -s "Apple Development: REDACTED" --force --deep "$APP"

echo "Built: $APP"
echo "Run: open '$APP'"
