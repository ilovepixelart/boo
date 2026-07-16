// The Ctrl+Shift+Space global hotkey.
#ifndef BOO_HOTKEY_H
#define BOO_HOTKEY_H

#include "app.h"

// Registers the hotkey against `hwnd`'s thread; WM_HOTKEY arrives in its
// message loop. Returns false when the combo is taken (or anything else went
// wrong); `reason` (capacity `len`) then says which, for the status line.
bool boo_hotkey_register(HWND hwnd, wchar_t *reason, size_t len);
void boo_hotkey_unregister(HWND hwnd);

#endif // BOO_HOTKEY_H
