// Boo overlay window, record button, waveform display, transcript.
// Transcription runs on a worker thread (boo_transcribe is synchronous) and
// updates the UI back on the main loop via g_idle_add. The result is auto-
// copied to the system clipboard and announced via an AdwToast.

#include "overlay_window.h"
#include "global_shortcut.h"
#include "text_inject.h"
#include "waveform_widget.h"

#include <adwaita.h>
#include <stdbool.h>

typedef struct {
    BooContext *ctx;
    GtkWindow *window;
    GtkBox *card_stack; // transcript history, chronological, newest last
    GtkScrolledWindow *scroller;
    GtkWidget *live_card; // provisional streaming card, NULL when absent
    GtkLabel *live_label; // its text label
    GtkLabel *hint_label; // status line: hotkey hint / elapsed / thinking...
    GtkButton *record_button;
    GtkWidget *waveform;
    AdwToastOverlay *toast_overlay;
    BooGlobalShortcut *shortcut;
    BooTextInject *inject;
    GtkCssProvider *css; // reloaded on theme change
    guint hint_reset;    // 0 == no pending reset to the idle hint
    gboolean hotkey_ok;

    // The UI's own view of whether we're recording. Deliberately not
    // boo_is_recording(): the core clears that when it hits the recording cap.
    gboolean ui_recording;
    guint auto_stop_poll; // 0 == not polling

    // Streaming transcription: one dedicated thread polls boo_stream_tick
    // while recording (the C API wants ticks from a single background thread;
    // each call may block for one utterance's inference). The flag is the
    // thread's stop signal; the handle is joined before reuse or teardown.
    GThread *stream_thread; // NULL == no thread to join
    gint stream_running;    // atomic
    // The batch transcription thread. Kept joinable (not detached) so closing
    // the window mid-transcription joins it rather than leaving its completion
    // idle to fire against freed state.
    GThread *transcribe_thread; // NULL == no thread to join
} WindowState;

typedef struct {
    WindowState *state;
    char *text; // owned, may be NULL
} TranscribeResult;

static void window_state_free(gpointer data) {
    WindowState *state = data;
    // Cancel the timers first: closing the window mid-recording would
    // otherwise leave them firing against freed state.
    if (state->auto_stop_poll != 0) g_source_remove(state->auto_stop_poll);
    if (state->hint_reset != 0) g_source_remove(state->hint_reset);
    // The tick thread reads this state; it must be gone before the free.
    if (state->stream_thread) {
        g_atomic_int_set(&state->stream_running, 0);
        g_thread_join(state->stream_thread);
    }
    // Likewise the transcribe thread: closing the window during "Transcribing…"
    // must not leave it finishing against freed state. boo_deinit already
    // flushes the in-flight boo_transcribe, so this join is bounded.
    if (state->transcribe_thread) g_thread_join(state->transcribe_thread);
    if (state->shortcut) boo_global_shortcut_free(state->shortcut);
    if (state->inject) boo_text_inject_free(state->inject);
    if (state->css) g_object_unref(state->css);
    g_free(state);
}

static void show_toast(WindowState *st, const char *message) {
    AdwToast *toast = adw_toast_new(message);
    adw_toast_set_timeout(toast, 2);
    adw_toast_overlay_add_toast(st->toast_overlay, toast);
}

static void copy_to_clipboard(WindowState *st, const char *text) {
    GdkDisplay *display = gtk_widget_get_display(GTK_WIDGET(st->record_button));
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    gdk_clipboard_set_text(clipboard, text);
}

// ── status line (the reference's persistent hotkey hint) ──

static void set_hint(WindowState *st, const char *text) {
    gtk_label_set_text(st->hint_label, text);
}

static void set_hint_idle(WindowState *st) {
    set_hint(st, st->hotkey_ok ? "ctrl+shift+space" : "click record to dictate");
}

static gboolean hint_reset_cb(gpointer data) {
    WindowState *st = data;
    st->hint_reset = 0;
    if (!st->ui_recording) set_hint_idle(st);
    return G_SOURCE_REMOVE;
}

// Show a transient status, then settle back on the idle hint.
static void set_hint_transient(WindowState *st, const char *text) {
    set_hint(st, text);
    if (st->hint_reset != 0) g_source_remove(st->hint_reset);
    st->hint_reset = g_timeout_add(2500, hint_reset_cb, st);
}

static void set_button_idle(WindowState *st) {
    gtk_widget_set_sensitive(GTK_WIDGET(st->record_button), TRUE);
    gtk_widget_remove_css_class(GTK_WIDGET(st->record_button), "boo-recording");
}

static void set_button_recording(WindowState *st) {
    gtk_widget_add_css_class(GTK_WIDGET(st->record_button), "boo-recording");
}

// ── transcript cards (reference anatomy: docs/ui-spec.md) ──

static gboolean unflash_copy(gpointer data) {
    gtk_widget_remove_css_class(GTK_WIDGET(data), "boo-flash");
    return G_SOURCE_REMOVE;
}

static void on_card_copy(GtkButton *btn, gpointer user_data) {
    WindowState *st = user_data;
    GtkWidget *card = g_object_get_data(G_OBJECT(btn), "boo-card");
    const char *text = g_object_get_data(G_OBJECT(card), "boo-text");
    if (text) copy_to_clipboard(st, text);
    // The reference flashes the copy icon cyan for half a second.
    gtk_widget_add_css_class(GTK_WIDGET(btn), "boo-flash");
    g_timeout_add_full(G_PRIORITY_DEFAULT, 500, unflash_copy, g_object_ref(btn),
                       g_object_unref);
}

static void on_card_dismiss(GtkButton *btn, gpointer user_data) {
    WindowState *st = user_data;
    GtkWidget *card = g_object_get_data(G_OBJECT(btn), "boo-card");
    gtk_box_remove(st->card_stack, card);
}

// Keep the newest card visible after layout settles, the reference's
// scroll-to-newest.
static gboolean scroll_to_newest(gpointer data) {
    WindowState *st = data;
    GtkAdjustment *vadj = gtk_scrolled_window_get_vadjustment(st->scroller);
    gtk_adjustment_set_value(vadj, gtk_adjustment_get_upper(vadj) -
                                       gtk_adjustment_get_page_size(vadj));
    return G_SOURCE_REMOVE;
}

// A transcript card: header (copy … dismiss), separator, wrapped text.
// `live` cards are the dimmer provisional streaming variant with no header.
static GtkWidget *card_new(WindowState *st, const char *text, gboolean live) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(card, live ? "boo-card-live" : "boo-card");

    if (!live) {
        g_object_set_data_full(G_OBJECT(card), "boo-text", g_strdup(text), g_free);

        GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *copy = gtk_button_new_from_icon_name("edit-copy-symbolic");
        gtk_widget_add_css_class(copy, "flat");
        gtk_widget_add_css_class(copy, "boo-card-btn");
        g_object_set_data(G_OBJECT(copy), "boo-card", card);
        g_signal_connect(copy, "clicked", G_CALLBACK(on_card_copy), st);
        gtk_box_append(GTK_BOX(header), copy);

        GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_set_hexpand(spacer, TRUE);
        gtk_box_append(GTK_BOX(header), spacer);

        GtkWidget *close = gtk_button_new_from_icon_name("window-close-symbolic");
        gtk_widget_add_css_class(close, "flat");
        gtk_widget_add_css_class(close, "boo-card-btn");
        g_object_set_data(G_OBJECT(close), "boo-card", card);
        g_signal_connect(close, "clicked", G_CALLBACK(on_card_dismiss), st);
        gtk_box_append(GTK_BOX(header), close);

        gtk_box_append(GTK_BOX(card), header);
        gtk_box_append(GTK_BOX(card), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    }

    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0);
    gtk_label_set_selectable(GTK_LABEL(label), !live);
    gtk_box_append(GTK_BOX(card), label);
    if (live) g_object_set_data(G_OBJECT(card), "boo-live-label", label);

    return card;
}

static void live_card_remove(WindowState *st) {
    if (!st->live_card) return;
    gtk_box_remove(st->card_stack, st->live_card);
    st->live_card = NULL;
    st->live_label = NULL;
}

// Show committed-so-far text in the dim provisional card while recording.
// Ordering with the final transcript is safe: both this and transcribe_done
// run on the main loop, and begin_transcription clears ui_recording there
// first, so a stale live update queued behind the final text drops itself.
static gboolean live_text_update(gpointer user_data) {
    TranscribeResult *res = user_data;
    WindowState *st = res->state;
    if (st->ui_recording && res->text && *res->text) {
        if (!st->live_card) {
            st->live_card = card_new(st, "", TRUE);
            st->live_label =
                GTK_LABEL(g_object_get_data(G_OBJECT(st->live_card), "boo-live-label"));
            gtk_box_append(st->card_stack, st->live_card);
        }
        gtk_label_set_text(st->live_label, res->text);
        g_idle_add(scroll_to_newest, st);
    }
    g_free(res->text);
    g_free(res);
    return G_SOURCE_REMOVE;
}

// 250ms cadence: when nothing ended, a tick is a cheap VAD scan; when an
// utterance did end, the tick blocks for its inference and the next timer
// slot simply starts late. Ticks become no-ops once recording stops.
static gpointer stream_tick_worker(gpointer data) {
    WindowState *state = data;
    while (g_atomic_int_get(&state->stream_running)) {
        if (boo_stream_tick(state->ctx)) {
            const char *live = boo_get_live_transcript(state->ctx);
            if (live) {
                TranscribeResult *res = g_new0(TranscribeResult, 1);
                res->state = state;
                res->text = g_strdup(live);
                g_idle_add(live_text_update, res);
            }
        }
        g_usleep(250 * 1000);
    }
    return NULL;
}

static gboolean transcribe_done(gpointer user_data) {
    TranscribeResult *res = user_data;
    WindowState *state = res->state;

    // The provisional live card is superseded by the final transcript card
    // (or by "no speech") either way.
    live_card_remove(state);
    if (res->text && *res->text) {
        gtk_box_append(state->card_stack, card_new(state, res->text, FALSE));
        g_idle_add(scroll_to_newest, state);
        copy_to_clipboard(state, res->text);
        show_toast(state, "Copied to clipboard");
        set_hint_idle(state);
        // When dictation was triggered by the global hotkey, focus stayed in
        // the target app, auto-paste there. When our own window is focused
        // (Record button click), pasting would land back in Boo; skip it.
        if (!gtk_window_is_active(state->window)) {
            boo_text_inject_paste(state->inject);
        }
    } else {
        set_hint_transient(state, "no speech detected");
    }
    set_button_idle(state);

    g_free(res->text);
    g_free(res);
    return G_SOURCE_REMOVE;
}

static gpointer transcribe_worker(gpointer task_data) {
    WindowState *state = task_data;
    const char *text = boo_transcribe(state->ctx);

    TranscribeResult *res = g_new0(TranscribeResult, 1);
    res->state = state;
    res->text = text ? g_strdup(text) : NULL;
    g_idle_add(transcribe_done, res);
    return NULL;
}

// Stop capturing and kick off transcription on a worker thread.
static void begin_transcription(WindowState *state) {
    state->ui_recording = FALSE;
    if (state->auto_stop_poll != 0) {
        g_source_remove(state->auto_stop_poll);
        state->auto_stop_poll = 0;
    }

    // Signal the tick thread to wind down, but don't join here: a tick mid-
    // inference would stall the main thread. The core serializes tick against
    // boo_transcribe internally, and the handle is joined before the next
    // recording (or at window teardown).
    g_atomic_int_set(&state->stream_running, 0);

    boo_stop_recording(state->ctx);
    set_hint(state, "thinking...");
    set_button_idle(state);
    gtk_widget_set_sensitive(GTK_WIDGET(state->record_button), FALSE);
    // Reap the prior take's thread (long finished by now) before replacing the
    // handle, so a completed thread is never leaked.
    if (state->transcribe_thread) g_thread_join(state->transcribe_thread);
    state->transcribe_thread = g_thread_new("boo-transcribe", transcribe_worker, state);
}

// The core stops capturing by itself once a recording hits MAX_RECORDING_SECONDS
// (see src/audio/common.zig), it can't finish the job from inside the audio
// callback. Poll for that and wrap up as though the user had pressed stop.
static gboolean check_auto_stop(gpointer data) {
    WindowState *state = data;
    if (!state->ui_recording) return G_SOURCE_REMOVE;
    if (boo_is_recording(state->ctx)) {
        // Live elapsed time in the status line, like the reference.
        const int secs = boo_get_audio_samples(state->ctx) / 16000;
        if (secs > 0) {
            char buf[16];
            g_snprintf(buf, sizeof(buf), "%ds", secs);
            set_hint(state, buf);
        }
        return G_SOURCE_CONTINUE;
    }

    show_toast(state, "Maximum recording length reached");
    state->auto_stop_poll = 0; // about to be removed; don't remove twice
    begin_transcription(state);
    return G_SOURCE_REMOVE;
}

static void toggle_recording(WindowState *state) {
    // Track the UI's own recording state rather than reading boo_is_recording():
    // the core drops that flag when it auto-stops, and trusting it would make
    // the next press start a fresh recording instead of transcribing this one.
    if (state->ui_recording) {
        begin_transcription(state);
    } else {
        // One take at a time. The button is disabled during transcription, but
        // the global hotkey routes here directly; starting now would desync the
        // UI, since the core ignores a start while a transcription is in flight.
        if (boo_is_transcribing(state->ctx)) return;

        // No microphone: Boo still runs, but recording is a no-op. Say so
        // instead of faking a take (which the auto-stop poll would then misread
        // as the 10-minute cap).
        if (!boo_has_microphone(state->ctx)) {
            set_hint_transient(state, "no microphone");
            return;
        }

        // Collect the previous take's tick thread; it exits within one
        // cadence of its stop signal, so this join is effectively instant.
        if (state->stream_thread) {
            g_thread_join(state->stream_thread);
            state->stream_thread = NULL;
        }

        boo_warm_up(state->ctx);
        boo_start_recording(state->ctx);
        live_card_remove(state);
        set_hint(state, "recording...");
        set_button_recording(state);

        state->ui_recording = TRUE;
        state->auto_stop_poll = g_timeout_add(500, check_auto_stop, state);

        // Without a VAD model every tick is an immediate no-op, so the thread
        // idles harmlessly; with one, utterances land as you pause.
        g_atomic_int_set(&state->stream_running, 1);
        state->stream_thread = g_thread_new("boo-stream", stream_tick_worker, state);
    }
}

static void on_record_clicked(GtkButton *btn, gpointer data) {
    (void)btn;
    toggle_recording(data);
}

static void on_shortcut_activated(gpointer user_data) {
    toggle_recording(user_data);
}

// The hotkey couldn't be registered, most often because the desktop has no
// GlobalShortcuts portal at all (GNOME only gained one in 48, so Ubuntu 24.04's
// GNOME 46 has none). Say so, rather than leaving the user pressing a key that
// does nothing.
static void on_shortcut_unavailable(const char *reason, gpointer user_data) {
    WindowState *state = user_data;

    g_autofree char *msg =
        g_strdup_printf("Hotkey unavailable: %s. Use the Record button.", reason);
    show_toast(state, msg);

    // The idle status line advertises the hotkey; stop promising one.
    state->hotkey_ok = FALSE;
    if (!state->ui_recording) set_hint_idle(state);
}

// Design tokens come from the active Ghostty theme (docs/ui-spec.md); %06x
// slots are filled from the theme by apply_theme. #FF3B30 is the one
// cross-platform hardcode; the record disc's border-radius transition IS the
// circle -> rounded-square morph (20px idle, 6px recording, 150ms).
static const char *BOO_CSS_FMT =
    "window.boo, window.boo headerbar { background: #%06x; color: #%06x; }\n"
    ".boo-card { background: alpha(#ffffff, 0.06); border-radius: 10px;"
    "  padding: 8px 12px; color: #%06x; }\n"
    ".boo-card-live { background: alpha(#ffffff, 0.03); border-radius: 10px;"
    "  padding: 8px 12px; color: #%06x; }\n"
    ".boo-card-btn { color: #%06x; min-width: 0; min-height: 0; padding: 2px; }\n"
    ".boo-card-btn.boo-flash { color: #%06x; }\n"
    ".boo-hint { color: #%06x; font-family: monospace; font-size: 11pt; }\n"
    "button.boo-record { background: #ff3b30; min-width: 40px; min-height: 40px;"
    "  padding: 0; border-radius: 20px; transition: border-radius 150ms ease;"
    "  background-image: none; border: none; box-shadow: none; }\n"
    "button.boo-record.boo-recording { border-radius: 6px; }\n";

// "Ghostty Default Style Dark" values, the fallback when no themes dir is found.
static const BooThemeColors DEFAULT_THEME = {
    .bg = 0x282C34,
    .fg = 0xFFFFFF,
    .palette = {[8] = 0x666666, [9] = 0xD54E53, [11] = 0xE7C547, [14] = 0x70C0B1},
};

// ./themes for a source run, then the XDG data dir, the Flatpak share, and the
// system share, mirroring the model search.
static char *find_themes_dir(void) {
    const char *xdg_env = g_getenv("XDG_DATA_HOME");
    g_autofree char *xdg = (xdg_env && *xdg_env)
                               ? g_build_filename(xdg_env, "boo", "themes", NULL)
                               : g_build_filename(g_get_home_dir(), ".local", "share",
                                                  "boo", "themes", NULL);
    const char *dirs[] = {"themes", xdg, "/app/share/boo/themes", "/usr/share/boo/themes",
                          NULL};
    for (int i = 0; dirs[i]; i++)
        if (g_file_test(dirs[i], G_FILE_TEST_IS_DIR)) return g_strdup(dirs[i]);
    return NULL;
}

static BooThemeColors default_theme_colors(void) {
    g_autofree char *dir = find_themes_dir();
    if (dir) {
        g_autofree char *path = g_build_filename(dir, "Ghostty Default Style Dark", NULL);
        BooThemeColors c;
        if (boo_theme_parse_file(path, &c)) return c;
    }
    return DEFAULT_THEME;
}

// Regenerate the window CSS and the waveform colors from `c`.
static void apply_theme(WindowState *st, const BooThemeColors *c) {
    char *css = g_strdup_printf(BOO_CSS_FMT, c->bg, c->fg, c->fg, c->palette[8],
                                c->palette[8], c->palette[14], c->palette[8]);
    gtk_css_provider_load_from_string(st->css, css);
    g_free(css);
    if (st->waveform)
        boo_waveform_widget_set_colors(st->waveform, c->palette[14], c->palette[9],
                                       c->palette[11]);
}

GtkWindow *boo_overlay_window_new(GtkApplication *app, BooContext *ctx) {
    GtkWidget *window = adw_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Boo");
    // The reference geometry.
    gtk_window_set_default_size(GTK_WINDOW(window), 400, 500);
    gtk_widget_add_css_class(window, "boo");

    WindowState *state = g_new0(WindowState, 1);
    state->ctx = ctx;
    state->window = GTK_WINDOW(window);
    state->hotkey_ok = TRUE; // downgraded by on_shortcut_unavailable
    g_object_set_data_full(G_OBJECT(window), "boo-state", state, window_state_free);

    // The CSS provider is reloaded on every theme change; apply_theme (below,
    // once the waveform exists) fills it from the default theme.
    state->css = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(window),
                                               GTK_STYLE_PROVIDER(state->css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    AdwHeaderBar *header = ADW_HEADER_BAR(adw_header_bar_new());

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(header));

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(body, 12);
    gtk_widget_set_margin_bottom(body, 12);
    gtk_widget_set_margin_start(body, 12);
    gtk_widget_set_margin_end(body, 12);

    state->waveform = boo_waveform_widget_new(ctx);
    gtk_widget_set_size_request(state->waveform, -1, 48);
    gtk_box_append(GTK_BOX(body), state->waveform);

    // Transcript history: a stack of cards in a scroller, newest last.
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroller, TRUE);
    state->scroller = GTK_SCROLLED_WINDOW(scroller);
    state->card_stack = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8));
    gtk_widget_set_valign(GTK_WIDGET(state->card_stack), GTK_ALIGN_START);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller),
                                  GTK_WIDGET(state->card_stack));
    gtk_box_append(GTK_BOX(body), scroller);

    // The persistent status line: the visible hotkey at rest.
    state->hint_label = GTK_LABEL(gtk_label_new(""));
    gtk_widget_add_css_class(GTK_WIDGET(state->hint_label), "boo-hint");
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(state->hint_label));
    set_hint_idle(state);

    // The record disc (empty label; the shape and color carry the state).
    state->record_button = GTK_BUTTON(gtk_button_new());
    gtk_widget_add_css_class(GTK_WIDGET(state->record_button), "boo-record");
    gtk_widget_set_halign(GTK_WIDGET(state->record_button), GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(GTK_WIDGET(state->record_button),
                                "Record (Ctrl+Shift+Space)");
    gtk_accessible_update_property(GTK_ACCESSIBLE(state->record_button),
                                   GTK_ACCESSIBLE_PROPERTY_LABEL, "Record", -1);
    g_signal_connect(state->record_button, "clicked", G_CALLBACK(on_record_clicked),
                     state);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(state->record_button));

    // Toast overlay wraps the whole body so toasts float over the content.
    state->toast_overlay = ADW_TOAST_OVERLAY(adw_toast_overlay_new());
    adw_toast_overlay_set_child(state->toast_overlay, body);
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(state->toast_overlay));
    gtk_widget_set_vexpand(GTK_WIDGET(state->toast_overlay), TRUE);

    adw_application_window_set_content(ADW_APPLICATION_WINDOW(window), content);

    // Request the Ctrl+Shift+Space global hotkey. Asynchronous and best-effort:
    // the portal may decline or the user may rebind it, so the Record button
    // above stays the primary control.
    state->shortcut = boo_global_shortcut_new(GTK_WINDOW(window), on_shortcut_activated,
                                              on_shortcut_unavailable, state);

    // Auto-paste of transcripts into the focused app (RemoteDesktop portal).
    // First run shows a one-time permission dialog; the grant persists.
    state->inject = boo_text_inject_new(GTK_WINDOW(window));

    // Colour everything from the default theme now that the waveform exists.
    const BooThemeColors colors = default_theme_colors();
    apply_theme(state, &colors);

    return GTK_WINDOW(window);
}
