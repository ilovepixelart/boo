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

    PostMessageW(overlay, WM_COMMAND, BOO_CMD_SETTINGS, 0);
    HWND dlg = wait_for(BOO_SETTINGS_CLASS, 10000);
    if (dlg) {
        Sleep(300);
        poke_settings(dlg);
        Sleep(300);
        PostMessageW(dlg, WM_CLOSE, 0, 0);
        Sleep(300);
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
