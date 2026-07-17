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

// Open the diagnostic log at %LOCALAPPDATA%\Boo\logs\boo.log. Best-effort; on
// failure boo_log falls back to stderr. Never logs recognized text.
static void init_logging(void) {
    WCHAR base[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    WCHAR dir[MAX_PATH];
    if (swprintf(dir, MAX_PATH, L"%ls\\Boo", base) < 0) return;
    CreateDirectoryW(dir, NULL);
    if (swprintf(dir, MAX_PATH, L"%ls\\Boo\\logs", base) < 0) return;
    CreateDirectoryW(dir, NULL);
    WCHAR path[MAX_PATH];
    if (swprintf(path, MAX_PATH, L"%ls\\boo.log", dir) < 0) return;
    char upath[MAX_PATH * 3];
    if (WideCharToMultiByte(CP_UTF8, 0, path, -1, upath, sizeof(upath), NULL, NULL) > 0)
        boo_log_init(upath, BOO_LOG_INFO);
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

    init_logging();

    char *model_path = boo_model_find();
    if (!model_path) {
        boo_log(BOO_LOG_ERROR, "no speech model found");
        WCHAR hint[1024];
        boo_model_missing_hint(hint, ARRAYSIZE(hint));
        return fail_dialog(L"No speech model found", hint);
    }

    BooContext *ctx = boo_init(model_path);
    free(model_path);
    if (!ctx) {
        boo_log(BOO_LOG_ERROR, "speech model failed to load");
        return fail_dialog(
            L"Could not start Boo",
            L"The model file exists but could not be loaded, or the microphone "
            L"is unavailable.\n\nA corrupt or truncated model: download it "
            L"again.\nMicrophone blocked: check Settings > Privacy & security > "
            L"Microphone,\nboth the global toggle and \"Let desktop apps access "
            L"your microphone\".");
    }

    boo_log(BOO_LOG_INFO, "speech model loaded");

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
    } else {
        // Rest on the visible hotkey hint now that registration settled.
        boo_overlay_status_idle(&app);
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    // Workers may still hold the context; joining them is the difference
    // between a clean quit and a use-after-free in whisper.
    if (app.stream_thread) {
        WaitForSingleObject(app.stream_thread, INFINITE);
        CloseHandle(app.stream_thread);
    }
    if (app.worker) {
        WaitForSingleObject(app.worker, INFINITE);
        CloseHandle(app.worker);
    }
    boo_deinit(ctx);
    for (int i = 0; i < app.card_count; i++) free(app.cards[i]);
    free(app.live_text);
    CloseHandle(singleton);
    return 0;
}
