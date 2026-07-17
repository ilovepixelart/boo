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
#include "models.h"
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
    g_autofree const char *dir =
        (state && *state)
            ? g_build_filename(state, "boo", NULL)
            : g_build_filename(g_get_home_dir(), ".local", "state", "boo", NULL);
    g_mkdir_with_parents(dir, 0700);
    g_autofree const char *path = g_build_filename(dir, "boo.log", NULL);
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
    g_autofree char *vad_path = boo_find_vad_model_path();
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

    gtk_window_present(boo_overlay_window_new(app, state->ctx, model_path));
}

// ── in-app model download (docs/model-onboarding.md) ──
// A curated dropdown + a progress bar; the transfer itself (streaming,
// SHA-256 verification, atomic move) lives in models.c and is shared with the
// settings model switcher. The manifest (boo_models) is the shared source.

// The onboarding dialog's widgets, for the transfer callbacks. Owned by the
// dialog window.
typedef struct {
    AppState *state;
    GtkWidget *win;
    GtkDropDown *dropdown;
    GtkProgressBar *progress;
    GtkLabel *status;
    GtkWidget *button;
} OnboardingUI;

static void on_onboarding_done(const char *path, gpointer user_data) {
    OnboardingUI *ui = user_data;
    AppState *state = ui->state;
    g_autofree char *loaded = g_strdup(path);
    gtk_window_destroy(GTK_WINDOW(ui->win)); // frees ui, the window owns it
    start_with_model(state, loaded);         // open the app
}

static void on_onboarding_fail(const char *why, gpointer user_data) {
    OnboardingUI *ui = user_data;
    gtk_label_set_text(ui->status, why);
    gtk_widget_set_sensitive(ui->button, TRUE);
    gtk_window_set_deletable(GTK_WINDOW(ui->win), TRUE);
}

static void on_download_clicked(GtkButton *button, gpointer user_data) {
    OnboardingUI *ui = user_data;
    guint idx = gtk_drop_down_get_selected(ui->dropdown);
    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);
    if (idx >= count) return;

    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    gtk_label_set_text(ui->status, "Downloading…");
    // No mid-download close: the async chain updates this dialog's widgets.
    gtk_window_set_deletable(GTK_WINDOW(ui->win), FALSE);
    boo_model_download(&models[idx], ui->progress, on_onboarding_done, on_onboarding_fail,
                       ui);
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

    OnboardingUI *ui = g_new0(OnboardingUI, 1);
    ui->state = state;
    ui->win = win;
    ui->dropdown = GTK_DROP_DOWN(dropdown);
    ui->progress = GTK_PROGRESS_BAR(progress);
    ui->status = GTK_LABEL(status);
    ui->button = button;
    g_object_set_data_full(G_OBJECT(win), "boo-onboarding-ui", ui, g_free);
    g_signal_connect(button, "clicked", G_CALLBACK(on_download_clicked), ui);

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
        g_autofree const char *path = g_file_get_path(file);
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

    g_autofree char *model_path = boo_find_model_path();
    if (!model_path) {
        boo_log(BOO_LOG_ERROR, "no speech model found");
        g_autofree char *hint = model_install_hint();
        show_no_model_dialog(state, hint);
        return;
    }
    start_with_model(state, model_path);
}

static void on_shutdown(const GApplication *app, gpointer user_data) {
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
