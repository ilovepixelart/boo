#include "palette.h"

// COLORREF is 0x00BBGGRR: R in the low byte, then G, then B. These mirror the
// windows.h RGB/GetRValue macros without pulling the header in.
static uint32_t chan_r(uint32_t c) { return c & 0xFF; }
static uint32_t chan_g(uint32_t c) { return (c >> 8) & 0xFF; }
static uint32_t chan_b(uint32_t c) { return (c >> 16) & 0xFF; }
static uint32_t pack(int r, int g, int b) {
    return (uint32_t)((r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16));
}

// A theme color is packed 0xRRGGBB (boo.h); reorder into a COLORREF.
static uint32_t pcolor(uint32_t rgb) {
    return pack((int)((rgb >> 16) & 0xFF), (int)((rgb >> 8) & 0xFF), (int)(rgb & 0xFF));
}

uint32_t boo_color_mix(uint32_t fg, uint32_t bg, float alpha) {
    const int r = (int)(chan_r(fg) * alpha + chan_r(bg) * (1.0f - alpha));
    const int g = (int)(chan_g(fg) * alpha + chan_g(bg) * (1.0f - alpha));
    const int b = (int)(chan_b(fg) * alpha + chan_b(bg) * (1.0f - alpha));
    return pack(r, g, b);
}

Palette boo_palette(const BooThemeColors *theme, bool dark) {
    const uint32_t record = pack(0xFF, 0x3B, 0x30);
    // A picked theme wins over the system light/dark follow; its tokens map to
    // the same slots the hardcoded default below uses.
    if (theme) {
        const uint32_t bg = pcolor(theme->bg);
        // Card fills are white over a dark surface, black over a light one.
        const int lum =
            (int)(((theme->bg >> 16) & 0xFF) + ((theme->bg >> 8) & 0xFF) + (theme->bg & 0xFF));
        const uint32_t over = lum < 3 * 128 ? pack(255, 255, 255) : pack(0, 0, 0);
        return (Palette){bg,
                         pcolor(theme->fg),
                         pcolor(theme->palette[8]),  // dim
                         record,
                         pcolor(theme->palette[14]), // idle
                         pcolor(theme->palette[9]),  // recording
                         pcolor(theme->palette[11]), // thinking
                         boo_color_mix(over, bg, 0.06f),
                         boo_color_mix(over, bg, 0.03f)};
    }
    if (dark) {
        const uint32_t bg = pack(0x28, 0x2C, 0x34); // theme background
        return (Palette){bg,
                         pack(0xFF, 0xFF, 0xFF), // theme foreground
                         pack(0x66, 0x66, 0x66), // palette[8], dim
                         record,
                         pack(0x70, 0xC0, 0xB1), // palette[14], idle
                         pack(0xD5, 0x4E, 0x53), // palette[9], recording
                         pack(0xE7, 0xC5, 0x47), // palette[11], thinking
                         boo_color_mix(pack(255, 255, 255), bg, 0.06f),
                         boo_color_mix(pack(255, 255, 255), bg, 0.03f)};
    }
    const uint32_t bg = pack(0xF6, 0xF6, 0xF6);
    return (Palette){bg,
                     pack(0x14, 0x14, 0x14),
                     pack(0x6E, 0x6E, 0x6E),
                     record,
                     pack(0x4E, 0x8F, 0x83),
                     pack(0xC2, 0x3B, 0x40),
                     pack(0xB4, 0x8A, 0x00),
                     boo_color_mix(pack(0, 0, 0), bg, 0.06f),
                     boo_color_mix(pack(0, 0, 0), bg, 0.03f)};
}
