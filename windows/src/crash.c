// SEH minidump on unhandled exceptions (see crash.h). The dump path is
// pre-formatted at install time so the filter only opens and writes.

#include "crash.h"

#include "app.h"

#include <dbghelp.h>
#include <stdio.h>

static WCHAR dump_path[MAX_PATH];

static LONG WINAPI on_unhandled(EXCEPTION_POINTERS *info) {
    HANDLE file = CreateFileW(dump_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei = {
            .ThreadId = GetCurrentThreadId(),
            .ExceptionPointers = info,
            .ClientPointers = FALSE,
        };
        MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file,
                          MiniDumpNormal, &mei, NULL, NULL);
        CloseHandle(file);
    }
    // Hand the exception on so Windows Error Reporting still runs.
    return EXCEPTION_CONTINUE_SEARCH;
}

void boo_crash_install(void) {
    WCHAR base[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    // The logs directory already exists: init_logging created it first.
    if (swprintf(dump_path, MAX_PATH, L"%ls\\Boo\\logs\\boo-crash.dmp", base) < 0) return;
    SetUnhandledExceptionFilter(on_unhandled);
}
