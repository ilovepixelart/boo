// Speech model discovery. Mirrors the Linux frontend's rules: accept any
// ggml-*.bin speech model (a user who fetched large-v3-turbo on our own
// advice must not be told no model is installed), prefer the most capable of
// the recommended ones, alphabetical order breaking ties for determinism.

#include "model.h"

#include "app.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Models the README recommends, most capable first. Downloading a bigger
// model is a deliberate act, so it wins over the default base.en when both
// exist. Matches the macOS and Linux frontends.
static const WCHAR *const preferred_models[] = {
    L"ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
    L"ggml-parakeet-tdt-0.6b-v3-f16.bin",
    L"ggml-large-v3-turbo-q5_0.bin",
    L"ggml-large-v3-turbo.bin",
    L"ggml-small.en.bin",
    L"ggml-base.en.bin",
};

#define PREFERRED_COUNT (sizeof(preferred_models) / sizeof(preferred_models[0]))

// Position in preferred_models, or one past the end for everything else.
static unsigned model_rank(const WCHAR *name) {
    for (unsigned i = 0; i < PREFERRED_COUNT; i++) {
        if (wcscmp(name, preferred_models[i]) == 0) return i;
    }
    return PREFERRED_COUNT;
}

// Pick a model out of `dir`, or NULL. Returned path is malloc'd, wide.
static WCHAR *find_model_in(const WCHAR *dir) {
    WCHAR pattern[MAX_PATH];
    if (swprintf(pattern, MAX_PATH, L"%ls\\ggml-*.bin", dir) < 0) return NULL;

    WIN32_FIND_DATAW entry;
    HANDLE it = FindFirstFileW(pattern, &entry);
    if (it == INVALID_HANDLE_VALUE) return NULL;

    WCHAR best[MAX_PATH] = L"";
    unsigned best_rank = 0;
    do {
        if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        // ggml-silero-* is the VAD model, not a speech model.
        if (wcsncmp(entry.cFileName, L"ggml-silero", 11) == 0) continue;

        const unsigned rank = model_rank(entry.cFileName);
        if (best[0] == 0 || rank < best_rank ||
            (rank == best_rank && wcscmp(entry.cFileName, best) < 0)) {
            wcscpy(best, entry.cFileName);
            best_rank = rank;
        }
    } while (FindNextFileW(it, &entry));
    FindClose(it);

    if (best[0] == 0) return NULL;

    WCHAR *path = malloc(MAX_PATH * sizeof(WCHAR));
    if (!path) return NULL;
    if (swprintf(path, MAX_PATH, L"%ls\\%ls", dir, best) < 0) {
        free(path);
        return NULL;
    }
    return path;
}

// %USERPROFILE%\.boo\models, the same dot-dir as macOS/Linux (and the ollama /
// LM Studio convention on Windows, rather than AppData).
static bool primary_model_dir(WCHAR *buf, size_t len) {
    WCHAR home[MAX_PATH];
    if (!GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH)) return false;
    return swprintf(buf, len, L"%ls\\.boo\\models", home) >= 0;
}

static char *to_utf8(const WCHAR *wide) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char *utf8 = malloc((size_t)len);
    if (!utf8) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, len, NULL, NULL);
    return utf8;
}

char *boo_model_find(void) {
    // $BOO_MODEL points at one file directly.
    WCHAR env[MAX_PATH];
    if (GetEnvironmentVariableW(L"BOO_MODEL", env, MAX_PATH) && env[0]) {
        if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) return to_utf8(env);
    }

    WCHAR primary[MAX_PATH];
    WCHAR local[MAX_PATH] = L"";
    WCHAR localappdata[MAX_PATH];
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH))
        swprintf(local, MAX_PATH, L"%ls\\boo\\models", localappdata);

    const WCHAR *dirs[] = {
        primary_model_dir(primary, MAX_PATH) ? primary : NULL,
        L"models",
        local[0] ? local : NULL,
    };
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
        if (!dirs[i]) continue;
        WCHAR *found = find_model_in(dirs[i]);
        if (found) {
            char *utf8 = to_utf8(found);
            free(found);
            return utf8;
        }
    }
    return NULL;
}

void boo_model_missing_hint(wchar_t *buf, size_t len) {
    WCHAR dir[MAX_PATH];
    if (!primary_model_dir(dir, MAX_PATH)) wcscpy(dir, L"%USERPROFILE%\\.boo\\models");

    swprintf(buf, len,
             L"Boo needs a whisper model, which isn't bundled, they're 140 MB+.\n\n"
             L"Download one (curl ships with Windows) and relaunch:\n\n"
             L"  mkdir \"%ls\"\n"
             L"  curl.exe -L -o \"%ls\\ggml-base.en.bin\" ^\n"
             L"    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
             L"ggml-base.en.bin\n\n"
             L"Or point BOO_MODEL at a model you already have.",
             dir, dir);
}
