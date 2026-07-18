#include "opacity.h"

bool boo_opacity_valid(int pct) {
    return pct >= BOO_OPACITY_MIN && pct <= BOO_OPACITY_MAX;
}

bool boo_opacity_alpha(int pct, uint8_t *alpha) {
    // Fully opaque: the caller drops WS_EX_LAYERED entirely, so it never sets an
    // alpha at all. Guarding here keeps that decision in one tested place.
    if (pct >= BOO_OPACITY_MAX) return false;
    *alpha = (uint8_t)(pct * 255 / 100);
    return true;
}
