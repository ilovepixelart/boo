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
pass() {
    echo "  ok   $*"
    return 0
}
bad() {
    echo "  FAIL $*"
    fail=1
    return 0
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
    return 0
}

shot() {
    local name="$1"
    "${SHOT_CMD[@]}" -window root "$OUT/$name.png" 2>/dev/null
    return $?
}
alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
    return $?
}

# The 40px record disc sits bottom-centre (x=200), but its exact screen y shifts
# a few pixels with the runner's GTK header-bar height and DPI, so a single
# hardcoded coordinate catches the anti-aliased circle edge on some runners.
# Scan a vertical strip for the most red-dominant pixel (the disc centre) and
# assert that is #FF3B30.
check_disc() { # <png> <label>
    local png=$1 label=$2 best=-1 best_y=0 y r g b score
    for y in $(seq 445 3 495); do
        read -r r g b < <("$MAGICK" "$png" -crop "1x1+200+$y" -depth 8 \
            -format '%[fx:int(255*p.r)] %[fx:int(255*p.g)] %[fx:int(255*p.b)]' info: 2>/dev/null)
        score=$((r - (g + b) / 2))
        if ((score > best)); then
            best=$score
            best_y=$y
        fi
    done
    check_pixel "$png" 200 "$best_y" "ff3b30" "$label (reddest at y=$best_y)"
    return 0
}

# Locate the "3024 Day" reference theme the way the app does, so the switch test
# only runs when the theme set is present (it is in CI, from the repo themes/).
find_ref_theme() {
    local d
    for d in "themes" "$PWD/themes" "$(dirname "$APP")/themes" \
        "$(dirname "$APP")/../themes" "/app/share/boo/themes" "/usr/share/boo/themes"; do
        [[ -f "$d/3024 Day" ]] && return 0
    done
    return 1
}

# A persisted non-default theme must apply at startup. Exercises the exact
# settings-load + apply path the Settings dialog writes to, without pixel-
# clicking the dialog (whose gear shifts with header-bar width across runners).
check_theme_switch() {
    if ! find_ref_theme; then
        echo "  skip theme switch (no '3024 Day' theme found)"
        return
    fi
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/boo"
    mkdir -p "$cfg"
    [[ -f "$cfg/settings.ini" ]] && mv "$cfg/settings.ini" "$cfg/settings.ini.bak"
    printf '[boo]\ntheme=3024 Day\nopacity=1\nauto-type=true\n' >"$cfg/settings.ini"
    GSK_RENDERER=cairo "$APP" </dev/null >"$OUT/app-theme.log" 2>&1 &
    local pid=$!
    sleep 5
    xdotool search --name "Boo" windowmove 0 0 >/dev/null 2>&1
    sleep 1
    shot themed
    # 3024 Day background is #f7f7f7: an empty body pixel must read light.
    check_pixel "$OUT/themed.png" 200 250 "f7f7f7" "persisted theme applied at startup" 12
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$cfg/settings.ini"
    [[ -f "$cfg/settings.ini.bak" ]] && mv "$cfg/settings.ini.bak" "$cfg/settings.ini"
}

echo "== Boo Linux UI smoke =="
# </dev/null is load-bearing: a backgrounded child inherits the script's stdin,
# and for a script large enough that bash must re-read it mid-run, a child that
# consumes that shared stream makes bash read from a corrupted offset and stop
# early. Detaching stdin keeps the app off the script's input.
GSK_RENDERER=cairo "$APP" </dev/null >"$OUT/app.log" 2>&1 &
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
check_disc "$OUT/idle.png" "record disc"

# The record morph needs no audio: clicking Record starts a take and the disc
# stays #FF3B30 while it morphs from circle to rounded square. This runs in CI.
xdotool mousemove 200 463 click 1
sleep 1
shot recording
check_disc "$OUT/recording.png" "record disc while recording"

# Single-instance handoff: a second launch must forward its activate to the
# first instance and exit, not open a rival window (main.c's on_activate
# guard). GApplication uniqueness rides on the session bus; skip without one.
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    GSK_RENDERER=cairo timeout 20 "$APP" </dev/null >"$OUT/second.log" 2>&1
    second_rc=$?
    if ((second_rc == 0)) && alive "$APP_PID"; then
        pass "second launch hands off to the first instance"
    else
        bad "second launch rc=$second_rc, first alive: $(alive "$APP_PID" && echo yes || echo no)"
    fi
else
    echo "  skip second-launch handoff (no session bus)"
fi

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

# With the main app down, verify a persisted theme paints a different window.
check_theme_switch

echo "== $([[ $fail -eq 0 ]] && echo PASS || echo FAIL) (screenshots in $OUT) =="
exit $fail
