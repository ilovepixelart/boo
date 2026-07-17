// Speech model discovery. Mirrors the Linux frontend's rules: accept any
// ggml-*.bin speech model (a user who fetched large-v3-turbo on our own
// advice must not be told no model is installed), prefer the most capable of
// the recommended ones, alphabetical order breaking ties for determinism.

#include "model.h"

#include "app.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *to_utf8(const WCHAR *wide);

// Rank of a model filename via the shared core order (boo_model_rank), which
// takes UTF-8; the names are ASCII so the conversion is cheap. Unknown or
// unconvertible names rank worst.
static unsigned rank_of(const WCHAR *name) {
    char *u = to_utf8(name);
    if (!u) return (unsigned)-1;
    const unsigned r = boo_model_rank(u);
    free(u);
    return r;
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

        const unsigned rank = rank_of(entry.cFileName);
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
    const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    // A return >= MAX_PATH means truncated: the buffer contents are
    // documented as undefined then, not a usable path.
    if (n == 0 || n >= MAX_PATH) return false;
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
    // $BOO_MODEL points at one file directly. A length at or past MAX_PATH
    // means truncation, and truncated buffers are undefined, so skip those.
    WCHAR env[MAX_PATH];
    const DWORD env_len = GetEnvironmentVariableW(L"BOO_MODEL", env, MAX_PATH);
    if (env_len > 0 && env_len < MAX_PATH) {
        if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) return to_utf8(env);
    }

    WCHAR primary[MAX_PATH];
    WCHAR local[MAX_PATH] = L"";
    WCHAR localappdata[MAX_PATH];
    const DWORD lad_len =
        GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH);
    if (lad_len > 0 && lad_len < MAX_PATH)
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
             L"Boo needs a speech model, which isn't bundled.\n\n"
             L"Download one (curl ships with Windows) and relaunch.\n\n"
             L"Recommended, best accuracy, 25 languages (669 MB):\n"
             L"  mkdir \"%ls\"\n"
             L"  curl.exe -L -o \"%ls\\ggml-parakeet-tdt-0.6b-v3-q8_0.bin\" ^\n"
             L"    https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/"
             L"ggml-parakeet-tdt-0.6b-v3-q8_0.bin\n\n"
             L"Lighter and faster, English only (148 MB):\n"
             L"  curl.exe -L -o \"%ls\\ggml-base.en.bin\" ^\n"
             L"    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
             L"ggml-base.en.bin\n\n"
             L"Or point BOO_MODEL at a model you already have.",
             dir, dir, dir);
}
