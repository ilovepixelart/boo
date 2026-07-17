// Boo overlay window, record button, waveform display, transcript.
// Transcription runs on a worker thread (boo_transcribe is synchronous) and
// updates the UI back on the main loop via g_idle_add. The result is auto-
// copied to the system clipboard and announced via an AdwToast.

#include "overlay_window.h"
#include "global_shortcut.h"
#include "models.h"
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
    // Theme + preferences: set from the Settings dialog, persisted in
    // settings.ini, applied through the CSS provider.
    struct {
        GtkCssProvider *css; // reloaded on theme change
        GArray *themes;      // ThemeEntry, all parsed themes sorted by name
        int current_theme;   // index into themes, -1 == the built-in default
        double opacity;      // window opacity, 0.1..1.0
        gboolean auto_type;  // paste into the focused app vs clipboard-only
        char *model_current; // full path of the loaded speech model
        char *model_choice;  // the user's explicit pick, persisted; NULL until made
    } settings;
    guint hint_reset; // 0 == no pending reset to the idle hint
    gboolean hotkey_ok;

    // The UI's own view of whether we're recording. Deliberately not
    // boo_is_recording(): the core clears that when it hits the recording cap.
    gboolean ui_recording;
    guint auto_stop_poll; // 0 == not polling

    struct {
        // Streaming transcription: one dedicated thread polls boo_stream_tick
        // while recording (the C API wants ticks from a single background
        // thread; each call may block for one utterance's inference). The flag
        // is the thread's stop signal; the handle is joined before reuse or
        // teardown.
        GThread *stream_thread; // NULL == no thread to join
        gint stream_running;    // atomic
        // The batch transcription thread. Kept joinable (not detached) so
        // closing the window mid-transcription joins it rather than leaving
        // its completion idle to fire against freed state.
        GThread *transcribe_thread; // NULL == no thread to join
    } workers;
} WindowState;

typedef struct {
    WindowState *state;
    char *text; // owned, may be NULL
} TranscribeResult;

// A parsed theme (name + colors) for the picker list.
typedef struct {
    char *name;
    BooThemeColors colors;
} ThemeEntry;

static void window_state_free(gpointer data) {
    WindowState *state = data;
    // Cancel the timers first: closing the window mid-recording would
    // otherwise leave them firing against freed state.
    if (state->auto_stop_poll != 0) g_source_remove(state->auto_stop_poll);
    if (state->hint_reset != 0) g_source_remove(state->hint_reset);
    // The tick thread reads this state; it must be gone before the free.
    if (state->workers.stream_thread) {
        g_atomic_int_set(&state->workers.stream_running, 0);
        g_thread_join(state->workers.stream_thread);
    }
    // Likewise the transcribe thread: closing the window during "Transcribing…"
    // must not leave it finishing against freed state. boo_deinit already
    // flushes the in-flight boo_transcribe, so this join is bounded.
    if (state->workers.transcribe_thread) g_thread_join(state->workers.transcribe_thread);
    if (state->shortcut) boo_global_shortcut_free(state->shortcut);
    if (state->inject) boo_text_inject_free(state->inject);
    if (state->settings.css) g_object_unref(state->settings.css);
    if (state->settings.themes) {
        for (guint i = 0; i < state->settings.themes->len; i++)
            g_free(g_array_index(state->settings.themes, ThemeEntry, i).name);
        g_array_free(state->settings.themes, TRUE);
    }
    g_free(state->settings.model_current);
    g_free(state->settings.model_choice);
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
    while (g_atomic_int_get(&state->workers.stream_running)) {
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
        // Auto-type off makes Boo clipboard-only (never paste).
        if (state->settings.auto_type && !gtk_window_is_active(state->window)) {
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
    g_atomic_int_set(&state->workers.stream_running, 0);

    boo_stop_recording(state->ctx);
    set_hint(state, "thinking...");
    set_button_idle(state);
    gtk_widget_set_sensitive(GTK_WIDGET(state->record_button), FALSE);
    // Reap the prior take's thread (long finished by now) before replacing the
    // handle, so a completed thread is never leaked.
    if (state->workers.transcribe_thread) g_thread_join(state->workers.transcribe_thread);
    state->workers.transcribe_thread = g_thread_new("boo-transcribe", transcribe_worker, state);
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
        if (state->workers.stream_thread) {
            g_thread_join(state->workers.stream_thread);
            state->workers.stream_thread = NULL;
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
        g_atomic_int_set(&state->workers.stream_running, 1);
        state->workers.stream_thread = g_thread_new("boo-stream", stream_tick_worker, state);
    }
}

static void on_record_clicked(const GtkButton *btn, gpointer data) {
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
// A macro (not a const char *) so g_strdup_printf sees a string literal for its
// format argument, the trusted CSS template with %06x colour slots.
#define BOO_CSS_FMT                                                                      \
    "window.boo, window.boo headerbar { background: #%06x; color: #%06x; }\n"            \
    ".boo-card { background: alpha(#ffffff, 0.06); border-radius: 10px;"                 \
    "  padding: 8px 12px; color: #%06x; }\n"                                             \
    ".boo-card-live { background: alpha(#ffffff, 0.03); border-radius: 10px;"            \
    "  padding: 8px 12px; color: #%06x; }\n"                                             \
    ".boo-card-btn { color: #%06x; min-width: 0; min-height: 0; padding: 2px; }\n"       \
    ".boo-card-btn.boo-flash { color: #%06x; }\n"                                        \
    ".boo-hint { color: #%06x; font-family: monospace; font-size: 11pt; }\n"             \
    "button.boo-record { background: #ff3b30; min-width: 40px; min-height: 40px;"        \
    "  padding: 0; border-radius: 20px; transition: border-radius 150ms ease;"           \
    "  background-image: none; border: none; box-shadow: none; }\n"                      \
    "button.boo-record.boo-recording { border-radius: 6px; }\n"

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
    g_autofree const char *xdg = (xdg_env && *xdg_env)
                                     ? g_build_filename(xdg_env, "boo", "themes", NULL)
                                     : g_build_filename(g_get_home_dir(), ".local",
                                                        "share", "boo", "themes", NULL);
    const char *dirs[] = {"themes", xdg, "/app/share/boo/themes", "/usr/share/boo/themes",
                          NULL};
    for (int i = 0; dirs[i]; i++)
        if (g_file_test(dirs[i], G_FILE_TEST_IS_DIR)) return g_strdup(dirs[i]);
    return NULL;
}

static BooThemeColors default_theme_colors(void) {
    g_autofree const char *dir = find_themes_dir();
    if (dir) {
        g_autofree const char *path =
            g_build_filename(dir, "Ghostty Default Style Dark", NULL);
        BooThemeColors c;
        if (boo_theme_parse_file(path, &c)) return c;
    }
    return DEFAULT_THEME;
}

// Regenerate the window CSS and the waveform colors from `c`.
static void apply_theme(WindowState *st, const BooThemeColors *c) {
    char *css = g_strdup_printf(BOO_CSS_FMT, c->bg, c->fg, c->fg, c->palette[8],
                                c->palette[8], c->palette[14], c->palette[8]);
    gtk_css_provider_load_from_string(st->settings.css, css);
    g_free(css);
    if (st->waveform)
        boo_waveform_widget_set_colors(st->waveform, c->palette[14], c->palette[9],
                                       c->palette[11]);
}

static gint theme_name_cmp(gconstpointer a, gconstpointer b) {
    return g_strcmp0(*(const char *const *)a, *(const char *const *)b);
}

// Enumerate the themes dir and parse every file via the shared core parser,
// sorted by name. Empty when no themes dir is found (built-in default only).
static void load_theme_list(WindowState *st) {
    st->settings.themes = g_array_new(FALSE, FALSE, sizeof(ThemeEntry));
    st->settings.current_theme = -1;
    g_autofree const char *dir = find_themes_dir();
    if (!dir) return;
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return;
    GPtrArray *names = g_ptr_array_new_with_free_func(g_free);
    const char *nm;
    while ((nm = g_dir_read_name(d)))
        if (nm[0] != '.') g_ptr_array_add(names, g_strdup(nm));
    g_dir_close(d);
    g_ptr_array_sort(names, theme_name_cmp);
    for (guint i = 0; i < names->len; i++) {
        g_autofree const char *path = g_build_filename(dir, names->pdata[i], NULL);
        BooThemeColors c;
        if (boo_theme_parse_file(path, &c)) {
            ThemeEntry e = {g_strdup(names->pdata[i]), c};
            g_array_append_val(st->settings.themes, e);
        }
    }
    g_ptr_array_free(names, TRUE);
}

// ── settings persistence (XDG config keyfile) ──

static char *settings_path(void) {
    const char *cfg = g_getenv("XDG_CONFIG_HOME");
    g_autofree const char *dir =
        (cfg && *cfg) ? g_build_filename(cfg, "boo", NULL)
                      : g_build_filename(g_get_home_dir(), ".config", "boo", NULL);
    g_mkdir_with_parents(dir, 0700);
    return g_build_filename(dir, "settings.ini", NULL);
}

static void settings_save(WindowState *st) {
    g_autoptr(GKeyFile) kf = g_key_file_new();
    const char *theme =
        (st->settings.themes && st->settings.current_theme >= 0)
            ? g_array_index(st->settings.themes, ThemeEntry, st->settings.current_theme).name
            : "";
    g_key_file_set_string(kf, "boo", "theme", theme);
    g_key_file_set_double(kf, "boo", "opacity", st->settings.opacity);
    g_key_file_set_boolean(kf, "boo", "auto-type", st->settings.auto_type);
    if (st->settings.model_choice)
        g_key_file_set_string(kf, "boo", "model", st->settings.model_choice);
    g_autofree const char *path = settings_path();
    g_key_file_save_to_file(kf, path, NULL);
}

char *boo_saved_model_read(void) {
    g_autoptr(GKeyFile) kf = g_key_file_new();
    g_autofree const char *path = settings_path();
    if (!g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL)) return NULL;
    return g_key_file_get_string(kf, "boo", "model", NULL);
}

static void settings_load(WindowState *st) {
    st->settings.opacity = 1.0;
    st->settings.auto_type = TRUE;
    g_autoptr(GKeyFile) kf = g_key_file_new();
    g_autofree const char *path = settings_path();
    if (!g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL)) return;
    double o = g_key_file_get_double(kf, "boo", "opacity", NULL);
    if (o >= 0.1 && o <= 1.0) st->settings.opacity = o;
    if (g_key_file_has_key(kf, "boo", "auto-type", NULL))
        st->settings.auto_type = g_key_file_get_boolean(kf, "boo", "auto-type", NULL);
    g_autofree const char *theme = g_key_file_get_string(kf, "boo", "theme", NULL);
    if (theme && st->settings.themes)
        for (guint i = 0; i < st->settings.themes->len; i++)
            if (g_strcmp0(g_array_index(st->settings.themes, ThemeEntry, i).name, theme) == 0) {
                st->settings.current_theme = (int)i;
                break;
            }
    // Keep the explicit model choice across saves: settings_save rewrites the
    // whole file, so an unloaded key would be silently dropped.
    st->settings.model_choice = g_key_file_get_string(kf, "boo", "model", NULL);
}

static void select_theme(WindowState *st, int index) {
    if (!st->settings.themes || index < 0 || index >= (int)st->settings.themes->len) return;
    st->settings.current_theme = index;
    apply_theme(st, &g_array_index(st->settings.themes, ThemeEntry, index).colors);
    settings_save(st);
}

// ── settings dialog (theme picker + opacity + auto-type, per docs/ui-spec.md) ──

static void swatch_draw(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    (void)area;
    guint32 rgb = GPOINTER_TO_UINT(data);
    cairo_set_source_rgb(cr, ((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0,
                         (rgb & 0xFF) / 255.0);
    cairo_rectangle(cr, 0, 0, w, h);
    cairo_fill(cr);
}

static GtkWidget *swatch_new(guint32 rgb, int size) {
    GtkWidget *a = gtk_drawing_area_new();
    gtk_widget_set_size_request(a, size, size);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(a), swatch_draw,
                                   GUINT_TO_POINTER(rgb), NULL);
    return a;
}

typedef struct {
    WindowState *st;
    GtkWindow *win;
    GtkListBox *list;
    GtkSearchEntry *search;
    GtkBox *palette; // 16-swatch preview strip
    // Model switcher (see ui-spec §Settings): one dropdown merging models on
    // disk with the curated manifest, a progress bar for inline downloads.
    GtkDropDown *model_dd;
    GtkProgressBar *model_progress;
    GtkLabel *model_status;
    GPtrArray *model_entries; // ModelEntry*, parallel to the dropdown rows
    gboolean model_updating;  // guard against programmatic selection changes
} SettingsUI;

// One model-dropdown entry: a model on disk (`path` set) or a curated
// manifest model not yet downloaded (`manifest` set; picking it downloads).
typedef struct {
    char *path;                   // NULL == needs download first
    const BooModelInfo *manifest; // static core storage; NULL for on-disk files
} ModelEntry;

static void model_entry_free(gpointer data) {
    ModelEntry *e = data;
    g_free(e->path);
    g_free(e);
}

static void settings_ui_free(gpointer data) {
    SettingsUI *ui = data;
    if (ui->model_entries) g_ptr_array_unref(ui->model_entries);
    g_free(ui);
}

static void palette_preview(SettingsUI *ui, const BooThemeColors *c) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(ui->palette))))
        gtk_box_remove(ui->palette, child);
    for (int i = 0; i < 16; i++)
        gtk_box_append(ui->palette, swatch_new(c->palette[i], 16));
}

static void on_theme_row(const GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box;
    SettingsUI *ui = data;
    if (!row) return;
    int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "boo-theme-index"));
    select_theme(ui->st, index);
    palette_preview(ui, &g_array_index(ui->st->settings.themes, ThemeEntry, index).colors);
}

static gboolean theme_filter(GtkListBoxRow *row, gpointer data) {
    SettingsUI *ui = data;
    const char *q = gtk_editable_get_text(GTK_EDITABLE(ui->search));
    if (!q || !*q) return TRUE;
    const char *name = g_object_get_data(G_OBJECT(row), "boo-theme-name");
    g_autofree const char *lname = g_ascii_strdown(name, -1);
    g_autofree const char *lq = g_ascii_strdown(q, -1);
    return strstr(lname, lq) != NULL;
}

static void on_search_changed(const GtkSearchEntry *entry, gpointer data) {
    (void)entry;
    gtk_list_box_invalidate_filter(((SettingsUI *)data)->list);
}

static void on_opacity_changed(GtkRange *range, gpointer data) {
    SettingsUI *ui = data;
    ui->st->settings.opacity = gtk_range_get_value(range);
    gtk_widget_set_opacity(GTK_WIDGET(ui->st->window), ui->st->settings.opacity);
    settings_save(ui->st);
}

static gboolean on_autotype_changed(const GtkSwitch *sw, gboolean active,
                                    gpointer data) {
    (void)sw;
    SettingsUI *ui = data;
    ui->st->settings.auto_type = active;
    settings_save(ui->st);
    return FALSE; // let the default handler update the visual state
}

// Refill the model dropdown: models on disk first (ranked), then curated
// manifest models not yet downloaded, tagged with their size. Selects the
// loaded model.
static void model_list_rebuild(SettingsUI *ui) {
    ui->model_updating = TRUE;
    g_ptr_array_set_size(ui->model_entries, 0);
    GtkStringList *labels = gtk_string_list_new(NULL);
    guint selected = GTK_INVALID_LIST_POSITION;

    g_autoptr(GPtrArray) installed = boo_installed_models();
    for (guint i = 0; i < installed->len; i++) {
        const char *path = g_ptr_array_index(installed, i);
        ModelEntry *e = g_new0(ModelEntry, 1);
        e->path = g_strdup(path);
        g_ptr_array_add(ui->model_entries, e);
        g_autofree char *base = g_path_get_basename(path);
        gtk_string_list_append(labels, base);
        if (g_strcmp0(path, ui->st->settings.model_current) == 0)
            selected = ui->model_entries->len - 1;
    }

    size_t count = 0;
    const BooModelInfo *models = boo_models(&count);
    for (size_t i = 0; i < count; i++) {
        gboolean on_disk = FALSE;
        for (guint j = 0; j < installed->len && !on_disk; j++) {
            g_autofree char *base =
                g_path_get_basename(g_ptr_array_index(installed, j));
            on_disk = g_strcmp0(base, models[i].filename) == 0;
        }
        if (on_disk) continue;
        ModelEntry *e = g_new0(ModelEntry, 1);
        e->manifest = &models[i];
        g_ptr_array_add(ui->model_entries, e);
        g_autofree char *label =
            g_strdup_printf("%s  (download, %u MB)", models[i].filename,
                            (unsigned)(models[i].size / 1000000));
        gtk_string_list_append(labels, label);
    }

    gtk_drop_down_set_model(ui->model_dd, G_LIST_MODEL(labels));
    g_object_unref(labels);
    if (selected != GTK_INVALID_LIST_POSITION)
        gtk_drop_down_set_selected(ui->model_dd, selected);
    ui->model_updating = FALSE;
}

typedef struct {
    SettingsUI *ui;
    char *path;
} ModelSwitchJob;

static void model_switch_worker(GTask *task, gpointer source, gpointer task_data,
                                GCancellable *cancel) {
    (void)source;
    (void)cancel;
    ModelSwitchJob *job = task_data;
    g_task_return_boolean(task, boo_reload_model(job->ui->st->ctx, job->path));
}

static void model_switch_finish(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    ModelSwitchJob *job = data;
    SettingsUI *ui = job->ui;
    gboolean ok = g_task_propagate_boolean(G_TASK(result), NULL);
    g_autofree char *base = g_path_get_basename(job->path);

    gtk_widget_set_sensitive(GTK_WIDGET(ui->model_dd), TRUE);
    gtk_window_set_deletable(ui->win, TRUE);
    if (ok) {
        g_free(ui->st->settings.model_current);
        ui->st->settings.model_current = g_strdup(job->path);
        g_free(ui->st->settings.model_choice);
        ui->st->settings.model_choice = g_strdup(job->path);
        settings_save(ui->st);
        boo_log(BOO_LOG_INFO, "model switched");
        g_autofree char *msg = g_strdup_printf("Loaded %s.", base);
        gtk_label_set_text(ui->model_status, msg);
    } else {
        g_autofree char *msg =
            g_strdup_printf("Could not load %s; keeping the previous model.", base);
        gtk_label_set_text(ui->model_status, msg);
    }
    model_list_rebuild(ui);
    g_free(job->path);
    g_free(job);
}

// Swap models off the main loop (loading takes seconds; boo_reload_model
// keeps the old model on failure). The settings window's close button is
// disabled for the duration so these widgets cannot die under the worker.
static void model_switch_start(SettingsUI *ui, const char *path) {
    gtk_widget_set_sensitive(GTK_WIDGET(ui->model_dd), FALSE);
    gtk_window_set_deletable(ui->win, FALSE);
    g_autofree char *base = g_path_get_basename(path);
    g_autofree char *msg = g_strdup_printf("Loading %s…", base);
    gtk_label_set_text(ui->model_status, msg);

    ModelSwitchJob *job = g_new0(ModelSwitchJob, 1);
    job->ui = ui;
    job->path = g_strdup(path);
    GTask *task = g_task_new(NULL, NULL, model_switch_finish, job);
    g_task_set_task_data(task, job, NULL);
    g_task_run_in_thread(task, model_switch_worker);
    g_object_unref(task);
}

static void on_model_download_done(const char *path, gpointer data) {
    SettingsUI *ui = data;
    gtk_widget_set_visible(GTK_WIDGET(ui->model_progress), FALSE);
    model_switch_start(ui, path);
}

static void on_model_download_fail(const char *why, gpointer data) {
    SettingsUI *ui = data;
    gtk_widget_set_visible(GTK_WIDGET(ui->model_progress), FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(ui->model_dd), TRUE);
    gtk_window_set_deletable(ui->win, TRUE);
    gtk_label_set_text(ui->model_status, why);
    model_list_rebuild(ui);
}

static void model_download_start(SettingsUI *ui, const BooModelInfo *model) {
    gtk_widget_set_sensitive(GTK_WIDGET(ui->model_dd), FALSE);
    gtk_window_set_deletable(ui->win, FALSE);
    gtk_progress_bar_set_fraction(ui->model_progress, 0);
    gtk_widget_set_visible(GTK_WIDGET(ui->model_progress), TRUE);
    g_autofree char *msg = g_strdup_printf("Downloading %s…", model->filename);
    gtk_label_set_text(ui->model_status, msg);
    boo_model_download(model, ui->model_progress, on_model_download_done,
                       on_model_download_fail, ui);
}

static void on_model_selected(GObject *dd, GParamSpec *spec, gpointer data) {
    (void)dd;
    (void)spec;
    SettingsUI *ui = data;
    if (ui->model_updating) return;
    guint idx = gtk_drop_down_get_selected(ui->model_dd);
    if (idx >= ui->model_entries->len) return;
    ModelEntry *e = g_ptr_array_index(ui->model_entries, idx);

    if (!e->path) {
        if (e->manifest) model_download_start(ui, e->manifest);
        return;
    }
    if (g_strcmp0(e->path, ui->st->settings.model_current) == 0) return;
    if (boo_is_recording(ui->st->ctx) || boo_is_transcribing(ui->st->ctx)) {
        gtk_label_set_text(ui->model_status, "Stop recording first.");
        model_list_rebuild(ui); // snap the selection back to the loaded model
        return;
    }
    model_switch_start(ui, e->path);
}

static void open_settings(GtkButton *btn, gpointer data) {
    (void)btn;
    WindowState *st = data;
    SettingsUI *ui = g_new0(SettingsUI, 1);
    ui->st = st;

    GtkWidget *win = adw_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Boo Settings");
    gtk_window_set_default_size(GTK_WINDOW(win), 360, 600);
    gtk_window_set_transient_for(GTK_WINDOW(win), st->window);
    ui->win = GTK_WINDOW(win);
    g_object_set_data_full(G_OBJECT(win), "boo-settings-ui", ui, settings_ui_free);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(content, 12);
    gtk_widget_set_margin_bottom(content, 12);
    gtk_widget_set_margin_start(content, 12);
    gtk_widget_set_margin_end(content, 12);
    gtk_widget_set_vexpand(content, TRUE);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(outer), adw_header_bar_new());
    gtk_box_append(GTK_BOX(outer), content);
    adw_window_set_content(ADW_WINDOW(win), outer);

    // Opacity slider
    GtkWidget *orow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(orow), gtk_label_new("Opacity"));
    GtkWidget *scale =
        gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.1, 1.0, 0.05);
    gtk_range_set_value(GTK_RANGE(scale), st->settings.opacity);
    gtk_widget_set_hexpand(scale, TRUE);
    // Live value readout, the reference's monospace "1.00" label.
    gtk_scale_set_draw_value(GTK_SCALE(scale), TRUE);
    gtk_scale_set_digits(GTK_SCALE(scale), 2);
    gtk_scale_set_value_pos(GTK_SCALE(scale), GTK_POS_RIGHT);
    g_signal_connect(scale, "value-changed", G_CALLBACK(on_opacity_changed), ui);
    gtk_box_append(GTK_BOX(orow), scale);
    gtk_box_append(GTK_BOX(content), orow);

    // Auto-type toggle
    GtkWidget *arow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *alabel = gtk_label_new("Auto-type into focused app");
    gtk_widget_set_hexpand(alabel, TRUE);
    gtk_widget_set_halign(alabel, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(arow), alabel);
    GtkWidget *sw = gtk_switch_new();
    gtk_switch_set_active(GTK_SWITCH(sw), st->settings.auto_type);
    gtk_widget_set_valign(sw, GTK_ALIGN_CENTER);
    g_signal_connect(sw, "state-set", G_CALLBACK(on_autotype_changed), ui);
    gtk_box_append(GTK_BOX(arow), sw);
    gtk_box_append(GTK_BOX(content), arow);

    // Model switcher: dropdown + inline download progress + status line.
    gtk_box_append(GTK_BOX(content), gtk_label_new("Model"));
    GtkWidget *model_dd = gtk_drop_down_new(NULL, NULL);
    ui->model_dd = GTK_DROP_DOWN(model_dd);
    ui->model_entries = g_ptr_array_new_with_free_func(model_entry_free);
    gtk_box_append(GTK_BOX(content), model_dd);
    GtkWidget *model_progress = gtk_progress_bar_new();
    ui->model_progress = GTK_PROGRESS_BAR(model_progress);
    gtk_widget_set_visible(model_progress, FALSE);
    gtk_box_append(GTK_BOX(content), model_progress);
    GtkWidget *model_status = gtk_label_new("");
    gtk_widget_add_css_class(model_status, "boo-hint");
    gtk_widget_set_halign(model_status, GTK_ALIGN_START);
    ui->model_status = GTK_LABEL(model_status);
    gtk_box_append(GTK_BOX(content), model_status);
    model_list_rebuild(ui);
    // Connected after the initial rebuild; later rebuilds are guarded by
    // model_updating.
    g_signal_connect(model_dd, "notify::selected", G_CALLBACK(on_model_selected), ui);

    gtk_box_append(GTK_BOX(content), gtk_label_new("Theme"));

    // Theme search + list (swatch + name), filtered live.
    GtkWidget *search = gtk_search_entry_new();
    ui->search = GTK_SEARCH_ENTRY(search);
    g_signal_connect(search, "search-changed", G_CALLBACK(on_search_changed), ui);
    gtk_box_append(GTK_BOX(content), search);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    GtkWidget *list = gtk_list_box_new();
    ui->list = GTK_LIST_BOX(list);
    gtk_list_box_set_filter_func(GTK_LIST_BOX(list), theme_filter, ui, NULL);
    g_signal_connect(list, "row-activated", G_CALLBACK(on_theme_row), ui);
    for (guint i = 0; st->settings.themes && i < st->settings.themes->len; i++) {
        ThemeEntry *e = &g_array_index(st->settings.themes, ThemeEntry, i);
        GtkWidget *row = gtk_list_box_row_new();
        g_object_set_data(G_OBJECT(row), "boo-theme-index", GINT_TO_POINTER((int)i));
        g_object_set_data(G_OBJECT(row), "boo-theme-name", e->name);
        GtkWidget *rb = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_top(rb, 4);
        gtk_widget_set_margin_bottom(rb, 4);
        gtk_widget_set_margin_start(rb, 6);
        gtk_box_append(GTK_BOX(rb), swatch_new(e->colors.bg, 20));
        gtk_box_append(GTK_BOX(rb), gtk_label_new(e->name));
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), rb);
        gtk_list_box_append(GTK_LIST_BOX(list), row);
    }
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(content), scroll);

    // 16-color palette preview strip for the current theme.
    GtkWidget *palette = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    ui->palette = GTK_BOX(palette);
    gtk_box_append(GTK_BOX(content), palette);
    if (st->settings.themes && st->settings.current_theme >= 0)
        palette_preview(ui,
                        &g_array_index(st->settings.themes, ThemeEntry, st->settings.current_theme).colors);

    gtk_window_present(GTK_WINDOW(win));
}

GtkWindow *boo_overlay_window_new(GtkApplication *app, BooContext *ctx,
                                  const char *model_path) {
    GtkWidget *window = adw_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Boo");
    // The reference geometry.
    gtk_window_set_default_size(GTK_WINDOW(window), 400, 500);
    gtk_widget_add_css_class(window, "boo");

    WindowState *state = g_new0(WindowState, 1);
    state->ctx = ctx;
    state->settings.model_current = g_strdup(model_path);
    state->window = GTK_WINDOW(window);
    state->hotkey_ok = TRUE; // downgraded by on_shortcut_unavailable
    g_object_set_data_full(G_OBJECT(window), "boo-state", state, window_state_free);

    // The CSS provider is reloaded on every theme change; apply_theme (below,
    // once the waveform exists) fills it from the default theme.
    state->settings.css = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(window),
                                               GTK_STYLE_PROVIDER(state->settings.css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    AdwHeaderBar *header = ADW_HEADER_BAR(adw_header_bar_new());

    // Settings button (opacity + auto-type + theme picker), mirroring the macOS
    // gear in the title bar.
    GtkWidget *settings_btn = gtk_button_new_from_icon_name("emblem-system-symbolic");
    gtk_widget_set_tooltip_text(settings_btn, "Settings");
    gtk_accessible_update_property(GTK_ACCESSIBLE(settings_btn),
                                   GTK_ACCESSIBLE_PROPERTY_LABEL, "Settings", -1);
    g_signal_connect(settings_btn, "clicked", G_CALLBACK(open_settings), state);
    adw_header_bar_pack_end(header, settings_btn);

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

    // Load every theme and the persisted settings, then colour everything now
    // that the waveform exists. A persisted theme wins; else the built-in
    // default. Opacity is a whole-window property.
    load_theme_list(state);
    settings_load(state);
    if (state->settings.themes && state->settings.current_theme >= 0) {
        apply_theme(
            state,
            &g_array_index(state->settings.themes, ThemeEntry, state->settings.current_theme).colors);
    } else {
        const BooThemeColors colors = default_theme_colors();
        apply_theme(state, &colors);
    }
    gtk_widget_set_opacity(window, state->settings.opacity);

    return GTK_WINDOW(window);
}
