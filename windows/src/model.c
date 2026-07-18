// Speech model discovery. Mirrors the Linux frontend's rules: accept any
// ggml-*.bin speech model (a user who fetched large-v3-turbo on our own
// advice must not be told no model is installed), prefer the most capable of
// the recommended ones, alphabetical order breaking ties for determinism.

#include "model.h"

#include "strconv.h"

#include "app.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Model kind (speech / VAD / neither) via the shared core policy
// (boo_model_classify), which takes UTF-8. The "ggml-silero is the VAD, not a
// speech model" rule lives in the core so all three frontends agree.
static int kind_of(const WCHAR *name) {
    char *u = boo_to_utf8(name);
    if (!u) return BOO_MODEL_OTHER;
    const int kind = boo_model_classify(u);
    free(u);
    return kind;
}

// Whether the model at dir\name is usable: not a truncated partial download
// (an interrupted hand-run curl), judged by the core against the pinned
// manifest size.
static bool usable_model(const WCHAR *dir, const WCHAR *name) {
    WCHAR full[MAX_PATH];
    if (swprintf(full, MAX_PATH, L"%ls\\%ls", dir, name) < 0) return false;
    char *ufull = boo_to_utf8(full);
    if (!ufull) return false;
    const bool ok = boo_model_verify(ufull) != BOO_MODEL_FILE_TRUNCATED;
    free(ufull);
    return ok;
}

// Gather a directory's usable ggml-*.bin models as UTF-8 paths; defined below
// with the installed-models listing that also uses it.
static void scan_model_dir(const WCHAR *dir, char ***paths, int *count, int *cap);

// The best speech model in `dir` as an owned UTF-8 path, or NULL if it holds
// none. scan_model_dir enumerates the directory; the core then applies the
// shared selection policy across all three frontends (boo_best_model: lowest
// rank wins, basename breaks ties). UTF-8 out because every caller wants that,
// not the wide path.
static char *find_model_in(const WCHAR *dir) {
    char **paths = NULL;
    int count = 0;
    int cap = 0;
    scan_model_dir(dir, &paths, &count, &cap);

    char *best = NULL;
    const int idx = boo_best_model((const char *const *)paths, count);
    if (idx >= 0) {
        best = paths[idx];
        paths[idx] = NULL; // hand the winner to the caller before freeing the rest
    }
    for (int i = 0; i < count; i++) free(paths[i]);
    free(paths);
    return best;
}

// Best Silero VAD model in `dir`, or NULL. First name wins so a newer silero
// version beats an older one. Returned path is malloc'd, wide. Mirrors
// find_model_in; the core decides which ggml-*.bin is the VAD.
static WCHAR *find_vad_in(const WCHAR *dir) {
    WCHAR pattern[MAX_PATH];
    if (swprintf(pattern, MAX_PATH, L"%ls\\ggml-*.bin", dir) < 0) return NULL;

    WIN32_FIND_DATAW e;
    HANDLE it = FindFirstFileW(pattern, &e);
    if (it == INVALID_HANDLE_VALUE) return NULL;

    WCHAR best[MAX_PATH] = L"";
    do {
        if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (kind_of(e.cFileName) != BOO_MODEL_VAD) continue;
        if (best[0] == 0 || wcscmp(e.cFileName, best) < 0) wcscpy(best, e.cFileName);
    } while (FindNextFileW(it, &e));
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
    if (RegGetValueW(HKEY_CURRENT_USER, BOO_REG_KEY, L"Model", RRF_RT_REG_SZ, NULL, saved,
                     &size) != ERROR_SUCCESS)
        return NULL;
    if (GetFileAttributesW(saved) == INVALID_FILE_ATTRIBUTES) return NULL;
    char *utf8 = boo_to_utf8(saved);
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
        if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) return boo_to_utf8(env);
    }

    char *saved = saved_model_choice();
    if (saved) return saved;

    WCHAR dirs[BOO_MODEL_DIRS][MAX_PATH];
    const size_t ndirs = model_dirs(dirs);
    for (size_t i = 0; i < ndirs; i++) {
        char *found = find_model_in(dirs[i]);
        if (found) return found;
    }
    return NULL;
}

char *boo_model_find_vad(void) {
    WCHAR env[MAX_PATH];
    const DWORD env_len = GetEnvironmentVariableW(L"BOO_VAD_MODEL", env, MAX_PATH);
    if (env_len > 0 && env_len < MAX_PATH) {
        if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) return boo_to_utf8(env);
    }

    WCHAR dirs[BOO_MODEL_DIRS][MAX_PATH];
    const size_t ndirs = model_dirs(dirs);
    for (size_t i = 0; i < ndirs; i++) {
        WCHAR *found = find_vad_in(dirs[i]);
        if (found) {
            char *utf8 = boo_to_utf8(found);
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

// Append `ufull` to the grown-on-demand list, taking ownership. Returns false
// (and frees it) when the list cannot grow.
static bool push_path(char ***paths, int *count, int *cap, char *ufull) {
    if (*count == *cap) {
        const int ncap = *cap ? *cap * 2 : 8;
        char **grown = realloc(*paths, (size_t)ncap * sizeof(*grown));
        if (!grown) {
            free(ufull);
            return false;
        }
        *paths = grown;
        *cap = ncap;
    }
    (*paths)[(*count)++] = ufull;
    return true;
}

// Append one directory's usable ggml-*.bin models to the list. A basename seen
// in an earlier directory wins: ~\.boo\models shadows a bundled copy.
static void scan_model_dir(const WCHAR *dir, char ***paths, int *count, int *cap) {
    WCHAR pattern[MAX_PATH];
    if (swprintf(pattern, MAX_PATH, L"%ls\\ggml-*.bin", dir) < 0) return;
    WIN32_FIND_DATAW e;
    HANDLE it = FindFirstFileW(pattern, &e);
    if (it == INVALID_HANDLE_VALUE) return;
    do {
        if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (kind_of(e.cFileName) != BOO_MODEL_SPEECH) continue;
        if (!usable_model(dir, e.cFileName)) continue;
        WCHAR full[MAX_PATH];
        if (swprintf(full, MAX_PATH, L"%ls\\%ls", dir, e.cFileName) < 0) continue;
        char *ufull = boo_to_utf8(full);
        if (!ufull) continue;
        if (already_listed(*paths, *count, boo_model_basename(ufull))) {
            free(ufull);
            continue;
        }
        if (!push_path(paths, count, cap, ufull)) break;
    } while (FindNextFileW(it, &e));
    FindClose(it);
}

int boo_model_installed(char ***out) {
    *out = NULL;
    WCHAR dirs[BOO_MODEL_DIRS][MAX_PATH];
    const size_t ndirs = model_dirs(dirs);

    char **paths = NULL;
    int count = 0;
    int cap = 0;
    for (size_t i = 0; i < ndirs; i++) scan_model_dir(dirs[i], &paths, &count, &cap);

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
