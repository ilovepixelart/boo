#!/bin/bash
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJ/zig-out/Boo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Single source of truth: the version comes from build.zig.zon, so a release is
# one edit there (plus a metainfo changelog entry), not four files in sync.
VERSION="$(sed -n 's/.*\.version = "\([0-9][^"]*\)".*/\1/p' "$PROJ/build.zig.zon")"
if [ -z "$VERSION" ]; then
    echo "bundle.sh: could not read .version from build.zig.zon" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$PROJ/zig-out/Boo" "$MACOS/Boo"
cp "$PROJ/assets/boo.icns" "$RESOURCES/boo.icns"
# The Metal shader library is embedded in the binary at build time
# (GGML_METAL_EMBED_LIBRARY), so no loose .metal resource is needed.
# Themes, ThemeManager looks for Resources/themes in bundles
cp -R "$PROJ/themes" "$RESOURCES/themes"

cat >"$CONTENTS/Info.plist" <<'EOF'
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
    <string>@@VERSION@@</string>
    <key>CFBundleShortVersionString</key>
    <string>@@VERSION@@</string>
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

# Fill the version placeholder from build.zig.zon (see VERSION above). Done by
# substitution rather than an unquoted heredoc so nothing else in the plist can
# be accidentally expanded.
sed -i '' "s/@@VERSION@@/$VERSION/g" "$CONTENTS/Info.plist"

# Code sign with stable identity so macOS remembers permissions across rebuilds.
# Defaults to ad-hoc; override with BOO_CODESIGN_IDENTITY env var, e.g.
#   BOO_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./bundle.sh
CODESIGN_IDENTITY="${BOO_CODESIGN_IDENTITY:--}"
codesign -s "$CODESIGN_IDENTITY" --force --deep \
    --entitlements "$PROJ/macos/Boo.entitlements" "$APP"

echo "Built: $APP"
echo "Run: open '$APP'"
