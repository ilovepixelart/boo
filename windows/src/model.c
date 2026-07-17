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

// Whether the model at dir\name is usable: not a truncated partial download
// (an interrupted hand-run curl), judged by the core against the pinned
// manifest size.
static bool usable_model(const WCHAR *dir, const WCHAR *name) {
    WCHAR full[MAX_PATH];
    if (swprintf(full, MAX_PATH, L"%ls\\%ls", dir, name) < 0) return false;
    char *ufull = to_utf8(full);
    if (!ufull) return false;
    const bool ok = boo_model_verify(ufull) != BOO_MODEL_FILE_TRUNCATED;
    free(ufull);
    return ok;
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
        if (!usable_model(dir, entry.cFileName)) continue;

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

// Fill the ordered candidate model directories; returns how many are usable.
#define BOO_MODEL_DIRS 3
static size_t model_dirs(WCHAR dirs[][MAX_PATH]) {
    size_t n = 0;
    if (primary_model_dir(dirs[n], MAX_PATH)) n++;
    wcscpy(dirs[n++], L"models");
    WCHAR localappdata[MAX_PATH];
    const DWORD lad_len =
        GetEnvironmentVariableW(L"LOCALAPPDATA", localappdata, MAX_PATH);
    if (lad_len > 0 && lad_len < MAX_PATH &&
        swprintf(dirs[n], MAX_PATH, L"%ls\\boo\\models", localappdata) >= 0)
        n++;
    return n;
}

// The model the user explicitly picked in Settings (HKCU\Software\Boo\Model),
// as a malloc'd UTF-8 path, or NULL. A stale choice (file deleted or
// truncated since) is treated as absent so discovery falls through.
static char *saved_model_choice(void) {
    WCHAR saved[MAX_PATH];
    DWORD size = sizeof(saved);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Boo", L"Model", RRF_RT_REG_SZ, NULL,
                     saved, &size) != ERROR_SUCCESS)
        return NULL;
    if (GetFileAttributesW(saved) == INVALID_FILE_ATTRIBUTES) return NULL;
    char *utf8 = to_utf8(saved);
    if (utf8 && boo_model_verify(utf8) != BOO_MODEL_FILE_TRUNCATED) return utf8;
    free(utf8);
    return NULL;
}

char *boo_model_find(void) {
    // $BOO_MODEL points at one file directly. A length at or past MAX_PATH
    // means truncation, and truncated buffers are undefined, so skip those.
    WCHAR env[MAX_PATH];
    const DWORD env_len = GetEnvironmentVariableW(L"BOO_MODEL", env, MAX_PATH);
    if (env_len > 0 && env_len < MAX_PATH) {
        if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) return to_utf8(env);
    }

    char *saved = saved_model_choice();
    if (saved) return saved;

    WCHAR dirs[BOO_MODEL_DIRS][MAX_PATH];
    const size_t ndirs = model_dirs(dirs);
    for (size_t i = 0; i < ndirs; i++) {
        WCHAR *found = find_model_in(dirs[i]);
        if (found) {
            char *utf8 = to_utf8(found);
            free(found);
            return utf8;
        }
    }
    return NULL;
}

const char *boo_model_basename(const char *path) {
    const char *base = path;
    for (const char *p = path; *p; p++)
        if (*p == '\\' || *p == '/') base = p + 1;
    return base;
}

// Ranked compare of two full UTF-8 model paths by basename.
static int cmp_installed(const void *a, const void *b) {
    const char *na = boo_model_basename(*(const char *const *)a);
    const char *nb = boo_model_basename(*(const char *const *)b);
    const unsigned ra = boo_model_rank(na);
    const unsigned rb = boo_model_rank(nb);
    if (ra != rb) return ra < rb ? -1 : 1;
    return strcmp(na, nb);
}

static bool already_listed(char **paths, int count, const char *basename) {
    for (int i = 0; i < count; i++)
        if (strcmp(boo_model_basename(paths[i]), basename) == 0) return true;
    return false;
}

int boo_model_installed(char ***out) {
    *out = NULL;
    WCHAR dirs[BOO_MODEL_DIRS][MAX_PATH];
    const size_t ndirs = model_dirs(dirs);

    char **paths = NULL;
    int count = 0;
    int cap = 0;
    for (size_t i = 0; i < ndirs; i++) {
        WCHAR pattern[MAX_PATH];
        if (swprintf(pattern, MAX_PATH, L"%ls\\ggml-*.bin", dirs[i]) < 0) continue;
        WIN32_FIND_DATAW e;
        HANDLE it = FindFirstFileW(pattern, &e);
        if (it == INVALID_HANDLE_VALUE) continue;
        do {
            if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
            if (wcsncmp(e.cFileName, L"ggml-silero", 11) == 0) continue;
            if (!usable_model(dirs[i], e.cFileName)) continue;
            WCHAR full[MAX_PATH];
            if (swprintf(full, MAX_PATH, L"%ls\\%ls", dirs[i], e.cFileName) < 0) continue;
            char *ufull = to_utf8(full);
            if (!ufull) continue;
            // First directory wins: ~\.boo\models shadows a bundled copy.
            if (already_listed(paths, count, boo_model_basename(ufull))) {
                free(ufull);
                continue;
            }
            if (count == cap) {
                const int ncap = cap ? cap * 2 : 8;
                char **grown = realloc(paths, (size_t)ncap * sizeof(*grown));
                if (!grown) {
                    free(ufull);
                    break;
                }
                paths = grown;
                cap = ncap;
            }
            paths[count++] = ufull;
        } while (FindNextFileW(it, &e));
        FindClose(it);
    }

    if (paths) qsort(paths, (size_t)count, sizeof(*paths), cmp_installed);
    *out = paths;
    return count;
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
