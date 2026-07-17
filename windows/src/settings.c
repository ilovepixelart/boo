// Settings dialog: theme picker + opacity + auto-type, the Windows counterpart
// of macos SettingsWindow and the Linux header-bar Settings dialog. Themes are
// parsed by the shared core (boo_theme_parse_file); prefs persist to the
// registry under HKCU\Software\Boo.

#include "settings.h"

#include <commctrl.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BOO_SETTINGS_CLASS L"BooSettings"
#define IDC_OPACITY        2001
#define IDC_AUTOTYPE       2002
#define IDC_THEMES         2003
#define IDC_OPACITY_VAL    2004

// Live opacity readout, the reference's "1.00" label (shown as a percentage).
static void set_opacity_label(HWND dlg, int pct) {
    WCHAR text[8];
    swprintf(text, ARRAYSIZE(text), L"%d%%", pct);
    SetDlgItemTextW(dlg, IDC_OPACITY_VAL, text);
}

static int scale(int base, UINT dpi) {
    return MulDiv(base, (int)dpi, 96);
}

static char *to_utf8(const WCHAR *wide) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char *utf8 = malloc((size_t)len);
    if (!utf8) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, len, NULL, NULL);
    return utf8;
}

// ── theme discovery ──

// The dir holding the bundled Ghostty theme set. First the folder next to the
// exe (how the release zip ships them), then the cwd, then the user dot-dir.
static bool themes_dir(WCHAR *buf, size_t len) {
    WCHAR exe[MAX_PATH];
    if (GetModuleFileNameW(NULL, exe, MAX_PATH) &&
        GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        PathRemoveFileSpecW(exe);
        if (swprintf(buf, len, L"%ls\\themes", exe) >= 0 &&
            GetFileAttributesW(buf) != INVALID_FILE_ATTRIBUTES)
            return true;
    }
    if (GetFileAttributesW(L"themes") != INVALID_FILE_ATTRIBUTES) {
        wcsncpy(buf, L"themes", len);
        return true;
    }
    WCHAR home[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    if (n > 0 && n < MAX_PATH && swprintf(buf, len, L"%ls\\.boo\\themes", home) >= 0)
        return GetFileAttributesW(buf) != INVALID_FILE_ATTRIBUTES;
    return false;
}

static int cmp_theme(const void *a, const void *b) {
    return wcscmp(((const BooThemeEntry *)a)->name, ((const BooThemeEntry *)b)->name);
}

static void load_themes(BooApp *app) {
    app->themes = NULL;
    app->theme_count = 0;
    app->current_theme = -1;

    WCHAR dir[MAX_PATH];
    if (!themes_dir(dir, MAX_PATH)) return;

    WCHAR pattern[MAX_PATH];
    if (swprintf(pattern, MAX_PATH, L"%ls\\*", dir) < 0) return;
    WIN32_FIND_DATAW e;
    HANDLE it = FindFirstFileW(pattern, &e);
    if (it == INVALID_HANDLE_VALUE) return;

    int cap = 0;
    do {
        if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        WCHAR path[MAX_PATH];
        if (swprintf(path, MAX_PATH, L"%ls\\%ls", dir, e.cFileName) < 0) continue;
        char *upath = to_utf8(path);
        if (!upath) continue;
        BooThemeColors colors;
        const bool ok = boo_theme_parse_file(upath, &colors);
        free(upath);
        if (!ok) continue;

        if (app->theme_count == cap) {
            const int ncap = cap ? cap * 2 : 64;
            BooThemeEntry *grown = realloc(app->themes, (size_t)ncap * sizeof(*grown));
            if (!grown) break;
            app->themes = grown;
            cap = ncap;
        }
        app->themes[app->theme_count].name = _wcsdup(e.cFileName);
        app->themes[app->theme_count].colors = colors;
        app->theme_count++;
    } while (FindNextFileW(it, &e));
    FindClose(it);

    if (app->themes)
        qsort(app->themes, (size_t)app->theme_count, sizeof(*app->themes), cmp_theme);
}

// ── prefs persistence (registry) ──

static void load_prefs(BooApp *app) {
    app->opacity_pct = 100;
    app->auto_type = true;

    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Boo", 0, KEY_READ, &key) !=
        ERROR_SUCCESS)
        return;

    DWORD val, size = sizeof(val);
    if (RegQueryValueExW(key, L"Opacity", NULL, NULL, (BYTE *)&val, &size) ==
            ERROR_SUCCESS &&
        val >= 10 && val <= 100)
        app->opacity_pct = (int)val;
    size = sizeof(val);
    if (RegQueryValueExW(key, L"AutoType", NULL, NULL, (BYTE *)&val, &size) ==
        ERROR_SUCCESS)
        app->auto_type = val != 0;

    WCHAR name[256];
    size = sizeof(name);
    if (RegQueryValueExW(key, L"Theme", NULL, NULL, (BYTE *)name, &size) ==
        ERROR_SUCCESS) {
        for (int i = 0; i < app->theme_count; i++)
            if (wcscmp(app->themes[i].name, name) == 0) {
                app->current_theme = i;
                break;
            }
    }
    RegCloseKey(key);
}

static void save_prefs(BooApp *app) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Boo", 0, NULL, 0, KEY_WRITE, NULL,
                        &key, NULL) != ERROR_SUCCESS)
        return;
    const DWORD opacity = (DWORD)app->opacity_pct;
    const DWORD autotype = app->auto_type ? 1 : 0;
    RegSetValueExW(key, L"Opacity", 0, REG_DWORD, (const BYTE *)&opacity,
                   sizeof(opacity));
    RegSetValueExW(key, L"AutoType", 0, REG_DWORD, (const BYTE *)&autotype,
                   sizeof(autotype));
    const WCHAR *name =
        (app->current_theme >= 0) ? app->themes[app->current_theme].name : L"";
    RegSetValueExW(key, L"Theme", 0, REG_SZ, (const BYTE *)name,
                   (DWORD)((wcslen(name) + 1) * sizeof(WCHAR)));
    RegCloseKey(key);
}

// ── public: init / apply / free ──

void boo_settings_init(BooApp *app) {
    load_themes(app);
    load_prefs(app);
}

void boo_settings_apply(BooApp *app) {
    if (!app->overlay) return;
    const LONG_PTR ex = GetWindowLongPtrW(app->overlay, GWL_EXSTYLE);
    if (app->opacity_pct >= 100) {
        // Fully opaque: drop WS_EX_LAYERED entirely so it can never interfere
        // with the DWM rounded corners in the common (default) case.
        SetWindowLongPtrW(app->overlay, GWL_EXSTYLE, ex & ~(LONG_PTR)WS_EX_LAYERED);
    } else {
        SetWindowLongPtrW(app->overlay, GWL_EXSTYLE, ex | WS_EX_LAYERED);
        const BYTE alpha = (BYTE)(app->opacity_pct * 255 / 100);
        SetLayeredWindowAttributes(app->overlay, 0, alpha, LWA_ALPHA);
    }
    InvalidateRect(app->overlay, NULL, FALSE);
}

void boo_settings_free(BooApp *app) {
    for (int i = 0; i < app->theme_count; i++) free(app->themes[i].name);
    free(app->themes);
    app->themes = NULL;
    app->theme_count = 0;
}

// ── dialog ──

static void select_theme(BooApp *app, int index) {
    if (index < 0 || index >= app->theme_count) return;
    app->current_theme = index;
    save_prefs(app);
    InvalidateRect(app->overlay, NULL, FALSE);
}

static LRESULT CALLBACK settings_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    BooApp *app = (BooApp *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    switch (msg) {
    case WM_CREATE: {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)lparam;
        app = (BooApp *)cs->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)app);
        const UINT dpi = GetDpiForWindow(hwnd);
        HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        const int m = scale(16, dpi), w = scale(288, dpi);

        const int vw = scale(44, dpi);
        HWND l1 = CreateWindowW(L"STATIC", L"Opacity", WS_CHILD | WS_VISIBLE, m, m,
                                w - vw, scale(18, dpi), hwnd, NULL, cs->hInstance, NULL);
        HWND val = CreateWindowW(L"STATIC", NULL, WS_CHILD | WS_VISIBLE | SS_RIGHT,
                                 m + w - vw, m, vw, scale(18, dpi), hwnd,
                                 (HMENU)IDC_OPACITY_VAL, cs->hInstance, NULL);
        HWND bar = CreateWindowW(TRACKBAR_CLASSW, NULL,
                                 WS_CHILD | WS_VISIBLE | TBS_HORZ | TBS_NOTICKS, m,
                                 scale(38, dpi), w, scale(30, dpi), hwnd,
                                 (HMENU)IDC_OPACITY, cs->hInstance, NULL);
        SendMessageW(bar, TBM_SETRANGE, TRUE, MAKELPARAM(10, 100));
        SendMessageW(bar, TBM_SETPOS, TRUE, app->opacity_pct);
        set_opacity_label(hwnd, app->opacity_pct);

        HWND chk =
            CreateWindowW(L"BUTTON", L"Auto-type into focused app",
                          WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, m, scale(78, dpi), w,
                          scale(24, dpi), hwnd, (HMENU)IDC_AUTOTYPE, cs->hInstance, NULL);
        SendMessageW(chk, BM_SETCHECK, app->auto_type ? BST_CHECKED : BST_UNCHECKED, 0);

        HWND l2 =
            CreateWindowW(L"STATIC", L"Theme", WS_CHILD | WS_VISIBLE, m, scale(112, dpi),
                          w, scale(18, dpi), hwnd, NULL, cs->hInstance, NULL);
        HWND list = CreateWindowW(L"LISTBOX", NULL,
                                  WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_BORDER |
                                      LBS_NOTIFY | LBS_HASSTRINGS,
                                  m, scale(136, dpi), w, scale(280, dpi), hwnd,
                                  (HMENU)IDC_THEMES, cs->hInstance, NULL);
        for (int i = 0; i < app->theme_count; i++)
            SendMessageW(list, LB_ADDSTRING, 0, (LPARAM)app->themes[i].name);
        if (app->current_theme >= 0)
            SendMessageW(list, LB_SETCURSEL, app->current_theme, 0);

        HWND kids[] = {l1, val, bar, chk, l2, list};
        for (size_t i = 0; i < ARRAYSIZE(kids); i++)
            SendMessageW(kids[i], WM_SETFONT, (WPARAM)font, TRUE);
        return 0;
    }
    case WM_HSCROLL:
        if (app && GetDlgCtrlID((HWND)lparam) == IDC_OPACITY) {
            app->opacity_pct = (int)SendMessageW((HWND)lparam, TBM_GETPOS, 0, 0);
            set_opacity_label(hwnd, app->opacity_pct);
            boo_settings_apply(app);
            save_prefs(app);
        }
        return 0;
    case WM_COMMAND:
        if (!app) return 0;
        if (LOWORD(wparam) == IDC_AUTOTYPE && HIWORD(wparam) == BN_CLICKED) {
            app->auto_type = SendMessageW((HWND)lparam, BM_GETCHECK, 0, 0) == BST_CHECKED;
            save_prefs(app);
        } else if (LOWORD(wparam) == IDC_THEMES && HIWORD(wparam) == LBN_SELCHANGE) {
            select_theme(app, (int)SendMessageW((HWND)lparam, LB_GETCURSEL, 0, 0));
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (app) app->settings_win = NULL;
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

void boo_settings_open(BooApp *app) {
    if (app->settings_win) {
        SetForegroundWindow(app->settings_win);
        return;
    }

    static bool registered;
    if (!registered) {
        INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_BAR_CLASSES};
        InitCommonControlsEx(&icc);
        WNDCLASSEXW wc = {
            .cbSize = sizeof(wc),
            .lpfnWndProc = settings_proc,
            .hInstance = app->hinst,
            .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW),
            .hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1),
            .lpszClassName = BOO_SETTINGS_CLASS,
        };
        if (!RegisterClassExW(&wc)) return;
        registered = true;
    }

    const UINT dpi = GetDpiForWindow(app->overlay);
    RECT wr = {0, 0, scale(320, dpi), scale(432, dpi)};
    AdjustWindowRectExForDpi(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    app->settings_win =
        CreateWindowExW(0, BOO_SETTINGS_CLASS, L"Boo Settings",
                        WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX | WS_THICKFRAME),
                        CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left,
                        wr.bottom - wr.top, NULL, NULL, app->hinst, app);
    if (app->settings_win) {
        ShowWindow(app->settings_win, SW_SHOW);
    }
}
