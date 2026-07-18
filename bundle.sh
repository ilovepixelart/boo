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

# Code sign with a stable identity so macOS remembers permissions (Accessibility,
# Automation) across rebuilds; ad-hoc signing re-identifies the app on every
# build and loses them. Identity precedence:
#   1. BOO_CODESIGN_IDENTITY  (explicit; a Developer ID or Apple Development cert)
#   2. "Boo Local Signing"    (the free self-signed cert from
#                              scripts/make-signing-cert.sh, if it exists)
#   3. "-"                    (ad-hoc fallback: builds, but grants reset each time)
CODESIGN_IDENTITY="${BOO_CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
    if security find-certificate -c "Boo Local Signing" >/dev/null 2>&1; then
        CODESIGN_IDENTITY="Boo Local Signing"
    else
        CODESIGN_IDENTITY="-"
        echo "bundle.sh: ad-hoc signing (grants reset every build)." >&2
        echo "  Run ./scripts/make-signing-cert.sh once to make them stick." >&2
    fi
fi
codesign -s "$CODESIGN_IDENTITY" --force --deep \
    --entitlements "$PROJ/macos/Boo.entitlements" "$APP"

# Register the freshly built bundle with LaunchServices so Finder picks up its
# icon immediately. Without this a rebuilt (and, when ad-hoc, re-identified)
# bundle keeps showing the generic icon until the OS happens to re-register it.
# `touch` bumps the mtime so the icon cache is treated as stale.
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo "Built: $APP"
echo "Run: open '$APP'"
