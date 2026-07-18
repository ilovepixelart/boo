// Host-runnable tests for the pure overlay color mapping (palette.c). No
// windows.h, so it runs on the Linux/macOS CI runners too:
//
//   cc -I include -I windows/src windows/tests/palette_test.c
//      windows/src/palette.c -o palette_test && ./palette_test
//   (one command; a literal backslash here would trip gcc's -Wcomment)
//
// What it pins: each waveform state reads its OWN ANSI slot (a slot swap would
// silently recolor recording vs thinking vs idle), the record disc stays
// #FF3B30 regardless of theme, the card fill lifts off a dark surface but sits
// below a light one (the luminance decision), and the no-theme fallbacks are
// the documented reference colors and differ between light and dark.

#include "palette.h"

#include <stdio.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Mirror palette.c's packed-0xRRGGBB -> COLORREF reorder, for expected values.
static uint32_t as_colorref(uint32_t rrggbb) {
    const int r = (int)((rrggbb >> 16) & 0xFF);
    const int g = (int)((rrggbb >> 8) & 0xFF);
    const int b = (int)(rrggbb & 0xFF);
    return (uint32_t)(r | (g << 8) | (b << 16));
}

static int channel_sum(uint32_t c) {
    return (int)((c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF));
}

int main(void) {
    // A picked theme with a unique value per slot, so a mis-mapping is visible.
    BooThemeColors theme = {.bg = 0x101418, .fg = 0xEEEEEE, .palette = {0}};
    theme.palette[8] = 0x808182;   // dim
    theme.palette[9] = 0xAA0102;   // recording
    theme.palette[11] = 0xCC0304;  // thinking
    theme.palette[14] = 0x050607;  // idle

    // ── a picked theme maps each token to its own slot ──
    {
        const Palette p = boo_palette(&theme, false);
        check(p.bg == as_colorref(0x101418), "bg comes from the theme background");
        check(p.text == as_colorref(0xEEEEEE), "text comes from the theme foreground");
        check(p.subtext == as_colorref(0x808182), "subtext maps to ANSI slot 8 (dim)");
        check(p.wave_rec == as_colorref(0xAA0102), "the recording wave maps to slot 9");
        check(p.wave_think == as_colorref(0xCC0304), "the thinking wave maps to slot 11");
        check(p.wave_idle == as_colorref(0x050607), "the idle wave maps to slot 14");
        check(p.record == as_colorref(0xFF3B30), "the record disc is #FF3B30");
    }

    // ── card fill follows surface luminance (white over dark, black over light) ──
    {
        const Palette dark_p = boo_palette(&theme, false);  // bg 0x101418, dark
        BooThemeColors light = {.bg = 0xF0F0F0, .fg = 0x101010, .palette = {0}};
        const Palette light_p = boo_palette(&light, false); // bg 0xF0F0F0, light
        check(channel_sum(dark_p.card) > channel_sum(dark_p.bg),
              "a dark theme's card fill lifts off the background");
        check(channel_sum(light_p.card) < channel_sum(light_p.bg),
              "a light theme's card fill sits below the background");
    }

    // ── no theme: the documented reference fallbacks, distinct per mode ──
    {
        const Palette dark_p = boo_palette(NULL, true);
        const Palette light_p = boo_palette(NULL, false);
        check(dark_p.bg == as_colorref(0x282C34), "no theme + dark uses the reference dark bg");
        check(light_p.bg == as_colorref(0xF6F6F6), "no theme + light uses the reference light bg");
        check(dark_p.bg != light_p.bg, "the dark and light fallbacks differ");
        check(dark_p.record == as_colorref(0xFF3B30), "the record disc holds on the fallback path");
    }

    // ── the alpha lerp: endpoints and midpoint ──
    {
        check(boo_color_mix(0xFFFFFF, 0x000000, 1.0f) == 0xFFFFFF, "mix at alpha 1 is the foreground");
        check(boo_color_mix(0xFFFFFF, 0x000000, 0.0f) == 0x000000, "mix at alpha 0 is the background");
        const uint32_t mid = boo_color_mix(0xFFFFFF, 0x000000, 0.5f);
        check((mid & 0xFF) == 127, "mix at 0.5 is the channel midpoint");
    }

    printf(failures ? "palette_test: FAIL\n" : "palette_test: ok\n");
    return failures ? 1 : 0;
}
