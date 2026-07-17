// Headless harness for the GTK overlay (linux/tests/ui-harness.sh builds and
// runs it under Xvfb). Includes the source under test so its statics are
// reachable (the portal_payloads.c pattern): the widget tree is real, the
// BooContext is NULL (every core call tolerates that), and the checks drive
// the same handlers the app wires to signals. What the pixel smoke cannot
// reach lives here: the transcription worker round-trip, the tracked-idle
// machinery, the Settings dialog logic, and the manifest download engine
// against a local HTTP server (BOO_HARNESS_HTTP_PORT/_DIR, set by the
// wrapper; the download slice is skipped when absent).

#include "overlay_window.c"

#include <glib/gstdio.h>
#include <stdio.h>

static int failures = 0;

static void check(gboolean ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Pump the main loop for `ms` wall-clock milliseconds.
static void pump_ms(guint ms) {
    gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < end) {
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
}

// Pump until the status line shows `want`; FALSE on timeout. Polling beats a
// single sleep because portal failures may briefly rewrite the hint.
static gboolean wait_hint(WindowState *st, const char *want, guint ms) {
    gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < end) {
        if (g_strcmp0(gtk_label_get_text(st->hint_label), want) == 0) return TRUE;
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
    return FALSE;
}

// Pump until `label`'s text contains `substr`; FALSE on timeout. Used for the
// model switcher, whose GTask finish updates the status label on the main loop.
static gboolean pump_hint_until(GtkLabel *label, const char *substr, guint ms) {
    gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < end) {
        const char *t = gtk_label_get_text(label);
        if (t && strstr(t, substr)) return TRUE;
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
    return FALSE;
}

// ── download engine, against the wrapper's local HTTP server ──

typedef struct {
    char *done_path;
    char *fail_why;
} DownloadOutcome;

static void on_dl_done(const char *path, gpointer data) {
    DownloadOutcome *out = data;
    out->done_path = g_strdup(path);
}

static void on_dl_fail(const char *why, gpointer data) {
    DownloadOutcome *out = data;
    out->fail_why = g_strdup(why);
}

static gboolean wait_download(DownloadOutcome *out, guint ms) {
    gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < end) {
        if (out->done_path || out->fail_why) return TRUE;
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
    return FALSE;
}

static void outcome_clear(DownloadOutcome *out) {
    g_free(out->done_path);
    g_free(out->fail_why);
    out->done_path = NULL;
    out->fail_why = NULL;
}

static void check_downloads(void) {
    const char *port = g_getenv("BOO_HARNESS_HTTP_PORT");
    const char *dir = g_getenv("BOO_HARNESS_HTTP_DIR");
    if (!port || !dir) {
        printf("  skip download checks (no local HTTP server)\n");
        return;
    }

    gchar *payload = NULL;
    gsize payload_len = 0;
    g_autofree char *payload_path = g_build_filename(dir, "harness-model.bin", NULL);
    if (!g_file_get_contents(payload_path, &payload, &payload_len, NULL)) {
        check(FALSE, "the served payload is readable");
        return;
    }
    g_autofree char *sha =
        g_compute_checksum_for_data(G_CHECKSUM_SHA256, (guchar *)payload, payload_len);
    g_free(payload);

    g_autofree char *url = g_strdup_printf("http://127.0.0.1:%s/harness-model.bin", port);
    BooModelInfo model = {.filename = "harness-model.bin",
                          .url = url,
                          .sha256 = sha,
                          .label = "harness",
                          .note = "harness",
                          .size = payload_len};
    DownloadOutcome out = {0};

    // Success: verified and moved into the (isolated) XDG data dir.
    boo_model_download(&model, NULL, on_dl_done, on_dl_fail, &out);
    check(wait_download(&out, 30000) && out.done_path != NULL,
          "a good download completes");
    check(out.done_path && g_file_test(out.done_path, G_FILE_TEST_EXISTS),
          "the verified file is in place");
    if (out.done_path) g_unlink(out.done_path);
    outcome_clear(&out);

    // Wrong pin: refused, and the .part never becomes the real name.
    model.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    boo_model_download(&model, NULL, on_dl_done, on_dl_fail, &out);
    check(wait_download(&out, 30000) && out.fail_why != NULL &&
              strstr(out.fail_why, "checksum") != NULL,
          "a wrong pin fails on the checksum");
    outcome_clear(&out);
    model.sha256 = sha;

    // A body longer than the manifest size: cut off by the size bound.
    model.size = payload_len - 1;
    boo_model_download(&model, NULL, on_dl_done, on_dl_fail, &out);
    check(wait_download(&out, 30000) && out.fail_why != NULL &&
              strstr(out.fail_why, "larger") != NULL,
          "an oversized body trips the size bound");
    outcome_clear(&out);
    model.size = payload_len;

    // A missing file: the HTTP status check, not a baffling checksum error.
    g_autofree char *gone = g_strdup_printf("http://127.0.0.1:%s/no-such-file.bin", port);
    model.url = gone;
    boo_model_download(&model, NULL, on_dl_done, on_dl_fail, &out);
    check(wait_download(&out, 30000) && out.fail_why != NULL &&
              strstr(out.fail_why, "server") != NULL,
          "an HTTP error is reported as such");
    outcome_clear(&out);
}

int main(void) {
    adw_init();
    GtkApplication *app =
        gtk_application_new("com.boo.harness", G_APPLICATION_NON_UNIQUE);
    g_application_register(G_APPLICATION(app), NULL, NULL);

    printf("overlay_harness:\n");

    GtkWindow *win = boo_overlay_window_new(app, NULL, "/nonexistent/model.bin");
    check(win != NULL, "the overlay constructs without a context");
    WindowState *st = g_object_get_data(G_OBJECT(win), "boo-state");
    check(st != NULL, "the window state rides on the window");
    if (!st) return 1;
    gtk_window_present(win);
    // Let the portal requests fail (no portals under Xvfb) so their callbacks
    // stop rewriting the status line under the checks below.
    pump_ms(1500);

    // Status line and record button states.
    const char *hint = gtk_label_get_text(st->hint_label);
    check(g_strcmp0(hint, "ctrl+shift+space") == 0 ||
              g_strcmp0(hint, "click record to dictate") == 0,
          "the idle hint is one of the two idle forms");
    set_button_recording(st);
    check(gtk_widget_has_css_class(GTK_WIDGET(st->record_button), "boo-recording"),
          "the recording class lands on the disc");
    set_button_idle(st);
    check(!gtk_widget_has_css_class(GTK_WIDGET(st->record_button), "boo-recording"),
          "idle removes it again");

    // A transient hint schedules its own reset back to idle.
    set_hint_transient(st, "harness transient");
    check(g_strcmp0(gtk_label_get_text(st->hint_label), "harness transient") == 0,
          "a transient hint shows");
    check(st->hint_reset != 0, "and schedules its reset");
    guint reset_id = st->hint_reset;
    hint_reset_cb(st);
    g_source_remove(reset_id);
    check(st->hint_reset == 0, "the reset clears its own id");

    // No microphone (NULL context): a toggle must refuse and say why.
    toggle_recording(st);
    check(!st->ui_recording, "a no-mic toggle never starts a take");
    check(g_strcmp0(gtk_label_get_text(st->hint_label), "no microphone") == 0,
          "the no-mic hint shows");
    reset_id = st->hint_reset;
    hint_reset_cb(st);
    if (reset_id != 0) g_source_remove(reset_id);

    // Transcript cards: create, copy (flash + clipboard), dismiss.
    GtkWidget *card = card_new(st, "harness card", FALSE);
    gtk_box_append(st->card_stack, card);
    GtkWidget *header = gtk_widget_get_first_child(card);
    GtkWidget *copy_btn = gtk_widget_get_first_child(header);
    GtkWidget *close_btn = gtk_widget_get_last_child(header);
    on_card_copy(GTK_BUTTON(copy_btn), st);
    check(gtk_widget_has_css_class(copy_btn, "boo-flash"), "copy flashes its icon");
    pump_ms(700);
    check(!gtk_widget_has_css_class(copy_btn, "boo-flash"), "the flash settles");
    on_card_dismiss(GTK_BUTTON(close_btn), st);
    check(gtk_widget_get_first_child(GTK_WIDGET(st->card_stack)) == NULL,
          "dismiss removes the card");

    // The provisional live card while recording.
    st->ui_recording = TRUE;
    TranscribeResult live = {.state = st, .text = g_strdup("live words")};
    live_text_update(&live);
    check(st->live_card != NULL, "live text creates the provisional card");
    check(g_strcmp0(gtk_label_get_text(st->live_label), "live words") == 0,
          "the live card shows the committed text");
    g_free(live.text);
    live_card_remove(st);
    check(st->live_card == NULL, "the live card retires");
    scroll_to_newest(st);

    // Auto-type off: transcripts stay clipboard-only (also keeps this harness
    // from poking the RemoteDesktop portal on every synthetic transcript).
    st->settings.auto_type = FALSE;

    // A full transcription round-trip with a NULL context: worker thread,
    // tracked idle, and the no-speech transient. Then a second full cycle:
    // the tracked-idle state must survive consecutive takes (this is the
    // use-after-free regression check).
    st->ui_recording = TRUE;
    begin_transcription(st);
    check(wait_hint(st, "no speech detected", 5000),
          "a null transcript reports no speech");
    check(gtk_widget_get_sensitive(GTK_WIDGET(st->record_button)),
          "the record button re-enables");
    st->ui_recording = TRUE;
    begin_transcription(st);
    check(wait_hint(st, "no speech detected", 5000),
          "a second consecutive take still works");

    // A real transcript through the same completion path: card + clipboard.
    TranscribeResult *res = g_new0(TranscribeResult, 1);
    res->state = st;
    res->text = g_strdup("final transcript");
    transcribe_done(res);
    transcribe_result_free(res);
    check(gtk_widget_get_first_child(GTK_WIDGET(st->card_stack)) != NULL,
          "a transcript lands as a card");

    // The cap path: with recording gone the poll wraps the take up.
    st->ui_recording = TRUE;
    check(check_auto_stop(st) == G_SOURCE_REMOVE, "the cap check ends the poll");
    check(wait_hint(st, "no speech detected", 5000), "the capped take transcribes");
    check(check_auto_stop(st) == G_SOURCE_REMOVE, "the poll retires once the take ended");

    // Hotkey unavailable: honest status, and the idle hint stops promising it.
    on_shortcut_unavailable("harness reason", st);
    check(!st->hotkey_ok, "the hotkey downgrade sticks");
    check(g_strcmp0(gtk_label_get_text(st->hint_label), "click record to dictate") == 0,
          "the idle hint falls back to the button");

    // Themes: the repo set loads, selection persists, bounds hold.
    check(st->settings.themes != NULL && st->settings.themes->len >= 400,
          "the Ghostty theme set loads");
    select_theme(st, 0);
    check(st->settings.current_theme == 0, "a theme selection applies");
    select_theme(st, -3);
    select_theme(st, (int)st->settings.themes->len);
    check(st->settings.current_theme == 0, "out-of-bounds selections are ignored");

    // Settings round-trip through the isolated XDG config home.
    st->settings.opacity = 0.65;
    st->settings.auto_type = FALSE;
    settings_save(st);
    st->settings.opacity = 1.0;
    st->settings.auto_type = TRUE;
    st->settings.current_theme = -1;
    settings_load(st);
    check(st->settings.opacity > 0.64 && st->settings.opacity < 0.66,
          "opacity survives the save/load round-trip");
    check(!st->settings.auto_type, "auto-type survives it too");
    check(st->settings.current_theme == 0, "the theme choice survives it");

    // The Settings dialog: singleton, search, busy refusal, teardown.
    open_settings(NULL, st);
    check(st->settings.dialog != NULL, "the Settings dialog opens");
    SettingsUI *ui = NULL;
    if (st->settings.dialog) {
        ui = g_object_get_data(G_OBJECT(st->settings.dialog), "boo-settings-ui");
        check(ui != NULL, "its UI state rides on the dialog");
        GtkWindow *first = st->settings.dialog;
        open_settings(NULL, st);
        check(st->settings.dialog == first, "a second gear click reuses the dialog");
        pump_ms(300);
    }
    if (ui) {
        check(ui->model_entries != NULL && ui->model_entries->len > 0,
              "the model dropdown merges disk and manifest");
        gtk_editable_set_text(GTK_EDITABLE(ui->search), "dark");
        pump_ms(200);
        GtkWidget *scale =
            gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.1, 1.0, 0.05);
        g_object_ref_sink(scale);
        gtk_range_set_value(GTK_RANGE(scale), 0.55);
        on_opacity_changed(GTK_RANGE(scale), ui);
        check(st->settings.opacity > 0.54 && st->settings.opacity < 0.56,
              "the opacity slider applies live");
        g_object_unref(scale);
        GtkWidget *sw = gtk_switch_new();
        g_object_ref_sink(sw);
        check(on_autotype_changed(GTK_SWITCH(sw), TRUE, ui) == FALSE,
              "the auto-type switch handler lets the state settle");
        check(st->settings.auto_type, "and records the new preference");
        g_object_unref(sw);
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui->list, 0);
        if (row) on_theme_row(ui->list, row, ui);
        check(st->settings.current_theme == 0, "activating a theme row selects it");
        settings_set_busy(ui, TRUE);
        check(on_settings_close_request(ui->win, ui) == TRUE,
              "closing is refused while busy");
        settings_set_busy(ui, FALSE);
        check(on_settings_close_request(ui->win, ui) == FALSE,
              "closing is allowed when idle");

        // The model switcher. With a NULL context boo_reload_model returns
        // false, so a switch runs its worker + finish and reports the failure
        // without needing a real model load or network. This covers the GTask
        // path, the download callbacks, and on_model_selected.
        model_switch_start(ui, "/nonexistent/ggml-switch-target.bin");
        check(pump_hint_until(ui->model_status, "Could not load", 5000),
              "a failed model switch reports and re-enables");
        on_model_download_fail("harness download failure", ui);
        check(g_strcmp0(gtk_label_get_text(ui->model_status),
                        "harness download failure") == 0,
              "a failed model download surfaces its reason");
        on_model_download_done("/nonexistent/ggml-downloaded.bin", ui);
        check(pump_hint_until(ui->model_status, "Could not load", 5000),
              "a completed download swaps to the new model");

        // on_model_selected on a real on-disk entry: seed a fake model so the
        // dropdown lists it, then select it and drive the notify handler.
        g_autofree char *mdir = boo_models_write_dir();
        g_autofree char *fake = g_build_filename(mdir, "ggml-harness-fake.bin", NULL);
        g_file_set_contents(fake, "x", 1, NULL);
        model_list_rebuild(ui);
        guint fake_idx = 0;
        gboolean seeded = FALSE;
        for (guint i = 0; i < ui->model_entries->len; i++) {
            ModelEntry *e = g_ptr_array_index(ui->model_entries, i);
            if (e->path && strstr(e->path, "ggml-harness-fake")) {
                fake_idx = i;
                seeded = TRUE;
                break;
            }
        }
        check(seeded, "a seeded on-disk model appears in the dropdown");
        if (seeded) {
            ui->model_updating = TRUE;
            gtk_drop_down_set_selected(ui->model_dd, fake_idx);
            ui->model_updating = FALSE;
            on_model_selected(NULL, NULL, ui);
            check(pump_hint_until(ui->model_status, "Could not load", 5000),
                  "selecting an on-disk model drives a switch");
        }
        g_unlink(fake);

        gtk_window_destroy(st->settings.dialog);
        pump_ms(300);
        check(st->settings.dialog == NULL, "destroying the dialog clears the singleton");
    }

    // The manifest download engine against the wrapper's local server.
    check_downloads();

    // Full window teardown: joins workers, cancels pending idles, frees state.
    gtk_window_destroy(win);
    pump_ms(300);
    g_object_unref(app);

    printf("overlay_harness: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
