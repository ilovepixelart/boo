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

// One paint's inputs: `bars`/`n` from boo_get_waveform, `phase` drives the
// transcribing animation (seconds, monotonic); `bg` is blended with `color` to
// emulate the reference's per-bar alpha, which plain GDI has no direct
// equivalent for.
typedef struct {
    const float *bars;
    int n;
    float peak;
    BooWaveState state;
    COLORREF color;
    COLORREF bg;
    float phase;
} BooWavePaint;

// Draw the bars into `rc`.
void boo_waveform_paint(HDC dc, RECT rc, const BooWavePaint *wp);

#endif // BOO_WAVEFORM_H
