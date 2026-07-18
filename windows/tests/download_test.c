// Native-runner tests for the Windows download verify/rename logic. Includes the
// source under test so its statics are reachable. The WinHTTP transfer itself is
// exercised end to end by onboarding; what must never regress silently is the
// digest gate on .part promotion. The hash check itself lives in the tested core
// (boo_model_verify_sha256); finish_part reads the finished .part and calls it.

#include "download.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    printf("download_test:\n");

    // SHA-256("abc"), the FIPS 180 test vector.
    static const char abc_sha[] =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    WCHAR tmp[MAX_PATH];
    WCHAR part[MAX_PATH];
    WCHAR final_path[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
    if (n > 0 && n < MAX_PATH &&
        swprintf(part, MAX_PATH, L"%ls\\boo-dl-test.part", tmp) >= 0 &&
        swprintf(final_path, MAX_PATH, L"%ls\\boo-dl-test.bin", tmp) >= 0) {
        const BooModelInfo fake = {.filename = "boo-dl-test.bin",
                                   .url = "https://example.invalid/x",
                                   .sha256 = abc_sha,
                                   .label = "t",
                                   .note = "t",
                                   .size = 3};
        const DownloadJob job = {.notify = NULL, .model = &fake};

        // Matching contents ("abc") pass the digest and promote the .part.
        FILE *f = _wfopen(part, L"wb");
        if (f) {
            fwrite("abc", 1, 3, f);
            fclose(f);
        }
        _wremove(final_path);
        const char *why = NULL;
        check(finish_part(&job, part, final_path, &why),
              "matching digest promotes the .part");
        check(GetFileAttributesW(final_path) != INVALID_FILE_ATTRIBUTES,
              "the final file exists");
        check(GetFileAttributesW(part) == INVALID_FILE_ATTRIBUTES,
              "the .part is gone after promotion");

        // Mismatched contents ("xyz") are refused, and the reason names the checksum.
        f = _wfopen(part, L"wb");
        if (f) {
            fwrite("xyz", 1, 3, f);
            fclose(f);
        }
        why = NULL;
        check(!finish_part(&job, part, final_path, &why),
              "wrong digest refuses promotion");
        check(why && strstr(why, "checksum") != NULL, "the reason names the checksum");
        _wremove(part);
        _wremove(final_path);

        // A valid .part whose destination sits under a directory that does not
        // exist: the digest passes but _wrename fails, so promotion is refused
        // with the save-failure reason and the .part is left in place for retry.
        WCHAR bad_final[MAX_PATH];
        if (swprintf(bad_final, MAX_PATH, L"%ls\\boo-dl-nodir\\x.bin", tmp) >= 0) {
            f = _wfopen(part, L"wb");
            if (f) {
                fwrite("abc", 1, 3, f);
                fclose(f);
            }
            why = NULL;
            check(!finish_part(&job, part, bad_final, &why),
                  "a rename into a missing directory refuses promotion");
            check(why && strstr(why, "save") != NULL,
                  "the reason names saving the model file");
            check(GetFileAttributesW(part) != INVALID_FILE_ATTRIBUTES,
                  "the .part is left in place on a rename failure");
            _wremove(part);
        }
    } else {
        check(false, "TEMP fixture paths");
    }

    printf("download_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
