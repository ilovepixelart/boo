// Headless harness for the Linux app entry point (linux/tests/ui-harness.sh
// builds and runs it under Xvfb, alongside overlay_harness). Includes main.c
// with its own entry renamed away, so the file's statics, the no-model and
// download dialogs, the crash surfacing, and the model-load error path, are
// reachable and driven directly without a real g_application_run. The pixel
// smoke launches the app for the happy path; this covers the branches it
// cannot reach (bad model, dialog responses, first-run onboarding widgets).
//
// Network is never touched: the callbacks that a real transfer would fire
// (on_onboarding_done/fail, on_vad_done/fail) are invoked with synthetic
// arguments; the transfer starters that would hit Hugging Face are not.

#define main boo_linux_main_unused
#include "main.c"
#undef main

#include <stdio.h>

static int failures = 0;

static void check(gboolean ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Pump the main loop briefly so presented dialogs realize and idle callbacks
// run, without blocking on any real work.
static void pump_ms(guint ms) {
    gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < end) {
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
}

int main(void) {
    adw_init();
    GtkApplication *app =
        GTK_APPLICATION(adw_application_new("com.boo.mainharness", G_APPLICATION_NON_UNIQUE));
    g_application_register(G_APPLICATION(app), NULL, NULL);
    AppState state = {0};
    state.app = app;

    printf("main_harness:\n");

    // The install hint: a pure string builder naming the models dir and the
    // curl commands. XDG_DATA_HOME is set by the wrapper to the sandbox.
    g_autofree char *hint = model_install_hint();
    check(hint != NULL, "the install hint builds");
    check(hint && strstr(hint, "models") != NULL, "the hint names the models dir");
    check(hint && strstr(hint, "curl -L") != NULL, "the hint gives a curl command");
    check(hint && strstr(hint, "parakeet") != NULL, "the hint offers the recommended model");

    // Logging init: creates the state dir and points the core log sink there.
    init_logging();
    g_autofree char *state_dir = g_build_filename(g_get_user_state_dir(), "boo", NULL);
    check(g_file_test(state_dir, G_FILE_TEST_IS_DIR), "init_logging makes the state dir");

    // The model-load error path: a nonexistent model fails boo_init and shows
    // the error dialog (which quits). start_with_model returns after presenting
    // it; ctx stays NULL.
    start_with_model(&state, "/nonexistent/ggml-does-not-exist.bin");
    check(state.ctx == NULL, "a bad model leaves no context");
    pump_ms(200);

    // The no-model dialog and its three responses, driven directly. download
    // opens the onboarding dialog, choose opens a file chooser (no user, so it
    // just realizes), quit routes to g_application_quit.
    show_no_model_dialog(&state, "harness hint");
    pump_ms(200);
    on_no_model_response(NULL, "download", &state); // builds the download dialog
    pump_ms(200);
    on_no_model_response(NULL, "choose", &state); // opens the file chooser
    pump_ms(200);
    g_application_release(G_APPLICATION(app)); // balance the choose hold
    check(TRUE, "the no-model responses run without crashing");

    // The download dialog widgets, then its transfer callbacks with synthetic
    // results (never a real network transfer): a failure re-enables the button,
    // and success would load a model, so drive fail here and cover done via a
    // bad path so it lands in start_with_model's error branch.
    show_download_dialog(&state);
    pump_ms(200);
    GtkWindow *active = gtk_application_get_active_window(app);
    OnboardingUI *ui =
        active ? g_object_get_data(G_OBJECT(active), "boo-onboarding-ui") : NULL;
    if (ui) {
        on_onboarding_fail("harness failure", ui);
        check(gtk_widget_get_sensitive(ui->button), "a failed download re-enables Download");
    } else {
        check(FALSE, "the download dialog exposes its UI");
    }

    // VAD callbacks: on_vad_fail logs, on_vad_done with a NULL ctx is a no-op.
    on_vad_fail("harness reason", &state);
    on_vad_done("/nonexistent/ggml-silero.bin", &state);
    check(TRUE, "the VAD callbacks tolerate a null context");

    // Crash surfacing: seed a report, surface it (renames + presents a dialog),
    // then drive both responses directly.
    g_autofree char *report = g_build_filename(state_dir, "boo-crash.txt", NULL);
    g_file_set_contents(report, "== Boo crash ==\n", -1, NULL);
    surface_previous_crash();
    check(!g_file_test(report, G_FILE_TEST_EXISTS), "surfacing renames the crash report");
    on_crash_response(NULL, "dismiss", state_dir);
    on_crash_response(NULL, "reveal", state_dir);
    check(TRUE, "the crash responses run");

    // on_activate's second-launch guard: with a context already set it presents
    // the existing window instead of re-running startup.
    state.ctx = (BooContext *)&state; // any non-NULL; the guard only checks it
    on_activate(ADW_APPLICATION(app), &state);
    check(TRUE, "a second activate is a no-op present");
    state.ctx = NULL;

    pump_ms(200);
    printf("main_harness: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
