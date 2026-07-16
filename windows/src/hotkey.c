// Global hotkey via RegisterHotKey. Chosen over a low-level keyboard hook on
// purpose: hotkeys are matched by the system before the focused app sees the
// key, need no message-pump latency budget, and are not silently unhooked the
// way WH_KEYBOARD_LL is when a callback overruns its timeout.

#include "hotkey.h"

#include <stdio.h>

#define BOO_HOTKEY_ID 1

#ifndef MOD_NOREPEAT
#define MOD_NOREPEAT 0x4000
#endif

bool boo_hotkey_register(HWND hwnd, wchar_t *reason, size_t len) {
    if (RegisterHotKey(hwnd, BOO_HOTKEY_ID, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT,
                       VK_SPACE))
        return true;

    if (GetLastError() == ERROR_HOTKEY_ALREADY_REGISTERED) {
        swprintf(reason, len, L"Ctrl+Shift+Space is taken by another app");
    } else {
        swprintf(reason, len, L"hotkey registration failed (error %lu)", GetLastError());
    }
    return false;
}

void boo_hotkey_unregister(HWND hwnd) {
    UnregisterHotKey(hwnd, BOO_HOTKEY_ID);
}
