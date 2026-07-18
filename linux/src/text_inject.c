// XDG RemoteDesktop portal client, synthesizes the paste chord.
//
// Session setup is a three-step Request/Response chain:
//
//   CreateSession -> SelectDevices(KEYBOARD, persist) -> Start
//
// after which NotifyKeyboardKeysym() calls are plain fire-and-forget methods on
// the session. The Request/Response plumbing, including the subscribe-before-
// call dance the protocol requires, lives in portal.c, shared with the
// GlobalShortcuts client.
//
// Persistence: SelectDevices asks for persist_mode=2 ("until revoked") and
// replays the restore token from the previous run, so the user sees the portal
// permission dialog exactly once, ever. Tokens are single-use, every Start
// response carries a fresh one, which we write back to disk each time.
//
// See:
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html

#include "text_inject.h"
#include "portal.h"

#include <glib/gstdio.h>

#define PORTAL_IFACE_REMOTE_DESKTOP "org.freedesktop.portal.RemoteDesktop"

#define DEVICE_KEYBOARD       1u // SelectDevices `types` bitmask
#define PERSIST_UNTIL_REVOKED 2u

#define KEY_PRESSED  1u
#define KEY_RELEASED 0u

// X11 keysyms, the portal resolves these against the active layout. Every
// layout can produce Control, Shift, and the letter V, which is the whole point
// of pasting instead of typing out each character.
#define XKS_CONTROL_L 0xffe3
#define XKS_SHIFT_L   0xffe1
#define XKS_V         0x0076

// Wayland clipboard offers propagate through the compositor asynchronously; if
// the paste keystroke beats the new offer, the target pastes stale data. A small
// fixed delay after the caller sets the clipboard is the same mitigation every
// injection tool uses, there is no "offer is visible to peers" event.
#define PASTE_DELAY_MS 75

typedef enum {
    BOO_INJECT_CREATING_SESSION,
    BOO_INJECT_SELECTING_DEVICES,
    BOO_INJECT_STARTING,
    BOO_INJECT_READY,
    BOO_INJECT_FAILED,
} BooInjectState;

struct BooTextInject {
    GDBusConnection *dbus; // owned ref; NULL when the session bus is unavailable
    char *session_handle;  // owned; NULL until CreateSession succeeds

    BooInjectState state;
    gboolean pending_paste; // a paste arrived before the session was ready

    guint response_subscription; // 0 == no request in flight
    guint paste_timeout;         // 0 == no delayed paste scheduled
};

// ---------------------------------------------------------------------------
// Restore token, what turns the second launch into a silent one

static char *token_path(void) {
    return g_build_filename(g_get_user_state_dir(), "boo", "remote-desktop-token", NULL);
}

static char *load_restore_token(void) {
    g_autofree const char *path = token_path();

    char *token = NULL;
    if (!g_file_get_contents(path, &token, NULL, NULL)) return NULL;

    g_strstrip(token);
    if (*token) return token;

    g_free(token);
    return NULL;
}

static void save_restore_token(const char *token) {
    g_autofree const char *path = token_path();
    g_autofree const char *dir = g_path_get_dirname(path);
    g_mkdir_with_parents(dir, 0700);

    // 0600, not g_file_set_contents' default 0644. This token is a capability:
    // it restores a RemoteDesktop session that can synthesize keyboard input
    // into the user's desktop. It has no business being world-readable, and it
    // outlives the process, it is the whole point that it persists.
    g_autoptr(GError) error = NULL;
    if (!g_file_set_contents_full(path, token, -1, G_FILE_SET_CONTENTS_CONSISTENT, 0600,
                                  &error)) {
        g_warning("Boo: could not save portal restore token: %s", error->message);
    }
}

static void clear_restore_token(void) {
    g_autofree const char *path = token_path();
    g_unlink(path);
}

// ---------------------------------------------------------------------------
// The paste chord

static void notify_keysym(BooTextInject *ti, guint32 keysym, guint32 state) {
    g_dbus_connection_call(ti->dbus, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
                           PORTAL_IFACE_REMOTE_DESKTOP, "NotifyKeyboardKeysym",
                           g_variant_new_parsed("(%o, @a{sv} {}, %i, %u)",
                                                ti->session_handle, (gint32)keysym,
                                                state),
                           NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

typedef struct {
    guint32 keysym;
    guint32 state;
} BooChordEvent;

#define BOO_PASTE_CHORD_LEN 6

// The Ctrl+Shift+V paste chord: press Ctrl, Shift, V in order, then release in
// reverse so the modifiers enclose the key (the target sees exactly
// Ctrl+Shift+V) and nothing is left held. Pure and connection-free, so
// portal_payloads.c can pin the sequence without a live portal. Fills `out`
// (capacity BOO_PASTE_CHORD_LEN); returns the event count.
static int build_paste_chord(BooChordEvent *out) {
    int n = 0;
    out[n++] = (BooChordEvent){XKS_CONTROL_L, KEY_PRESSED};
    out[n++] = (BooChordEvent){XKS_SHIFT_L, KEY_PRESSED};
    out[n++] = (BooChordEvent){XKS_V, KEY_PRESSED};
    out[n++] = (BooChordEvent){XKS_V, KEY_RELEASED};
    out[n++] = (BooChordEvent){XKS_SHIFT_L, KEY_RELEASED};
    out[n++] = (BooChordEvent){XKS_CONTROL_L, KEY_RELEASED};
    return n;
}

static gboolean send_paste_chord(gpointer user_data) {
    BooTextInject *ti = user_data;
    ti->paste_timeout = 0;

    if (ti->state != BOO_INJECT_READY) return G_SOURCE_REMOVE;

    // D-Bus preserves message order on a connection, so the chord arrives
    // press-to-release intact.
    BooChordEvent chord[BOO_PASTE_CHORD_LEN];
    const int n = build_paste_chord(chord);
    for (int i = 0; i < n; i++) notify_keysym(ti, chord[i].keysym, chord[i].state);
    return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Session setup: CreateSession -> SelectDevices -> Start

static void request(BooTextInject *ti, BooInjectState step);

static void fail(BooTextInject *ti, const char *why) {
    ti->state = BOO_INJECT_FAILED;
    ti->pending_paste = FALSE;
    g_message("Boo: auto-paste disabled: %s. The transcript is still copied "
              "to the clipboard.",
              why);
}

static GVariant *make_payload(gpointer user_data, const char *handle_token) {
    BooTextInject *ti = user_data;

    switch (ti->state) {
    case BOO_INJECT_CREATING_SESSION: {
        g_autofree char *session_token = boo_portal_new_token();
        return g_variant_new_parsed(
            "({'handle_token': <%s>, 'session_handle_token': <%s>},)", handle_token,
            session_token);
    }

    case BOO_INJECT_SELECTING_DEVICES: {
        if (!ti->session_handle) return NULL;

        GVariantBuilder options;
        g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
        g_variant_builder_add(&options, "{sv}", "handle_token",
                              g_variant_new_string(handle_token));
        g_variant_builder_add(&options, "{sv}", "types",
                              g_variant_new_uint32(DEVICE_KEYBOARD));
        g_variant_builder_add(&options, "{sv}", "persist_mode",
                              g_variant_new_uint32(PERSIST_UNTIL_REVOKED));

        // Replaying the token is what stops the portal asking again.
        g_autofree const char *restore = load_restore_token();
        if (restore) {
            g_variant_builder_add(&options, "{sv}", "restore_token",
                                  g_variant_new_string(restore));
        }
        return g_variant_new("(oa{sv})", ti->session_handle, &options);
    }

    case BOO_INJECT_STARTING:
        if (!ti->session_handle) return NULL;
        // Empty parent-window handle: the portal dialog is unparented.
        // Parenting needs an xdg-foreign exported handle, which is async and
        // per-backend; Ghostty ships the same tradeoff.
        return g_variant_new_parsed("(%o, '', {'handle_token': <%s>})",
                                    ti->session_handle, handle_token);

    default:
        return NULL;
    }
}

static void on_response(guint32 response, GVariant *results, gpointer user_data) {
    BooTextInject *ti = user_data;

    if (response != 0) {
        // A stale restore token can sour the whole chain, so drop it, the next
        // run then gets a fresh permission dialog instead of failing forever.
        clear_restore_token();
        fail(ti, response == 1 ? "permission was declined" : "the portal request failed");
        return;
    }

    switch (ti->state) {
    case BOO_INJECT_CREATING_SESSION: {
        const char *handle = NULL;
        if (!g_variant_lookup(results, "session_handle", "&s", &handle) || !handle) {
            fail(ti, "CreateSession returned no session handle");
            return;
        }
        ti->session_handle = g_strdup(handle);
        request(ti, BOO_INJECT_SELECTING_DEVICES);
        break;
    }

    case BOO_INJECT_SELECTING_DEVICES:
        request(ti, BOO_INJECT_STARTING);
        break;

    case BOO_INJECT_STARTING: {
        guint32 devices = 0;
        if (g_variant_lookup(results, "devices", "u", &devices) &&
            !(devices & DEVICE_KEYBOARD)) {
            clear_restore_token();
            fail(ti, "keyboard access was not granted");
            return;
        }

        // The old token was consumed by this Start; persist its replacement.
        const char *fresh = NULL;
        if (g_variant_lookup(results, "restore_token", "&s", &fresh)) {
            save_restore_token(fresh);
        }

        ti->state = BOO_INJECT_READY;
        g_debug("Boo: RemoteDesktop session ready");

        if (ti->pending_paste) {
            ti->pending_paste = FALSE;
            boo_text_inject_paste(ti);
        }
        break;
    }

    default:
        break;
    }
}

static void on_error(const char *reason, gboolean unsupported, gpointer user_data) {
    fail(user_data, unsupported ? "this desktop has no remote-desktop portal" : reason);
}

static void request(BooTextInject *ti, BooInjectState step) {
    static const char *const methods[] = {
        [BOO_INJECT_CREATING_SESSION] = "CreateSession",
        [BOO_INJECT_SELECTING_DEVICES] = "SelectDevices",
        [BOO_INJECT_STARTING] = "Start",
    };

    ti->state = step; // make_payload and on_response both key off this
    const BooPortalHandlers handlers = {make_payload, on_response, on_error, ti};
    boo_portal_call(ti->dbus, &ti->response_subscription, PORTAL_IFACE_REMOTE_DESKTOP,
                    methods[step], &handlers);
}

// ---------------------------------------------------------------------------
// Public API

BooTextInject *boo_text_inject_new(GtkWindow *parent_window) {
    BooTextInject *ti = g_new0(BooTextInject, 1);
    ti->state = BOO_INJECT_FAILED; // until we have a bus connection

    GApplication *app =
        parent_window ? G_APPLICATION(gtk_window_get_application(parent_window)) : NULL;
    GDBusConnection *dbus = app ? g_application_get_dbus_connection(app) : NULL;

    if (!dbus) {
        g_message("Boo: no session bus, so auto-paste is disabled");
        return ti;
    }

    ti->dbus = g_object_ref(dbus);
    request(ti, BOO_INJECT_CREATING_SESSION);
    return ti;
}

void boo_text_inject_paste(BooTextInject *ti) {
    if (!ti) return;

    switch (ti->state) {
    case BOO_INJECT_READY:
        if (ti->paste_timeout == 0) {
            ti->paste_timeout = g_timeout_add(PASTE_DELAY_MS, send_paste_chord, ti);
        }
        break;

    case BOO_INJECT_FAILED:
        break; // the clipboard copy still happened; nothing more to do

    default:
        ti->pending_paste = TRUE; // session still coming up; fire when ready
        break;
    }
}

void boo_text_inject_free(BooTextInject *ti) {
    if (!ti) return;

    if (ti->paste_timeout != 0) g_source_remove(ti->paste_timeout);

    if (ti->dbus) {
        if (ti->response_subscription != 0) {
            g_dbus_connection_signal_unsubscribe(ti->dbus, ti->response_subscription);
        }
        boo_portal_close_session(ti->dbus, ti->session_handle);
        g_object_unref(ti->dbus);
    }

    g_free(ti->session_handle);
    g_free(ti);
}
