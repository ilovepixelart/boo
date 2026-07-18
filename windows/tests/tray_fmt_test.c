// Host-runnable tests for the pure tray tooltip formatter (tray_fmt.c). No
// windows.h, so it runs on the Linux/macOS CI runners too:
//
//   cc -I include -I windows/src windows/tests/tray_fmt_test.c
//      windows/src/tray_fmt.c -o tray_fmt_test && ./tray_fmt_test
//
// What it pins: seconds under a minute read "Ns", a minute crosses to "M:SS"
// with a zero-padded seconds field, and the boundary is exactly 60.

#include "tray_fmt.h"

#include <stdio.h>
#include <wchar.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    wchar_t buf[64];

    boo_tray_elapsed_tip(buf, 64, 0);
    check(wcscmp(buf, L"Boo, recording 0s") == 0, "zero seconds is 0s");
    boo_tray_elapsed_tip(buf, 64, 5);
    check(wcscmp(buf, L"Boo, recording 5s") == 0, "under a minute reads Ns");
    boo_tray_elapsed_tip(buf, 64, 59);
    check(wcscmp(buf, L"Boo, recording 59s") == 0, "59 is the last Ns");
    boo_tray_elapsed_tip(buf, 64, 60);
    check(wcscmp(buf, L"Boo, recording 1:00") == 0, "60 crosses to M:SS");
    boo_tray_elapsed_tip(buf, 64, 125);
    check(wcscmp(buf, L"Boo, recording 2:05") == 0,
          "125 is 2:05 with a zero-padded seconds field");

    printf(failures ? "tray_fmt_test: FAIL\n" : "tray_fmt_test: ok\n");
    return failures ? 1 : 0;
}
