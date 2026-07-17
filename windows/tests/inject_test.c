// Native-runner tests for clipboard delivery (inject.c) plus the app.h inline
// helpers. Includes the source under test so its statics are reachable. The
// paste chord itself is pinned host-side by inject_plan_test; what runs here
// is the real clipboard round-trip and the delivery decision tree.

#include "inject.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Read CF_UNICODETEXT back and compare; the set/get pair proves the clipboard
// actually holds what boo_clipboard_set_wide put there.
static bool clipboard_equals(HWND owner, const WCHAR *expected) {
    bool same = false;
    if (!OpenClipboard(owner)) return false;
    HANDLE mem = GetClipboardData(CF_UNICODETEXT);
    if (mem) {
        const WCHAR *text = GlobalLock(mem);
        if (text) {
            same = wcscmp(text, expected) == 0;
            GlobalUnlock(mem);
        }
    }
    CloseClipboard();
    return same;
}

int main(void) {
    printf("inject_test:\n");

    // Real windows: SetClipboardData needs an owning hwnd (see inject.c).
    HWND owner = CreateWindowExW(0, L"STATIC", L"boo-inject-owner", WS_OVERLAPPEDWINDOW,
                                 0, 0, 80, 60, NULL, NULL, NULL, NULL);
    check(owner != NULL, "owner window created");

    check(boo_clipboard_set_wide(owner, L"boo wide \x00e9"), "wide clipboard set");
    check(clipboard_equals(owner, L"boo wide \x00e9"), "wide text round-trips");

    // UTF-8 entry point: the e-acute must survive the CP_UTF8 conversion.
    check(clipboard_set(owner, "boo utf8 \xc3\xa9"), "utf8 clipboard set");
    check(clipboard_equals(owner, L"boo utf8 \x00e9"), "utf8 text round-trips");

    // No target / self target: clipboard-only, never a synthetic chord.
    check(boo_inject_deliver(owner, NULL, "x") == BOO_DELIVER_CLIPBOARD,
          "no target stays clipboard-only");
    check(boo_inject_deliver(owner, owner, "x") == BOO_DELIVER_CLIPBOARD,
          "self target stays clipboard-only");

    // A real foreground target: the chord path. CI may refuse foreground
    // activation, so assert consistency with what the OS actually did rather
    // than a fixed outcome; either way delivery must not fail.
    HWND target = CreateWindowExW(0, L"STATIC", L"boo-inject-target",
                                  WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 80, 60, NULL,
                                  NULL, NULL, NULL);
    check(target != NULL, "target window created");
    SetForegroundWindow(target);
    const BooDeliverResult res = boo_inject_deliver(owner, target, "chord");
    check(res != BOO_DELIVER_FAILED, "delivery with a target never fails");
    check(GetForegroundWindow() == target ? res == BOO_DELIVER_PASTED
                                          : res == BOO_DELIVER_CLIPBOARD,
          "result matches where the foreground actually was");

    // app.h helpers. boo_px: 96-dpi base scaled per monitor.
    check(boo_px(100, 96) == 100, "boo_px identity at 96 dpi");
    check(boo_px(100, 192) == 200, "boo_px doubles at 192 dpi");

    // boo_dialog_freeze flips the listed controls and the close item.
    HWND child = CreateWindowExW(0, L"BUTTON", L"b", WS_CHILD | WS_VISIBLE, 0, 0, 40, 20,
                                 owner, (HMENU)(INT_PTR)123, NULL, NULL);
    check(child != NULL, "child control created");
    static const int ids[] = {123};
    boo_dialog_freeze(owner, ids, 1, true);
    check(!IsWindowEnabled(child), "freeze disables the control");
    boo_dialog_freeze(owner, ids, 1, false);
    check(IsWindowEnabled(child), "thaw re-enables the control");

    DestroyWindow(target);
    DestroyWindow(owner);
    printf("inject_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
