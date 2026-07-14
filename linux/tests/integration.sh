#!/bin/bash
# Drives Boo's XDG portal clients against a live session bus.
#
# Linux only — it needs a real D-Bus. Run it in CI, in a container, or on a
# Linux desktop:
#
#   ./linux/tests/integration.sh
#
# Unlike run.sh (which only checks that the D-Bus payloads are well-formed),
# this executes the actual handshakes end to end against a stand-in portal:
#
#   GlobalShortcuts  CreateSession -> BindShortcuts -> Activated -> callback
#   RemoteDesktop    CreateSession -> SelectDevices -> Start -> paste chord
#
# The mock derives the Request object path independently, exactly as a real
# portal does. Boo predicts the same path and subscribes to it *before* calling.
# If that prediction were wrong Boo would never see a Response and would hang —
# so a pass here is what proves the prediction correct.
#
# Needs: xvfb, dbus-x11, python3-gi, gtk4, libadwaita.
#
# No `set -e`: the assertions below report which check failed and why, which is
# far more useful than the script vanishing on the first non-zero exit. But
# `pipefail` matters — without it a failing command inside a pipeline is masked
# by a succeeding one, and a test that cannot fail is worse than no test.
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS="$PROJ/linux/tests"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${PORTAL:-}" ] && kill "$PORTAL" 2>/dev/null; [ -n "${XVFB:-}" ] && kill "$XVFB" 2>/dev/null' EXIT

export XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Boo's portal clients hang off a GtkWindow, so GTK needs a display. Nothing
# is ever looked at.
export GTK_A11Y=none
Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:99
export GDK_BACKEND=x11
sleep 1

eval "$(dbus-launch --sh-syntax)"
echo "[integration] session bus up"

python3 "$TESTS/mock_portal.py" > "$WORK/events.jsonl" 2>"$WORK/portal.err" &
PORTAL=$!

# Wait for a condition rather than sleeping a guessed interval — a fixed sleep is
# how a suite starts failing intermittently on a loaded CI runner.
wait_for() {
    local pattern="$1" what="$2" deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -q "$pattern" "$WORK/events.jsonl" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "[integration] FAIL: timed out waiting for $what"
    echo "--- portal stderr ---"; cat "$WORK/portal.err"
    echo "--- events so far ---"; cat "$WORK/events.jsonl"
    return 1
}

wait_for '"event": "ready"' "the mock portal to claim the bus name" || exit 1
echo "[integration] mock portal owns org.freedesktop.portal.Desktop"

# shellcheck disable=SC2046  # pkg-config emits several flags; splitting is the point.
cc -o "$WORK/harness" "$TESTS/portal_harness.c" \
    "$PROJ/linux/src/global_shortcut.c" "$PROJ/linux/src/text_inject.c" \
    -I"$PROJ/linux/src" -I"$PROJ/include" \
    $(pkg-config --cflags --libs gtk4 libadwaita-1) \
    -std=c11 -Wall -Wextra || { echo "[integration] FAIL: harness build"; exit 1; }

# Fire the hotkey only once the shortcut is actually bound. Firing on a timer
# would race the handshake and flake under load.
( wait_for '"event": "gs.BindShortcuts"' "the shortcut to be bound" || exit 1
  dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
      /org/freedesktop/portal/desktop \
      com.boo.MockControl.FireShortcut string:'toggle-record' \
      > "$WORK/fire.log" 2>&1 \
      || echo "[integration] WARN: FireShortcut failed: $(cat "$WORK/fire.log")"
) &

"$WORK/harness"
HARNESS_RC=$?

sleep 1
kill "$PORTAL" 2>/dev/null
EVENTS="$(cat "$WORK/events.jsonl")"

echo
echo "──── portal traffic observed on the bus ────"
echo "$EVENTS"
echo "───────────────────────────────────────────"

fail() { echo "[integration] FAIL: $1"; exit 1; }

[ "$HARNESS_RC" -eq 0 ] || fail "harness exited $HARNESS_RC (shortcut callback never fired)"

# GlobalShortcuts: the hotkey must actually be bound, with our ID and trigger.
grep -q '"event": "gs.CreateSession"' <<<"$EVENTS" || fail "no GlobalShortcuts CreateSession"
grep -q '"id": "toggle-record"' <<<"$EVENTS"       || fail "shortcut not bound as toggle-record"
grep -q 'CTRL+SHIFT+space' <<<"$EVENTS"            || fail "wrong preferred trigger"

# RemoteDesktop: keyboard access, and a grant that survives a restart.
grep -q '"event": "rd.Start"' <<<"$EVENTS"         || fail "RemoteDesktop session never started"
grep -q '"types": 1' <<<"$EVENTS"                  || fail "did not request KEYBOARD"
grep -q '"persist_mode": 2' <<<"$EVENTS"           || fail "did not ask to persist the grant"

# The paste must be a well-formed Ctrl+Shift+V: press ctrl, shift, v then
# release in reverse. Keysyms: 65507=Control_L, 65505=Shift_L, 118=v.
CHORD="$(grep '"event": "rd.NotifyKeyboardKeysym"' <<<"$EVENTS" \
    | sed -E 's/.*"keysym": ([0-9]+), "state": ([0-9]+).*/\1:\2/' | paste -sd' ' -)"
EXPECT="65507:1 65505:1 118:1 118:0 65505:0 65507:0"
[ "$CHORD" = "$EXPECT" ] || fail "paste chord was [$CHORD], expected [$EXPECT]"
echo "[integration] paste chord correct: Ctrl+Shift+V, press/release ordered"

echo "[integration] PASS — both portal handshakes completed against a live bus"

# ── Second launch: the shortcut is already bound, so Boo must NOT call
# BindShortcuts again. That call is what raises the approval dialog, so
# re-issuing it would re-prompt the user on every single launch.
echo
echo "── second launch (shortcut already bound) ──"
kill "$PORTAL" 2>/dev/null
sleep 1

python3 "$TESTS/mock_portal.py" --prebound > "$WORK/events2.jsonl" 2>&1 &
PORTAL=$!

( deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
      grep -q '"event": "ready"' "$WORK/events2.jsonl" 2>/dev/null && exit 0
      sleep 0.2
  done
  exit 1 ) || { echo "[integration] FAIL: mock portal (prebound) did not start"; exit 1; }

# No shortcut is fired here; we only care about which portal calls Boo makes.
timeout 30 "$WORK/harness" >/dev/null 2>&1 || true
sleep 1
kill "$PORTAL" 2>/dev/null
EVENTS2="$(cat "$WORK/events2.jsonl")"

echo "$EVENTS2" | grep -E '"event": "gs\.' || true

grep -q '"event": "gs.ListShortcuts"' <<<"$EVENTS2" \
    || fail "second launch did not call ListShortcuts"

if grep -q '"event": "gs.BindShortcuts"' <<<"$EVENTS2"; then
    fail "second launch called BindShortcuts again — the user would be re-prompted"
fi

echo "[integration] PASS — already-bound shortcut is reused, so no approval dialog"
