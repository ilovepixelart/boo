#!/usr/bin/env bash
# Headless UI smoke test for the Linux overlay.
#
# Launches the built app under an X display and asserts on the ACTUAL rendered
# pixels (via ImageMagick), so a theme, colour or layout regression fails here
# instead of on a user's desktop. This is the harness that caught the card
# anchor, the frozen waveform and the silent no-model exit; run it after every
# frontend change.
#
# Needs: a running X display ($DISPLAY), the built boo-app, a speech model
# already discoverable by the app, and imagemagick + xdotool. Optional WAV plays
# through the default source to exercise a full dictation. Screenshots and the
# verdict land in $BOO_SMOKE_OUT (default /tmp/boo-smoke).
#
# Usage: DISPLAY=:99 ui-smoke.sh <path/to/boo-app> [speech.wav]
set -uo pipefail

APP="${1:?usage: ui-smoke.sh <boo-app> [wav]}"
WAV="${2:-}"
OUT="${BOO_SMOKE_OUT:-/tmp/boo-smoke}"
mkdir -p "$OUT"

: "${DISPLAY:?a running X display is required (Xvfb :99 ...)}"

# ImageMagick 7 ships `magick`; 6 (Ubuntu) ships `convert`/`import`. Support both.
MAGICK=$(command -v magick || command -v convert)
: "${MAGICK:?ImageMagick (magick or convert) is required}"
if command -v import >/dev/null 2>&1; then SHOT_CMD=(import); else SHOT_CMD=("$MAGICK" import); fi

fail=0
pass() { echo "  ok   $*"; }
bad() {
    echo "  FAIL $*"
    fail=1
}

# Assert one pixel of PNG at (x,y) is within TOL (per channel) of #RRGGBB.
check_pixel() { # <png> <x> <y> <rrggbb> <label> [tol]
    local png=$1 x=$2 y=$3 want=$4 label=$5 tol=${6:-28}
    read -r r g b < <("$MAGICK" "$png" -crop "1x1+$x+$y" -depth 8 \
        -format '%[fx:int(255*p.r)] %[fx:int(255*p.g)] %[fx:int(255*p.b)]' info: 2>/dev/null)
    local wr=$((16#${want:0:2})) wg=$((16#${want:2:2})) wb=$((16#${want:4:2}))
    local dr=$((r > wr ? r - wr : wr - r))
    local dg=$((g > wg ? g - wg : wg - g))
    local db=$((b > wb ? b - wb : wb - b))
    if ((dr <= tol && dg <= tol && db <= tol)); then
        pass "$label = rgb($r,$g,$b) ~ #$want"
    else
        bad "$label = rgb($r,$g,$b), expected ~#$want (tol $tol)"
    fi
}

shot() { "${SHOT_CMD[@]}" -window root "$OUT/$1.png" 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null; }

echo "== Boo Linux UI smoke =="
GSK_RENDERER=cairo "$APP" >"$OUT/app.log" 2>&1 &
APP_PID=$!
sleep 5

if ! alive "$APP_PID"; then
    bad "app exited during launch (see $OUT/app.log)"
    tail -5 "$OUT/app.log"
    exit 1
fi
pass "app launched and stayed up"

# Pin the window to a known origin so pixel coordinates are deterministic.
xdotool search --name "Boo" windowmove 0 0 >/dev/null 2>&1
sleep 1
shot idle

# The reference default theme: window bg #282C34, record disc #FF3B30. These are
# the exact tokens docs/ui-spec.md §2 pins, sampled from empty body and the disc.
check_pixel "$OUT/idle.png" 200 250 "282c34" "idle window background"
check_pixel "$OUT/idle.png" 200 463 "ff3b30" "record disc"

# The record morph needs no audio: clicking Record starts a take and the disc
# stays #FF3B30 while it morphs from circle to rounded square. This runs in CI.
xdotool mousemove 200 463 click 1
sleep 1
shot recording
check_pixel "$OUT/recording.png" 200 463 "ff3b30" "record disc while recording"

if [[ -n "$WAV" && -f "$WAV" ]]; then
    # Full dictation: play a clip through the virtual mic and expect a card.
    pw-cat --playback --target virtmic-in "$WAV" 2>/dev/null ||
        paplay "$WAV" 2>/dev/null || true
    sleep 1
    xdotool mousemove 200 463 click 1
    sleep 6
    shot card
    # A transcript card fills white@6% over the bg (#282C34, r=40), so a body
    # pixel under the waveform where the top card sits reads ~r=53. Anything
    # meaningfully above the bare background means a card rendered.
    read -r cr _ _ < <("$MAGICK" "$OUT/card.png" -crop "1x1+200+160" -depth 8 \
        -format '%[fx:int(255*p.r)]' info: 2>/dev/null)
    if ((cr >= 46)); then pass "transcript card rendered (body lightened to r=$cr from 40)"; else
        bad "no card at the top of the stack (r=$cr, bare bg is 40)"
    fi
else
    xdotool mousemove 200 463 click 1 # stop, leave a clean state
    sleep 1
fi

kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

echo "== $([ $fail -eq 0 ] && echo PASS || echo FAIL) (screenshots in $OUT) =="
exit $fail
