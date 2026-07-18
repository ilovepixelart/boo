#include "overlay_layout.h"

// Mirrors app.h's boo_px (MulDiv(base, dpi, 96), round half away from zero)
// without pulling in windows.h; exact for the non-negative sizes used here.
static int scale(int base, unsigned dpi) {
    return (int)(((long long)base * (long long)dpi + 48) / 96);
}

// Card glyph edge length in 96-dpi logical px (mirrors overlay.c's ICON_SIZE).
#define BOO_CARD_ICON_SIZE 12

static BooRect inflate(BooRect r, int by) {
    return (BooRect){r.left - by, r.top - by, r.right + by, r.bottom + by};
}

void boo_card_icon_rects(int card_left, int card_top, int card_right, unsigned dpi,
                         BooRect *copy_glyph, BooRect *close_glyph, BooRect *copy_hit,
                         BooRect *close_hit) {
    const int icon = scale(BOO_CARD_ICON_SIZE, dpi);
    const int inset = scale(8, dpi);
    const int top = card_top + scale(5, dpi);
    *copy_glyph = (BooRect){card_left + inset, top, card_left + inset + icon, top + icon};
    *close_glyph =
        (BooRect){card_right - inset - icon, top, card_right - inset, top + icon};
    // Generous hit areas around the small glyphs.
    const int by = scale(6, dpi);
    *copy_hit = inflate(*copy_glyph, by);
    *close_hit = inflate(*close_glyph, by);
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
    // Place the survivors top-down from area_top. Cap the count up front so the
    // loop runs on a single counter, rather than a write index that also gates it.
    int count = total - first;
    if (count > cap) count = cap;
    int y = area_top;
    for (int k = 0; k < count; k++) {
        const int i = first + k;
        slots[k] = (BooCardSlot){i, y, heights[i]};
        y += heights[i] + gap;
    }
    return count;
}
