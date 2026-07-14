// Drives Boo's two XDG portal clients against a live session bus.
//
// Deliberately never calls boo_init(), so it needs no model and no PipeWire —
// the portal code has no audio dependency. What it proves is the part that has
// never run anywhere: that global_shortcut.c and text_inject.c complete their
// real D-Bus handshakes, that the request paths Boo predicts are the ones the
// portal actually replies on, and that an Activated signal reaches Boo's
// callback.
//
// Exit 0 only if the shortcut callback fired.

#include "global_shortcut.h"
#include "text_inject.h"

#include <adwaita.h>
#include <stdio.h>

static gboolean shortcut_fired = FALSE;
static gboolean shortcut_unavailable = FALSE;
static BooGlobalShortcut *shortcut = NULL;
static BooTextInject *inject = NULL;
static GtkWindow *window = NULL;

static void on_unavailable(const char *reason, gpointer user_data) {
    (void)user_data;
    printf("[harness] SHORTCUT UNAVAILABLE: %s\n", reason);
    fflush(stdout);
    shortcut_unavailable = TRUE;
}

static void on_shortcut(gpointer user_data) {
    (void)user_data;
    printf("[harness] SHORTCUT CALLBACK FIRED\n");
    fflush(stdout);
    shortcut_fired = TRUE;

    // Same thing the real app does after a transcript: ask the injector to
    // paste. Should surface as NotifyKeyboardKeysym on the bus.
    printf("[harness] requesting paste\n");
    fflush(stdout);
    boo_text_inject_paste(inject);
}

static gboolean finish(gpointer data) {
    GApplication *app = data;
    printf("[harness] done — shortcut_fired=%s\n", shortcut_fired ? "yes" : "no");
    fflush(stdout);
    if (shortcut) boo_global_shortcut_free(shortcut);
    if (inject) boo_text_inject_free(inject);
    g_application_quit(app);
    return G_SOURCE_REMOVE;
}

static void on_activate(AdwApplication *app, gpointer user_data) {
    (void)user_data;
    printf("[harness] activate — registering portal clients\n");
    fflush(stdout);

    window = GTK_WINDOW(adw_application_window_new(GTK_APPLICATION(app)));

    shortcut = boo_global_shortcut_new(window, on_shortcut, on_unavailable, NULL);
    inject = boo_text_inject_new(window);

    // Give the portal handshakes time to complete, then let the mock fire the
    // shortcut; the harness is torn down shortly after.
    g_timeout_add_seconds(8, finish, app);
}

int main(int argc, char **argv) {
    AdwApplication *app =
        adw_application_new("com.boo.harness", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);

    int rc = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);

    if (shortcut_unavailable) {
        fprintf(stderr, "[harness] FAIL: shortcut reported unavailable\n");
        return 1;
    }
    if (!shortcut_fired) {
        fprintf(stderr, "[harness] FAIL: shortcut callback never fired\n");
        return 1;
    }
    printf("[harness] PASS\n");
    return rc;
}
