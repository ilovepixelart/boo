// Model discovery, enumeration, and download (see models.h). The ranking
// policy and the download manifest live in the core (boo_model_rank,
// boo_models, boo_model_verify); this file owns the per-OS directory walking
// and the GIO/soup transfer.

#include "models.h"
#include "overlay_window.h"

#include <glib/gstdio.h>
#include <libsoup/soup.h>

GPtrArray *boo_data_dirs(const char *subdir) {
    GPtrArray *dirs = g_ptr_array_new_with_free_func(g_free);
    g_ptr_array_add(dirs, g_strdup(subdir));
    // g_get_user_data_dir already honors XDG_DATA_HOME with the
    // ~/.local/share fallback; no hand-rolled env check needed.
    g_ptr_array_add(dirs, g_build_filename(g_get_user_data_dir(), "boo", subdir, NULL));
    g_ptr_array_add(dirs, g_build_filename("/app/share/boo", subdir, NULL));
    g_ptr_array_add(dirs, g_build_filename("/usr/share/boo", subdir, NULL));
    return dirs;
}

static GPtrArray *model_dirs(void) {
    return boo_data_dirs("models");
}

// Whether `name` in `dir` is a usable speech model: the core says it is a
// speech model (ggml-*.bin, not the VAD), and it is not a truncated partial
// download.
static gboolean is_speech_model(const char *dir, const char *name) {
    if (boo_model_classify(name) != BOO_MODEL_SPEECH) return FALSE;
    g_autofree const char *path = g_build_filename(dir, name, NULL);
    return boo_model_verify(path) != BOO_MODEL_FILE_TRUNCATED;
}

// Pick the best speech model out of `dir`, or NULL if it holds none.
//
// Any GGML speech model works, so this accepts any ggml-*.bin rather than only
// the models we happen to recommend; pinning filenames meant a user who
// followed our own advice and fetched, say, large-v3-turbo would be told no
// model was installed.
static char *find_model_in(const char *dir) {
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return NULL;

    char *best = NULL;
    unsigned best_rank = 0;
    const char *name;
    while ((name = g_dir_read_name(d))) {
        if (!is_speech_model(dir, name)) continue;

        // Best rank wins; alphabetical order breaks ties among the
        // unrecognized, so the choice is at least deterministic.
        unsigned rank = boo_model_rank(name);
        if (!best || rank < best_rank ||
            (rank == best_rank && g_strcmp0(name, best) < 0)) {
            g_free(best);
            best = g_strdup(name);
            best_rank = rank;
        }
    }
    g_dir_close(d);

    if (!best) return NULL;
    char *path = g_build_filename(dir, best, NULL);
    g_free(best);
    return path;
}

// The Silero VAD model that enables streaming transcription. First
// alphabetically wins so a newer silero version beats an older one.
static char *find_vad_model_in(const char *dir) {
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return NULL;

    char *best = NULL;
    const char *name;
    while ((name = g_dir_read_name(d))) {
        if (boo_model_classify(name) != BOO_MODEL_VAD) continue;
        if (!best || g_strcmp0(name, best) < 0) {
            g_free(best);
            best = g_strdup(name);
        }
    }
    g_dir_close(d);

    if (!best) return NULL;
    char *path = g_build_filename(dir, best, NULL);
    g_free(best);
    return path;
}

// Walk the model directories with a per-directory finder.
static char *search_model_dirs(char *(*find_in)(const char *dir)) {
    g_autoptr(GPtrArray) dirs = model_dirs();
    for (guint i = 0; i < dirs->len; i++) {
        char *found = find_in(g_ptr_array_index(dirs, i));
        if (found) return found;
    }
    return NULL;
}

char *boo_find_model_path(void) {
    const char *env = g_getenv("BOO_MODEL");
    if (env && *env) {
        if (g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);
        g_warning("Boo: BOO_MODEL points at %s, which does not exist", env);
    }

    // The model the user explicitly picked in Settings wins over the ranked
    // scan; a stale choice (deleted or truncated since) falls through.
    g_autofree char *saved = boo_saved_model_read();
    if (saved && g_file_test(saved, G_FILE_TEST_EXISTS) &&
        boo_model_verify(saved) != BOO_MODEL_FILE_TRUNCATED)
        return g_steal_pointer(&saved);

    return search_model_dirs(find_model_in);
}

char *boo_find_vad_model_path(void) {
    const char *env = g_getenv("BOO_VAD_MODEL");
    if (env && *env) {
        if (g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);
        g_warning("Boo: BOO_VAD_MODEL points at %s, which does not exist", env);
    }
    return search_model_dirs(find_vad_model_in);
}

char *boo_models_write_dir(void) {
    char *dir = g_build_filename(g_get_user_data_dir(), "boo", "models", NULL);
    g_mkdir_with_parents(dir, 0700);
    return dir;
}

// Ranked compare of two full model paths by basename: capability rank first,
// then name, so the order is deterministic.
static gint model_path_cmp(gconstpointer a, gconstpointer b) {
    const char *pa = *(const char *const *)a;
    const char *pb = *(const char *const *)b;
    g_autofree const char *na = g_path_get_basename(pa);
    g_autofree const char *nb = g_path_get_basename(pb);
    unsigned ra = boo_model_rank(na);
    unsigned rb = boo_model_rank(nb);
    if (ra != rb) return ra < rb ? -1 : 1;
    return g_strcmp0(na, nb);
}

GPtrArray *boo_installed_models(void) {
    GPtrArray *out = g_ptr_array_new_with_free_func(g_free);
    g_autoptr(GHashTable) seen =
        g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_autoptr(GPtrArray) dirs = model_dirs();

    for (guint i = 0; i < dirs->len; i++) {
        const char *dir = g_ptr_array_index(dirs, i);
        GDir *d = g_dir_open(dir, 0, NULL);
        if (!d) continue;
        const char *name;
        while ((name = g_dir_read_name(d))) {
            if (!is_speech_model(dir, name)) continue;
            if (g_hash_table_contains(seen, name)) continue;
            g_hash_table_add(seen, g_strdup(name));
            g_ptr_array_add(out, g_build_filename(dir, name, NULL));
        }
        g_dir_close(d);
    }

    g_ptr_array_sort(out, model_path_cmp);
    return out;
}

// ── manifest download ─────────────────────────────────────────────────────────
// The file streams to models/<name>.part, its SHA-256 is verified against the
// pinned manifest digest, then it is renamed into place. One transfer per
// call; the context frees itself after the done/fail callback returns.

typedef struct {
    const BooModelInfo *model;
    GtkProgressBar *progress; // ref'd for the transfer
    BooDownloadDone on_done;
    BooDownloadFail on_fail;
    gpointer user_data;
    SoupSession *session;
    GCancellable *cancel;
    GChecksum *sum;
    GFileOutputStream *out;
    char *tmp_path;   // models/<name>.part while downloading
    char *final_path; // models/<name>
    goffset received;
    guint8 buf[65536];
} DownloadCtx;

static void download_free(DownloadCtx *dc) {
    g_clear_object(&dc->out);
    if (dc->sum) g_checksum_free(dc->sum);
    g_clear_object(&dc->cancel);
    g_clear_object(&dc->session);
    g_clear_object(&dc->progress);
    g_free(dc->tmp_path);
    g_free(dc->final_path);
    g_free(dc);
}

static void download_fail(DownloadCtx *dc, const char *why) {
    boo_log(BOO_LOG_ERROR, "model download failed");
    if (dc->tmp_path) g_unlink(dc->tmp_path);
    dc->on_fail(why, dc->user_data);
    download_free(dc);
}

static void read_chunk(DownloadCtx *dc, GInputStream *stream);

static void on_chunk_read(GObject *source, GAsyncResult *result, gpointer user_data) {
    DownloadCtx *dc = user_data;
    GInputStream *stream = G_INPUT_STREAM(source);
    g_autoptr(GError) error = NULL;
    gssize n = g_input_stream_read_finish(stream, result, &error);

    if (n < 0) {
        g_object_unref(stream);
        download_fail(dc, "Download interrupted.");
        return;
    }
    if (n == 0) { // end of stream: verify, move into place, report
        g_object_unref(stream);
        g_output_stream_close(G_OUTPUT_STREAM(dc->out), NULL, NULL);
        const char *got = g_checksum_get_string(dc->sum);
        if (g_ascii_strcasecmp(got, dc->model->sha256) != 0) {
            download_fail(dc, "Downloaded file failed its checksum. Try again.");
            return;
        }
        if (g_rename(dc->tmp_path, dc->final_path) != 0) {
            download_fail(dc, "Could not save the model file.");
            return;
        }
        boo_log(BOO_LOG_INFO, "model downloaded and verified");
        dc->on_done(dc->final_path, dc->user_data);
        download_free(dc);
        return;
    }

    if (!g_output_stream_write_all(G_OUTPUT_STREAM(dc->out), dc->buf, (gsize)n, NULL,
                                   NULL, NULL)) {
        g_object_unref(stream);
        download_fail(dc, "Could not write the model file (disk full?).");
        return;
    }
    g_checksum_update(dc->sum, dc->buf, n);
    dc->received += n;
    // The manifest size is exact; a longer body is the wrong file, and the
    // bound keeps a misbehaving server from filling the disk before the
    // checksum check ever runs.
    if (dc->received > (goffset)dc->model->size) {
        g_object_unref(stream);
        download_fail(dc, "The download is larger than the model. Try again.");
        return;
    }
    if (dc->progress)
        gtk_progress_bar_set_fraction(dc->progress,
                                      (double)dc->received / (double)dc->model->size);
    read_chunk(dc, stream);
}

static void read_chunk(DownloadCtx *dc, GInputStream *stream) {
    g_input_stream_read_async(stream, dc->buf, sizeof(dc->buf), G_PRIORITY_DEFAULT,
                              dc->cancel, on_chunk_read, dc);
}

static void on_send_ready(GObject *source, GAsyncResult *result, gpointer user_data) {
    DownloadCtx *dc = user_data;
    g_autoptr(GError) error = NULL;
    GInputStream *stream = soup_session_send_finish(SOUP_SESSION(source), result, &error);
    if (!stream) {
        download_fail(dc, "Could not connect. Check your network and try again.");
        return;
    }

    // send_async succeeds on an HTTP error too; without this a moved URL
    // streams the 404 page to disk and surfaces as a baffling checksum
    // failure that retries forever.
    SoupMessage *msg =
        soup_session_get_async_result_message(SOUP_SESSION(source), result);
    if (!msg || soup_message_get_status(msg) != SOUP_STATUS_OK) {
        g_object_unref(stream);
        download_fail(dc, "The server did not return the model. Try again later.");
        return;
    }

    g_autoptr(GError) ferr = NULL;
    GFile *file = g_file_new_for_path(dc->tmp_path);
    dc->out = g_file_replace(file, NULL, FALSE, G_FILE_CREATE_NONE, NULL, &ferr);
    g_object_unref(file);
    if (!dc->out) {
        g_object_unref(stream);
        download_fail(dc, "Could not create the model file.");
        return;
    }
    read_chunk(dc, stream);
}

void boo_model_download(const BooModelInfo *model, GtkProgressBar *progress,
                        BooDownloadDone on_done, BooDownloadFail on_fail,
                        gpointer user_data) {
    DownloadCtx *dc = g_new0(DownloadCtx, 1);
    dc->model = model;
    dc->progress = progress ? g_object_ref(progress) : NULL;
    dc->on_done = on_done;
    dc->on_fail = on_fail;
    dc->user_data = user_data;

    g_autofree char *dir = boo_models_write_dir();
    dc->final_path = g_build_filename(dir, model->filename, NULL);
    dc->tmp_path = g_strconcat(dc->final_path, ".part", NULL);
    dc->sum = g_checksum_new(G_CHECKSUM_SHA256);
    dc->cancel = g_cancellable_new();
    dc->session = soup_session_new();

    SoupMessage *msg = soup_message_new("GET", model->url);
    soup_session_send_async(dc->session, msg, G_PRIORITY_DEFAULT, dc->cancel,
                            on_send_ready, dc);
    g_object_unref(msg);
}
