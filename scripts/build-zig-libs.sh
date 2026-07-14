#!/bin/bash
# Build the Zig core libraries for consumption by the Xcode project.
#
# Produces:
#   zig-out/lib/libboo-core.a
#   zig-out/lib/libwhisper.a   (re-archived so Apple ld accepts the alignment)
#
# The repack step exists because Zig 0.16's archiver writes Mach-O object
# files into static archives without 8-byte alignment that Apple's linker
# requires. We extract the .o files, merge them via `ld -r` (which produces a
# single properly-aligned object), and re-archive that single object.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64) ZIG_ARCH=arm64 ;;
    x86_64) ZIG_ARCH=x86_64 ;;
    *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "→ zig build -Doptimize=ReleaseFast"
zig build -Doptimize=ReleaseFast

WHISPER_A=$(find .zig-cache/o -name "libwhisper.a" -size +1M | head -1)
if [[ -z "$WHISPER_A" ]]; then
    echo "Could not locate Zig-built libwhisper.a in .zig-cache" >&2
    exit 1
fi

echo "→ repacking $WHISPER_A for ld alignment"
WORK=$(mktemp -d)
# Single quotes: expand $WORK when the trap fires, not when it's installed.
trap 'rm -rf "$WORK"' EXIT

(
    cd "$WORK"
    ar -x "$PROJ/$WHISPER_A"
    chmod u+r ./*.o
    ld -r -arch "$ZIG_ARCH" \
        ggml.o ggml-alloc.o ggml-backend.o ggml-quants.o whisper.o \
        -o whisper-merged.o
)

mkdir -p zig-out/lib
rm -f zig-out/lib/libwhisper.a
ar -rcs zig-out/lib/libwhisper.a "$WORK/whisper-merged.o"

echo "✓ libs ready: zig-out/lib/{libboo-core.a, libwhisper.a}"
