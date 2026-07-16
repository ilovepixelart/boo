// Boo Windows apprt, entry point.
// Single-instances via a named mutex, finds a whisper model, initializes the
// Boo Zig core, creates the overlay + tray icon + global hotkey, pumps
// messages, and tears everything down on quit.
//
// Permissions: classic desktop apps see no per-app microphone prompt; capture
// is governed by the global privacy toggles (Settings > Privacy & security >
// Microphone). When those block it, boo_init fails and the dialog below says
// where to look.

#include "app.h"
#include "hotkey.h"
#include "model.h"
#include "overlay.h"
#include "tray.h"

#include <stdlib.h>

// Local\ (per-session), not Global\: a second user on the same machine gets
// their own Boo, they are only blocked from a second one in the same session.
static const WCHAR SINGLETON_NAME[] = L"Local\\boo-app-single-instance";

static int fail_dialog(const WCHAR *heading, const WCHAR *body) {
    MessageBoxW(NULL, body, heading, MB_OK | MB_ICONERROR);
    return 1;
}

int WINAPI wWinMain(HINSTANCE hinst, HINSTANCE prev, PWSTR cmdline, int show) {
    (void)prev;
    (void)cmdline;
    (void)show;

    HANDLE singleton = CreateMutexW(NULL, FALSE, SINGLETON_NAME);
    if (singleton && GetLastError() == ERROR_ALREADY_EXISTS) {
        // Hand off: surface the first instance's overlay instead of a second
        // tray icon fighting over the same hotkey.
        HWND existing = FindWindowW(BOO_OVERLAY_CLASS, NULL);
        if (existing) ShowWindow(existing, SW_SHOWNOACTIVATE);
        CloseHandle(singleton);
        return 0;
    }

    char *model_path = boo_model_find();
    if (!model_path) {
        WCHAR hint[1024];
        boo_model_missing_hint(hint, ARRAYSIZE(hint));
        return fail_dialog(L"No speech model found", hint);
    }

    BooContext *ctx = boo_init(model_path);
    free(model_path);
    if (!ctx) {
        return fail_dialog(
            L"Could not start Boo",
            L"The model file exists but could not be loaded, or the microphone "
            L"is unavailable.\n\nA corrupt or truncated model: download it "
            L"again.\nMicrophone blocked: check Settings > Privacy & security > "
            L"Microphone,\nboth the global toggle and \"Let desktop apps access "
            L"your microphone\".");
    }

    static BooApp app; // zero-initialized
    app.ctx = ctx;
    app.hinst = hinst;

    if (!boo_overlay_create(&app)) {
        boo_deinit(ctx);
        return fail_dialog(L"Could not start Boo", L"Window creation failed.");
    }
    ShowWindow(app.overlay, SW_SHOWNOACTIVATE);

    boo_tray_add(app.overlay);

    WCHAR reason[128];
    app.hotkey_ok = boo_hotkey_register(app.overlay, reason, ARRAYSIZE(reason));
    if (!app.hotkey_ok) {
        // Same policy as the Linux frontend: the hotkey is best-effort and the
        // Record button stays the primary control, so say so, don't die.
        WCHAR status[160];
        swprintf(status, ARRAYSIZE(status), L"Hotkey unavailable: %ls", reason);
        wcsncpy(app.status, status, ARRAYSIZE(app.status) - 1);
        app.status[ARRAYSIZE(app.status) - 1] = 0;
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    // A transcription worker may still hold the context; joining it is the
    // difference between a clean quit and a use-after-free in whisper.
    if (app.worker) {
        WaitForSingleObject(app.worker, INFINITE);
        CloseHandle(app.worker);
    }
    boo_deinit(ctx);
    CloseHandle(singleton);
    return 0;
}
