#!/usr/bin/env bash
# Build and run the headless overlay harness (overlay_harness.c) against the
# real GTK stack. Complements ui-smoke.sh: the smoke asserts rendered pixels,
# this drives the handlers the smoke cannot reach (transcription round-trip,
# tracked idles, the Settings dialog, the download engine).
#
# Needs: GTK4 + libadwaita + libsoup dev packages, zig (the archives link via
# `zig c++`, whisper's C++ was compiled against zig's bundled libc++), the
# zig-built archives in zig-out/lib (zig build app), and an X display, Xvfb
# via xvfb-run is fine and used automatically when $DISPLAY is absent.
#
# Usage: ui-harness.sh
# Env: BOO_HARNESS_CFLAGS  extra compile flags (e.g. --coverage)
#      BOO_HARNESS_LIBS    extra link inputs  (e.g. libgcov.a)
#      BOO_HARNESS_WORK    caller-owned build dir, kept after the run (the
#                          coverage pipeline harvests the .gcda there)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)

for lib in "$root/zig-out/lib/libboo-core.a" "$root/zig-out/lib/libwhisper.a"; do
    [[ -f "$lib" ]] || {
        echo "ui-harness: missing $lib (run: zig build app)" >&2
        exit 1
    }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
build_dir=${BOO_HARNESS_WORK:-$work/build}
mkdir -p "$build_dir"

# Isolated XDG homes: settings and downloaded files land in the sandbox, and
# GLib caches these on first use, so they must be set before the harness runs.
export XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

# A local HTTP server for the download-engine checks; the harness skips them
# when these env vars are absent.
serve_dir="$work/serve"
mkdir -p "$serve_dir"
printf 'boo linux harness payload' >"$serve_dir/harness-model.bin"
port_file="$work/port"
python3 -c '
import http.server, socketserver, sys, os
os.chdir(sys.argv[1])
httpd = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
' "$serve_dir" >"$port_file" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 50); do
    [[ -s "$port_file" ]] && break
    sleep 0.1
done
BOO_HARNESS_HTTP_PORT=$(<"$port_file")
export BOO_HARNESS_HTTP_PORT
export BOO_HARNESS_HTTP_DIR="$serve_dir"

cflags=(-O0 -g -std=c11 -Wall -Wextra -I "$root/linux/src" -I "$root/include")
# shellcheck disable=SC2206  # word-splitting the extra flags is the point
[[ -n "${BOO_HARNESS_CFLAGS:-}" ]] && cflags+=($BOO_HARNESS_CFLAGS)

(
    cd "$build_dir"
    for src in global_shortcut text_inject portal waveform_widget models; do
        # shellcheck disable=SC2046
        cc "${cflags[@]}" $(pkg-config --cflags gtk4 libadwaita-1 libsoup-3.0) \
            -c "$root/linux/src/$src.c" -o "$src.o"
    done
    # shellcheck disable=SC2046
    cc "${cflags[@]}" $(pkg-config --cflags gtk4 libadwaita-1 libsoup-3.0) \
        -c "$root/linux/tests/overlay_harness.c" -o overlay_harness.o
    # shellcheck disable=SC2046,SC2086
    zig c++ ./*.o "$root/zig-out/lib/libboo-core.a" "$root/zig-out/lib/libwhisper.a" \
        $(pkg-config --libs gtk4 libadwaita-1 libsoup-3.0 libpipewire-0.3) \
        ${BOO_HARNESS_LIBS:-} -lm -lpthread -o overlay_harness
)

runner=()
if [[ -z "${DISPLAY:-}" ]]; then
    command -v xvfb-run >/dev/null || {
        echo "ui-harness: no display and no xvfb-run" >&2
        exit 1
    }
    runner=(xvfb-run -a)
fi

# Run from the repo root so ./themes resolves for the theme checks.
(cd "$root" && GSK_RENDERER=cairo "${runner[@]}" "$build_dir/overlay_harness")
