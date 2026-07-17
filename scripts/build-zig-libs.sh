#!/bin/bash
# Build the Zig core libraries for consumption by the Xcode project.
#
# Produces:
#   zig-out/lib/libboo-core.a
#   zig-out/lib/libwhisper.a   (re-archived so Apple ld accepts the alignment)
#
# The repack step exists because Zig 0.16's archiver writes Mach-O object
# files into static archives without 8-byte alignment that Apple's linker
# requires. We merge the archive via `ld -r -all_load` (which produces a
# single properly-aligned object), and re-archive that single object.
# -all_load keeps this robust against colliding member basenames (whisper
# v1.9 emits ggml-cpu.o twice, from ggml-cpu.c and ggml-cpu.cpp), which an
# `ar -x` extraction would silently overwrite.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64) ZIG_ARCH=arm64 ;;
    x86_64) ZIG_ARCH=x86_64 ;;
    *)
        echo "Unsupported arch: $ARCH" >&2
        exit 1
        ;;
esac

echo "→ zig build -Doptimize=ReleaseFast"
zig build -Doptimize=ReleaseFast

# Newest first: stale archives from previous whisper.cpp versions may still
# sit in the cache alongside the one this build just produced. `stat -f` (BSD)
# emits "mtime path" so sort does the ordering; avoids the xargs-ls-head pipe,
# whose SIGPIPE and multi-batch ordering both misbehave under pipefail.
WHISPER_A=$(find .zig-cache/o -name "libwhisper.a" -size +1M -exec stat -f '%m %N' {} + |
    sort -rn | head -1 | cut -d' ' -f2-)
if [[ -z "$WHISPER_A" ]]; then
    echo "Could not locate Zig-built libwhisper.a in .zig-cache" >&2
    exit 1
fi

WORK=$(mktemp -d)
# Single quotes: expand $WORK when the trap fires, not when it's installed.
trap 'rm -rf "$WORK"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-version)
mkdir -p zig-out/lib

# Repack BOTH archives, not just whisper: Zig's archiver omits the 8-byte
# member alignment Apple's ld needs, and the exact alignment is content-
# dependent, so libboo-core.a links only by luck until a source change shifts
# it and the Swift/Xcode link fails. Merge each via `ld -r -all_load` into one
# aligned object and re-archive, exactly as build.zig does for `zig build app`.
# boo-core's source is the archive the default build just installed.
repack() { # <src.a> <name>
    local src=$1 name=$2
    ld -r -arch "$ZIG_ARCH" -platform_version macos 14.0 "$SDK" -all_load "$src" \
        -o "$WORK/$name-merged.o"
    rm -f "zig-out/lib/lib$name.a"
    ar -rcs "zig-out/lib/lib$name.a" "$WORK/$name-merged.o"
}

echo "→ repacking libwhisper.a and libboo-core.a for ld alignment"
cp "zig-out/lib/libboo-core.a" "$WORK/boo-core-src.a"
repack "$WORK/boo-core-src.a" boo-core
repack "$PROJ/$WHISPER_A" whisper

echo "✓ libs ready: zig-out/lib/{libboo-core.a, libwhisper.a}"
