#ifndef BOO_TRAY_FMT_H
#define BOO_TRAY_FMT_H

// Pure (no windows.h): the tray tooltip's recording-timer text, split out of
// tray.c so the seconds/minutes format decision can be host-tested (see
// windows/tests/tray_fmt_test.c). Wide chars, since the tooltip is a WCHAR field.

#include <stddef.h>
#include <wchar.h>

// Format the recording tooltip for `seconds` into `out` (capacity `cap` wide
// chars): "Boo, recording 5s" under a minute, "Boo, recording 1:05" at or past
// it (zero-padded seconds). Returns swprintf's result.
int boo_tray_elapsed_tip(wchar_t *out, size_t cap, int seconds);

#endif
