// Clipboard-first delivery. One paste chord instead of typing each character:
// synthesized keystrokes resolve against the active keyboard layout, so any
// character the layout can't produce would be silently dropped, and Ctrl+V
// pastes by default in Windows Terminal and the classic console alike.
//
// UIPI caveat, by design: SendInput into an elevated window is silently
// discarded, and neither the return value nor GetLastError says so. The
// transcript is on the clipboard either way; the caller words its status line
// so a blocked paste still tells the user what to press.

#include "inject.h"

#include "inject_plan.h"

// How long to wait for the user to lift Ctrl+Shift(+anything) from the hotkey
// press before forcing key-ups. Transcription usually eats seconds before we
// get here, so this almost never actually waits.
#define MODIFIER_WAIT_MS 1000
#define MODIFIER_POLL_MS 20

// Clipboard access is contended by clipboard managers and the Win+V history
// service; a short retry loop is standard etiquette.
#define CLIPBOARD_TRIES    5
#define CLIPBOARD_RETRY_MS 20

static bool clipboard_set(HWND owner, const char *utf8) {
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (len <= 0) return false;

    // GMEM_MOVEABLE is required by SetClipboardData; on success the system
    // owns the allocation and we must not touch or free it again.
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)len * sizeof(WCHAR));
    if (!mem) return false;
    WCHAR *wide = GlobalLock(mem);
    if (!wide) {
        GlobalFree(mem);
        return false;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, len);
    GlobalUnlock(mem);

    bool opened = false;
    for (int i = 0; i < CLIPBOARD_TRIES && !opened; i++) {
        // A real hwnd, not NULL: OpenClipboard(NULL) makes SetClipboardData
        // fail after EmptyClipboard resets the owner.
        opened = OpenClipboard(owner);
        if (!opened) Sleep(CLIPBOARD_RETRY_MS);
    }
    if (!opened) {
        GlobalFree(mem);
        return false;
    }

    EmptyClipboard();
    const bool ok = SetClipboardData(CF_UNICODETEXT, mem) != NULL;
    if (!ok) GlobalFree(mem);
    CloseClipboard();
    return ok;
}

static unsigned held_modifiers(void) {
    unsigned held = 0;
    if (GetAsyncKeyState(VK_SHIFT) & 0x8000) held |= BOO_HELD_SHIFT;
    if (GetAsyncKeyState(VK_MENU) & 0x8000) held |= BOO_HELD_MENU;
    if (GetAsyncKeyState(VK_LWIN) & 0x8000) held |= BOO_HELD_LWIN;
    if (GetAsyncKeyState(VK_RWIN) & 0x8000) held |= BOO_HELD_RWIN;
    return held;
}

static void send_paste_chord(void) {
    // Politeness first: wait for physically held modifiers to lift, so the
    // logical key state is not desynced from the keyboard (a forced key-up
    // leaves the OS thinking a still-held key is up, the "stuck modifier"
    // bug). Whatever survives the wait is released explicitly by the plan.
    for (int waited = 0; held_modifiers() && waited < MODIFIER_WAIT_MS;
         waited += MODIFIER_POLL_MS)
        Sleep(MODIFIER_POLL_MS);

    BooKeyEvent plan[BOO_PLAN_MAX];
    const int n = boo_inject_plan_paste(held_modifiers(), plan);

    INPUT inputs[BOO_PLAN_MAX];
    memset(inputs, 0, sizeof(inputs));
    for (int i = 0; i < n; i++) {
        inputs[i].type = INPUT_KEYBOARD;
        inputs[i].ki.wVk = plan[i].vk;
        inputs[i].ki.dwFlags = plan[i].action == BOO_KEY_UP ? KEYEVENTF_KEYUP : 0;
    }
    SendInput((UINT)n, inputs, sizeof(INPUT));
}

BooDeliverResult boo_inject_deliver(HWND owner, HWND target, const char *utf8) {
    if (!clipboard_set(owner, utf8)) return BOO_DELIVER_FAILED;

    // Only paste into the window the dictation started in, and only while it
    // is still where the input would actually go.
    if (!target || target == owner) return BOO_DELIVER_CLIPBOARD;
    if (GetForegroundWindow() != target) return BOO_DELIVER_CLIPBOARD;

    send_paste_chord();

    // The modifier wait may have given the user time to switch windows; if
    // focus moved mid-flight the chord went to the wrong place at worst as a
    // harmless Ctrl+V, but report honestly whether the target got it.
    return GetForegroundWindow() == target ? BOO_DELIVER_PASTED : BOO_DELIVER_CLIPBOARD;
}
