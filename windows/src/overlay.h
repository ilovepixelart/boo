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

#endif // BOO_OVERLAY_H
