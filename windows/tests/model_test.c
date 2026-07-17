// Native-runner tests for the Windows model discovery logic. Includes the
// source under test so its statics are reachable (the portal_payloads.c
// pattern from Linux). Runs via `zig build win-tests` on the Windows CI job;
// prints one line per check and exits nonzero on any failure.

#include "model.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// A scratch directory under %TEMP% seeded with fake model files.
static bool make_fixture(WCHAR *dir, size_t len) {
    WCHAR tmp[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    if (swprintf(dir, len, L"%ls\\boo-model-test-%lu", tmp,
                 (unsigned long)GetCurrentProcessId()) < 0)
        return false;
    return CreateDirectoryW(dir, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
}

static void write_file(const WCHAR *dir, const WCHAR *name, size_t bytes) {
    WCHAR path[MAX_PATH];
    if (swprintf(path, MAX_PATH, L"%ls\\%ls", dir, name) < 0) return;
    FILE *f = _wfopen(path, L"wb");
    if (!f) return;
    for (size_t i = 0; i < bytes; i++) fputc('x', f);
    fclose(f);
}

int main(void) {
    printf("model_test:\n");

    // Basename handling across separators.
    check(strcmp(boo_model_basename("C:\\a\\b\\ggml-base.en.bin"), "ggml-base.en.bin") ==
              0,
          "basename after backslashes");
    check(strcmp(boo_model_basename("a/b/ggml-x.bin"), "ggml-x.bin") == 0,
          "basename after forward slashes");
    check(strcmp(boo_model_basename("ggml-x.bin"), "ggml-x.bin") == 0,
          "bare name is its own basename");

    // Ranked ordering: the recommended order wins, alphabetical breaks ties.
    const char *paths[] = {
        "d\\ggml-zzz.bin",                       // unknown, ranks last
        "d\\ggml-base.en.bin",                   // recommended, mid rank
        "d\\ggml-parakeet-tdt-0.6b-v3-q8_0.bin", // best rank
        "d\\ggml-aaa.bin",                       // unknown, before zzz alphabetically
    };
    qsort(paths, 4, sizeof(*paths), cmp_installed);
    check(strcmp(boo_model_basename(paths[0]), "ggml-parakeet-tdt-0.6b-v3-q8_0.bin") == 0,
          "parakeet sorts first");
    check(strcmp(boo_model_basename(paths[1]), "ggml-base.en.bin") == 0,
          "recognized model beats unknowns");
    check(strcmp(boo_model_basename(paths[2]), "ggml-aaa.bin") == 0 &&
              strcmp(boo_model_basename(paths[3]), "ggml-zzz.bin") == 0,
          "unknowns tie-break alphabetically");

    // Dedup by basename.
    char *listed[] = {(char *)"x\\ggml-a.bin", (char *)"y\\ggml-b.bin"};
    check(already_listed(listed, 2, "ggml-a.bin"), "dedup finds a listed basename");
    check(!already_listed(listed, 2, "ggml-c.bin"), "dedup passes an unlisted one");

    // Truncation detection against the manifest, and discovery honoring it:
    // a manifest-named file with the wrong size must be skipped while an
    // unknown-name file (unjudgeable) stays usable.
    WCHAR dir[MAX_PATH];
    if (make_fixture(dir, MAX_PATH)) {
        write_file(dir, L"ggml-base.en.bin", 100); // truncated stand-in
        write_file(dir, L"ggml-unknown.bin", 100); // not in the manifest
        check(!usable_model(dir, L"ggml-base.en.bin"),
              "manifest-named wrong-size file is unusable");
        check(usable_model(dir, L"ggml-unknown.bin"),
              "unknown-name file cannot be judged, stays usable");

        WCHAR *found = find_model_in(dir);
        char *found_u8 = found ? to_utf8(found) : NULL;
        check(found_u8 && strcmp(boo_model_basename(found_u8), "ggml-unknown.bin") == 0,
              "discovery skips the truncated file");
        free(found_u8);
        free(found);
    } else {
        check(false, "fixture directory");
    }

    printf("model_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
