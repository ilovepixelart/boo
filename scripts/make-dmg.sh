#!/bin/bash
# Package zig-out/Boo.app into a distributable .dmg.
#
#   zig build app -Doptimize=ReleaseFast
#   ./bundle.sh
#   ./scripts/make-dmg.sh
#
# The app is ad-hoc signed (see bundle.sh), so the DMG is NOT notarized and
# Gatekeeper will refuse to open it on first launch. That is expected and
# documented in the README — users right-click → Open, or strip the quarantine
# attribute. Notarizing would need a paid Apple Developer ID.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

APP="zig-out/Boo.app"
VERSION="${BOO_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)}"
ARCH="$(uname -m)"
DMG="zig-out/Boo-${VERSION}-${ARCH}.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run 'zig build app -Doptimize=ReleaseFast && ./bundle.sh' first" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# A /Applications symlink beside the app is the conventional drag-to-install
# layout; without it users have to know where to put the bundle.
cp -R "$APP" "$STAGE/Boo.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Boo $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"

# Sanity-check the image really mounts and carries an intact bundle — a DMG
# that fails here would fail identically on a user's machine.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
if [ -x "$MOUNT/Boo.app/Contents/MacOS/Boo" ] && codesign -v "$MOUNT/Boo.app" 2>/dev/null; then
    echo "Verified: mounts, bundle intact, signature valid (ad-hoc)"
    hdiutil detach "$MOUNT" -quiet
else
    hdiutil detach "$MOUNT" -quiet || true
    rmdir "$MOUNT" 2>/dev/null || true
    echo "error: DMG verification failed" >&2
    exit 1
fi
rmdir "$MOUNT" 2>/dev/null || true
