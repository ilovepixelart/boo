// Manifest model download (see download.h). WinHTTP does the transfer (it
// follows the HuggingFace resolve -> CDN redirects on its own), CNG hashes the
// stream as it lands, and the .part file only takes the real name after the
// digest matches the manifest's pinned SHA-256, so a crash or a lie leaves
// nothing loadable behind.

#include "download.h"

#include <bcrypt.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winhttp.h>

typedef struct {
    HWND notify;
    const BooModelInfo *model; // static core storage
} DownloadJob;

static WCHAR *to_wide(const char *utf8) {
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (len <= 0) return NULL;
    WCHAR *wide = malloc((size_t)len * sizeof(WCHAR));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, len);
    return wide;
}

static char *to_utf8(const WCHAR *wide) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char *utf8 = malloc((size_t)len);
    if (!utf8) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, len, NULL, NULL);
    return utf8;
}

// %USERPROFILE%\.boo\models, created if missing.
static bool ensure_models_dir(WCHAR *buf, size_t len) {
    WCHAR home[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    WCHAR dot[MAX_PATH];
    if (swprintf(dot, MAX_PATH, L"%ls\\.boo", home) < 0) return false;
    CreateDirectoryW(dot, NULL);
    if (swprintf(buf, len, L"%ls\\models", dot) < 0) return false;
    CreateDirectoryW(buf, NULL);
    return true;
}

static void post_done(HWND notify, bool ok, const char *text) {
    char *copy = _strdup(text);
    if (copy && !PostMessageW(notify, BOO_MSG_DL_DONE, ok ? 1 : 0, (LPARAM)copy))
        free(copy);
}

// One HTTP GET streamed to `out` with progress posts; the SHA-256 of every
// byte written lands in `hash`. Returns false on any transport failure.
static bool stream_body(const DownloadJob *job, HINTERNET request, FILE *out,
                        BCRYPT_HASH_HANDLE hash) {
    unsigned long long received = 0;
    int last_pct = -1;
    for (;;) {
        BYTE buf[65536];
        DWORD n = 0;
        if (!WinHttpReadData(request, buf, sizeof(buf), &n)) return false;
        if (n == 0) return true; // end of body
        if (fwrite(buf, 1, n, out) != n) return false;
        BCryptHashData(hash, buf, n, 0);
        received += n;
        const int pct = (int)(received * 100 / job->model->size);
        if (pct != last_pct) {
            last_pct = pct;
            PostMessageW(job->notify, BOO_MSG_DL_PROGRESS,
                         (WPARAM)(pct > 100 ? 100 : pct), 0);
        }
    }
}

// The transfer proper: connect, GET, stream, hash. Splits out so the worker
// owns setup/teardown and this owns the WinHTTP handles.
static bool fetch(const DownloadJob *job, FILE *out, BCRYPT_HASH_HANDLE hash) {
    WCHAR *url = to_wide(job->model->url);
    if (!url) return false;

    URL_COMPONENTSW parts = {.dwStructSize = sizeof(parts)};
    WCHAR host[256];
    WCHAR path[1024];
    parts.lpszHostName = host;
    parts.dwHostNameLength = ARRAYSIZE(host);
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = ARRAYSIZE(path);
    const bool cracked = WinHttpCrackUrl(url, 0, 0, &parts);
    free(url);
    if (!cracked) return false;

    bool ok = false;
    HINTERNET session = WinHttpOpen(L"Boo/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET connect = session ? WinHttpConnect(session, host, parts.nPort, 0) : NULL;
    HINTERNET request =
        connect ? WinHttpOpenRequest(connect, L"GET", path, NULL, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)
                : NULL;
    if (request &&
        WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(request, NULL)) {
        DWORD status = 0;
        DWORD size = sizeof(status);
        WinHttpQueryHeaders(
            request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
        if (status == 200) ok = stream_body(job, request, out, hash);
    }
    if (request) WinHttpCloseHandle(request);
    if (connect) WinHttpCloseHandle(connect);
    if (session) WinHttpCloseHandle(session);
    return ok;
}

static bool digest_matches(BCRYPT_HASH_HANDLE hash, const char *expected) {
    BYTE digest[32];
    if (BCryptFinishHash(hash, digest, sizeof(digest), 0) != 0) return false;
    char hex[65];
    for (size_t i = 0; i < sizeof(digest); i++) sprintf(hex + i * 2, "%02x", digest[i]);
    return _stricmp(hex, expected) == 0;
}

static DWORD WINAPI download_worker(LPVOID param) {
    DownloadJob *job = param;

    WCHAR dir[MAX_PATH];
    WCHAR final_path[MAX_PATH];
    WCHAR part_path[MAX_PATH];
    WCHAR *name = to_wide(job->model->filename);
    const bool paths_ok = name && ensure_models_dir(dir, MAX_PATH) &&
                          swprintf(final_path, MAX_PATH, L"%ls\\%ls", dir, name) >= 0 &&
                          swprintf(part_path, MAX_PATH, L"%ls\\%ls.part", dir, name) >= 0;
    free(name);
    if (!paths_ok) {
        post_done(job->notify, false, "Could not build the model path.");
        free(job);
        return 0;
    }

    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    FILE *out = NULL;
    bool ok = false;
    const char *why = "Download failed. Check your network and try again.";

    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
        BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0) == 0 &&
        (out = _wfopen(part_path, L"wb")) != NULL) {
        if (fetch(job, out, hash)) {
            fclose(out);
            out = NULL;
            if (!digest_matches(hash, job->model->sha256)) {
                why = "Downloaded file failed its checksum. Try again.";
            } else {
                _wremove(final_path);
                if (_wrename(part_path, final_path) == 0)
                    ok = true;
                else
                    why = "Could not save the model file.";
            }
        }
    } else if (!out) {
        why = "Could not create the model file.";
    }

    if (out) fclose(out);
    if (!ok) _wremove(part_path);
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);

    if (ok) {
        boo_log(BOO_LOG_INFO, "model downloaded and verified");
        char *upath = to_utf8(final_path);
        if (upath) {
            post_done(job->notify, true, upath);
            free(upath);
        } else {
            post_done(job->notify, false, "Could not encode the model path.");
        }
    } else {
        boo_log(BOO_LOG_ERROR, "model download failed");
        post_done(job->notify, false, why);
    }
    free(job);
    return 0;
}

bool boo_download_start(HWND notify, const BooModelInfo *model) {
    DownloadJob *job = malloc(sizeof(*job));
    if (!job) return false;
    job->notify = notify;
    job->model = model;
    HANDLE worker = CreateThread(NULL, 0, download_worker, job, 0, NULL);
    if (!worker) {
        free(job);
        return false;
    }
    CloseHandle(worker);
    return true;
}
