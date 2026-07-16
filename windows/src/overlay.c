// Overlay window. The one non-negotiable behavior: it must NEVER take focus,
// or the transcript would land back in Boo instead of the app being dictated
// into. Three layers enforce that: WS_EX_NOACTIVATE, MA_NOACTIVATE (mouse
// "active window tracking" ignores the style, per Raymond Chen), and manual
// dragging via SetCapture + SWP_NOACTIVATE (an HTCAPTION drag activates).
//
// Transcription runs on a worker thread (boo_transcribe is synchronous) and
// posts the result back to this window as BOO_MSG_TRANSCRIBED.

#include "overlay.h"

#include "hotkey.h"
#include "inject.h"
#include "tray.h"
#include "waveform.h"

#include <dwmapi.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <windowsx.h>

// Not yet in every mingw dwmapi.h; values are ABI, not SDK-version dependent.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

// Base layout in 96-dpi pixels.
#define BASE_W   380
#define BASE_H   230
#define MARGIN   16
#define WAVE_H   64
#define STATUS_H 18
#define BUTTON_W 120
#define BUTTON_H 32

typedef struct {
    COLORREF bg, text, subtext, accent, danger, button_text;
} Palette;

// GDI/interaction state. One overlay per process (single-instance mutex), so
// module statics are the whole story.
static HFONT font_text;
static HFONT font_status;
static bool dragging;
static bool button_pressed;
static POINT drag_cursor; // cursor position at drag start, screen coords
static RECT drag_window;  // window rect at drag start

static int px(int base, UINT dpi) {
    return MulDiv(base, (int)dpi, 96);
}

static Palette palette(bool dark) {
    if (dark)
        return (Palette){RGB(32, 32, 32),   RGB(240, 240, 240), RGB(160, 160, 160),
                         RGB(76, 194, 255), RGB(255, 99, 71),   RGB(16, 16, 16)};
    return (Palette){RGB(246, 246, 246), RGB(20, 20, 20),  RGB(96, 96, 96),
                     RGB(0, 103, 192),   RGB(196, 43, 28), RGB(255, 255, 255)};
}

// Follows the system Apps theme. The documented WinRT route (UISettings) is
// COM; the registry value plus WM_SETTINGCHANGE is the plain-C equivalent
// everyone uses. Missing value (user never touched the setting) means light.
static bool system_dark(void) {
    DWORD light = 1;
    DWORD size = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER,
                 L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size);
    return light == 0;
}

static void make_fonts(UINT dpi) {
    if (font_text) DeleteObject(font_text);
    if (font_status) DeleteObject(font_status);
    font_text = CreateFontW(-px(15, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    font_status = CreateFontW(-px(12, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
}

static RECT button_rect(HWND hwnd, UINT dpi) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    const int w = px(BUTTON_W, dpi);
    const int h = px(BUTTON_H, dpi);
    const int x = (rc.right - w) / 2;
    const int y = rc.bottom - px(MARGIN, dpi) - h;
    return (RECT){x, y, x + w, y + h};
}

static void set_status(BooApp *app, const WCHAR *text) {
    wcsncpy(app->status, text, ARRAYSIZE(app->status) - 1);
    app->status[ARRAYSIZE(app->status) - 1] = 0;
}

// ── recording lifecycle (mirrors linux/src/overlay_window.c) ──

static DWORD WINAPI transcribe_worker(LPVOID param) {
    BooApp *app = param;
    const char *text = boo_transcribe(app->ctx);
    // The context owns `text` and frees it on the next recording; the UI
    // thread gets its own copy, released in the BOO_MSG_TRANSCRIBED handler.
    char *copy = text ? _strdup(text) : NULL;
    PostMessageW(app->overlay, BOO_MSG_TRANSCRIBED, 0, (LPARAM)copy);
    return 0;
}

static void begin_transcription(BooApp *app) {
    app->ui_recording = false;
    KillTimer(app->overlay, BOO_TIMER_WAVEFORM);
    KillTimer(app->overlay, BOO_TIMER_AUTO_STOP);

    boo_stop_recording(app->ctx);
    boo_tray_set_recording(app->overlay, false);

    app->transcribing = true;
    set_status(app, L"Transcribing…");
    app->worker = CreateThread(NULL, 0, transcribe_worker, app, 0, NULL);
    if (!app->worker) {
        app->transcribing = false;
        set_status(app, L"Could not start transcription");
    }
    InvalidateRect(app->overlay, NULL, FALSE);
}

void boo_overlay_toggle_recording(BooApp *app) {
    if (app->transcribing) return; // one take at a time

    if (app->ui_recording) {
        begin_transcription(app);
        return;
    }

    // The paste target is whatever the user is dictating into. The overlay
    // never takes focus, so this is valid even for Record-button clicks.
    app->paste_target = GetForegroundWindow();
    if (app->paste_target == app->overlay) app->paste_target = NULL;

    boo_warm_up(app->ctx);
    boo_start_recording(app->ctx);
    app->ui_recording = true;
    app->transcript[0] = 0;
    set_status(app, L"");
    boo_tray_set_recording(app->overlay, true);

    SetTimer(app->overlay, BOO_TIMER_WAVEFORM, 33, NULL);
    // The core stops capturing by itself at the recording cap; it can't
    // finish the job from inside the audio callback, so poll for it.
    SetTimer(app->overlay, BOO_TIMER_AUTO_STOP, 500, NULL);
    InvalidateRect(app->overlay, NULL, FALSE);
}

static void on_transcribed(BooApp *app, char *text) {
    app->transcribing = false;
    if (app->worker) {
        CloseHandle(app->worker);
        app->worker = NULL;
    }

    if (text && *text) {
        MultiByteToWideChar(CP_UTF8, 0, text, -1, app->transcript,
                            ARRAYSIZE(app->transcript));
        app->transcript[ARRAYSIZE(app->transcript) - 1] = 0;

        switch (boo_inject_deliver(app->overlay, app->paste_target, text)) {
        case BOO_DELIVER_PASTED:
            set_status(app, L"Copied to clipboard and pasted");
            break;
        case BOO_DELIVER_CLIPBOARD:
            // Also the elevated-window outcome: UIPI silently discards the
            // paste, so tell the user what still works.
            set_status(app, L"Copied to clipboard, press Ctrl+V to paste");
            break;
        case BOO_DELIVER_FAILED:
            set_status(app, L"Could not access the clipboard");
            break;
        }
    } else {
        set_status(app, L"(no speech detected)");
    }
    free(text);
    InvalidateRect(app->overlay, NULL, FALSE);
}

static void on_auto_stop_poll(BooApp *app) {
    if (!app->ui_recording) return;
    if (boo_is_recording(app->ctx)) return;
    set_status(app, L"Maximum recording length reached");
    begin_transcription(app);
}

// ── painting ──

static const WCHAR *button_label(const BooApp *app) {
    if (app->transcribing) return L"Transcribing…";
    return app->ui_recording ? L"Stop" : L"Record";
}

static void paint_button(const BooApp *app, HDC dc, RECT rc, const Palette *pal) {
    const COLORREF fill = app->ui_recording ? pal->danger : pal->accent;
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, fill);
    HGDIOBJ old_brush = SelectObject(dc, brush);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    const int radius = (rc.bottom - rc.top); // pill: full-height rounding
    RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, radius, radius);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(brush);
    DeleteObject(pen);

    SetTextColor(dc, app->transcribing ? pal->subtext : pal->button_text);
    DrawTextW(dc, button_label(app), -1, &rc,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
}

static void paint(BooApp *app, HWND hwnd) {
    PAINTSTRUCT ps;
    HDC win_dc = BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);

    // Double buffer: render into a memory DC, blit once. No flicker at 30fps.
    HDC dc = CreateCompatibleDC(win_dc);
    HBITMAP bmp = CreateCompatibleBitmap(win_dc, rc.right, rc.bottom);
    HGDIOBJ old_bmp = SelectObject(dc, bmp);

    const UINT dpi = GetDpiForWindow(hwnd);
    const Palette pal = palette(app->dark);
    const int margin = px(MARGIN, dpi);

    HBRUSH bg = CreateSolidBrush(pal.bg);
    FillRect(dc, &rc, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);

    RECT wave = {margin, margin, rc.right - margin, margin + px(WAVE_H, dpi)};
    int bars = 0;
    const float *waveform = boo_get_waveform(app->ctx, &bars);
    boo_waveform_paint(dc, wave, waveform, bars, boo_get_peak_rms(app->ctx),
                       app->ui_recording ? pal.accent : pal.subtext);

    const RECT button = button_rect(hwnd, dpi);
    RECT status = {margin, button.top - px(STATUS_H + 8, dpi), rc.right - margin,
                   button.top - px(8, dpi)};
    RECT text = {margin, wave.bottom + px(8, dpi), rc.right - margin,
                 status.top - px(4, dpi)};

    HGDIOBJ old_font = SelectObject(dc, font_text);
    SetTextColor(dc, pal.text);
    if (app->transcript[0]) {
        DrawTextW(dc, app->transcript, -1, &text,
                  DT_WORDBREAK | DT_NOPREFIX | DT_END_ELLIPSIS);
    } else if (!app->ui_recording && !app->transcribing) {
        SetTextColor(dc, pal.subtext);
        DrawTextW(dc,
                  app->hotkey_ok ? L"Press Ctrl+Shift+Space to dictate,\nor click Record."
                                 : L"Click Record to dictate.",
                  -1, &text, DT_WORDBREAK | DT_NOPREFIX);
    }

    SelectObject(dc, font_status);
    SetTextColor(dc, pal.subtext);
    DrawTextW(dc, app->status, -1, &status,
              DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);

    SelectObject(dc, font_text);
    paint_button(app, dc, button, &pal);
    SelectObject(dc, old_font);

    BitBlt(win_dc, 0, 0, rc.right, rc.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, old_bmp);
    DeleteObject(bmp);
    DeleteDC(dc);
    EndPaint(hwnd, &ps);
}

// ── input ──

static void on_mouse_down(BooApp *app, HWND hwnd, LPARAM lparam) {
    const POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    const RECT button = button_rect(hwnd, GetDpiForWindow(hwnd));
    if (PtInRect(&button, pt)) {
        button_pressed = true;
        SetCapture(hwnd);
        return;
    }
    // Manual drag: HTCAPTION would enter the modal move loop, which activates
    // a WS_EX_NOACTIVATE window and steals focus from the dictation target.
    dragging = true;
    GetCursorPos(&drag_cursor);
    GetWindowRect(hwnd, &drag_window);
    SetCapture(hwnd);
    (void)app;
}

static void on_mouse_move(HWND hwnd) {
    if (!dragging) return;
    POINT now;
    GetCursorPos(&now);
    SetWindowPos(hwnd, NULL, drag_window.left + (now.x - drag_cursor.x),
                 drag_window.top + (now.y - drag_cursor.y), 0, 0,
                 SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE);
}

static void on_mouse_up(BooApp *app, HWND hwnd, LPARAM lparam) {
    ReleaseCapture();
    dragging = false;
    if (!button_pressed) return;
    button_pressed = false;
    const POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    const RECT button = button_rect(hwnd, GetDpiForWindow(hwnd));
    if (PtInRect(&button, pt)) boo_overlay_toggle_recording(app);
}

static void on_tray_event(BooApp *app, HWND hwnd, WPARAM wparam, LPARAM lparam) {
    switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
        ShowWindow(hwnd, IsWindowVisible(hwnd) ? SW_HIDE : SW_SHOWNOACTIVATE);
        break;
    case WM_CONTEXTMENU: {
        const POINT anchor = {GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)};
        boo_tray_show_menu(hwnd, anchor, app->ui_recording);
        break;
    }
    default:
        break;
    }
}

// ── window proc ──

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == WM_NCCREATE) {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)lparam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    BooApp *app = (BooApp *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (!app) return DefWindowProcW(hwnd, msg, wparam, lparam);

    if (msg == boo_tray_taskbar_created_msg()) {
        boo_tray_add(hwnd); // Explorer restarted; the icon is gone, re-add it
        return 0;
    }

    switch (msg) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE; // mouse hover "active tracking" ignores the style
    case WM_LBUTTONDOWN:
        on_mouse_down(app, hwnd, lparam);
        return 0;
    case WM_MOUSEMOVE:
        on_mouse_move(hwnd);
        return 0;
    case WM_LBUTTONUP:
        on_mouse_up(app, hwnd, lparam);
        return 0;
    case WM_HOTKEY:
        boo_overlay_toggle_recording(app);
        return 0;
    case BOO_MSG_TRAY:
        on_tray_event(app, hwnd, wparam, lparam);
        return 0;
    case BOO_MSG_TRANSCRIBED:
        on_transcribed(app, (char *)lparam);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == BOO_CMD_TOGGLE_RECORD) boo_overlay_toggle_recording(app);
        if (LOWORD(wparam) == BOO_CMD_QUIT) DestroyWindow(hwnd);
        return 0;
    case WM_TIMER:
        if (wparam == BOO_TIMER_WAVEFORM) InvalidateRect(hwnd, NULL, FALSE);
        if (wparam == BOO_TIMER_AUTO_STOP) on_auto_stop_poll(app);
        return 0;
    case WM_PAINT:
        paint(app, hwnd);
        return 0;
    case WM_ERASEBKGND:
        return 1; // the paint path fills everything; skip the flickery erase
    case WM_SETTINGCHANGE:
        if (lparam && wcscmp((const WCHAR *)lparam, L"ImmersiveColorSet") == 0) {
            app->dark = system_dark();
            InvalidateRect(hwnd, NULL, FALSE);
        }
        return 0;
    case WM_DPICHANGED: {
        const RECT *suggested = (const RECT *)lparam;
        make_fonts(HIWORD(wparam));
        SetWindowPos(hwnd, NULL, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOACTIVATE | SWP_NOZORDER);
        return 0;
    }
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE); // tray apps hide; Quit lives in the menu
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, BOO_TIMER_WAVEFORM);
        KillTimer(hwnd, BOO_TIMER_AUTO_STOP);
        boo_hotkey_unregister(hwnd);
        boo_tray_remove(hwnd);
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

HWND boo_overlay_create(BooApp *app) {
    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc),
        .lpfnWndProc = wnd_proc,
        .hInstance = app->hinst,
        .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW),
        .lpszClassName = BOO_OVERLAY_CLASS,
    };
    if (!RegisterClassExW(&wc)) return NULL;

    // NOACTIVATE: never steal focus. TOOLWINDOW: no taskbar button, no
    // Alt-Tab entry; the tray icon is the app's presence. TOPMOST: an overlay
    // you can watch while dictating into another window.
    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                                BOO_OVERLAY_CLASS, L"Boo", WS_POPUP, 0, 0, BASE_W, BASE_H,
                                NULL, NULL, app->hinst, app);
    if (!hwnd) return NULL;
    app->overlay = hwnd;
    app->dark = system_dark();

    const UINT dpi = GetDpiForWindow(hwnd);
    make_fonts(dpi);

    // Rounded corners on Windows 11; a failing HRESULT on Windows 10 just
    // means square corners. Never per-pixel layering or SetWindowRgn, those
    // opt a window out of rounding permanently.
    const DWORD corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));

    // Bottom-right of the primary work area, like a notification.
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    const int w = px(BASE_W, dpi);
    const int h = px(BASE_H, dpi);
    SetWindowPos(hwnd, NULL, work.right - w - px(24, dpi), work.bottom - h - px(24, dpi),
                 w, h, SWP_NOACTIVATE | SWP_NOZORDER);

    return hwnd;
}
