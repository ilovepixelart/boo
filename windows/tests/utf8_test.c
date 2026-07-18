// Host-runnable tests for the pure UTF-8 helpers. No windows.h, so it runs on
// the Linux/macOS CI runners too:
//
//   cc -I windows/src windows/tests/utf8_test.c windows/src/utf8.c
//      -o utf8_test && ./utf8_test
//   (one command; a literal backslash here would trip gcc's -Wcomment)
//
// What it pins: truncation walks back to a code-point boundary so a long
// transcript's display copy never splits a multi-byte character.

#include "utf8.h"

#include <stdio.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    // "a" + U+00E9 (0xC3 0xA9) + "b": byte 2 is a continuation byte.
    const char *s = "a\xC3\xA9"
                    "b";
    check(boo_utf8_trunc_len(s, 2) == 1,
          "a boundary inside a 2-byte sequence walks back to its start");
    check(boo_utf8_trunc_len(s, 3) == 3, "a boundary on an ASCII byte is kept");
    check(boo_utf8_trunc_len(s, 4) == 4, "a boundary at the end is kept");
    check(boo_utf8_trunc_len(s, 0) == 0, "a zero start stays zero");

    printf(failures ? "utf8_test: FAIL\n" : "utf8_test: ok\n");
    return failures ? 1 : 0;
}
