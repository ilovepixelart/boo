// Boo Linux apprt, entry point.
// Creates an AdwApplication, initializes the Boo Zig core, opens the overlay
// window, and tears everything down on shutdown.
//
// Permissions: microphone access on Linux is mediated by the PipeWire daemon
// (and the org.freedesktop.portal.PipeWire portal under Flatpak). The user
// will see a system permission prompt on first capture; no in-app UI needed.

#include <adwaita.h>
#include <gtk/gtk.h>
#include <stdlib.h>

#include "boo.h"
#include "overlay_window.h"

typedef struct {
    BooContext *ctx;
} AppState;

// Pick a whisper model out of `dir`, or NULL if it holds none.
//
// Any of whisper.cpp's GGML models works, so this accepts any ggml-*.bin rather
// than only the ggml-base.en.bin we happen to recommend, pinning the filename
// meant a user who followed our own advice and fetched, say, large-v3-turbo
// would be told no model was installed.
// Models the README recommends, most capable first. Parakeet TDT tops the
// list: near large-v3 accuracy at roughly base.en decode speed. Downloading
// a bigger model is a deliberate act, so it wins over the default base.en
// when both exist. Matches the macOS frontend.
static const char *const preferred_models[] = {
    "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
    "ggml-parakeet-tdt-0.6b-v3-f16.bin",
    "ggml-large-v3-turbo-q5_0.bin",
    "ggml-large-v3-turbo.bin",
    "ggml-small.en.bin",
    "ggml-base.en.bin",
};

// Position in preferred_models, or one past the end for everything else.
static unsigned model_rank(const char *name) {
    for (unsigned i = 0; i < G_N_ELEMENTS(preferred_models); i++) {
        if (g_str_equal(name, preferred_models[i])) return i;
    }
    return G_N_ELEMENTS(preferred_models);
}

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
        unsigned rank = model_rank(name);
        if (!best || rank < best_rank || (rank == best_rank && g_strcmp0(name, best) < 0)) {
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

// Search order: $BOO_MODEL, ./models, $XDG_DATA_HOME/boo/models (falling back to
// ~/.local/share/boo/models), then /usr/share/boo/models.
// Returns NULL when nothing is found, so the caller can say so properly.
static char *find_model_path(void) {
    const char *env = g_getenv("BOO_MODEL");
    if (env && *env) {
        if (g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);
        g_warning("Boo: BOO_MODEL points at %s, which does not exist", env);
    }

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
        char *found = find_model_in(dirs[i]);
        if (found) return found;
    }
    return NULL;
}

static void show_error(GtkApplication *app, const char *heading, const char *body) {
    AdwAlertDialog *dialog = ADW_ALERT_DIALOG(adw_alert_dialog_new(heading, body));
    adw_alert_dialog_add_response(dialog, "quit", "Quit");
    g_signal_connect_swapped(dialog, "response", G_CALLBACK(g_application_quit), app);
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
        "Boo needs a whisper model, which isn't bundled, they're 140 MB+.\n\n"
        "Download one and relaunch:\n\n"
        "  mkdir -p %s\n"
        "  curl -L -o %s/ggml-base.en.bin \\\n"
        "    "
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin\n\n"
        "Or point BOO_MODEL at a model you already have.",
        dir, dir);
}

static void on_activate(AdwApplication *app, gpointer user_data) {
    AppState *state = user_data;

    g_autofree char *model_path = find_model_path();
    if (!model_path) {
        g_autofree char *hint = model_install_hint();
        show_error(GTK_APPLICATION(app), "No speech model found", hint);
        return;
    }
    g_print("Boo 👻 loading model: %s\n", model_path);

    state->ctx = boo_init(model_path);
    if (!state->ctx) {
        g_autofree char *body = g_strdup_printf(
            "%s\n\nThe file exists but whisper could not read it. It may be "
            "corrupt or truncated, try downloading it again.",
            model_path);
        show_error(GTK_APPLICATION(app), "Could not load the model", body);
        return;
    }
    g_print("Model loaded.\n");

    GtkWindow *window = boo_overlay_window_new(GTK_APPLICATION(app), state->ctx);
    gtk_window_present(window);
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
