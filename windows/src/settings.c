// Settings dialog: theme picker + opacity + auto-type, the Windows counterpart
// of macos SettingsWindow and the Linux header-bar Settings dialog. Themes are
// parsed by the shared core (boo_theme_parse_file); prefs persist to the
// registry under HKCU\Software\Boo.

#include "settings.h"

#include "download.h"
#include "model.h"
#include "strconv.h"

#include <commctrl.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Live opacity readout, the reference's "1.00" label (shown as a percentage).
static void set_opacity_label(HWND dlg, int pct) {
    WCHAR text[8];
    swprintf(text, ARRAYSIZE(text), L"%d%%", pct);
    SetDlgItemTextW(dlg, IDC_OPACITY_VAL, text);
}

// ── theme discovery ──

// The dir holding the bundled Ghostty theme set. First the folder next to the
// exe (how the release zip ships them), then the cwd, then the user dot-dir.
static bool themes_dir(WCHAR *buf, size_t len) {
    WCHAR exe[MAX_PATH];
    const DWORD exe_len = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (exe_len > 0 && exe_len < MAX_PATH) {
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
    app->settings.themes = NULL;
    app->settings.theme_count = 0;
    app->settings.current_theme = -1;

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
        char *upath = boo_to_utf8(path);
        if (!upath) continue;
        BooThemeColors colors;
        const bool ok = boo_theme_parse_file(upath, &colors);
        free(upath);
        if (!ok) continue;

        if (app->settings.theme_count == cap) {
            const int ncap = cap ? cap * 2 : 64;
            BooThemeEntry *grown =
                realloc(app->settings.themes, (size_t)ncap * sizeof(*grown));
            if (!grown) break;
            app->settings.themes = grown;
            cap = ncap;
        }
        app->settings.themes[app->settings.theme_count].name = _wcsdup(e.cFileName);
        app->settings.themes[app->settings.theme_count].colors = colors;
        app->settings.theme_count++;
    } while (FindNextFileW(it, &e));
    FindClose(it);

    if (app->settings.themes)
        qsort(app->settings.themes, (size_t)app->settings.theme_count,
              sizeof(*app->settings.themes), cmp_theme);
}

// ── prefs persistence (registry) ──

static void load_prefs(BooApp *app) {
    app->settings.opacity_pct = 100;
    app->settings.auto_type = true;

    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, BOO_REG_KEY, 0, KEY_READ, &key) != ERROR_SUCCESS)
        return;

    DWORD val;
    DWORD size = sizeof(val);
    if (RegQueryValueExW(key, L"Opacity", NULL, NULL, (BYTE *)&val, &size) ==
            ERROR_SUCCESS &&
        val >= 10 && val <= 100)
        app->settings.opacity_pct = (int)val;
    size = sizeof(val);
    if (RegQueryValueExW(key, L"AutoType", NULL, NULL, (BYTE *)&val, &size) ==
        ERROR_SUCCESS)
        app->settings.auto_type = val != 0;

    // RegGetValueW, not RegQueryValueExW: only the former guarantees the
    // string comes back null-terminated (an externally written value may not
    // be), and the wcscmp below must never run off the buffer.
    WCHAR name[256];
    size = sizeof(name);
    if (RegGetValueW(key, NULL, L"Theme", RRF_RT_REG_SZ, NULL, name, &size) ==
        ERROR_SUCCESS) {
        for (int i = 0; i < app->settings.theme_count; i++)
            if (wcscmp(app->settings.themes[i].name, name) == 0) {
                app->settings.current_theme = i;
                break;
            }
    }
    RegCloseKey(key);
}

static void save_prefs(BooApp *app) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, BOO_REG_KEY, 0, NULL, 0, KEY_WRITE, NULL, &key,
                        NULL) != ERROR_SUCCESS)
        return;
    const DWORD opacity = (DWORD)app->settings.opacity_pct;
    const DWORD autotype = app->settings.auto_type ? 1 : 0;
    RegSetValueExW(key, L"Opacity", 0, REG_DWORD, (const BYTE *)&opacity,
                   sizeof(opacity));
    RegSetValueExW(key, L"AutoType", 0, REG_DWORD, (const BYTE *)&autotype,
                   sizeof(autotype));
    const WCHAR *name = (app->settings.current_theme >= 0)
                            ? app->settings.themes[app->settings.current_theme].name
                            : L"";
    RegSetValueExW(key, L"Theme", 0, REG_SZ, (const BYTE *)name,
                   (DWORD)((wcslen(name) + 1) * sizeof(WCHAR)));
    RegCloseKey(key);
}

// Persist an explicit model switch (and only that: auto-discovered models are
// never written, so a newly downloaded better model still wins by default).
// boo_model_find honors this key on later launches.
static void save_model_choice(const char *path) {
    WCHAR *model = boo_to_wide(path);
    if (!model) return;
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, BOO_REG_KEY, 0, NULL, 0, KEY_WRITE, NULL, &key,
                        NULL) == ERROR_SUCCESS) {
        RegSetValueExW(key, L"Model", 0, REG_SZ, (const BYTE *)model,
                       (DWORD)((wcslen(model) + 1) * sizeof(WCHAR)));
        RegCloseKey(key);
    }
    free(model);
}

// ── public: init / apply / free ──

void boo_settings_init(BooApp *app) {
    load_themes(app);
    load_prefs(app);
}

void boo_settings_apply(BooApp *app) {
    if (!app->overlay) return;
    const LONG_PTR ex = GetWindowLongPtrW(app->overlay, GWL_EXSTYLE);
    if (app->settings.opacity_pct >= 100) {
        // Fully opaque: drop WS_EX_LAYERED entirely so it can never interfere
        // with the DWM rounded corners in the common (default) case.
        SetWindowLongPtrW(app->overlay, GWL_EXSTYLE, ex & ~(LONG_PTR)WS_EX_LAYERED);
    } else {
        SetWindowLongPtrW(app->overlay, GWL_EXSTYLE, ex | WS_EX_LAYERED);
        const BYTE alpha = (BYTE)(app->settings.opacity_pct * 255 / 100);
        SetLayeredWindowAttributes(app->overlay, 0, alpha, LWA_ALPHA);
    }
    InvalidateRect(app->overlay, NULL, FALSE);
}

void boo_settings_free(BooApp *app) {
    // Destroy the modeless Settings dialog first: it holds no theme strings of
    // its own (the listbox copied them), but a theme-selection notify still
    // queued for it would run select_theme -> save_prefs against the theme
    // array we free just below. DestroyWindow runs the dialog's WM_DESTROY
    // synchronously (clearing settings.win and freeing its model arrays), so
    // nothing can reach the freed themes afterward.
    if (app->settings.win) DestroyWindow(app->settings.win);
    free(app->settings.model_current);
    app->settings.model_current = NULL;
    for (int i = 0; i < app->settings.theme_count; i++)
        free(app->settings.themes[i].name);
    free(app->settings.themes);
    app->settings.themes = NULL;
    app->settings.theme_count = 0;
}

// ── model switcher ──
// One dropdown merging the usable models on disk (boo_model_installed) with
// the manifest models not yet downloaded, the latter tagged with their size.
// Picking a tagged entry downloads it first (download.c, progress bar under
// the combo), then swaps like any on-disk model: in place off the UI thread
// via boo_reload_model, which keeps the old model serving on a failed load.
// The explicit choice persists in the registry and wins over ranked
// auto-discovery on later launches.

static void model_paths_free(BooApp *app);

typedef struct {
    BooApp *app;
    HWND dlg;
    char *path; // malloc'd; the handler takes ownership on success
} ModelSwap;

static DWORD WINAPI model_swap_worker(LPVOID param) {
    ModelSwap *job = param;
    const bool ok = boo_reload_model(job->app->ctx, job->path);
    PostMessageW(job->dlg, BOO_MSG_MODEL_SWAPPED, ok, (LPARAM)job);
    return 0;
}

// Point the combo selection back at the loaded model (or clear it).
static void model_combo_select_current(BooApp *app, HWND combo) {
    for (int i = 0; i < app->settings.model_count; i++)
        if (app->settings.model_current &&
            strcmp(app->settings.model_paths[i], app->settings.model_current) == 0) {
            SendMessageW(combo, CB_SETCURSEL, (WPARAM)i, 0);
            return;
        }
    SendMessageW(combo, CB_SETCURSEL, (WPARAM)-1, 0);
}

// Freeze or thaw the dialog around background work (a swap or a download):
// the combo and the close button, so the worker's message target stays alive.
static void model_set_frozen(BooApp *app, HWND dlg, bool frozen) {
    (void)app;
    static const int ids[] = {IDC_MODEL};
    boo_dialog_freeze(dlg, ids, 1, frozen);
}

// Swap to `path` on a worker thread; loading takes seconds.
static void model_swap_begin(BooApp *app, HWND dlg, HWND combo, const char *path) {
    if (app->settings.model_current && strcmp(path, app->settings.model_current) == 0)
        return;
    if (boo_is_recording(app->ctx) || boo_is_transcribing(app->ctx)) {
        MessageBoxW(dlg, L"Stop recording first.", L"Boo", MB_ICONINFORMATION);
        model_combo_select_current(app, combo);
        return;
    }

    ModelSwap *job = malloc(sizeof(*job));
    if (!job) return;
    job->app = app;
    job->dlg = dlg;
    job->path = _strdup(path);
    if (!job->path) {
        free(job);
        return;
    }

    model_set_frozen(app, dlg, true);
    // The previous swap (if any) fully finished before the UI thawed; reclaim
    // its handle before storing the new one.
    if (app->model_swap_worker) {
        WaitForSingleObject(app->model_swap_worker, INFINITE);
        CloseHandle(app->model_swap_worker);
        app->model_swap_worker = NULL;
    }
    HANDLE worker = CreateThread(NULL, 0, model_swap_worker, job, 0, NULL);
    if (!worker) {
        model_set_frozen(app, dlg, false);
        free(job->path);
        free(job);
        return;
    }
    // Kept for the shutdown join in main.c, not closed here: quitting the app
    // mid-swap must wait for boo_reload_model before boo_deinit.
    app->model_swap_worker = worker;
}

// (Re)fill the model combo: usable models on disk (ranked), then manifest
// models not yet downloaded, tagged with their size. Selects the loaded one.
static void model_combo_fill(BooApp *app, HWND combo) {
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    model_paths_free(app);
    app->settings.model_count = boo_model_installed(&app->settings.model_paths);
    for (int i = 0; i < app->settings.model_count; i++) {
        WCHAR *base = boo_to_wide(boo_model_basename(app->settings.model_paths[i]));
        if (!base) continue;
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)base);
        free(base);
    }

    size_t mcount = 0;
    const BooModelInfo *manifest = boo_models(&mcount);
    app->settings.model_absent = malloc(mcount * sizeof(*app->settings.model_absent));
    app->settings.model_absent_count = 0;
    for (size_t i = 0; app->settings.model_absent && i < mcount; i++) {
        bool on_disk = false;
        for (int j = 0; j < app->settings.model_count && !on_disk; j++)
            on_disk = strcmp(boo_model_basename(app->settings.model_paths[j]),
                             manifest[i].filename) == 0;
        if (on_disk) continue;
        app->settings.model_absent[app->settings.model_absent_count++] = &manifest[i];
        char label[300];
        snprintf(label, sizeof(label), "%s  (download, %u MB)", manifest[i].filename,
                 (unsigned)(manifest[i].size / 1000000));
        WCHAR *wide = boo_to_wide(label);
        if (!wide) continue;
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)wide);
        free(wide);
    }
    model_combo_select_current(app, combo);
}

// A not-yet-downloaded manifest entry was picked: fetch it (progress bar
// under the combo), then BOO_MSG_DL_DONE swaps to it.
static void model_download_begin(BooApp *app, HWND dlg, HWND combo,
                                 const BooModelInfo *model) {
    model_set_frozen(app, dlg, true);
    HWND bar = GetDlgItem(dlg, IDC_MODEL_PROGRESS);
    SendMessageW(bar, PBM_SETPOS, 0, 0);
    ShowWindow(bar, SW_SHOW);
    if (!boo_download_start(dlg, model)) {
        ShowWindow(bar, SW_HIDE);
        model_set_frozen(app, dlg, false);
        model_combo_select_current(app, combo);
    }
}

static void model_switch(BooApp *app, HWND dlg, HWND combo) {
    const int idx = (int)SendMessageW(combo, CB_GETCURSEL, 0, 0);
    if (idx < 0) return;
    if (idx < app->settings.model_count) {
        model_swap_begin(app, dlg, combo, app->settings.model_paths[idx]);
        return;
    }
    const int a = idx - app->settings.model_count;
    if (a < app->settings.model_absent_count)
        model_download_begin(app, dlg, combo, app->settings.model_absent[a]);
}

// The download finished: swap to the fresh file, or report and reset.
static void model_downloaded(BooApp *app, HWND dlg, bool ok, char *text) {
    HWND combo = GetDlgItem(dlg, IDC_MODEL);
    ShowWindow(GetDlgItem(dlg, IDC_MODEL_PROGRESS), SW_HIDE);
    model_set_frozen(app, dlg, false);
    if (ok) {
        model_swap_begin(app, dlg, combo, text);
    } else {
        WCHAR *wide = boo_to_wide(text ? text : "Download failed.");
        if (wide) {
            MessageBoxW(dlg, wide, L"Boo", MB_ICONWARNING);
            free(wide);
        }
        model_combo_select_current(app, combo);
    }
    free(text);
}

static void model_swapped(BooApp *app, HWND dlg, bool ok, ModelSwap *job) {
    HWND combo = GetDlgItem(dlg, IDC_MODEL);
    model_set_frozen(app, dlg, false);
    if (ok) {
        free(app->settings.model_current);
        app->settings.model_current = job->path; // ownership moves
        save_model_choice(job->path);
        boo_log(BOO_LOG_INFO, "model switched");
        // A downloaded model just moved from the tagged rows to the on-disk
        // rows; refill so the list matches the disk again.
        model_combo_fill(app, combo);
    } else {
        free(job->path);
        MessageBoxW(dlg, L"Could not load that model; keeping the previous one.", L"Boo",
                    MB_ICONWARNING);
        model_combo_select_current(app, combo);
    }
    free(job);
}

static void model_paths_free(BooApp *app) {
    for (int i = 0; i < app->settings.model_count; i++)
        free(app->settings.model_paths[i]);
    free(app->settings.model_paths);
    app->settings.model_paths = NULL;
    app->settings.model_count = 0;
    free(app->settings.model_absent);
    app->settings.model_absent = NULL;
    app->settings.model_absent_count = 0;
}

// ── dialog ──

static void select_theme(BooApp *app, int index) {
    if (index < 0 || index >= app->settings.theme_count) return;
    app->settings.current_theme = index;
    save_prefs(app);
    InvalidateRect(app->overlay, NULL, FALSE);
}

// Build the dialog's controls (WM_CREATE body, split out of settings_proc to
// keep the window proc's complexity within bounds).
static void settings_on_create(BooApp *app, HWND hwnd, const CREATESTRUCTW *cs) {
    const UINT dpi = GetDpiForWindow(hwnd);
    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    const int m = boo_px(16, dpi);
    const int w = boo_px(288, dpi);

    const int vw = boo_px(44, dpi);
    HWND l1 = CreateWindowW(L"STATIC", L"Opacity", WS_CHILD | WS_VISIBLE, m, m, w - vw,
                            boo_px(18, dpi), hwnd, NULL, cs->hInstance, NULL);
    HWND val = CreateWindowW(L"STATIC", NULL, WS_CHILD | WS_VISIBLE | SS_RIGHT,
                             m + w - vw, m, vw, boo_px(18, dpi), hwnd,
                             (HMENU)IDC_OPACITY_VAL, cs->hInstance, NULL);
    HWND bar =
        CreateWindowW(TRACKBAR_CLASSW, NULL,
                      WS_CHILD | WS_VISIBLE | TBS_HORZ | TBS_NOTICKS, m, boo_px(38, dpi),
                      w, boo_px(30, dpi), hwnd, (HMENU)IDC_OPACITY, cs->hInstance, NULL);
    SendMessageW(bar, TBM_SETRANGE, TRUE, MAKELPARAM(10, 100));
    SendMessageW(bar, TBM_SETPOS, TRUE, app->settings.opacity_pct);
    set_opacity_label(hwnd, app->settings.opacity_pct);

    HWND chk =
        CreateWindowW(L"BUTTON", L"Auto-type into focused app",
                      WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, m, boo_px(78, dpi), w,
                      boo_px(24, dpi), hwnd, (HMENU)IDC_AUTOTYPE, cs->hInstance, NULL);
    SendMessageW(chk, BM_SETCHECK, app->settings.auto_type ? BST_CHECKED : BST_UNCHECKED,
                 0);

    HWND lm =
        CreateWindowW(L"STATIC", L"Model", WS_CHILD | WS_VISIBLE, m, boo_px(112, dpi), w,
                      boo_px(18, dpi), hwnd, NULL, cs->hInstance, NULL);
    // Dropdown of the usable models on disk; the loaded one is selected.
    // The height covers the open list, per the combo box contract.
    HWND combo = CreateWindowW(L"COMBOBOX", NULL,
                               WS_CHILD | WS_VISIBLE | WS_VSCROLL | CBS_DROPDOWNLIST |
                                   CBS_HASSTRINGS,
                               m, boo_px(134, dpi), w, boo_px(160, dpi), hwnd,
                               (HMENU)IDC_MODEL, cs->hInstance, NULL);
    model_combo_fill(app, combo);
    // Download progress for tagged entries; hidden until one is picked.
    HWND dlbar = CreateWindowW(PROGRESS_CLASSW, NULL, WS_CHILD, m, boo_px(162, dpi), w,
                               boo_px(10, dpi), hwnd, (HMENU)IDC_MODEL_PROGRESS,
                               cs->hInstance, NULL);
    SendMessageW(dlbar, PBM_SETRANGE32, 0, 100);

    HWND l2 =
        CreateWindowW(L"STATIC", L"Theme", WS_CHILD | WS_VISIBLE, m, boo_px(176, dpi), w,
                      boo_px(18, dpi), hwnd, NULL, cs->hInstance, NULL);
    HWND list = CreateWindowW(L"LISTBOX", NULL,
                              WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_BORDER |
                                  LBS_NOTIFY | LBS_HASSTRINGS,
                              m, boo_px(200, dpi), w, boo_px(280, dpi), hwnd,
                              (HMENU)IDC_THEMES, cs->hInstance, NULL);
    for (int i = 0; i < app->settings.theme_count; i++)
        SendMessageW(list, LB_ADDSTRING, 0, (LPARAM)app->settings.themes[i].name);
    if (app->settings.current_theme >= 0)
        SendMessageW(list, LB_SETCURSEL, app->settings.current_theme, 0);

    HWND kids[] = {l1, val, bar, chk, lm, combo, l2, list};
    for (size_t i = 0; i < ARRAYSIZE(kids); i++)
        SendMessageW(kids[i], WM_SETFONT, (WPARAM)font, TRUE);
}

static LRESULT CALLBACK settings_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    BooApp *app = (BooApp *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    switch (msg) {
    case WM_CREATE: {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)lparam;
        app = (BooApp *)cs->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)app);
        settings_on_create(app, hwnd, cs);
        return 0;
    }
    case WM_HSCROLL:
        if (app && GetDlgCtrlID((HWND)lparam) == IDC_OPACITY) {
            app->settings.opacity_pct = (int)SendMessageW((HWND)lparam, TBM_GETPOS, 0, 0);
            set_opacity_label(hwnd, app->settings.opacity_pct);
            boo_settings_apply(app);
            save_prefs(app);
        }
        return 0;
    case WM_COMMAND:
        if (!app) return 0;
        if (LOWORD(wparam) == IDC_AUTOTYPE && HIWORD(wparam) == BN_CLICKED) {
            app->settings.auto_type =
                SendMessageW((HWND)lparam, BM_GETCHECK, 0, 0) == BST_CHECKED;
            save_prefs(app);
        } else if (LOWORD(wparam) == IDC_THEMES && HIWORD(wparam) == LBN_SELCHANGE) {
            select_theme(app, (int)SendMessageW((HWND)lparam, LB_GETCURSEL, 0, 0));
        } else if (LOWORD(wparam) == IDC_MODEL && HIWORD(wparam) == CBN_SELCHANGE) {
            model_switch(app, hwnd, (HWND)lparam);
        }
        return 0;
    case BOO_MSG_MODEL_SWAPPED:
        if (app) model_swapped(app, hwnd, wparam != 0, (ModelSwap *)lparam);
        return 0;
    case BOO_MSG_DL_PROGRESS:
        SendMessageW(GetDlgItem(hwnd, IDC_MODEL_PROGRESS), PBM_SETPOS, wparam, 0);
        return 0;
    case BOO_MSG_DL_DONE:
        if (app)
            model_downloaded(app, hwnd, wparam != 0, (char *)lparam);
        else
            free((char *)lparam);
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (app) {
            app->settings.win = NULL;
            model_paths_free(app);
        }
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

void boo_settings_open(BooApp *app) {
    if (app->settings.win) {
        SetForegroundWindow(app->settings.win);
        return;
    }

    static bool registered;
    if (!registered) {
        INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_BAR_CLASSES | ICC_PROGRESS_CLASS};
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
    RECT wr = {0, 0, boo_px(320, dpi), boo_px(496, dpi)};
    AdjustWindowRectExForDpi(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    app->settings.win =
        CreateWindowExW(0, BOO_SETTINGS_CLASS, L"Boo Settings",
                        WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX | WS_THICKFRAME),
                        CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left,
                        wr.bottom - wr.top, NULL, NULL, app->hinst, app);
    if (app->settings.win) {
        ShowWindow(app->settings.win, SW_SHOW);
    }
}
