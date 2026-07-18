// Host-runnable tests for the pure overlay opacity math (opacity.c). No
// windows.h, so it runs on the Linux/macOS CI runners too:
//
//   cc -I include -I windows/src windows/tests/opacity_test.c
//      windows/src/opacity.c -o opacity_test && ./opacity_test
//
// What it pins: the persisted-value range check is inclusive at both ends, and
// the layered alpha is pct*255/100 truncated toward zero with a hard opaque
// cutoff at 100% (where the caller drops WS_EX_LAYERED and leaves *alpha alone).

#include "opacity.h"

#include <stdio.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    // ── the persisted-opacity validity range is inclusive [10, 100] ──
    check(boo_opacity_valid(10), "10 percent is the low bound, valid");
    check(boo_opacity_valid(100), "100 percent is the high bound, valid");
    check(boo_opacity_valid(55), "a mid value is valid");
    check(!boo_opacity_valid(9), "just below the low bound is rejected");
    check(!boo_opacity_valid(101), "just above the high bound is rejected");
    check(!boo_opacity_valid(0), "zero is rejected");
    check(!boo_opacity_valid(-1), "a negative percent is rejected");

    // ── the opaque cutoff: 100% (or more) drops the layered style ──
    {
        uint8_t alpha = 42; // sentinel: must stay untouched on the opaque path
        check(!boo_opacity_alpha(100, &alpha), "100 percent is fully opaque");
        check(alpha == 42, "the opaque path leaves *alpha untouched");
        check(!boo_opacity_alpha(150, &alpha), "past 100 percent is opaque too");
    }

    // ── the translucent alpha is pct*255/100, truncated toward zero ──
    {
        uint8_t alpha = 0;
        check(boo_opacity_alpha(10, &alpha) && alpha == 25,
              "10 percent scales to alpha 25 (2550/100)");
        check(boo_opacity_alpha(50, &alpha) && alpha == 127,
              "50 percent truncates to alpha 127 (12750/100)");
        check(boo_opacity_alpha(99, &alpha) && alpha == 252,
              "99 percent scales to alpha 252 (25245/100)");
    }

    printf(failures ? "opacity_test: FAIL\n" : "opacity_test: ok\n");
    return failures ? 1 : 0;
}
