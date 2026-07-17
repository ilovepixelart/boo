// Native-runner test for the SEH minidump writer (crash.c). Includes the
// source under test so the static filter is callable directly: a fabricated
// but valid EXCEPTION_POINTERS exercises the same MiniDumpWriteDump call an
// unhandled exception would, without killing the test process.

#include "crash.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    printf("crash_test:\n");

    // Without LOCALAPPDATA the installer must bail out quietly.
    SetEnvironmentVariableW(L"LOCALAPPDATA", NULL);
    boo_crash_install();
    check(dump_path[0] == L'\0', "no LOCALAPPDATA leaves the path unset");

    // Fixture %LOCALAPPDATA% with the Boo\logs directory init_logging makes.
    WCHAR tmp[MAX_PATH];
    WCHAR fixture[MAX_PATH];
    WCHAR sub[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
    if (n == 0 || n >= MAX_PATH ||
        swprintf(fixture, MAX_PATH, L"%ls\\boo-crash-test-%lu", tmp,
                 (unsigned long)GetCurrentProcessId()) < 0) {
        check(false, "fixture path");
        return 1;
    }
    CreateDirectoryW(fixture, NULL);
    swprintf(sub, MAX_PATH, L"%ls\\Boo", fixture);
    CreateDirectoryW(sub, NULL);
    swprintf(sub, MAX_PATH, L"%ls\\Boo\\logs", fixture);
    CreateDirectoryW(sub, NULL);
    SetEnvironmentVariableW(L"LOCALAPPDATA", fixture);

    boo_crash_install();
    check(wcsstr(dump_path, L"boo-crash.dmp") != NULL, "install formats the dump path");

    // A live CONTEXT from this thread plus an access-violation record is what
    // the filter sees for a real crash (ClientPointers=FALSE, same process).
    EXCEPTION_RECORD record;
    memset(&record, 0, sizeof(record));
    record.ExceptionCode = (DWORD)EXCEPTION_ACCESS_VIOLATION;
    CONTEXT context;
    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_FULL;
    RtlCaptureContext(&context);
    EXCEPTION_POINTERS pointers = {.ExceptionRecord = &record, .ContextRecord = &context};

    check(on_unhandled(&pointers) == EXCEPTION_CONTINUE_SEARCH,
          "the filter hands the exception on to WER");

    WIN32_FILE_ATTRIBUTE_DATA info;
    const bool have = GetFileAttributesExW(dump_path, GetFileExInfoStandard, &info);
    check(have, "a dump file was written");
    check(have && (info.nFileSizeLow > 0 || info.nFileSizeHigh > 0),
          "the dump is not empty");

    DeleteFileW(dump_path);
    printf("crash_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
