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
    GtkLabel *transcript_label;
    GtkButton *record_button;
    GtkWidget *waveform;
    AdwToastOverlay *toast_overlay;
    BooGlobalShortcut *shortcut;
    BooTextInject *inject;

    // The UI's own view of whether we're recording. Deliberately not
    // boo_is_recording(): the core clears that when it hits the recording cap.
    gboolean ui_recording;
    guint auto_stop_poll; // 0 == not polling
} WindowState;

typedef struct {
    WindowState *state;
    char *text; // owned, may be NULL
} TranscribeResult;

static void window_state_free(gpointer data) {
    WindowState *state = data;
    // Cancel the auto-stop poll first: closing the window mid-recording would
    // otherwise leave a timer firing against freed state.
    if (state->auto_stop_poll != 0) g_source_remove(state->auto_stop_poll);
    if (state->shortcut) boo_global_shortcut_free(state->shortcut);
    if (state->inject) boo_text_inject_free(state->inject);
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

static void set_button_idle(WindowState *st) {
    gtk_button_set_label(st->record_button, "Record");
    gtk_widget_set_sensitive(GTK_WIDGET(st->record_button), TRUE);
    gtk_widget_remove_css_class(GTK_WIDGET(st->record_button), "destructive-action");
    gtk_widget_add_css_class(GTK_WIDGET(st->record_button), "suggested-action");
}

static void set_button_recording(WindowState *st) {
    gtk_button_set_label(st->record_button, "Stop");
    gtk_widget_remove_css_class(GTK_WIDGET(st->record_button), "suggested-action");
    gtk_widget_add_css_class(GTK_WIDGET(st->record_button), "destructive-action");
}

static gboolean transcribe_done(gpointer user_data) {
    TranscribeResult *res = user_data;
    WindowState *state = res->state;

    if (res->text && *res->text) {
        gtk_label_set_text(state->transcript_label, res->text);
        copy_to_clipboard(state, res->text);
        show_toast(state, "Copied to clipboard");
        // When dictation was triggered by the global hotkey, focus stayed in
        // the target app, auto-paste there. When our own window is focused
        // (Record button click), pasting would land back in Boo; skip it.
        if (!gtk_window_is_active(state->window)) {
            boo_text_inject_paste(state->inject);
        }
    } else {
        gtk_label_set_text(state->transcript_label, "(no speech detected)");
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

    boo_stop_recording(state->ctx);
    gtk_button_set_label(state->record_button, "Transcribing…");
    gtk_widget_set_sensitive(GTK_WIDGET(state->record_button), FALSE);
    g_thread_unref(g_thread_new("boo-transcribe", transcribe_worker, state));
}

// The core stops capturing by itself once a recording hits MAX_RECORDING_SECONDS
// (see src/audio/common.zig), it can't finish the job from inside the audio
// callback. Poll for that and wrap up as though the user had pressed stop.
static gboolean check_auto_stop(gpointer data) {
    WindowState *state = data;
    if (!state->ui_recording) return G_SOURCE_REMOVE;
    if (boo_is_recording(state->ctx)) return G_SOURCE_CONTINUE;

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
        boo_warm_up(state->ctx);
        boo_start_recording(state->ctx);
        gtk_label_set_text(state->transcript_label, "");
        set_button_recording(state);

        state->ui_recording = TRUE;
        state->auto_stop_poll = g_timeout_add(500, check_auto_stop, state);
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

    gtk_label_set_text(state->transcript_label,
                       "Ctrl+Shift+Space is not available on this desktop.\n"
                       "Press Record instead.");
}

GtkWindow *boo_overlay_window_new(GtkApplication *app, BooContext *ctx) {
    GtkWidget *window = adw_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Boo");
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 240);

    WindowState *state = g_new0(WindowState, 1);
    state->ctx = ctx;
    state->window = GTK_WINDOW(window);
    g_object_set_data_full(G_OBJECT(window), "boo-state", state, window_state_free);

    AdwHeaderBar *header = ADW_HEADER_BAR(adw_header_bar_new());

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(header));

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(body, 16);
    gtk_widget_set_margin_bottom(body, 16);
    gtk_widget_set_margin_start(body, 16);
    gtk_widget_set_margin_end(body, 16);

    state->waveform = boo_waveform_widget_new(ctx);
    gtk_widget_set_size_request(state->waveform, -1, 64);
    gtk_box_append(GTK_BOX(body), state->waveform);

    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroller, TRUE);
    state->transcript_label = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(state->transcript_label, TRUE);
    gtk_label_set_xalign(state->transcript_label, 0.0);
    gtk_label_set_yalign(state->transcript_label, 0.0);
    gtk_label_set_selectable(state->transcript_label, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller),
                                  GTK_WIDGET(state->transcript_label));
    gtk_box_append(GTK_BOX(body), scroller);

    state->record_button = GTK_BUTTON(gtk_button_new_with_label("Record"));
    gtk_widget_add_css_class(GTK_WIDGET(state->record_button), "suggested-action");
    gtk_widget_add_css_class(GTK_WIDGET(state->record_button), "pill");
    gtk_widget_set_halign(GTK_WIDGET(state->record_button), GTK_ALIGN_CENTER);
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

    return GTK_WINDOW(window);
}
