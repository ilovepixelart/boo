// First-run model onboarding dialog (see onboarding.h). The download itself
// lives in download.c and is shared with the Settings model switcher.

#include "onboarding.h"

#include "download.h"

#include <commctrl.h>
#include <commdlg.h>
#include <stdio.h>
#include <stdlib.h>

#define BOO_ONBOARDING_CLASS L"BooOnboarding"
#define IDC_OB_MODELS        3001
#define IDC_OB_PROGRESS      3002
#define IDC_OB_STATUS        3003
#define IDC_OB_DOWNLOAD      3004
#define IDC_OB_BROWSE        3005

static int scale(int base, UINT dpi) {
    return MulDiv(base, (int)dpi, 96);
}

static WCHAR *to_wide(const char *utf8) {
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (len <= 0) return NULL;
    WCHAR *wide = malloc((size_t)len * sizeof(WCHAR));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, len);
    return wide;
}

static char *to_utf8(const WCHAR *wide) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char *utf8 = malloc((size_t)len);
    if (!utf8) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, len, NULL, NULL);
    return utf8;
}

static void set_status(HWND dlg, const char *text) {
    WCHAR *wide = to_wide(text);
    if (!wide) return;
    SetDlgItemTextW(dlg, IDC_OB_STATUS, wide);
    free(wide);
}

// Freeze or thaw the interactive controls; frozen while a download runs so
// the dialog (the worker's message target) cannot die under it.
static void set_frozen(HWND dlg, bool frozen) {
    EnableWindow(GetDlgItem(dlg, IDC_OB_MODELS), !frozen);
    EnableWindow(GetDlgItem(dlg, IDC_OB_DOWNLOAD), !frozen);
    EnableWindow(GetDlgItem(dlg, IDC_OB_BROWSE), !frozen);
    EnableMenuItem(GetSystemMenu(dlg, FALSE), SC_CLOSE,
                   MF_BYCOMMAND | (frozen ? MF_GRAYED : MF_ENABLED));
}

// Boot the app with a model that just landed, then retire the dialog.
static void finish_with_model(BooApp *app, HWND dlg, char *path) {
    if (boo_app_start(app, path)) {
        DestroyWindow(dlg); // app is up; WM_DESTROY sees ctx and does not quit
    } else {
        set_frozen(dlg, false);
        set_status(dlg, "That model could not be loaded. Try another.");
    }
}

static void start_download(BooApp *app, HWND dlg) {
    (void)app;
    const int idx = (int)SendMessageW(GetDlgItem(dlg, IDC_OB_MODELS), CB_GETCURSEL, 0, 0);
    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);
    if (idx < 0 || (size_t)idx >= count) return;
    set_frozen(dlg, true);
    set_status(dlg, "Downloading…");
    if (!boo_download_start(dlg, &models[idx])) {
        set_frozen(dlg, false);
        set_status(dlg, "Could not start the download.");
    }
}

// The zero-network escape hatch for a model already on disk.
static void browse_for_model(BooApp *app, HWND dlg) {
    WCHAR file[MAX_PATH] = L"";
    OPENFILENAMEW ofn = {
        .lStructSize = sizeof(ofn),
        .hwndOwner = dlg,
        .lpstrFilter = L"GGML models (ggml-*.bin)\0ggml-*.bin\0All files\0*.*\0",
        .lpstrFile = file,
        .nMaxFile = ARRAYSIZE(file),
        .lpstrTitle = L"Choose a speech model",
        // NOCHANGEDIR: without it the picker changes the process CWD, and the
        // relative "models"/"themes" fallbacks then resolve against wherever
        // the user browsed to.
        .Flags = OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR,
    };
    if (!GetOpenFileNameW(&ofn)) return;
    char *path = to_utf8(file);
    if (path) finish_with_model(app, dlg, path);
}

static void create_controls(HWND hwnd, const CREATESTRUCTW *cs) {
    const UINT dpi = GetDpiForWindow(hwnd);
    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    const int m = scale(16, dpi);
    const int w = scale(388, dpi);

    HWND combo = CreateWindowW(
        L"COMBOBOX", NULL,
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | CBS_DROPDOWNLIST | CBS_HASSTRINGS, m, m, w,
        scale(160, dpi), hwnd, (HMENU)IDC_OB_MODELS, cs->hInstance, NULL);
    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);
    for (size_t i = 0; i < count; i++) {
        char label[256];
        snprintf(label, sizeof(label), "%s  (%s)", models[i].label, models[i].note);
        WCHAR *wide = to_wide(label);
        if (!wide) continue;
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)wide);
        free(wide);
    }
    SendMessageW(combo, CB_SETCURSEL, 0, 0);

    HWND bar =
        CreateWindowW(PROGRESS_CLASSW, NULL, WS_CHILD | WS_VISIBLE, m, scale(48, dpi), w,
                      scale(16, dpi), hwnd, (HMENU)IDC_OB_PROGRESS, cs->hInstance, NULL);
    SendMessageW(bar, PBM_SETRANGE32, 0, 100);

    HWND status = CreateWindowW(
        L"STATIC", L"Downloads to %USERPROFILE%\\.boo\\models, then opens Boo.",
        WS_CHILD | WS_VISIBLE, m, scale(72, dpi), w, scale(18, dpi), hwnd,
        (HMENU)IDC_OB_STATUS, cs->hInstance, NULL);

    const int bw = scale(120, dpi);
    HWND browse =
        CreateWindowW(L"BUTTON", L"Choose a File…", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                      m, scale(100, dpi), bw, scale(28, dpi), hwnd, (HMENU)IDC_OB_BROWSE,
                      cs->hInstance, NULL);
    HWND button =
        CreateWindowW(L"BUTTON", L"Download", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                      m + w - bw, scale(100, dpi), bw, scale(28, dpi), hwnd,
                      (HMENU)IDC_OB_DOWNLOAD, cs->hInstance, NULL);

    HWND kids[] = {combo, bar, status, browse, button};
    for (size_t i = 0; i < ARRAYSIZE(kids); i++)
        SendMessageW(kids[i], WM_SETFONT, (WPARAM)font, TRUE);
}

static LRESULT CALLBACK onboarding_proc(HWND hwnd, UINT msg, WPARAM wparam,
                                        LPARAM lparam) {
    BooApp *app = (BooApp *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    switch (msg) {
    case WM_CREATE: {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)lparam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        create_controls(hwnd, cs);
        return 0;
    }
    case WM_COMMAND:
        if (!app) return 0;
        if (LOWORD(wparam) == IDC_OB_DOWNLOAD && HIWORD(wparam) == BN_CLICKED)
            start_download(app, hwnd);
        else if (LOWORD(wparam) == IDC_OB_BROWSE && HIWORD(wparam) == BN_CLICKED)
            browse_for_model(app, hwnd);
        return 0;
    case BOO_MSG_DL_PROGRESS:
        SendMessageW(GetDlgItem(hwnd, IDC_OB_PROGRESS), PBM_SETPOS, wparam, 0);
        return 0;
    case BOO_MSG_DL_DONE: {
        char *text = (char *)lparam;
        if (app && wparam) {
            finish_with_model(app, hwnd, text); // takes ownership of the path
        } else {
            set_frozen(hwnd, false);
            if (text) set_status(hwnd, text);
            free(text);
        }
        return 0;
    }
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        // Closed without a model: nothing else keeps the process alive.
        if (!app || !app->ctx) PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

bool boo_onboarding_open(BooApp *app) {
    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_PROGRESS_CLASS};
    InitCommonControlsEx(&icc);
    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc),
        .lpfnWndProc = onboarding_proc,
        .hInstance = app->hinst,
        .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW),
        .hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1),
        .lpszClassName = BOO_ONBOARDING_CLASS,
    };
    if (!RegisterClassExW(&wc)) return false;

    const UINT dpi = GetDpiForSystem();
    RECT wr = {0, 0, scale(420, dpi), scale(144, dpi)};
    AdjustWindowRectExForDpi(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    HWND win = CreateWindowExW(0, BOO_ONBOARDING_CLASS, L"Download a Model",
                               WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX | WS_THICKFRAME),
                               CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left,
                               wr.bottom - wr.top, NULL, NULL, app->hinst, app);
    if (!win) return false;
    ShowWindow(win, SW_SHOW);
    return true;
}
