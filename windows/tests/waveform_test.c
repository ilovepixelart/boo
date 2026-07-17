// Native-runner tests for the GDI waveform painter (waveform.c). Includes the
// source under test so the static blend helper is reachable. Painting goes to
// a 32-bit DIB memory DC, so pixels can be asserted without a real window.

#include "waveform.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

#define CANVAS_W 200
#define CANVAS_H 60

static const COLORREF BG = RGB(20, 20, 30);

// Fresh background before each paint so leftovers cannot mask a no-op.
static void clear_canvas(HDC dc) {
    RECT rc = {0, 0, CANVAS_W, CANVAS_H};
    HBRUSH brush = CreateSolidBrush(BG);
    FillRect(dc, &rc, brush);
    DeleteObject(brush);
}

// Whether any pixel in the canvas differs from the background.
static bool painted_something(HDC dc) {
    for (int y = 0; y < CANVAS_H; y += 2)
        for (int x = 0; x < CANVAS_W; x += 2)
            if (GetPixel(dc, x, y) != BG) return true;
    return false;
}

int main(void) {
    printf("waveform_test:\n");

    // blend: straight lerp between fg and bg, alpha clamped to [0,1].
    check(blend(RGB(255, 255, 255), RGB(0, 0, 0), 2.0f) == RGB(255, 255, 255),
          "alpha clamps high to pure fg");
    check(blend(RGB(255, 255, 255), RGB(0, 0, 0), -1.0f) == RGB(0, 0, 0),
          "alpha clamps low to pure bg");
    check(blend(RGB(200, 100, 0), RGB(0, 100, 200), 0.5f) == RGB(100, 100, 100),
          "midpoint blends channelwise");

    HDC dc = CreateCompatibleDC(NULL);
    BITMAPINFO bmi = {.bmiHeader = {.biSize = sizeof(BITMAPINFOHEADER),
                                    .biWidth = CANVAS_W,
                                    .biHeight = -CANVAS_H,
                                    .biPlanes = 1,
                                    .biBitCount = 32,
                                    .biCompression = BI_RGB}};
    void *bits = NULL;
    HBITMAP bmp = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    check(dc != NULL && bmp != NULL, "memory canvas created");
    SelectObject(dc, bmp);

    RECT rc = {0, 0, CANVAS_W, CANVAS_H};
    float bars[40];
    for (int i = 0; i < 40; i++) bars[i] = 0.5f + 0.4f * (float)(i % 3);
    BooWavePaint wp = {.bars = bars,
                       .n = 40,
                       .peak = 1.0f,
                       .state = BOO_WAVE_RECORDING,
                       .color = RGB(255, 59, 48),
                       .bg = BG,
                       .phase = 0.0f};

    clear_canvas(dc);
    wp.n = 0;
    boo_waveform_paint(dc, rc, &wp);
    check(!painted_something(dc), "zero bars paints nothing");

    clear_canvas(dc);
    wp.n = 40;
    RECT narrow = {0, 0, 8, CANVAS_H};
    boo_waveform_paint(dc, narrow, &wp);
    check(!painted_something(dc), "a too-narrow rect paints nothing");

    // Smoothing lerps from zero, so run a few frames before asserting pixels.
    clear_canvas(dc);
    for (int frame = 0; frame < 8; frame++) boo_waveform_paint(dc, rc, &wp);
    check(painted_something(dc), "recording paints live bars");

    clear_canvas(dc);
    wp.state = BOO_WAVE_TRANSCRIBING;
    wp.phase = 1.5f;
    boo_waveform_paint(dc, rc, &wp);
    check(painted_something(dc), "transcribing paints the breathing wave");

    clear_canvas(dc);
    wp.state = BOO_WAVE_IDLE;
    boo_waveform_paint(dc, rc, &wp);
    check(painted_something(dc), "idle paints the flat dim bars");

    DeleteObject(bmp);
    DeleteDC(dc);
    printf("waveform_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
