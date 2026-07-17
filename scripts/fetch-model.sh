#!/bin/bash
# Fetch a model file into a cache dir and verify its SHA-256, used by CI so a
# corrupt or substituted download can't be stored under a fixed cache key and
# then poison every later run. Idempotent: an existing file with the right hash
# is left alone; a wrong-hash file is refetched.
#
#   fetch-model.sh <dest-file> <sha256> <url>
set -euo pipefail

DEST="$1"
SHA="$2"
URL="$3"

# sha256sum on Linux (Fedora ships no shasum), shasum on macOS.
sha_of() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
verify() { [ "$(sha_of "$1")" = "$SHA" ]; }

if [ -f "$DEST" ] && verify "$DEST"; then
    echo "fetch-model: $DEST already present and verified"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
# -f: fail (non-zero) on HTTP errors instead of saving the error body as the
# model. --retry: ride out transient CDN blips.
curl -fSL --retry 3 -o "$DEST" "$URL"

if ! verify "$DEST"; then
    echo "fetch-model: SHA-256 mismatch for $DEST" >&2
    echo "  expected $SHA" >&2
    echo "  got      $(sha_of "$DEST")" >&2
    rm -f "$DEST"
    exit 1
fi
echo "fetch-model: $DEST verified"
