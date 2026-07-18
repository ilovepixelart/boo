#ifndef BOO_OPACITY_H
#define BOO_OPACITY_H

// Pure (no windows.h): the overlay opacity math, split out of settings.c so the
// persisted-value range check and the layered-window alpha scaling can be tested
// on any host (see windows/tests/opacity_test.c).

#include <stdbool.h>
#include <stdint.h>

// The usable opacity percent range: the Settings trackbar bounds and the values
// accepted back from the registry. Below the minimum the overlay would be
// near-invisible; the maximum is fully opaque.
#define BOO_OPACITY_MIN 10
#define BOO_OPACITY_MAX 100

// Whether a persisted opacity percent is in the usable range; load_prefs keeps
// the default (fully opaque) when this is false.
bool boo_opacity_valid(int pct);

// The layered-window alpha for `pct`. Writes pct*255/100 (truncated) to *alpha
// and returns true when the window is translucent (needs WS_EX_LAYERED). Returns
// false when pct is fully opaque (>= BOO_OPACITY_MAX; drop the layered style),
// leaving *alpha untouched.
bool boo_opacity_alpha(int pct, uint8_t *alpha);

#endif
