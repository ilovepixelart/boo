// Overlay window. Per the spec, each OS dresses the overlay in its own native
// window controls (mac traffic lights, GTK header bar); on Windows that is the
// standard title bar with the system's native minimize and close buttons. A
// titled window is activatable, so the transcript could land back in Boo if we
// naively targeted the foreground; instead the dictation target is the last
// window from another process to hold focus, tracked by a foreground WinEvent
// hook (last_external_fg).
//
// Visual language mirrors the macOS reference (docs/ui-spec.md): 400x500 client,
// 3-state waveform, a stack of transcript cards with copy/dismiss, a persistent
// ctrl+shift+space hint, and the 40px record disc that morphs from circle
// (radius 20) to rounded square (radius 6) while recording.
//
// Transcription runs on a worker thread (boo_transcribe is synchronous) and
// posts the result back as BOO_MSG_TRANSCRIBED; a second background thread
// polls boo_stream_tick while recording and posts committed text as
// BOO_MSG_LIVE (the provisional dim card).

#include "overlay.h"

#include "history.h"
#include "hotkey.h"
#include "inject.h"
#include "overlay_layout.h"
#include "palette.h"
#include "settings.h"
#include "tray.h"
#include "utf8.h"
#include "waveform.h"

#include <dwmapi.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windowsx.h>

// Not yet in every mingw dwmapi.h; values are ABI, not SDK-version dependent.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

// Base layout in 96-dpi pixels; geometry from the macOS reference.
#define BASE_W 400
#define BASE_H 500
// The spec's height-only resize range (client px at 96 DPI).
#define MIN_H 300
#define MAX_H 800
// THICKFRAME makes the window resizable; WM_GETMINMAXINFO pins the width and
// clamps the height to the spec range.
#define BOO_OVERLAY_STYLE (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_THICKFRAME)
#define MARGIN            12
#define WAVE_TOP          20
#define WAVE_H            48
#define STATUS_H          16
#define BUTTON_SIZE       40
#define CARD_RADIUS       10
#define CARD_GAP          8
#define CARD_PAD_X        12
#define ICON_SIZE         12
// Per-card display cap; the clipboard always carries the full text.
#define CARD_MAX_UNITS 4096

// System-menu command for "Settings"; arrives via WM_SYSCOMMAND. Must be
// < 0xF000 and a multiple of 16 (Windows masks the low nibble).
#define BOO_SC_SETTINGS 0x0010

// GDI/interaction state. One overlay per process (single-instance mutex), so
// module statics are the whole story.
static HFONT font_text;
static HFONT font_mono;
static bool dragging;
static bool button_pressed;
static POINT drag_cursor; // cursor position at drag start, screen coords
static RECT drag_window;  // window rect at drag start
// Record disc corner radius, eased toward its state target each paint tick to
// animate the circle <-> rounded-square morph (reference: 20 <-> 6 over 150ms).
static float button_radius = 20.0f;
// Card hit regions, rebuilt on every paint; index pairs with drawn_card[].
static RECT copy_hit[BOO_HISTORY_MAX];
static RECT close_hit[BOO_HISTORY_MAX];
static int drawn_card[BOO_HISTORY_MAX];
static int drawn_count;
// Copy feedback: which card's copy icon flashes, until this tick count.
static int flash_card = -1;
static ULONGLONG flash_until;
// Dictation target tracking. The overlay is a normal, activatable window, so
// clicking Record can bring Boo to the foreground; this holds the last
// foreground window from another process (the real target), kept current by a
// system-wide foreground WinEvent hook. WINEVENT_SKIPOWNPROCESS excludes Boo's
// own foreground events, so this never becomes the overlay itself.
static HWND last_external_fg;
static HWINEVENTHOOK fg_hook;

// The overlay's colours: a picked theme's tokens, else the system light/dark
// fallback. The mapping itself (slots, luminance-based card fills, the
// #FF3B30 disc, the reference default) is the pure, host-tested boo_palette.
static Palette palette(const BooApp *app) {
    const BooThemeColors *theme =
        app->settings.current_theme >= 0
            ? &app->settings.themes[app->settings.current_theme].colors
            : NULL;
    return boo_palette(theme, app->dark);
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
    if (font_mono) DeleteObject(font_mono);
    font_text = CreateFontW(-boo_px(15, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    // The status/hint line is monospace in the reference.
    font_mono = CreateFontW(-boo_px(12, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, FIXED_PITCH, L"Consolas");
}

static RECT button_rect(HWND hwnd, UINT dpi) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    const int s = boo_px(BUTTON_SIZE, dpi);
    const int x = (rc.right - s) / 2;
    const int y = rc.bottom - boo_px(MARGIN, dpi) - s;
    return (RECT){x, y, x + s, y + s};
}

static void set_status(BooApp *app, const WCHAR *text) {
    wcsncpy(app->status, text, ARRAYSIZE(app->status) - 1);
    app->status[ARRAYSIZE(app->status) - 1] = 0;
}

// The persistent hint the status line rests on when nothing is happening
// (reference: the idle status literally reads the hotkey).
static void set_status_idle(BooApp *app) {
    set_status(app, app->hotkey_ok ? L"ctrl+shift+space" : L"click record to dictate");
}

void boo_overlay_set_status(BooApp *app, const WCHAR *text) {
    set_status(app, text);
}

void boo_overlay_status_idle(BooApp *app) {
    set_status_idle(app);
    InvalidateRect(app->overlay, NULL, FALSE);
}

// ── transcript history ──

// Truncating wide copy of a UTF-8 transcript for display; the clipboard gets
// the full text elsewhere. MultiByteToWideChar leaves the output undefined on
// overflow, so an over-long text is converted from a boundary-aligned prefix.
static WCHAR *card_dup(const char *utf8) {
    WCHAR *out = malloc(CARD_MAX_UNITS * sizeof(WCHAR));
    if (!out) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, CARD_MAX_UNITS) > 0) return out;

    const size_t len = boo_utf8_trunc_len(utf8, CARD_MAX_UNITS - 2);
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, out, CARD_MAX_UNITS - 2);
    if (n < 0) n = 0;
    out[n] = L'…';
    out[n + 1] = 0;
    return out;
}

static void history_push(BooApp *app, const char *utf8) {
    WCHAR *w = card_dup(utf8);
    if (!w) return;
    boo_history_push(app->cards, &app->card_count, BOO_HISTORY_MAX, w);
}

static void history_remove(BooApp *app, int index) {
    boo_history_remove(app->cards, &app->card_count, index);
}

static void live_set(BooApp *app, WCHAR *owned) {
    free(app->live_text);
    app->live_text = owned;
}

// ── recording lifecycle (mirrors the reference and linux/src/overlay_window.c) ──

static DWORD WINAPI transcribe_worker(LPVOID param) {
    BooApp *app = param;
    const char *text = boo_transcribe(app->ctx);
    // The context owns `text`; the UI thread gets its own copy, released in
    // the BOO_MSG_TRANSCRIBED handler. A failed post keeps ownership here.
    char *copy = text ? _strdup(text) : NULL;
    if (!PostMessageW(app->overlay, BOO_MSG_TRANSCRIBED, 0, (LPARAM)copy)) free(copy);
    return 0;
}

// Post the committed-so-far transcript to the UI thread, if there is any.
static void post_live_transcript(BooApp *app) {
    const char *live = boo_get_live_transcript(app->ctx);
    if (!live) return;
    WCHAR *w = card_dup(live);
    if (w && !PostMessageW(app->overlay, BOO_MSG_LIVE, 0, (LPARAM)w)) free(w);
}

// 250ms cadence, one background thread per take (the C API contract): a tick
// is a cheap VAD scan until an utterance ends, then blocks for its inference.
static DWORD WINAPI stream_tick_worker(LPVOID param) {
    BooApp *app = param;
    while (InterlockedCompareExchange(&app->stream_running, 0, 0)) {
        if (boo_stream_tick(app->ctx)) post_live_transcript(app);
        Sleep(250);
    }
    return 0;
}

static void reap_stream_thread(BooApp *app) {
    if (!app->stream_thread) return;
    WaitForSingleObject(app->stream_thread, INFINITE);
    CloseHandle(app->stream_thread);
    app->stream_thread = NULL;
}

static void begin_transcription(BooApp *app) {
    app->ui_recording = false;
    KillTimer(app->overlay, BOO_TIMER_AUTO_STOP);
    // The waveform timer keeps running: it drives the transcribing animation
    // and the button's square->circle morph; BOO_MSG_TRANSCRIBED stops it.

    // Signal the tick thread to wind down without joining here: a tick mid-
    // inference would stall the UI thread. The core serializes tick against
    // boo_transcribe; the handle is reaped before the next take or at exit.
    InterlockedExchange(&app->stream_running, 0);

    boo_stop_recording(app->ctx);
    boo_tray_set_recording(app->overlay, false);

    app->transcribing = true;
    set_status(app, L"thinking...");
    app->worker = CreateThread(NULL, 0, transcribe_worker, app, 0, NULL);
    if (!app->worker) {
        app->transcribing = false;
        set_status(app, L"could not start transcription");
    }
    InvalidateRect(app->overlay, NULL, FALSE);
}

void boo_overlay_toggle_recording(BooApp *app) {
    if (app->transcribing) return; // one take at a time

    if (app->ui_recording) {
        begin_transcription(app);
        return;
    }

    // No microphone: Boo still runs, but recording is a no-op. Say so instead
    // of faking a take the core will not capture.
    if (!boo_has_microphone(app->ctx)) {
        set_status(app, L"no microphone");
        InvalidateRect(app->overlay, NULL, FALSE);
        return;
    }

    // The paste target is whatever the user is dictating into. A Record-button
    // click brings Boo to the foreground, so trust the live foreground only when
    // it is another app; otherwise use the last external window that held focus.
    HWND fg = GetForegroundWindow();
    app->paste_target = (fg && fg != app->overlay) ? fg : last_external_fg;

    boo_warm_up(app->ctx);
    boo_start_recording(app->ctx);
    app->ui_recording = true;
    live_set(app, NULL);
    set_status(app, L"recording...");
    boo_tray_set_recording(app->overlay, true);

    reap_stream_thread(app);
    InterlockedExchange(&app->stream_running, 1);
    app->stream_thread = CreateThread(NULL, 0, stream_tick_worker, app, 0, NULL);

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
    KillTimer(app->overlay, BOO_TIMER_WAVEFORM);
    live_set(app, NULL);

    if (text && *text) {
        history_push(app, text);

        // paste_target may be a destroyed or even recycled HWND by now; safe
        // because delivery only pastes when it still equals the CURRENT
        // foreground window, so the worst case is Ctrl+V landing in the
        // window the user is actually looking at.
        // Auto-type off makes Boo clipboard-only: pass no paste target.
        HWND target = app->settings.auto_type ? app->paste_target : NULL;
        switch (boo_inject_deliver(app->overlay, target, text)) {
        case BOO_DELIVER_PASTED:
            set_status(app, L"copied to clipboard and pasted");
            break;
        case BOO_DELIVER_CLIPBOARD:
            // Also the elevated-window outcome: UIPI silently discards the
            // paste, so tell the user what still works.
            set_status(app, L"copied, press Ctrl+V to paste");
            break;
        case BOO_DELIVER_FAILED:
            set_status(app, L"could not access the clipboard");
            break;
        }
        // Let the confirmation read, then rest on the hint (reference: the
        // idle status is the hotkey).
        SetTimer(app->overlay, BOO_TIMER_STATUS, 2500, NULL);
    } else {
        set_status(app, L"no speech detected");
        SetTimer(app->overlay, BOO_TIMER_STATUS, 2500, NULL);
    }
    free(text);
    InvalidateRect(app->overlay, NULL, FALSE);
}

static void on_live_text(BooApp *app, WCHAR *owned) {
    // A straggler tick can land after stop; the final card supersedes it.
    if (!app->ui_recording) {
        free(owned);
        return;
    }
    live_set(app, owned);
    InvalidateRect(app->overlay, NULL, FALSE);
}

static void on_auto_stop_poll(BooApp *app) {
    if (!app->ui_recording) return;
    if (boo_is_recording(app->ctx)) return;
    set_status(app, L"max length reached");
    begin_transcription(app);
}

// Elapsed seconds into the status line while recording, like the reference.
static void on_waveform_tick(BooApp *app) {
    if (app->ui_recording) {
        const int secs = boo_get_audio_samples(app->ctx) / 16000;
        if (secs > 0) {
            WCHAR buf[16];
            swprintf(buf, ARRAYSIZE(buf), L"%ds", secs);
            set_status(app, buf);
            boo_tray_set_elapsed(app->overlay, secs);
        }
    }
    InvalidateRect(app->overlay, NULL, FALSE);
}

// ── painting ──

static void paint_icon_copy(HDC dc, RECT rc, COLORREF color) {
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;
    // Two overlapping rounded rectangles, the doc.on.doc shape.
    RoundRect(dc, rc.left + w / 4, rc.top, rc.right, rc.bottom - h / 4, 3, 3);
    RoundRect(dc, rc.left, rc.top + h / 4, rc.right - w / 4, rc.bottom, 3, 3);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(pen);
}

static void paint_icon_close(HDC dc, RECT rc, COLORREF color, bool circled) {
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    if (circled) Ellipse(dc, rc.left, rc.top, rc.right, rc.bottom);
    const int inset = (rc.right - rc.left) * 3 / 10;
    MoveToEx(dc, rc.left + inset, rc.top + inset, NULL);
    LineTo(dc, rc.right - inset, rc.bottom - inset);
    MoveToEx(dc, rc.right - inset, rc.top + inset, NULL);
    LineTo(dc, rc.left + inset, rc.bottom - inset);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(pen);
}

static void fill_round(HDC dc, RECT rc, int radius, COLORREF color) {
    HBRUSH brush = CreateSolidBrush(color);
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ old_brush = SelectObject(dc, brush);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, radius * 2, radius * 2);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(brush);
    DeleteObject(pen);
}

// The GDI context and geometry shared by every card in one painted stack.
typedef struct {
    HDC dc;
    const Palette *pal;
    UINT dpi;
    int left;
    int right;
} CardCtx;

// One transcript card; returns its height. When `measure_only`, nothing is
// drawn (used to stack cards bottom-up). `hit` may be -1 for the live card.
static int paint_card(const CardCtx *cc, int top, const WCHAR *text, bool live, int hit,
                      bool measure_only) {
    HDC dc = cc->dc;
    const Palette *pal = cc->pal;
    const UINT dpi = cc->dpi;
    const int left = cc->left;
    const int right = cc->right;
    const int pad_x = boo_px(CARD_PAD_X, dpi);
    const int header_h = live ? 0 : boo_px(BOO_CARD_HEADER_H, dpi);
    RECT text_rc = {left + pad_x, 0, right - pad_x, 0};
    RECT measure = text_rc;
    HGDIOBJ old_font = SelectObject(dc, font_text);
    DrawTextW(dc, text, -1, &measure, DT_WORDBREAK | DT_NOPREFIX | DT_CALCRECT);
    const int text_h = measure.bottom - measure.top;
    const int card_h = boo_card_height(text_h, live, dpi);
    if (measure_only) {
        SelectObject(dc, old_font);
        return card_h;
    }

    RECT card = {left, top, right, top + card_h};
    fill_round(dc, card, boo_px(CARD_RADIUS, dpi), live ? pal->card_live : pal->card);

    if (!live && hit >= 0 && drawn_count < BOO_HISTORY_MAX) {
        const int icon = boo_px(ICON_SIZE, dpi);
        const int inset = boo_px(8, dpi);
        RECT copy_rc = {left + inset, top + boo_px(5, dpi), left + inset + icon,
                        top + boo_px(5, dpi) + icon};
        RECT close_rc = {right - inset - icon, top + boo_px(5, dpi), right - inset,
                         top + boo_px(5, dpi) + icon};
        const bool flashing = hit == flash_card && GetTickCount64() < flash_until;
        // accent.confirm is the theme's palette[14], the same token the idle
        // waveform uses; a hardcoded color would ignore the picked theme.
        paint_icon_copy(dc, copy_rc, flashing ? pal->wave_idle : pal->subtext);
        paint_icon_close(dc, close_rc, pal->subtext, true);
        // Generous hit areas around the small glyphs.
        InflateRect(&copy_rc, boo_px(6, dpi), boo_px(6, dpi));
        InflateRect(&close_rc, boo_px(6, dpi), boo_px(6, dpi));
        copy_hit[drawn_count] = copy_rc;
        close_hit[drawn_count] = close_rc;
        drawn_card[drawn_count] = hit;
        drawn_count++;

        // Hairline separator under the header.
        RECT sep = {left + inset, top + header_h + boo_px(2, dpi), right - inset,
                    top + header_h + boo_px(3, dpi)};
        HBRUSH sep_brush =
            CreateSolidBrush(boo_color_mix(pal->subtext, pal->card, 0.35f));
        FillRect(dc, &sep, sep_brush);
        DeleteObject(sep_brush);
    }

    text_rc.top = top + header_h + (live ? boo_px(8, dpi) : boo_px(11, dpi));
    text_rc.bottom = text_rc.top + text_h;
    SetTextColor(dc, live ? pal->subtext : pal->text);
    DrawTextW(dc, text, -1, &text_rc, DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, old_font);
    return card_h;
}

// Stack cards chronologically from the top of `area` downward, matching the
// reference (a flipped scroll view with the stack pinned to the top): with room
// to spare the cards sit just under the waveform. When the area is full the
// newest still wins, older cards fall off the top, mirroring scroll-to-newest.
static void paint_cards(HDC dc, BooApp *app, const Palette *pal, UINT dpi, RECT area) {
    drawn_count = 0;
    const int gap = boo_px(CARD_GAP, dpi);
    const CardCtx cc = {dc, pal, dpi, area.left, area.right};

    int heights[BOO_HISTORY_MAX + 1];
    const int cap = (int)(sizeof(heights) / sizeof(heights[0]));
    int idx = 0;
    // Bound by the array size as well as card_count: the write index is then
    // provably in range even if card_count were ever off (history_push caps it).
    for (int i = 0; i < app->card_count && idx < cap; i++)
        heights[idx++] = paint_card(&cc, 0, app->cards[i], false, i, true);
    if (app->live_text && idx < cap)
        heights[idx++] = paint_card(&cc, 0, app->live_text, true, -1, true);
    const int total = idx;

    // The core picks which newest cards fit and where they sit; this only draws.
    BooCardSlot slots[BOO_HISTORY_MAX + 1];
    const int n = boo_cards_layout(heights, total, gap, area.top, area.bottom - area.top,
                                   slots, cap);
    for (int s = 0; s < n; s++) {
        const int i = slots[s].index;
        const bool live = app->live_text && i == total - 1;
        const WCHAR *text = live ? app->live_text : app->cards[i];
        paint_card(&cc, slots[s].top, text, live, live ? -1 : i, false);
    }
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
    const Palette pal = palette(app);
    const int margin = boo_px(MARGIN, dpi);

    HBRUSH bg = CreateSolidBrush(pal.bg);
    FillRect(dc, &rc, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);

    // Waveform: idle dim cyan, recording red, transcribing orange breathing.
    RECT wave = {margin, boo_px(WAVE_TOP, dpi), rc.right - margin,
                 boo_px(WAVE_TOP, dpi) + boo_px(WAVE_H, dpi)};
    int bars = 0;
    const float *waveform = boo_get_waveform(app->ctx, &bars);
    BooWaveState wstate = BOO_WAVE_IDLE;
    COLORREF wcolor = pal.wave_idle;
    if (app->ui_recording) {
        wstate = BOO_WAVE_RECORDING;
        wcolor = pal.wave_rec;
    } else if (app->transcribing) {
        wstate = BOO_WAVE_TRANSCRIBING;
        wcolor = pal.wave_think;
    }
    const BooWavePaint wp = {waveform,
                             bars,
                             boo_get_peak_rms(app->ctx),
                             wstate,
                             wcolor,
                             pal.bg,
                             (float)(GetTickCount64() % 100000) / 1000.0f};
    boo_waveform_paint(dc, wave, &wp);

    // Record disc: ease the corner radius toward its state target; ~0.4/tick
    // at 33ms settles in about 150ms, the reference's animation length.
    const RECT button = button_rect(hwnd, dpi);
    const float target = app->ui_recording ? 6.0f : 20.0f;
    button_radius += (target - button_radius) * 0.4f;
    fill_round(dc, button, boo_px((int)(button_radius + 0.5f), dpi), pal.record);

    // Status line above the button: hint / recording / elapsed / thinking.
    RECT status = {margin, button.top - boo_px(STATUS_H + 8, dpi), rc.right - margin,
                   button.top - boo_px(6, dpi)};
    HGDIOBJ old_font = SelectObject(dc, font_mono);
    SetTextColor(dc, pal.subtext);
    DrawTextW(dc, app->status, -1, &status,
              DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    SelectObject(dc, old_font);

    // Transcript cards fill the middle.
    RECT cards = {margin, wave.bottom + boo_px(CARD_GAP, dpi), rc.right - margin,
                  status.top - boo_px(CARD_GAP, dpi)};
    paint_cards(dc, app, &pal, dpi, cards);

    BitBlt(win_dc, 0, 0, rc.right, rc.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, old_bmp);
    DeleteObject(bmp);
    DeleteDC(dc);
    EndPaint(hwnd, &ps);
}

// ── input ──

static void copy_card_to_clipboard(BooApp *app, int index) {
    if (index < 0 || index >= app->card_count) return;
    // The shared setter, retries included: a clipboard-manager collision must
    // not make the copy button silently do nothing.
    if (!boo_clipboard_set_wide(app->overlay, app->cards[index])) return;

    // Flash the copy icon, the reference's 0.5s confirmation.
    flash_card = index;
    flash_until = GetTickCount64() + 500;
    InvalidateRect(app->overlay, NULL, FALSE);
    // Its own timer id, not BOO_TIMER_STATUS: reusing that one would replace an
    // in-flight "copied and pasted" settle (SetTimer resets a same-id timer),
    // clearing the confirmation ~1.9s early.
    SetTimer(app->overlay, BOO_TIMER_FLASH, 600, NULL); // repaint to unflash
}

// Returns true when the click landed on an interactive element.
static bool handle_click(BooApp *app, HWND hwnd, POINT pt) {
    for (int i = 0; i < drawn_count; i++) {
        if (PtInRect(&copy_hit[i], pt)) {
            copy_card_to_clipboard(app, drawn_card[i]);
            return true;
        }
        if (PtInRect(&close_hit[i], pt)) {
            history_remove(app, drawn_card[i]);
            InvalidateRect(hwnd, NULL, FALSE);
            return true;
        }
    }
    return false;
}

static bool over_interactive(HWND hwnd, POINT pt) {
    const RECT button = button_rect(hwnd, GetDpiForWindow(hwnd));
    if (PtInRect(&button, pt)) return true;
    for (int i = 0; i < drawn_count; i++)
        if (PtInRect(&copy_hit[i], pt) || PtInRect(&close_hit[i], pt)) return true;
    return false;
}

static void on_mouse_down(BooApp *app, HWND hwnd, LPARAM lparam) {
    const POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (over_interactive(hwnd, pt)) {
        button_pressed = true;
        SetCapture(hwnd);
        return;
    }
    // Drag by the body too, not just the title bar: SWP_NOACTIVATE keeps the
    // move from disturbing the z-order or focus.
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
    if (handle_click(app, hwnd, pt)) return;
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

static void on_timer(BooApp *app, HWND hwnd, WPARAM id) {
    if (id == BOO_TIMER_WAVEFORM) on_waveform_tick(app);
    if (id == BOO_TIMER_AUTO_STOP) on_auto_stop_poll(app);
    if (id == BOO_TIMER_STATUS) {
        KillTimer(hwnd, BOO_TIMER_STATUS);
        if (!app->ui_recording && !app->transcribing) set_status_idle(app);
        InvalidateRect(hwnd, NULL, FALSE);
    }
    if (id == BOO_TIMER_FLASH) {
        // The copy flash has expired; repaint so the paint's flash_until gate
        // drops it. Status settling is BOO_TIMER_STATUS's separate job.
        KillTimer(hwnd, BOO_TIMER_FLASH);
        InvalidateRect(hwnd, NULL, FALSE);
    }
}

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
    case WM_GETMINMAXINFO: {
        // The spec's height-only resize: clamp the client height to
        // MIN_H..MAX_H and pin the width by making min and max agree.
        const UINT dpi = GetDpiForWindow(hwnd);
        MINMAXINFO *mmi = (MINMAXINFO *)lparam;
        RECT min_rc = {0, 0, boo_px(BASE_W, dpi), boo_px(MIN_H, dpi)};
        RECT max_rc = {0, 0, boo_px(BASE_W, dpi), boo_px(MAX_H, dpi)};
        AdjustWindowRectExForDpi(&min_rc, BOO_OVERLAY_STYLE, FALSE, WS_EX_TOPMOST, dpi);
        AdjustWindowRectExForDpi(&max_rc, BOO_OVERLAY_STYLE, FALSE, WS_EX_TOPMOST, dpi);
        mmi->ptMinTrackSize.x = min_rc.right - min_rc.left;
        mmi->ptMinTrackSize.y = min_rc.bottom - min_rc.top;
        mmi->ptMaxTrackSize.x = min_rc.right - min_rc.left; // width fixed
        mmi->ptMaxTrackSize.y = max_rc.bottom - max_rc.top;
        return 0;
    }
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
    case BOO_MSG_LIVE:
        on_live_text(app, (WCHAR *)lparam);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == BOO_CMD_TOGGLE_RECORD) boo_overlay_toggle_recording(app);
        if (LOWORD(wparam) == BOO_CMD_QUIT) DestroyWindow(hwnd);
        if (LOWORD(wparam) == BOO_CMD_SETTINGS) boo_settings_open(app);
        return 0;
    case WM_SYSCOMMAND:
        // The custom "Settings" item added to the window's system menu.
        if ((wparam & 0xFFF0) == BOO_SC_SETTINGS) {
            boo_settings_open(app);
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    case WM_TIMER:
        on_timer(app, hwnd, wparam);
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
    case BOO_MSG_DL_PROGRESS:
        return 0; // the background VAD fetch; nothing to show
    case BOO_MSG_DL_DONE: {
        // The background VAD fetch (main.c) reporting in; on success
        // streaming starts working mid-session, exactly like macOS/Linux.
        char *text = (char *)lparam;
        if (wparam && text && app && app->ctx && boo_load_vad(app->ctx, text))
            boo_log(BOO_LOG_INFO, "streaming transcription enabled");
        free(text);
        return 0;
    }
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE); // tray apps hide; Quit lives in the tray menu
        return 0;
    case WM_DESTROY:
        if (fg_hook) {
            UnhookWinEvent(fg_hook);
            fg_hook = NULL;
        }
        KillTimer(hwnd, BOO_TIMER_WAVEFORM);
        KillTimer(hwnd, BOO_TIMER_AUTO_STOP);
        KillTimer(hwnd, BOO_TIMER_STATUS);
        KillTimer(hwnd, BOO_TIMER_FLASH);
        InterlockedExchange(&app->stream_running, 0);
        boo_hotkey_unregister(hwnd);
        boo_tray_remove(hwnd);
        boo_settings_free(app);
        // The DPI-scaled fonts are otherwise only replaced on the next DPI
        // change, so they leak at teardown; release them here.
        if (font_text) {
            DeleteObject(font_text);
            font_text = NULL;
        }
        if (font_mono) {
            DeleteObject(font_mono);
            font_mono = NULL;
        }
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

static void CALLBACK on_foreground_changed(HWINEVENTHOOK hook, DWORD event, HWND hwnd,
                                           LONG obj, LONG child, DWORD thread,
                                           DWORD time) {
    (void)hook, (void)event, (void)child, (void)thread, (void)time;
    if (obj == OBJID_WINDOW && hwnd) last_external_fg = hwnd;
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

    // A normal top-level window, so it carries the platform's native title bar
    // with minimize and close (the spec's per-OS window controls). TOPMOST
    // keeps the overlay watchable over the app you dictate into. It is
    // activatable now, so the dictation target is tracked separately (see
    // last_external_fg) instead of relying on the window never taking focus.
    HWND hwnd =
        CreateWindowExW(WS_EX_TOPMOST, BOO_OVERLAY_CLASS, L"Boo", BOO_OVERLAY_STYLE, 0, 0,
                        BASE_W, BASE_H, NULL, NULL, app->hinst, app);
    if (!hwnd) return NULL;
    app->overlay = hwnd;
    fg_hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL,
                              on_foreground_changed, 0, 0,
                              WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    app->dark = system_dark();
    set_status_idle(app);

    // A "Settings" entry at the top of the window's system menu (title-bar icon
    // / Alt+Space), the keyboard-reachable twin of the tray menu item.
    HMENU sysmenu = GetSystemMenu(hwnd, FALSE);
    if (sysmenu) {
        InsertMenuW(sysmenu, 0, MF_BYPOSITION | MF_STRING, BOO_SC_SETTINGS, L"Settings…");
        InsertMenuW(sysmenu, 1, MF_BYPOSITION | MF_SEPARATOR, 0, NULL);
    }

    // Load every theme + the persisted prefs, then apply the saved opacity (the
    // saved theme is picked up by the first paint via palette()).
    boo_settings_init(app);
    boo_settings_apply(app);

    const UINT dpi = GetDpiForWindow(hwnd);
    make_fonts(dpi);

    // Rounded corners on Windows 11; a failing HRESULT on Windows 10 just
    // means square corners. Never per-pixel layering or SetWindowRgn, those
    // opt a window out of rounding permanently.
    const DWORD corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));

    // Top-right of the primary work area, like the reference. Grow the window
    // by the title bar so the CLIENT area stays BASE_W x BASE_H.
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    RECT wr = {0, 0, boo_px(BASE_W, dpi), boo_px(BASE_H, dpi)};
    AdjustWindowRectExForDpi(&wr, BOO_OVERLAY_STYLE, FALSE, WS_EX_TOPMOST, dpi);
    const int w = wr.right - wr.left;
    const int h = wr.bottom - wr.top;
    SetWindowPos(hwnd, NULL, work.right - w - boo_px(20, dpi), work.top + boo_px(50, dpi),
                 w, h, SWP_NOACTIVATE | SWP_NOZORDER);

    return hwnd;
}
