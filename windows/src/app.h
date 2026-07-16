// Shared state and message ids for the Boo Windows apprt.
#ifndef BOO_APP_H
#define BOO_APP_H

// Win10 API surface (NIN_SELECT, per-monitor DPI, DWM attributes).
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef _WIN32_IE
#define _WIN32_IE 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdbool.h>

#include "boo.h"

// Window-message space private to Boo's own windows.
#define BOO_MSG_TRAY        (WM_APP + 1) // tray callback (NOTIFYICON_VERSION_4)
#define BOO_MSG_TRANSCRIBED (WM_APP + 2) // worker -> UI; lParam = malloc'd UTF-8
#define BOO_MSG_LIVE        (WM_APP + 3) // stream tick -> UI; lParam = malloc'd UTF-8

// Transcript history depth (the macOS reference keeps a session-long stack; a
// bounded one keeps the unscrolled card list honest).
#define BOO_HISTORY_MAX 8

// Timer ids on the overlay window.
#define BOO_TIMER_WAVEFORM  1
#define BOO_TIMER_AUTO_STOP 2
#define BOO_TIMER_STATUS    3 // one-shot: settle the status line back to idle

// Tray menu command ids.
#define BOO_CMD_TOGGLE_RECORD 100
#define BOO_CMD_QUIT          101

typedef struct BooApp {
    BooContext *ctx;
    HINSTANCE hinst;
    HWND overlay;

    // The UI's own view of whether we're recording. Deliberately not
    // boo_is_recording(): the core clears that when it hits the recording cap.
    bool ui_recording;
    bool transcribing;

    // Where the transcript should land: the window that was foreground when
    // recording started. NULL when there was none worth targeting.
    HWND paste_target;

    HANDLE worker; // transcription thread, NULL when idle

    // Streaming: one background thread polls boo_stream_tick while recording
    // (the C API contract), posting committed text back as BOO_MSG_LIVE.
    HANDLE stream_thread;         // NULL == no thread to join
    volatile LONG stream_running; // atomic stop signal

    bool hotkey_ok;
    bool dark;         // follow the system Apps theme
    WCHAR status[160]; // one-line status under the record button

    // Transcript history, chronological; cards[0] is the oldest. Each entry is
    // malloc'd. live_text is the provisional streaming card, dimmer than the
    // history cards and replaced by the final transcript on stop.
    WCHAR *cards[BOO_HISTORY_MAX];
    int card_count;
    WCHAR *live_text; // malloc'd, NULL when absent
} BooApp;

#endif // BOO_APP_H
