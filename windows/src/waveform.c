// Waveform bars in plain GDI. Forty solid rectangles at ~30fps is microseconds
// of CPU; Direct2D would add COM, device management and device-lost handling
// for no visible difference at this scale.

#include "waveform.h"

void boo_waveform_paint(HDC dc, RECT rc, const float *bars, int n, float peak,
                        COLORREF color) {
    if (n <= 0) return;

    const int width = rc.right - rc.left;
    const int height = rc.bottom - rc.top;
    const int gap = 2;
    const int bar_w = (width - gap * (n - 1)) / n;
    if (bar_w < 1) return;

    HBRUSH brush = CreateSolidBrush(color);
    for (int i = 0; i < n; i++) {
        float v = bars[i];
        if (v < 0.0f) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        int bar_h = (int)(v * (float)height);
        if (bar_h < 2) bar_h = 2; // idle bars stay visible as a baseline
        RECT bar = {
            .left = rc.left + i * (bar_w + gap),
            .top = rc.bottom - bar_h,
            .right = rc.left + i * (bar_w + gap) + bar_w,
            .bottom = rc.bottom,
        };
        FillRect(dc, &bar, brush);
    }

    // Peak level line, instant attack / slow decay, computed by the core.
    if (peak > 0.01f) {
        if (peak > 1.0f) peak = 1.0f;
        int y = rc.bottom - (int)(peak * (float)height);
        RECT line = {.left = rc.left, .top = y, .right = rc.right, .bottom = y + 1};
        FillRect(dc, &line, brush);
    }
    DeleteObject(brush);
}
