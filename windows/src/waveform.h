// Waveform bar rendering, custom-drawn GDI, matching the macOS reference:
// 40 center-symmetric rounded bars with three states (docs/ui-spec.md).
#ifndef BOO_WAVEFORM_H
#define BOO_WAVEFORM_H

#include "app.h"

typedef enum {
    BOO_WAVE_IDLE,        // flat minimal bars, dim
    BOO_WAVE_RECORDING,   // peak-normalized live bars, record red
    BOO_WAVE_TRANSCRIBING // gentle sine "breathing", thinking orange
} BooWaveState;

// Draw `n` bars into `rc`. `phase` drives the transcribing animation (seconds,
// monotonic); `bg` is blended with `color` to emulate the reference's per-bar
// alpha, which plain GDI has no direct equivalent for.
void boo_waveform_paint(HDC dc, RECT rc, const float *bars, int n, float peak,
                        BooWaveState state, COLORREF color, COLORREF bg, float phase);

#endif // BOO_WAVEFORM_H
