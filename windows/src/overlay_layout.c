#include "overlay_layout.h"

// Mirrors app.h's boo_px (MulDiv(base, dpi, 96), round half away from zero)
// without pulling in windows.h; exact for the non-negative sizes used here.
static int scale(int base, unsigned dpi) {
    return (int)(((long long)base * (long long)dpi + 48) / 96);
}

int boo_card_height(int text_h, bool live, unsigned dpi) {
    const int header = live ? 0 : scale(BOO_CARD_HEADER_H, dpi);
    const int top_pad = live ? scale(8, dpi) : scale(11, dpi);
    return header + top_pad + text_h + scale(10, dpi);
}

int boo_cards_layout(const int *heights, int total, int gap, int area_top, int avail,
                     BooCardSlot *slots, int cap) {
    // Stack bottom-up: the newest card wins, older ones fall off the top.
    int first = total;
    int used = 0;
    for (int i = total - 1; i >= 0; i--) {
        const int need = heights[i] + (used > 0 ? gap : 0);
        if (used + need > avail) break;
        used += need;
        first = i;
    }
    // Place the survivors top-down from area_top.
    int n = 0;
    int y = area_top;
    for (int i = first; i < total && n < cap; i++) {
        slots[n++] = (BooCardSlot){i, y, heights[i]};
        y += heights[i] + gap;
    }
    return n;
}
