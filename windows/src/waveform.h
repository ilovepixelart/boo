// Waveform bar rendering, custom-drawn GDI.
#ifndef BOO_WAVEFORM_H
#define BOO_WAVEFORM_H

#include "app.h"

// Draw `n` bottom-aligned RMS bars into `rc` on `dc`. `peak` drives a thin
// level line above the bars while it is above the noise floor.
void boo_waveform_paint(HDC dc, RECT rc, const float *bars, int n, float peak,
                        COLORREF color);

#endif // BOO_WAVEFORM_H
