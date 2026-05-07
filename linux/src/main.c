// Boo Linux apprt — entry point.
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

static char *find_model_path(void) {
    // Search order: $BOO_MODEL env, CWD, XDG_DATA_HOME, ~/.local/share/boo
    const char *env = g_getenv("BOO_MODEL");
    if (env && g_file_test(env, G_FILE_TEST_EXISTS)) return g_strdup(env);

    g_autofree char *xdg = NULL;
    const char *xdg_env = g_getenv("XDG_DATA_HOME");
    if (xdg_env && *xdg_env) {
        xdg = g_build_filename(xdg_env, "boo", "models", "ggml-base.en.bin", NULL);
    } else {
        xdg = g_build_filename(g_get_home_dir(), ".local", "share", "boo", "models",
                               "ggml-base.en.bin", NULL);
    }

    const char *candidates[] = {
        "models/ggml-base.en.bin",
        xdg,
        "/usr/share/boo/models/ggml-base.en.bin",
        NULL,
    };
    for (int i = 0; candidates[i]; i++) {
        if (g_file_test(candidates[i], G_FILE_TEST_EXISTS)) {
            return g_strdup(candidates[i]);
        }
    }
    return g_strdup("models/ggml-base.en.bin");
}

static void show_model_error(GtkApplication *app, const char *model_path) {
    AdwAlertDialog *dialog = ADW_ALERT_DIALOG(adw_alert_dialog_new(
        "Model not found", NULL));
    adw_alert_dialog_format_body(dialog,
        "Could not load model at:\n%s\n\nDownload ggml-base.en.bin to that path.",
        model_path);
    adw_alert_dialog_add_response(dialog, "ok", "Quit");
    g_signal_connect_swapped(dialog, "response", G_CALLBACK(g_application_quit), app);
    adw_dialog_present(ADW_DIALOG(dialog), NULL);
}

static void on_activate(AdwApplication *app, gpointer user_data) {
    AppState *state = user_data;

    g_autofree char *model_path = find_model_path();
    g_print("Boo 👻 — loading model: %s\n", model_path);

    state->ctx = boo_init(model_path);
    if (!state->ctx) {
        show_model_error(GTK_APPLICATION(app), model_path);
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
