#ifndef BOO_OVERLAY_LAYOUT_H
#define BOO_OVERLAY_LAYOUT_H

// Pure (no windows.h): the overlay's transcript-card geometry, split out of
// overlay.c so the card sizing and the scroll-to-newest stacking can be tested
// on any host (see windows/tests/overlay_layout_test.c). Sizes are device
// pixels; the caller copies each slot's top into its GDI draw calls.

#include <stdbool.h>

// Card header row height in 96-dpi logical pixels (matches overlay.c drawing).
#define BOO_CARD_HEADER_H 20

typedef struct {
    int index;  // into the caller's card array; the live card is index == total-1
    int top;    // y of the card's top edge, device px
    int height; // card height, device px
} BooCardSlot;

// Height of one transcript card whose wrapped text measured `text_h` device px
// tall. A live (provisional) card drops the header row and uses a tighter top
// pad. `dpi` scales the paddings (96 == identity), matching app.h's boo_px.
int boo_card_height(int text_h, bool live, unsigned dpi);

// Lay out the transcript stack: keep the newest cards that fit in `avail` device
// px (older ones scroll off the top) and place them top-down from `area_top`,
// separated by `gap`. Fills at most `cap` slots; returns the count placed.
int boo_cards_layout(const int *heights, int total, int gap, int area_top, int avail,
                     BooCardSlot *slots, int cap);

#endif
