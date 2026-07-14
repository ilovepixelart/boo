#!/bin/bash
# build.zig.zon is the single source of truth for the version. bundle.sh derives
# from it automatically; the two files that can't (xcodegen's project.yml, and
# the AppStream metainfo, which are static data) are checked here so they can't
# drift silently. Run in CI and before tagging.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

VERSION="$(sed -n 's/.*\.version = "\([0-9][^"]*\)".*/\1/p' build.zig.zon)"
[ -n "$VERSION" ] || {
    echo "check-version: no .version in build.zig.zon"
    exit 1
}
echo "build.zig.zon version: $VERSION"

fail=0
check() { # <description> <actual>
    if [ "$2" = "$VERSION" ]; then
        echo "  ok   $1 = $2"
    else
        echo "  DRIFT $1 = $2 (expected $VERSION)"
        fail=1
    fi
}

check "project.yml CFBundleShortVersionString" \
    "$(sed -n 's/.*CFBundleShortVersionString: "\([0-9.]*\)".*/\1/p' macos/project.yml)"
check "project.yml CFBundleVersion" \
    "$(sed -n 's/.*CFBundleVersion: "\([0-9.]*\)".*/\1/p' macos/project.yml)"

# The metainfo is a changelog: its *newest* <release> must be this version, so a
# release without a changelog entry is caught.
check "metainfo newest <release>" \
    "$(grep -m1 -oE 'release version="[0-9.]+"' linux/flatpak/com.boo.app.metainfo.xml |
        grep -oE '[0-9.]+')"

if [ "$fail" -ne 0 ]; then
    echo "Version drift. build.zig.zon is the source of truth; update the files above to $VERSION."
    exit 1
fi
echo "all version references agree"
