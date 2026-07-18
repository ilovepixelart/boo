// Host-runnable tests for the pure overlay card geometry (overlay_layout.c). No
// windows.h, so it runs on the Linux/macOS CI runners too:
//
//   cc -I include -I windows/src windows/tests/overlay_layout_test.c
//      windows/src/overlay_layout.c -o overlay_layout_test && ./overlay_layout_test
//
// What it pins: card height is header+pad+text+pad with the live card dropping
// the header and tightening the top pad, the paddings scale with dpi (matching
// boo_px's MulDiv), and the stack keeps the NEWEST cards that fit while older
// ones scroll off the top, placed top-down with the gap counted between cards.

#include "overlay_layout.h"

#include <stdio.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    // ── card height: the formula and the live-card delta, at 96 dpi ──
    check(boo_card_height(30, false, 96) == 71,
          "history card is header+11+text+10 (20+11+30+10)");
    check(boo_card_height(30, true, 96) == 48,
          "live card drops the header, tighter top pad (0+8+30+10)");
    check(boo_card_height(0, false, 96) == 41,
          "empty-text card is just the paddings (20+11+0+10)");

    // ── the paddings scale with dpi (a fixed 96-dpi height would stay ~71) ──
    check(boo_card_height(60, false, 192) == 142,
          "at 2x dpi the paddings double (40+22+60+20)");

    // ── all cards fit: placed top-down from area_top, gap between them ──
    {
        const int heights[] = {40, 40, 40};
        BooCardSlot slots[4];
        const int n = boo_cards_layout(heights, 3, 8, 100, 1000, slots, 4);
        check(n == 3, "all three cards fit");
        check(slots[0].index == 0 && slots[0].top == 100, "the oldest sits at area_top");
        check(slots[1].top == 148, "the next is one card + gap below (100+40+8)");
        check(slots[2].index == 2 && slots[2].top == 196, "the newest is last, top-down");
    }

    // ── overflow evicts the OLDEST, keeps the newest that fit ──
    {
        const int heights[] = {100, 100, 100};
        BooCardSlot slots[4];
        const int n = boo_cards_layout(heights, 3, 10, 0, 210, slots, 4);
        check(n == 2, "only two 100px cards + one gap fit in 210");
        check(slots[0].index == 1 && slots[1].index == 2,
              "card 0 scrolled off the top, 1 and 2 remain");
    }

    // ── a single gap short: the newest alone wins the tie ──
    {
        const int heights[] = {100, 100};
        BooCardSlot slots[4];
        const int n = boo_cards_layout(heights, 2, 8, 0, 150, slots, 4);
        check(n == 1 && slots[0].index == 1,
              "two + gap exceed 150, so only the newest shows");
    }

    // ── the newest card too tall to fit at all: nothing is placed ──
    {
        const int heights[] = {500};
        BooCardSlot slots[4];
        check(boo_cards_layout(heights, 1, 8, 0, 100, slots, 4) == 0,
              "a card taller than the area yields an empty stack");
    }

    // ── cap bounds the writes: never past slots[cap-1] ──
    {
        const int heights[] = {10, 10, 10, 10, 10};
        BooCardSlot slots[3];
        slots[2].index = -999; // sentinel: must survive
        const int n = boo_cards_layout(heights, 5, 0, 0, 1000, slots, 2);
        check(n == 2, "cap 2 places only two slots though five fit");
        check(slots[2].index == -999, "nothing is written past the cap");
    }

    // ── the empty stack ──
    {
        BooCardSlot slots[1];
        check(boo_cards_layout(NULL, 0, 8, 0, 100, slots, 1) == 0,
              "no cards yields count 0");
    }

    printf(failures ? "overlay_layout_test: FAIL\n" : "overlay_layout_test: ok\n");
    return failures ? 1 : 0;
}
