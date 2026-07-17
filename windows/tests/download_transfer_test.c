// Native-runner test that drives the REAL download worker end to end
// (boo_download_start -> download_worker -> fetch) through a message-only
// window, the same BOO_MSG_DL_PROGRESS/DL_DONE contract the onboarding and
// settings dialogs receive. Includes the source under test so its statics are
// reachable. What this covers beyond download_test.c: the worker's path
// building, CNG hash setup, .part creation and its teardown, boo_download_start
// itself, and fetch's connect/open/send handling with the failure cleanup.
//
// fetch pins WINHTTP_FLAG_SECURE, so the 200-status stream loop (stream_body)
// needs a trusted-TLS endpoint, and the protected-root store refuses trust
// injection on a headless runner; that success path stays covered by the live
// onboarding download. These scenarios exercise the transport-failure and
// malformed-URL branches, which the curated manifest must survive without
// crashing or hanging the worker.

#include "download.c"

#include <stdio.h>

static int failures = 0;

static volatile bool dl_done;
static volatile int dl_ok;
static int dl_progress_count;
static char dl_reason[256];

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// The worker posts here from its thread; DispatchMessageW runs this on the pump
// thread, so the captured state needs no locking.
static LRESULT CALLBACK sink_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == BOO_MSG_DL_PROGRESS) {
        dl_progress_count++;
        return 0;
    }
    if (msg == BOO_MSG_DL_DONE) {
        char *text = (char *)lparam;
        dl_ok = (int)wparam;
        if (text) {
            strncpy(dl_reason, text, sizeof(dl_reason) - 1);
            dl_reason[sizeof(dl_reason) - 1] = 0;
            free(text); // the contract: the receiver frees the message payload
        }
        dl_done = true;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

// A message-only window on this thread: the worker's PostMessage target.
static HWND make_sink(void) {
    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc),
        .lpfnWndProc = sink_proc,
        .hInstance = GetModuleHandleW(NULL),
        .lpszClassName = L"BooDlTransferSink",
    };
    RegisterClassExW(&wc);
    return CreateWindowExW(0, L"BooDlTransferSink", NULL, 0, 0, 0, 0, 0, HWND_MESSAGE,
                           NULL, wc.hInstance, NULL);
}

// Start the real worker and pump this thread's queue until it reports back.
// Returns false only if BOO_MSG_DL_DONE never arrived in time.
static bool run_download(HWND sink, const BooModelInfo *model) {
    dl_done = false;
    dl_ok = -1;
    dl_progress_count = 0;
    dl_reason[0] = 0;
    if (!boo_download_start(sink, model)) return false;
    // A refused connection or a failed TLS handshake to loopback returns at
    // once; the cap only guards against a regression that hangs the worker.
    for (int waited = 0; waited < 60000 && !dl_done; waited += 10) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (dl_done) break;
        Sleep(10);
    }
    return dl_done;
}

int main(void) {
    printf("download_transfer_test:\n");
    boo_log_init(NULL, BOO_LOG_ERROR); // stderr sink; the worker logs its outcome

    HWND sink = make_sink();
    check(sink != NULL, "message-only sink window created");
    if (!sink) {
        printf("download_transfer_test: FAIL\n");
        return 1;
    }

    // SHA-256("abc"), a valid pin so the digest field is never the reason the
    // transfer fails; here the transport does.
    static const char abc_sha[] =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    // A well-formed https URL whose port has no listener: the worker builds its
    // paths, opens the CNG hash and the .part, then fetch fails at
    // WinHttpSendRequest and the worker reports the network reason. Port 47921
    // is unused; a stray listener still fails the forced-TLS handshake, so the
    // covered path is the same either way.
    static const BooModelInfo unreachable = {
        .filename = "boo-transfer-test.bin",
        .url = "https://127.0.0.1:47921/boo-transfer-test.bin",
        .sha256 = abc_sha,
        .label = "t",
        .note = "t",
        .size = 3,
    };
    check(run_download(sink, &unreachable), "unreachable host reports back (no hang)");
    check(dl_ok == 0, "unreachable host is a failure");
    check(strstr(dl_reason, "network") != NULL, "the reason points at the network");

    // A manifest URL that cannot be parsed must fail cleanly through fetch's
    // WinHttpCrackUrl guard, not crash the worker.
    static const BooModelInfo malformed = {
        .filename = "boo-transfer-test.bin",
        .url = "not-a-valid-url",
        .sha256 = abc_sha,
        .label = "t",
        .note = "t",
        .size = 3,
    };
    check(run_download(sink, &malformed), "malformed URL reports back (no hang)");
    check(dl_ok == 0, "malformed URL is a failure");

    // The worker removes its .part on failure, so nothing loadable is left in
    // %USERPROFILE%\.boo\models behind a transfer that never verified.
    WCHAR home[MAX_PATH];
    WCHAR part[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    if (n > 0 && n < MAX_PATH &&
        swprintf(part, MAX_PATH, L"%ls\\.boo\\models\\boo-transfer-test.bin.part",
                 home) >= 0)
        check(GetFileAttributesW(part) == INVALID_FILE_ATTRIBUTES,
              "the .part is cleaned up after a failed transfer");

    DestroyWindow(sink);
    printf("download_transfer_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
