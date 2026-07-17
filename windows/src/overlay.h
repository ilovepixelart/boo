// The Boo overlay window: waveform, transcript, record button.
#ifndef BOO_OVERLAY_H
#define BOO_OVERLAY_H

#include "app.h"

// Window class name, also used by a second instance to find the first.
#define BOO_OVERLAY_CLASS L"BooOverlay"

// Creates (and positions) the overlay; stores it in app->overlay.
HWND boo_overlay_create(BooApp *app);

// Start/stop dictation. Every trigger funnels here: hotkey, tray, button.
void boo_overlay_toggle_recording(BooApp *app);

// Rest the status line on its idle text (the visible hotkey hint, or the
// record-button fallback when the hotkey could not be registered). Called by
// main once hotkey registration has settled hotkey_ok.
void boo_overlay_status_idle(BooApp *app);

// Set the one-line status under the record button (truncating safely).
void boo_overlay_set_status(BooApp *app, const WCHAR *text);

#endif // BOO_OVERLAY_H
