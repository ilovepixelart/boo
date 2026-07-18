#ifndef BOO_PALETTE_H
#define BOO_PALETTE_H

// Pure (no windows.h): the overlay's theme-to-color mapping, split out of
// overlay.c so the slot assignment, the light/dark card-fill choice, and the
// no-theme fallbacks can be tested on any host (see windows/tests/palette_test.c).
// Colors are packed as a Win32 COLORREF (0x00BBGGRR) held in a uint32_t.

#include <stdbool.h>
#include <stdint.h>

#include "boo.h" // BooThemeColors

typedef struct {
    uint32_t bg;
    uint32_t text;
    uint32_t subtext;
    uint32_t record;
    uint32_t wave_idle;
    uint32_t wave_rec;
    uint32_t wave_think;
    uint32_t card;
    uint32_t card_live;
} Palette;

// The overlay's colors. `theme` NULL means no theme is picked, so the fallback
// follows the system light/dark toggle via `dark`. Card fills are the reference
// white@6%/3% over a dark surface, black over a light one (GDI has no alpha, so
// they are pre-blended); the record disc is #FF3B30 on every path. The dark
// fallback is the macOS reference default (docs/ui-spec.md).
Palette boo_palette(const BooThemeColors *theme, bool dark);

// Straight alpha lerp between two packed colors; alpha is NOT clamped (callers
// pass values in [0,1]). Exposed for the overlay's card-separator tint.
uint32_t boo_color_mix(uint32_t fg, uint32_t bg, float alpha);

#endif
