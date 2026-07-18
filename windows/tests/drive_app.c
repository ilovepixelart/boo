// Coverage smoke driver: pokes a LIVE instrumented boo-app.exe from outside,
// the Windows twin of linux/tests/ui-smoke.sh. Never linked into the app and
// never instrumented itself; scripts/coverage.sh (windows-native section)
// launches the app, runs one scenario here, and the app's clean exit flushes
// the gcov counters.
//
//   drive_app onboarding   close the first-run dialog (quit-without-a-model)
//   drive_app main         toggle record, open/poke/close Settings, quit
//
// Exit 0 when the scenario ran; 1 when an expected window never appeared.

#include "app.h"
#include "onboarding.h"
#include "overlay.h"
#include "settings.h"

#include <commctrl.h>
#include <shellapi.h> // NIN_SELECT, excluded by WIN32_LEAN_AND_MEAN
#include <stdio.h>
#include <string.h>

// overlay.c keeps BOO_SC_SETTINGS private; mirror its value to drive the
// system-menu Settings item (WM_SYSCOMMAND). Kept a multiple of 16 and below
// 0xF000, like the source.
#define BOO_SC_SETTINGS 0x0010

// The app needs seconds to load a model before its windows exist.
static HWND wait_for(const WCHAR *class_name, int timeout_ms) {
    for (int waited = 0; waited < timeout_ms; waited += 200) {
        HWND win = FindWindowW(class_name, NULL);
        if (win) return win;
        Sleep(200);
    }
    return NULL;
}

static int drive_onboarding(void) {
    HWND dlg = wait_for(BOO_ONBOARDING_CLASS, 30000);
    if (!dlg) {
        fprintf(stderr, "drive_app: onboarding dialog never appeared\n");
        return 1;
    }
    Sleep(500);

    // A progress tick then a failed download with no reason: the messages the
    // download worker posts, driving onboarding's progress and failure-recovery
    // branches without a network round-trip. A success (wparam=1) would boot the
    // app on a bogus path and pop a modal, so only the failure lands here.
    PostMessageW(dlg, BOO_MSG_DL_PROGRESS, 40, 0);
    Sleep(200);
    PostMessageW(dlg, BOO_MSG_DL_DONE, 0, 0);
    Sleep(200);

    PostMessageW(dlg, WM_CLOSE, 0, 0);
    return 0;
}

static void poke_settings(HWND dlg) {
    // Auto-type: click twice so the persisted pref lands where it started.
    HWND check = GetDlgItem(dlg, IDC_AUTOTYPE);
    if (check) {
        SendMessageW(check, BM_CLICK, 0, 0);
        SendMessageW(check, BM_CLICK, 0, 0);
    }

    // Theme: select the first entry and notify, as a real click would.
    HWND list = GetDlgItem(dlg, IDC_THEMES);
    if (list && SendMessageW(list, LB_GETCOUNT, 0, 0) > 0) {
        SendMessageW(list, LB_SETCURSEL, 0, 0);
        SendMessageW(dlg, WM_COMMAND, MAKEWPARAM(IDC_THEMES, LBN_SELCHANGE),
                     (LPARAM)list);
    }

    // Opacity: 80% then back to 100%, driving both boo_settings_apply branches
    // (the layered translucent window, then dropping WS_EX_LAYERED when opaque).
    HWND slider = GetDlgItem(dlg, IDC_OPACITY);
    if (slider) {
        SendMessageW(slider, TBM_SETPOS, TRUE, 80);
        SendMessageW(dlg, WM_HSCROLL, TB_THUMBTRACK, (LPARAM)slider);
        SendMessageW(slider, TBM_SETPOS, TRUE, 100);
        SendMessageW(dlg, WM_HSCROLL, TB_THUMBTRACK, (LPARAM)slider);
    }

    // Model: re-pick the current selection; the switcher's same-model early
    // return keeps this a no-op swap.
    HWND combo = GetDlgItem(dlg, IDC_MODEL);
    if (combo)
        SendMessageW(dlg, WM_COMMAND, MAKEWPARAM(IDC_MODEL, CBN_SELCHANGE),
                     (LPARAM)combo);

    // A download-progress tick, the message the download worker posts while a
    // tagged model fetches; drives the progress-bar handler. The DL_DONE twin
    // is not posted here: on failure it pops a modal, and success carries a
    // cross-process path pointer.
    PostMessageW(dlg, BOO_MSG_DL_PROGRESS, 50, 0);
}

// Drive the overlay's own input handlers, all headless-safe: no message here
// carries a cross-process pointer, and none needs a microphone. Coordinates
// come from the live client rect so they track the window's actual size.
static void poke_overlay(HWND overlay) {
    RECT rc;
    if (!GetClientRect(overlay, &rc)) return;
    const int cx = rc.right / 2;
    const int body = rc.bottom / 3;

    // Body drag: press off every interactive element, slide, release. Covers
    // the mouse-down drag branch, the move handler, and the up handler.
    PostMessageW(overlay, WM_LBUTTONDOWN, 0, MAKELPARAM(cx, body));
    Sleep(50);
    PostMessageW(overlay, WM_MOUSEMOVE, 0, MAKELPARAM(cx + 8, body + 8));
    Sleep(50);
    PostMessageW(overlay, WM_LBUTTONUP, 0, MAKELPARAM(cx + 8, body + 8));
    Sleep(50);

    // Record disc: press and release on the button so the click lands on an
    // interactive element (over_interactive, handle_click, then the toggle).
    // Its centre sits MARGIN + BUTTON_SIZE/2 up from the client bottom, per
    // overlay.c's button_rect; at the CI default 96 DPI this is exact.
    const int by = rc.bottom - MulDiv(32, (int)GetDpiForWindow(overlay), 96);
    PostMessageW(overlay, WM_LBUTTONDOWN, 0, MAKELPARAM(cx, by));
    Sleep(50);
    PostMessageW(overlay, WM_LBUTTONUP, 0, MAKELPARAM(cx, by));
    Sleep(50);

    // Timer ticks the message loop would deliver: with no microphone the record
    // path never arms them, so post each id to drive on_timer's headless
    // branches (the idle waveform, the auto-stop poll, settle-to-idle).
    PostMessageW(overlay, WM_TIMER, BOO_TIMER_WAVEFORM, 0);
    PostMessageW(overlay, WM_TIMER, BOO_TIMER_AUTO_STOP, 0);
    PostMessageW(overlay, WM_TIMER, BOO_TIMER_STATUS, 0);
    Sleep(50);

    // A settings broadcast with no area string: exercises the handler and its
    // guard. The ImmersiveColorSet re-eval needs a string lParam, which a
    // cross-process post cannot carry, so that branch stays for the live app.
    PostMessageW(overlay, WM_SETTINGCHANGE, 0, 0);
    Sleep(50);

    // The transcription and streaming-result handlers with a NULL payload. A
    // real transcript pointer cannot cross the process boundary, so this drives
    // their dispatch and empty-result branches (on_transcribed's worker cleanup
    // and "no speech detected"; on_live_text's post-stop straggler drop). The
    // card push and paste delivery stay for the live app, which posts these
    // in-process with real text after an actual transcription.
    PostMessageW(overlay, BOO_MSG_TRANSCRIBED, 0, 0);
    PostMessageW(overlay, BOO_MSG_LIVE, 0, 0);
    Sleep(50);
}

static int drive_main(void) {
    HWND overlay = wait_for(BOO_OVERLAY_CLASS, 60000);
    if (!overlay) {
        fprintf(stderr, "drive_app: overlay never appeared\n");
        return 1;
    }
    Sleep(1000);

    // Record toggle both ways; without a microphone this exercises the
    // status paths, with one it records half a second of silence.
    PostMessageW(overlay, WM_COMMAND, BOO_CMD_TOGGLE_RECORD, 0);
    Sleep(500);
    PostMessageW(overlay, WM_COMMAND, BOO_CMD_TOGGLE_RECORD, 0);
    Sleep(500);

    // The same toggle through the hotkey path (WM_HOTKEY), the third trigger
    // alongside the tray and the button.
    PostMessageW(overlay, WM_HOTKEY, 0, 0);
    Sleep(500);
    PostMessageW(overlay, WM_HOTKEY, 0, 0);
    Sleep(500);

    // Maximize/restore so the sizing path asks for WM_GETMINMAXINFO, which pins
    // the width and clamps the height to the spec range.
    PostMessageW(overlay, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
    Sleep(300);
    PostMessageW(overlay, WM_SYSCOMMAND, SC_RESTORE, 0);
    Sleep(300);

    // Tray single-select toggles the overlay's visibility (hide, then show).
    PostMessageW(overlay, BOO_MSG_TRAY, 0, MAKELPARAM(NIN_SELECT, 0));
    Sleep(300);
    PostMessageW(overlay, BOO_MSG_TRAY, 0, MAKELPARAM(NIN_SELECT, 0));
    Sleep(300);

    poke_overlay(overlay);

    PostMessageW(overlay, WM_COMMAND, BOO_CMD_SETTINGS, 0);
    HWND dlg = wait_for(BOO_SETTINGS_CLASS, 10000);
    if (dlg) {
        Sleep(300);
        // Re-issue the open while the dialog lives: covers the "already open,
        // just focus it" early return in boo_settings_open.
        PostMessageW(overlay, WM_COMMAND, BOO_CMD_SETTINGS, 0);
        Sleep(200);
        poke_settings(dlg);
        Sleep(300);
        PostMessageW(dlg, WM_CLOSE, 0, 0);
        Sleep(300);

        // Reopen through the window's system menu (Alt+Space > Settings), the
        // WM_SYSCOMMAND twin of the tray/command open.
        PostMessageW(overlay, WM_SYSCOMMAND, BOO_SC_SETTINGS, 0);
        HWND sys_dlg = wait_for(BOO_SETTINGS_CLASS, 10000);
        if (sys_dlg) {
            Sleep(200);
            PostMessageW(sys_dlg, WM_CLOSE, 0, 0);
            Sleep(200);
        }
    }

    // Let the background VAD fetch usually finish so BOO_MSG_DL_DONE lands
    // while the overlay is alive; coverage stays honest either way.
    Sleep(8000);

    // Close hides a tray app rather than quitting; Quit is what tears it down.
    PostMessageW(overlay, WM_CLOSE, 0, 0);
    Sleep(300);
    PostMessageW(overlay, WM_COMMAND, BOO_CMD_QUIT, 0);
    return dlg ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "onboarding") == 0) return drive_onboarding();
    if (argc == 2 && strcmp(argv[1], "main") == 0) return drive_main();
    fprintf(stderr, "usage: drive_app onboarding|main\n");
    return 2;
}
