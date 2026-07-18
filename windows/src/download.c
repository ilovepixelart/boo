// Manifest model download (see download.h). WinHTTP does the transfer (it
// follows the HuggingFace resolve -> CDN redirects on its own), and the .part
// file only takes the real name after the tested core (boo_model_verify_sha256)
// confirms the finished file against the manifest's pinned SHA-256, so a crash
// or a lie leaves nothing loadable behind.

#include "download.h"

#include "strconv.h"

#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winhttp.h>

typedef struct {
    HWND notify;
    const BooModelInfo *model; // static core storage
} DownloadJob;

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

// Fold one received chunk into the download: write it, advance the running
// total, and post progress on a percentage change. Returns false when the total
// exceeds the manifest size (a longer body is the wrong file, and the bound
// stops a misbehaving server filling the disk before the digest check runs).
// Split from the WinHTTP read loop so the per-byte accounting is testable
// without a live connection.
static bool consume_chunk(const DownloadJob *job, const BYTE *buf, DWORD n, FILE *out,
                          unsigned long long *received, int *last_pct) {
    if (fwrite(buf, 1, n, out) != n) return false;
    *received += n;
    if (*received > job->model->size) return false;
    const int pct = (int)(*received * 100 / job->model->size);
    if (pct != *last_pct) {
        *last_pct = pct;
        PostMessageW(job->notify, BOO_MSG_DL_PROGRESS, (WPARAM)(pct > 100 ? 100 : pct),
                     0);
    }
    return true;
}

// One HTTP GET streamed to `out` with progress posts. Returns false on any
// transport failure; the finished file's digest is checked in finish_part.
static bool stream_body(const DownloadJob *job, HINTERNET request, FILE *out) {
    unsigned long long received = 0;
    int last_pct = -1;
    for (;;) {
        BYTE buf[65536];
        DWORD n = 0;
        if (!WinHttpReadData(request, buf, sizeof(buf), &n)) return false;
        if (n == 0) return true; // end of body
        if (!consume_chunk(job, buf, n, out, &received, &last_pct)) return false;
    }
}

// The transfer proper: connect, GET, stream. Splits out so the worker owns
// setup/teardown and this owns the WinHTTP handles.
static bool fetch(const DownloadJob *job, FILE *out) {
    WCHAR *url = boo_to_wide(job->model->url);
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
        if (status == 200) ok = stream_body(job, request, out);
    }
    if (request) WinHttpCloseHandle(request);
    if (connect) WinHttpCloseHandle(connect);
    if (session) WinHttpCloseHandle(session);
    return ok;
}

// Verify the finished .part against the manifest digest (in the tested core) and
// rename it into place. On failure points `why` at a user-facing reason. The
// core takes a UTF-8 path; the app's UTF-8 code page makes libc fopen honor it.
static bool finish_part(const DownloadJob *job, const WCHAR *part_path,
                        const WCHAR *final_path, const char **why) {
    char *part_utf8 = boo_to_utf8(part_path);
    const int verdict = part_utf8 ? boo_model_verify_sha256(part_utf8, job->model->sha256)
                                  : BOO_MODEL_SHA_UNREADABLE;
    free(part_utf8);
    if (verdict != BOO_MODEL_SHA_OK) {
        *why = verdict == BOO_MODEL_SHA_MISMATCH
                   ? "Downloaded file failed its checksum. Try again."
                   : "Could not read the download.";
        return false;
    }
    _wremove(final_path);
    if (_wrename(part_path, final_path) != 0) {
        *why = "Could not save the model file.";
        return false;
    }
    return true;
}

static DWORD WINAPI download_worker(LPVOID param) {
    DownloadJob *job = param;

    WCHAR dir[MAX_PATH];
    WCHAR final_path[MAX_PATH];
    WCHAR part_path[MAX_PATH];
    WCHAR *name = boo_to_wide(job->model->filename);
    const bool paths_ok = name && ensure_models_dir(dir, MAX_PATH) &&
                          swprintf(final_path, MAX_PATH, L"%ls\\%ls", dir, name) >= 0 &&
                          swprintf(part_path, MAX_PATH, L"%ls\\%ls.part", dir, name) >= 0;
    free(name);
    if (!paths_ok) {
        post_done(job->notify, false, "Could not build the model path.");
        free(job);
        return 0;
    }

    FILE *out = _wfopen(part_path, L"wb");
    bool ok = false;
    const char *why = "Download failed. Check your network and try again.";
    if (!out) why = "Could not create the model file.";

    if (out) {
        const bool fetched = fetch(job, out);
        fclose(out);
        out = NULL;
        if (fetched) ok = finish_part(job, part_path, final_path, &why);
    }

    if (out) fclose(out);
    if (!ok) _wremove(part_path);

    if (ok) {
        boo_log(BOO_LOG_INFO, "model downloaded and verified");
        char *upath = boo_to_utf8(final_path);
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
