// Notification-area icon via Shell_NotifyIcon, version-4 semantics: the shell
// posts BOO_MSG_TRAY with the event in LOWORD(lParam) and the anchor point in
// wParam, instead of raw mouse messages.

#include "tray.h"

#include "resource.h"

#include <shellapi.h>
#include <string.h>

#define BOO_TRAY_ID 1

static NOTIFYICONDATAW tray_data(HWND hwnd) {
    NOTIFYICONDATAW nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = BOO_TRAY_ID;
    return nid;
}

bool boo_tray_add(HWND hwnd) {
    NOTIFYICONDATAW nid = tray_data(hwnd);
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    nid.uCallbackMessage = BOO_MSG_TRAY;
    nid.hIcon = LoadIconW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(IDI_BOO));
    wcscpy(nid.szTip, L"Boo");
    if (!Shell_NotifyIconW(NIM_ADD, &nid)) return false;

    // Version must be (re)declared after every NIM_ADD; it is not persisted.
    nid.uVersion = NOTIFYICON_VERSION_4;
    return Shell_NotifyIconW(NIM_SETVERSION, &nid);
}

void boo_tray_remove(HWND hwnd) {
    NOTIFYICONDATAW nid = tray_data(hwnd);
    Shell_NotifyIconW(NIM_DELETE, &nid);
}

void boo_tray_set_recording(HWND hwnd, bool recording) {
    NOTIFYICONDATAW nid = tray_data(hwnd);
    nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    wcscpy(nid.szTip, recording ? L"Boo, recording" : L"Boo");
    Shell_NotifyIconW(NIM_MODIFY, &nid);
}

UINT boo_tray_taskbar_created_msg(void) {
    // Registered once per process; RegisterWindowMessage returns the same id
    // for the same string, which is how Explorer's broadcast finds us.
    static UINT msg = 0;
    if (msg == 0) msg = RegisterWindowMessageW(L"TaskbarCreated");
    return msg;
}

void boo_tray_show_menu(HWND hwnd, POINT anchor, bool recording) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    AppendMenuW(menu, MF_STRING, BOO_CMD_TOGGLE_RECORD,
                recording ? L"Stop recording" : L"Start recording");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, BOO_CMD_QUIT, L"Quit Boo");

    // TrackPopupMenu contract: the window must be foreground or the menu will
    // not dismiss on an outside click, and a WM_NULL afterwards works around
    // the matching shell quirk. Side effect: this activates the overlay, so a
    // recording stopped from this menu delivers clipboard-only (the paste
    // target is no longer foreground), which is the intended safe behavior.
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, anchor.x, anchor.y, 0, hwnd, NULL);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
}
