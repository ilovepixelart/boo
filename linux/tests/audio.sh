#!/bin/bash
# Proves the Linux audio path end to end: PipeWire capture -> whisper -> text.
#
#   ./linux/tests/audio.sh path/to/ggml-base.en.bin [speech.wav]
#
# Needs a real PipeWire graph with a working session manager, which in practice
# means a real Linux system, NOT a container. WirePlumber refuses to start
# without systemd-logind, so in a container PipeWire never links any nodes and
# Boo's stream sits there capturing nothing. A VM (or a desktop) works fine.
#
# With no WAV supplied it records from your default source, so you can just
# speak. With a WAV, it builds a virtual microphone from a null sink's monitor,
# plays the file into it, and asserts a transcript comes back, which is what
# makes this runnable unattended.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL="${1:?usage: audio.sh <model.bin> [speech.wav]}"
WAV="${2:-}"

command -v pactl >/dev/null || {
    echo "need pactl (pulseaudio-utils)"
    exit 1
}
pactl info >/dev/null 2>&1 || {
    echo "no PipeWire/Pulse server, is wireplumber running?"
    exit 1
}

cd "$PROJ"
echo "[audio] building core"
zig build -Doptimize=ReleaseFast 2>/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

WHISPER="$(find .zig-cache -name libwhisper.a -size +1M | head -1)"
[[ -n "$WHISPER" ]] || {
    echo "[audio] libwhisper.a not found"
    exit 1
}

# Zig's archiver omits the index, and its C++ objects want Zig's libc++ rather
# than the system libstdc++, so link with `zig cc`.
cp zig-out/lib/libboo-core.a "$WORK/"
cp "$WHISPER" "$WORK/"
ranlib "$WORK/libboo-core.a" "$WORK/libwhisper.a"

# shellcheck disable=SC2046  # pkg-config emits several flags; splitting is the point.
zig cc -o "$WORK/audio_smoke" linux/tests/audio_smoke.c \
    -Iinclude "$WORK/libboo-core.a" "$WORK/libwhisper.a" \
    $(pkg-config --cflags --libs libpipewire-0.3) \
    -lc++ -lm -lpthread -std=c11

if [[ -n "$WAV" ]]; then
    # A null sink's monitor is a perfectly good fake microphone: whatever is
    # played into the sink appears on its monitor, which we make the default
    # source. Boo autoconnects to the default, so it lands on our audio.
    pactl list short sources | grep -q virtmic ||
        pactl load-module module-null-sink sink_name=virtmic \
            sink_properties=device.description=VirtualMic >/dev/null
    pactl set-default-source virtmic.monitor
    echo "[audio] virtual mic is the default source"

    (
        sleep 1.5
        paplay -d virtmic "$WAV"
        sleep 0.3
        paplay -d virtmic "$WAV"
    ) &
    SECONDS_TO_RECORD=6
else
    echo "[audio] recording from your default source, speak now"
    SECONDS_TO_RECORD=5
fi

OUT="$("$WORK/audio_smoke" "$MODEL" "$SECONDS_TO_RECORD" 2>&1 | grep -viE '^whisper_|^ggml_')"
echo "$OUT"

grep -q "\[smoke\] PASS" <<<"$OUT" || {
    echo "[audio] FAIL"
    exit 1
}

# Guard against the failure that matters: a stream that opens, reports samples,
# and captures pure silence. Whisper would return nothing, so a non-empty
# transcript is the proof that real audio made it through.
TRANSCRIPT="$(sed -n 's/^\[smoke\] TRANSCRIPT: //p' <<<"$OUT" | tr -d ' ')"
[[ -n "$TRANSCRIPT" ]] || {
    echo "[audio] FAIL: captured audio but transcript empty"
    exit 1
}

echo "[audio] PASS, PipeWire captured real audio and whisper transcribed it"
