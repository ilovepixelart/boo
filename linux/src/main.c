// Boo Linux apprt, entry point.
// Creates an AdwApplication, initializes the Boo Zig core, opens the overlay
// window, and tears everything down on shutdown.
//
// Permissions: microphone access on Linux is mediated by the PipeWire daemon
// (and the org.freedesktop.portal.PipeWire portal under Flatpak). The user
// will see a system permission prompt on first capture; no in-app UI needed.

#include <adwaita.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <stdlib.h>

#include "boo.h"
#include "overlay_window.h"

#define VAD_MODEL_NAME "ggml-silero-v6.2.0.bin"
#define VAD_MODEL_URL                                                                    \
    "https://huggingface.co/ggml-org/whisper-vad/resolve/main/" VAD_MODEL_NAME
// Pinned SHA-256 (HuggingFace LFS oid). The download is over TLS, but pinning
// defends against a compromised mirror handing a substituted GGUF to the ggml
// parser, and rejects a truncated or oversized body before it is written.
#define VAD_MODEL_SHA256                                                                 \
    "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

typedef struct {
    BooContext *ctx;
    GtkApplication *app; // for callbacks that outlive on_activate (file picker)
} AppState;

// Pick a whisper (or parakeet) model out of `dir`, or NULL if it holds none.
//
// Any GGML speech model works, so this accepts any ggml-*.bin rather than only
// the ggml-base.en.bin we happen to recommend, pinning the filename meant a
// user who followed our own advice and fetched, say, large-v3-turbo would be
// told no model was installed.
static char *find_model_in(const char *dir) {
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return NULL;

    char *best = NULL;
    unsigned best_rank = 0;
    const char *name;
    while ((name = g_dir_read_name(d))) {
        if (!g_str_has_prefix(name, "ggml-") || !g_str_has_suffix(name, ".bin")) continue;
        // ggml-silero-* is the VAD model, not a speech model.
        if (g_str_has_prefix(name, "ggml-silero")) continue;

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
        if (!g_str_has_prefix(name, "ggml-silero") || !g_str_has_suffix(name, ".bin"))
            continue;
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

// Walk the model directories with a per-directory finder. Search order:
// ./models, $XDG_DATA_HOME/boo/models (falling back to
// ~/.local/share/boo/models), then /usr/share/boo/models.
static char *search_model_dirs(char *(*find_in)(const char *dir)) {
    g_autofree char *xdg = NULL;
    const char *xdg_env = g_getenv("XDG_DATA_HOME");
    if (xdg_env && *xdg_env) {
        xdg = g_build_filename(xdg_env, "boo", "models", NULL);
    } else {
        xdg =
            g_build_filename(g_get_home_dir(), ".local", "share", "boo", "models", NULL);
    }

    const char *dirs[] = {"models", xdg, "/usr/share/boo/models", NULL};
    for (int i = 0; dirs[i]; i++) {
        char *found = find_in(dirs[i]);
        if (found) return found;
    }
    return NULL;
}

// Returns NULL when nothing is found, so the caller can say so properly.
// $BOO_MODEL wins outright.
static char *find_model_path(void) {
    const char *env = g_getenv("BOO_MODEL");
    if (env && *env) {
        if (g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);
        g_warning("Boo: BOO_MODEL points at %s, which does not exist", env);
    }
    return search_model_dirs(find_model_in);
}

// $BOO_VAD_MODEL wins outright, matching $BOO_MODEL.
static char *find_vad_model_path(void) {
    const char *env = g_getenv("BOO_VAD_MODEL");
    if (env && *env) {
        if (g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);
        g_warning("Boo: BOO_VAD_MODEL points at %s, which does not exist", env);
    }
    return search_model_dirs(find_vad_model_in);
}

static void show_error(GtkApplication *app, const char *heading, const char *body) {
    AdwAlertDialog *dialog = ADW_ALERT_DIALOG(adw_alert_dialog_new(heading, body));
    adw_alert_dialog_add_response(dialog, "quit", "Quit");
    g_signal_connect_swapped(dialog, "response", G_CALLBACK(g_application_quit), app);
    // Parentless dialogs are not application windows, so without a hold the
    // main loop sees zero windows and quits before the dialog ever appears.
    // The response handler above quits, which terminates through the hold.
    g_application_hold(G_APPLICATION(app));
    adw_dialog_present(ADW_DIALOG(dialog), NULL);
}

// Where the model goes depends on how Boo was installed, so tell the user rather
// than making them guess. Inside Flatpak, XDG_DATA_HOME points at the sandbox.
static char *model_install_hint(void) {
    const char *xdg = g_getenv("XDG_DATA_HOME");
    g_autofree char *dir = xdg && *xdg ? g_build_filename(xdg, "boo", "models", NULL)
                                       : g_build_filename(g_get_home_dir(), ".local",
                                                          "share", "boo", "models", NULL);

    return g_strdup_printf(
        "Boo needs a speech model, which isn't bundled.\n\n"
        "Download one and relaunch.\n\n"
        "Recommended, best accuracy, 25 languages (669 MB):\n"
        "  mkdir -p %s\n"
        "  curl -L -o %s/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \\\n"
        "    "
        "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/"
        "ggml-parakeet-tdt-0.6b-v3-q8_0.bin\n\n"
        "Lighter and faster, English only (148 MB):\n"
        "  curl -L -o %s/ggml-base.en.bin \\\n"
        "    "
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin\n\n"
        "Or point BOO_MODEL at a model you already have.",
        dir, dir, dir);
}

// Fetch the Silero VAD model in the background on first run, mirroring the
// macOS frontend. It is under 1 MB and carries no size/language decision the
// user needs to make (unlike the speech models), so streaming transcription
// just starts working; batch mode covers the seconds until it lands, and any
// failure (offline, sandbox without network) leaves batch mode as before.
static void on_vad_downloaded(GObject *source, GAsyncResult *result, gpointer user_data) {
    AppState *state = user_data;
    SoupSession *session = SOUP_SESSION(source);

    g_autoptr(GError) error = NULL;
    g_autoptr(GBytes) bytes = soup_session_send_and_read_finish(session, result, &error);
    SoupMessage *msg = soup_session_get_async_result_message(session, result);
    guint status = msg ? soup_message_get_status(msg) : 0;

    if (!bytes || status != SOUP_STATUS_OK) {
        g_warning("Boo: VAD model download failed (%s); staying in batch mode",
                  error ? error->message : soup_status_get_phrase(status));
        g_object_unref(session);
        return;
    }

    // Verify integrity before trusting the bytes: a mismatch means a corrupt,
    // truncated, or substituted file, so drop it and stay in batch mode.
    g_autofree char *digest = g_compute_checksum_for_bytes(G_CHECKSUM_SHA256, bytes);
    if (!digest || g_strcmp0(digest, VAD_MODEL_SHA256) != 0) {
        g_warning("Boo: VAD model failed checksum; staying in batch mode");
        g_object_unref(session);
        return;
    }

    g_autofree char *dir = g_build_filename(g_get_user_data_dir(), "boo", "models", NULL);
    g_autofree char *dest = g_build_filename(dir, VAD_MODEL_NAME, NULL);
    gsize size = 0;
    const char *data = g_bytes_get_data(bytes, &size);

    g_mkdir_with_parents(dir, 0755);
    // g_file_set_contents writes to a temp file and renames, so a crash
    // mid-download never leaves a truncated model for the next launch.
    if (!g_file_set_contents(dest, data, (gssize)size, &error)) {
        g_warning("Boo: could not save the VAD model: %s", error->message);
        g_object_unref(session);
        return;
    }

    // This callback runs on the main loop; the shutdown handler also runs
    // there, so ctx cannot be torn down beneath us mid-call.
    if (state->ctx && boo_load_vad(state->ctx, dest)) {
        g_print("Streaming transcription enabled: %s\n", dest);
    }
    g_object_unref(session);
}

static void download_vad_model(AppState *state) {
    g_print("Fetching the VAD model to enable streaming transcription\n");
    SoupSession *session = soup_session_new();
    g_autoptr(SoupMessage) msg = soup_message_new(SOUP_METHOD_GET, VAD_MODEL_URL);
    soup_session_send_and_read_async(session, msg, G_PRIORITY_DEFAULT, NULL,
                                     on_vad_downloaded, state);
}

// Open the diagnostic log file at $XDG_STATE_HOME/boo/boo.log (else
// ~/.local/state/boo/boo.log). Best-effort; on failure boo_log falls back to
// stderr only. Never logs transcript text (see docs/logging-and-crash-reporting.md).
static void init_logging(void) {
    const char *state = g_getenv("XDG_STATE_HOME");
    g_autofree char *dir =
        (state && *state)
            ? g_build_filename(state, "boo", NULL)
            : g_build_filename(g_get_home_dir(), ".local", "state", "boo", NULL);
    g_mkdir_with_parents(dir, 0700);
    g_autofree char *path = g_build_filename(dir, "boo.log", NULL);
    boo_log_init(path, BOO_LOG_INFO);
}

// Load `model_path`, wire optional VAD, and open the overlay. On a load failure
// shows the error dialog (which quits). Shared by auto-discovery and the picker.
static void start_with_model(AppState *state, const char *model_path) {
    GtkApplication *app = state->app;
    g_print("Boo 👻 loading model: %s\n", model_path);

    state->ctx = boo_init(model_path);
    if (!state->ctx) {
        boo_log(BOO_LOG_ERROR, "speech model failed to load");
        g_autofree char *body = g_strdup_printf(
            "%s\n\nThe file exists but whisper could not read it. It may be "
            "corrupt or truncated, try downloading it again.",
            model_path);
        show_error(app, "Could not load the model", body);
        return;
    }
    g_print("Model loaded.\n");
    boo_log(BOO_LOG_INFO, "speech model loaded");

    // Optional streaming VAD: with a Silero model present, utterances are
    // transcribed at natural pauses while still recording, and only the final
    // one remains after stop. Without it, batch mode as before.
    g_autofree char *vad_path = find_vad_model_path();
    if (vad_path) {
        if (boo_load_vad(state->ctx, vad_path)) {
            g_print("Streaming transcription enabled: %s\n", vad_path);
        } else {
            g_warning("Boo: could not load VAD model %s, staying in batch mode",
                      vad_path);
        }
    } else {
        download_vad_model(state);
    }

    gtk_window_present(boo_overlay_window_new(app, state->ctx));
}

// ── in-app model download (docs/model-onboarding.md) ──
// A curated dropdown + a progress bar; the file streams to models/<name>.part,
// its SHA-256 is verified against the pinned manifest digest, then it is moved
// into place and the app opens. The manifest (boo_models) is the shared source.

typedef struct {
    AppState *state;
    const BooModelInfo *model;
    GtkWidget *win;
    GtkProgressBar *progress;
    GtkLabel *status;
    GtkWidget *button;
    SoupSession *session;
    GCancellable *cancel;
    GChecksum *sum;
    GFileOutputStream *out;
    char *tmp_path;   // models/<name>.part while downloading
    char *final_path; // models/<name>
    goffset received;
    guint8 buf[65536];
} DownloadCtx;

static char *models_write_dir(void) {
    const char *xdg = g_getenv("XDG_DATA_HOME");
    char *dir = (xdg && *xdg) ? g_build_filename(xdg, "boo", "models", NULL)
                              : g_build_filename(g_get_home_dir(), ".local", "share",
                                                 "boo", "models", NULL);
    g_mkdir_with_parents(dir, 0700);
    return dir;
}

// Free the per-attempt download resources, so a retry starts clean. Leaves the
// DownloadCtx itself, which the dialog window owns (freed on window destroy).
static void download_reset(DownloadCtx *dc) {
    g_clear_object(&dc->out);
    if (dc->sum) {
        g_checksum_free(dc->sum);
        dc->sum = NULL;
    }
    g_clear_object(&dc->cancel);
    g_clear_object(&dc->session);
    g_clear_pointer(&dc->tmp_path, g_free);
    g_clear_pointer(&dc->final_path, g_free);
}

static void download_ctx_free(gpointer data) {
    DownloadCtx *dc = data;
    download_reset(dc);
    g_free(dc);
}

static void download_fail(DownloadCtx *dc, const char *why) {
    boo_log(BOO_LOG_ERROR, "model download failed");
    if (dc->tmp_path) g_unlink(dc->tmp_path);
    download_reset(dc);
    gtk_label_set_text(dc->status, why);
    gtk_widget_set_sensitive(dc->button, TRUE);
    gtk_window_set_deletable(GTK_WINDOW(dc->win), TRUE);
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
    if (n == 0) { // end of stream: verify, move into place, load
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
        AppState *st = dc->state;
        g_autofree char *path = g_strdup(dc->final_path);
        g_clear_pointer(&dc->tmp_path, g_free);  // moved, do not unlink
        gtk_window_destroy(GTK_WINDOW(dc->win)); // window owns dc, this frees it
        start_with_model(st, path);              // open the app
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

static void on_download_clicked(GtkButton *button, gpointer user_data) {
    DownloadCtx *dc = user_data;
    guint idx = gtk_drop_down_get_selected(
        GTK_DROP_DOWN(g_object_get_data(G_OBJECT(dc->win), "boo-model-dropdown")));
    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);
    if (idx >= count) return;
    dc->model = &models[idx];

    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    gtk_label_set_text(dc->status, "Downloading…");
    // No mid-download close: the async chain reads dc and its widgets.
    gtk_window_set_deletable(GTK_WINDOW(dc->win), FALSE);

    g_autofree char *dir = models_write_dir();
    dc->final_path = g_build_filename(dir, dc->model->filename, NULL);
    dc->tmp_path = g_strconcat(dc->final_path, ".part", NULL);
    dc->sum = g_checksum_new(G_CHECKSUM_SHA256);
    dc->received = 0;
    dc->cancel = g_cancellable_new();
    dc->session = soup_session_new();

    SoupMessage *msg = soup_message_new("GET", dc->model->url);
    soup_session_send_async(dc->session, msg, G_PRIORITY_DEFAULT, dc->cancel,
                            on_send_ready, dc);
    g_object_unref(msg);
}

// The download dialog: a curated model dropdown, a progress bar, and Download.
static void show_download_dialog(AppState *state) {
    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);

    GtkWidget *win = adw_window_new();
    // An application window so it keeps the app alive while it is the only one.
    gtk_window_set_application(GTK_WINDOW(win), state->app);
    gtk_window_set_title(GTK_WINDOW(win), "Download a Model");
    gtk_window_set_default_size(GTK_WINDOW(win), 400, 220);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(box, 16);
    gtk_widget_set_margin_bottom(box, 16);
    gtk_widget_set_margin_start(box, 16);
    gtk_widget_set_margin_end(box, 16);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(outer), adw_header_bar_new());
    gtk_box_append(GTK_BOX(outer), box);
    adw_window_set_content(ADW_WINDOW(win), outer);

    GtkStringList *labels = gtk_string_list_new(NULL);
    for (size_t i = 0; i < count; i++) {
        g_autofree char *row =
            g_strdup_printf("%s  (%s)", models[i].label, models[i].note);
        gtk_string_list_append(labels, row);
    }
    GtkWidget *dropdown = gtk_drop_down_new(G_LIST_MODEL(labels), NULL);
    g_object_set_data(G_OBJECT(win), "boo-model-dropdown", dropdown);
    gtk_box_append(GTK_BOX(box), dropdown);

    GtkWidget *progress = gtk_progress_bar_new();
    gtk_box_append(GTK_BOX(box), progress);
    GtkWidget *status = gtk_label_new("Downloads to your models folder, then opens Boo.");
    gtk_widget_add_css_class(status, "boo-hint");
    gtk_box_append(GTK_BOX(box), status);

    GtkWidget *button = gtk_button_new_with_label("Download");
    gtk_widget_add_css_class(button, "suggested-action");
    gtk_widget_set_halign(button, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(box), button);

    DownloadCtx *dc = g_new0(DownloadCtx, 1);
    dc->state = state;
    dc->win = win;
    dc->progress = GTK_PROGRESS_BAR(progress);
    dc->status = GTK_LABEL(status);
    dc->button = button;
    g_object_set_data_full(G_OBJECT(win), "boo-download-ctx", dc, download_ctx_free);
    g_signal_connect(button, "clicked", G_CALLBACK(on_download_clicked), dc);

    gtk_window_present(GTK_WINDOW(win));
}

// The "Choose a File" path on the no-model dialog: a native file chooser, then
// load the picked model and open the app. Zero network, the friendly
// alternative to editing BOO_MODEL for a user who already has a GGML model.
static void on_model_picked(GObject *source, GAsyncResult *result, gpointer user_data) {
    AppState *state = user_data;
    g_autoptr(GError) error = NULL;
    g_autoptr(GFile) file =
        gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file) {
        g_autofree char *path = g_file_get_path(file);
        if (path) start_with_model(state, path);
    }
    // Balances the hold taken in choose_model_file; on cancel this drops the
    // last hold and the app exits.
    g_application_release(G_APPLICATION(state->app));
}

static void choose_model_file(AppState *state) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose a speech model");
    g_application_hold(G_APPLICATION(state->app));
    gtk_file_dialog_open(dialog, NULL, NULL, on_model_picked, state);
    g_object_unref(dialog);
}

static void on_no_model_response(AdwAlertDialog *dialog, const char *response,
                                 gpointer user_data) {
    (void)dialog;
    AppState *state = user_data;
    if (g_strcmp0(response, "download") == 0) {
        show_download_dialog(state); // its window keeps the app alive
    } else if (g_strcmp0(response, "choose") == 0) {
        choose_model_file(state); // takes its own hold before we drop the dialog's
    } else {
        g_application_quit(G_APPLICATION(state->app));
    }
    g_application_release(G_APPLICATION(state->app));
}

// The no-model dialog: Download a model, Choose one already on disk, or Quit, so
// a first run never requires a terminal.
static void show_no_model_dialog(AppState *state, const char *hint) {
    AdwAlertDialog *dialog =
        ADW_ALERT_DIALOG(adw_alert_dialog_new("No speech model found", hint));
    adw_alert_dialog_add_response(dialog, "download", "Download…");
    adw_alert_dialog_add_response(dialog, "choose", "Choose a File…");
    adw_alert_dialog_add_response(dialog, "quit", "Quit");
    adw_alert_dialog_set_default_response(dialog, "download");
    g_signal_connect(dialog, "response", G_CALLBACK(on_no_model_response), state);
    g_application_hold(G_APPLICATION(state->app));
    adw_dialog_present(ADW_DIALOG(dialog), NULL);
}

static void on_activate(AdwApplication *app, gpointer user_data) {
    AppState *state = user_data;
    state->app = GTK_APPLICATION(app);
    init_logging();

    g_autofree char *model_path = find_model_path();
    if (!model_path) {
        boo_log(BOO_LOG_ERROR, "no speech model found");
        g_autofree char *hint = model_install_hint();
        show_no_model_dialog(state, hint);
        return;
    }
    start_with_model(state, model_path);
}

static void on_shutdown(GApplication *app, gpointer user_data) {
    (void)app;
    AppState *state = user_data;
    if (state->ctx) {
        boo_deinit(state->ctx);
        state->ctx = NULL;
    }
}

int main(int argc, char **argv) {
    AppState state = {0};

    g_autoptr(AdwApplication) app =
        adw_application_new("com.boo.app", G_APPLICATION_DEFAULT_FLAGS);

    g_signal_connect(app, "activate", G_CALLBACK(on_activate), &state);
    g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), &state);

    return g_application_run(G_APPLICATION(app), argc, argv);
}
