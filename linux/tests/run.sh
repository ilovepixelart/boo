#!/bin/bash
# Compile and run the portal payload tests.
#
# Builds twice — once per portal client — because the two .c files define
# same-named static helpers and can't share a translation unit.
#
# Runs on any host with GTK4 + GLib, macOS included: the payloads are pure
# GVariant construction, so they're checkable without a live D-Bus session.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

CFLAGS=$(pkg-config --cflags gtk4)
LIBS=$(pkg-config --libs gtk4)

fail=0
for suite in global_shortcut text_inject; do
    echo "── $suite ──"

    define=""
    [ "$suite" = "text_inject" ] && define="-DTEST_TEXT_INJECT"

    # portal.c holds the Request/Response plumbing both clients call into.
    # shellcheck disable=SC2086  # $define/$CFLAGS/$LIBS are multi-flag; splitting is the point.
    cc -o "$OUT/$suite" "$PROJ/linux/tests/portal_payloads.c" \
        "$PROJ/linux/src/portal.c" \
        -I"$PROJ/linux/src" -I"$PROJ/include" \
        $define $CFLAGS $LIBS -std=c11 -Wall -Wextra

    "$OUT/$suite" || fail=1
done

if [ "$fail" -ne 0 ]; then
    echo "FAILED"
    exit 1
fi
echo "All portal payload tests passed."
