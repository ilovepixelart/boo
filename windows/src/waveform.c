// Waveform bars in plain GDI, mirroring macos/Sources/WaveformView.swift:
// center-symmetric rounded bars, lerp-smoothed, three states. The reference
// varies per-bar alpha; GDI has no alpha for fills, so each bar's color is
// blended toward the window background by the same factor, which reads the
// same over a solid backdrop.

#include "waveform.h"

#include <math.h>

// Smoothing state. One overlay per process, so module statics suffice.
static float smoothed[64];

static COLORREF blend(COLORREF fg, COLORREF bg, float alpha) {
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 1.0f) alpha = 1.0f;
    const int r = (int)(GetRValue(fg) * alpha + GetRValue(bg) * (1.0f - alpha));
    const int g = (int)(GetGValue(fg) * alpha + GetGValue(bg) * (1.0f - alpha));
    const int b = (int)(GetBValue(fg) * alpha + GetBValue(bg) * (1.0f - alpha));
    return RGB(r, g, b);
}

static void bar(HDC dc, int x, int center_y, int w, int h, COLORREF color) {
    if (h < 2) h = 2;
    HBRUSH brush = CreateSolidBrush(color);
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ old_brush = SelectObject(dc, brush);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    // Rounded ends, like the reference's capsule bars.
    const int round = w < h ? w : h;
    RoundRect(dc, x, center_y - h / 2, x + w, center_y - h / 2 + h, round, round);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void boo_waveform_paint(HDC dc, RECT rc, const BooWavePaint *wp) {
    const float *bars = wp->bars;
    const float peak = wp->peak;
    const BooWaveState state = wp->state;
    const COLORREF color = wp->color;
    const COLORREF bg = wp->bg;
    const float phase = wp->phase;
    int n = wp->n;
    if (n <= 0) return;
    if (n > (int)(sizeof(smoothed) / sizeof(smoothed[0])))
        n = (int)(sizeof(smoothed) / sizeof(smoothed[0]));

    // Reference smoothing: fast attack while recording, slow settle otherwise.
    const float lerp = state == BOO_WAVE_RECORDING ? 0.25f : 0.1f;
    for (int i = 0; i < n; i++) smoothed[i] += (bars[i] - smoothed[i]) * lerp;

    const int width = rc.right - rc.left;
    const int height = rc.bottom - rc.top;
    const int gap = 3;
    const int bar_w = (width - gap * (n - 1)) / n;
    if (bar_w < 2) return;
    const int center_y = rc.top + height / 2;
    const float max_h = (float)height * 0.75f;

    for (int i = 0; i < n; i++) {
        const int x = rc.left + i * (bar_w + gap);
        // Center bars slightly brighter, like the reference.
        const float center = 1.0f - fabsf((float)i / (float)n - 0.5f) *
                                        (state == BOO_WAVE_TRANSCRIBING ? 0.6f : 0.4f);
        float h;
        float alpha;
        if (state == BOO_WAVE_RECORDING) {
            const float norm = peak > 0.001f ? fminf(smoothed[i] / peak, 1.0f) : 0.0f;
            h = norm * max_h;
            alpha = (0.3f + norm * 0.7f) * center;
        } else if (state == BOO_WAVE_TRANSCRIBING) {
            const float wave = (sinf(phase * 2.0f + (float)i * 0.12f) + 1.0f) / 2.0f;
            h = wave * max_h * 0.25f + 3.0f;
            alpha = (0.2f + wave * 0.4f) * center;
        } else {
            h = 3.0f;
            alpha = 0.2f;
        }
        bar(dc, x, center_y, bar_w, (int)h, blend(color, bg, alpha));
    }
}
