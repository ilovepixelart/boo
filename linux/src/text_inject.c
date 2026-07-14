// XDG RemoteDesktop portal client — synthesizes the paste chord.
//
// Session setup is a three-step Request/Response chain:
//
//   CreateSession -> SelectDevices(KEYBOARD, persist) -> Start
//
// then NotifyKeyboardKeysym() calls are plain fire-and-forget methods on the
// session. Each step uses the same subscribe-before-call dance as
// global_shortcut.c (see the comment there for why the request path must be
// predicted up front).
//
// Persistence: SelectDevices asks for persist_mode=2 ("until revoked") and
// replays the restore token from the previous run, so the user sees the portal
// permission dialog exactly once, ever. Tokens are single-use — every Start
// response carries a fresh one, which we write back to disk each time.
//
// See:
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html

#include "text_inject.h"

#include <gio/gio.h>
#include <glib/gstdio.h>

#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_OBJECT_PATH "/org/freedesktop/portal/desktop"
#define PORTAL_IFACE_REMOTE_DESKTOP "org.freedesktop.portal.RemoteDesktop"
#define PORTAL_IFACE_REQUEST "org.freedesktop.portal.Request"
#define PORTAL_IFACE_SESSION "org.freedesktop.portal.Session"

#define DEVICE_KEYBOARD 1u  // SelectDevices `types` bitmask
#define PERSIST_UNTIL_REVOKED 2u

#define KEY_PRESSED 1u
#define KEY_RELEASED 0u

// X11 keysyms — the portal resolves these against the active layout. Every
// layout can produce Control, Shift, and the letter V, which is the whole point
// of pasting instead of typing.
#define XKS_CONTROL_L 0xffe3
#define XKS_SHIFT_L 0xffe1
#define XKS_V 0x0076

// Wayland clipboard offers propagate through the compositor asynchronously; if
// the paste keystroke beats the new offer, the target pastes stale data. A
// small fixed delay after the caller sets the clipboard is the same mitigation
// every injection tool uses — there is no "offer visible to peers" event.
#define PASTE_DELAY_MS 75

typedef enum {
    BOO_INJECT_STATE_CREATING_SESSION,
    BOO_INJECT_STATE_SELECTING_DEVICES,
    BOO_INJECT_STATE_STARTING,
    BOO_INJECT_STATE_READY,
    BOO_INJECT_STATE_FAILED,
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
// Restore token persistence

static char *boo_token_path(void) {
    return g_build_filename(g_get_user_state_dir(), "boo",
                            "remote-desktop-token", NULL);
}

static char *boo_load_restore_token(void) {
    char *path = boo_token_path();
    char *token = NULL;
    g_file_get_contents(path, &token, NULL, NULL);
    g_free(path);
    if (token) g_strstrip(token);
    if (token && !*token) {
        g_free(token);
        token = NULL;
    }
    return token;
}

static void boo_save_restore_token(const char *token) {
    char *path = boo_token_path();
    char *dir = g_path_get_dirname(path);
    g_mkdir_with_parents(dir, 0700);

    GError *error = NULL;
    if (!g_file_set_contents(path, token, -1, &error)) {
        g_warning("Boo: could not save portal restore token: %s", error->message);
        g_clear_error(&error);
    }

    g_free(dir);
    g_free(path);
}

static void boo_clear_restore_token(void) {
    char *path = boo_token_path();
    g_unlink(path);
    g_free(path);
}

// ---------------------------------------------------------------------------
// Portal request plumbing (see global_shortcut.c for the protocol notes)

static char *boo_generate_token(void) {
    return g_strdup_printf("boo_%08x", g_random_int());
}

static char *boo_request_path(GDBusConnection *dbus, const char *token) {
    const char *unique = g_dbus_connection_get_unique_name(dbus);
    if (!unique || unique[0] != ':') return NULL;

    char *name = g_strdup(unique + 1);
    for (char *p = name; *p; p++) {
        if (*p == '.') *p = '_';
    }

    char *path = g_strdup_printf("%s/request/%s/%s", PORTAL_OBJECT_PATH, name, token);
    g_free(name);
    return path;
}

static void on_call_done(GObject *source, GAsyncResult *res, gpointer user_data) {
    (void)user_data;

    GError *error = NULL;
    GVariant *reply =
        g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);

    if (!reply) {
        g_warning("Boo: RemoteDesktop portal call failed: %s",
                  error ? error->message : "(unknown)");
        g_clear_error(&error);
        return;
    }
    g_variant_unref(reply);
}

// ---------------------------------------------------------------------------
// The paste chord

static void boo_notify_keysym(BooTextInject *ti, guint32 keysym, guint32 state) {
    g_dbus_connection_call(
        ti->dbus, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
        PORTAL_IFACE_REMOTE_DESKTOP, "NotifyKeyboardKeysym",
        g_variant_new_parsed("(%o, @a{sv} {}, %i, %u)", ti->session_handle,
                             (gint32)keysym, state),
        NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, on_call_done, NULL);
}

static gboolean boo_send_paste_chord(gpointer user_data) {
    BooTextInject *ti = user_data;
    ti->paste_timeout = 0;

    if (ti->state != BOO_INJECT_STATE_READY) return G_SOURCE_REMOVE;

    // D-Bus preserves message order on a connection, so the chord arrives
    // press-to-release intact.
    boo_notify_keysym(ti, XKS_CONTROL_L, KEY_PRESSED);
    boo_notify_keysym(ti, XKS_SHIFT_L, KEY_PRESSED);
    boo_notify_keysym(ti, XKS_V, KEY_PRESSED);
    boo_notify_keysym(ti, XKS_V, KEY_RELEASED);
    boo_notify_keysym(ti, XKS_SHIFT_L, KEY_RELEASED);
    boo_notify_keysym(ti, XKS_CONTROL_L, KEY_RELEASED);
    return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Session setup chain

static void boo_portal_request(BooTextInject *ti, const char *method,
                               GVariant *(*make_payload)(BooTextInject *ti,
                                                         const char *token));

static GVariant *make_create_session_payload(BooTextInject *ti, const char *token) {
    (void)ti;
    char *session_token = boo_generate_token();
    GVariant *payload = g_variant_new_parsed(
        "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
        token, session_token);
    g_free(session_token);
    return payload;
}

static GVariant *make_select_devices_payload(BooTextInject *ti, const char *token) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token",
                          g_variant_new_string(token));
    g_variant_builder_add(&options, "{sv}", "types",
                          g_variant_new_uint32(DEVICE_KEYBOARD));
    g_variant_builder_add(&options, "{sv}", "persist_mode",
                          g_variant_new_uint32(PERSIST_UNTIL_REVOKED));

    char *restore_token = boo_load_restore_token();
    if (restore_token) {
        g_variant_builder_add(&options, "{sv}", "restore_token",
                              g_variant_new_string(restore_token));
        g_free(restore_token);
    }

    return g_variant_new("(oa{sv})", ti->session_handle, &options);
}

static GVariant *make_start_payload(BooTextInject *ti, const char *token) {
    // Empty parent-window handle: same unparented-dialog tradeoff as
    // global_shortcut.c.
    return g_variant_new_parsed("(%o, '', {'handle_token': <%s>})",
                                ti->session_handle, token);
}

static void boo_fail(BooTextInject *ti, const char *why) {
    ti->state = BOO_INJECT_STATE_FAILED;
    ti->pending_paste = FALSE;
    g_message("Boo: auto-paste disabled — %s. The transcript is still copied "
              "to the clipboard.", why);
}

static void on_portal_response(GDBusConnection *dbus, const char *sender,
                               const char *object_path, const char *iface,
                               const char *signal, GVariant *params,
                               gpointer user_data) {
    (void)sender; (void)object_path; (void)iface; (void)signal;
    BooTextInject *ti = user_data;

    if (ti->response_subscription != 0) {
        g_dbus_connection_signal_unsubscribe(dbus, ti->response_subscription);
        ti->response_subscription = 0;
    }

    guint32 response = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &response, &results);

    if (response != 0) {
        // A stale restore token can sour the whole chain; drop it so the next
        // run gets a fresh permission dialog instead of failing forever.
        boo_clear_restore_token();
        boo_fail(ti, response == 1 ? "permission was declined"
                                   : "the portal request failed");
        if (results) g_variant_unref(results);
        return;
    }

    switch (ti->state) {
    case BOO_INJECT_STATE_CREATING_SESSION: {
        const char *handle = NULL;
        if (!g_variant_lookup(results, "session_handle", "&s", &handle) || !handle) {
            boo_fail(ti, "CreateSession returned no session handle");
            break;
        }
        ti->session_handle = g_strdup(handle);
        ti->state = BOO_INJECT_STATE_SELECTING_DEVICES;
        boo_portal_request(ti, "SelectDevices", make_select_devices_payload);
        break;
    }

    case BOO_INJECT_STATE_SELECTING_DEVICES:
        ti->state = BOO_INJECT_STATE_STARTING;
        boo_portal_request(ti, "Start", make_start_payload);
        break;

    case BOO_INJECT_STATE_STARTING: {
        guint32 devices = 0;
        if (g_variant_lookup(results, "devices", "u", &devices) &&
            !(devices & DEVICE_KEYBOARD)) {
            boo_clear_restore_token();
            boo_fail(ti, "keyboard access was not granted");
            break;
        }

        // The old token was consumed by this Start; persist its replacement.
        const char *new_token = NULL;
        if (g_variant_lookup(results, "restore_token", "&s", &new_token)) {
            boo_save_restore_token(new_token);
        }

        ti->state = BOO_INJECT_STATE_READY;
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

    if (results) g_variant_unref(results);
}

static void boo_portal_request(BooTextInject *ti, const char *method,
                               GVariant *(*make_payload)(BooTextInject *ti,
                                                         const char *token)) {
    if (ti->response_subscription != 0) {
        g_warning("Boo: a portal request is already in flight; skipping");
        return;
    }

    char *request_token = boo_generate_token();
    char *request_path = boo_request_path(ti->dbus, request_token);
    if (!request_path) {
        boo_fail(ti, "no D-Bus unique name");
        g_free(request_token);
        return;
    }

    // Subscribe BEFORE calling — see global_shortcut.c.
    ti->response_subscription = g_dbus_connection_signal_subscribe(
        ti->dbus, NULL, PORTAL_IFACE_REQUEST, "Response", request_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, on_portal_response, ti, NULL);

    g_dbus_connection_call(ti->dbus, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
                           PORTAL_IFACE_REMOTE_DESKTOP, method,
                           make_payload(ti, request_token), NULL,
                           G_DBUS_CALL_FLAGS_NONE, -1, NULL, on_call_done, NULL);

    g_free(request_path);
    g_free(request_token);
}

// ---------------------------------------------------------------------------
// Public API

BooTextInject *boo_text_inject_new(GtkWindow *parent_window) {
    BooTextInject *ti = g_new0(BooTextInject, 1);
    ti->state = BOO_INJECT_STATE_FAILED; // until we get a bus connection

    GApplication *app =
        parent_window ? G_APPLICATION(gtk_window_get_application(parent_window)) : NULL;
    GDBusConnection *dbus = app ? g_application_get_dbus_connection(app) : NULL;

    if (!dbus) {
        g_message("Boo: no session bus — auto-paste disabled");
        return ti;
    }

    ti->dbus = g_object_ref(dbus);
    ti->state = BOO_INJECT_STATE_CREATING_SESSION;
    boo_portal_request(ti, "CreateSession", make_create_session_payload);
    return ti;
}

void boo_text_inject_paste(BooTextInject *ti) {
    if (!ti) return;

    switch (ti->state) {
    case BOO_INJECT_STATE_READY:
        if (ti->paste_timeout == 0) {
            ti->paste_timeout =
                g_timeout_add(PASTE_DELAY_MS, boo_send_paste_chord, ti);
        }
        break;

    case BOO_INJECT_STATE_FAILED:
        break; // clipboard copy still happened; nothing more to do

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

        if (ti->session_handle) {
            g_dbus_connection_call(ti->dbus, PORTAL_BUS_NAME, ti->session_handle,
                                   PORTAL_IFACE_SESSION, "Close", NULL, NULL,
                                   G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
        }

        g_object_unref(ti->dbus);
    }

    g_free(ti->session_handle);
    g_free(ti);
}
