// XDG GlobalShortcuts portal client.
//
// Registers a single shortcut ("toggle-record") with
// org.freedesktop.portal.GlobalShortcuts and invokes a callback whenever the
// compositor activates it. This is the only sandbox-friendly way to get a global
// hotkey on Wayland, and it works on X11 too, so we use it uniformly.
//
// The portal Request/Response protocol has a race that is easy to get wrong. The
// naive reading of the spec is:
//
//   1. Call the method; it returns the object path of a Request.
//   2. Subscribe to Response on that path.
//   3. Handle the reply.
//
// That does not work. The portal may emit Response before step 2 completes, and
// Response fires exactly once, so a lost signal stalls the exchange forever. The
// protocol therefore expects clients to *predict* the request path — it is a pure
// function of our D-Bus unique name plus a caller-chosen handle_token — and to
// subscribe BEFORE issuing the call, which makes the method's own return value
// redundant. This is documented only in passing, under the Request interface.
//
// See:
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html

#include "global_shortcut.h"

#include <gio/gio.h>

#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_OBJECT_PATH "/org/freedesktop/portal/desktop"
#define PORTAL_IFACE_GLOBAL_SHORTCUTS "org.freedesktop.portal.GlobalShortcuts"
#define PORTAL_IFACE_REQUEST "org.freedesktop.portal.Request"
#define PORTAL_IFACE_SESSION "org.freedesktop.portal.Session"

// The ID is our own opaque key. The trigger is only a *preferred* one: the
// portal's confirmation dialog lets the user rebind it, and some desktops ignore
// the preference outright. Never assume the bound key is the one we asked for.
#define BOO_SHORTCUT_ID "toggle-record"
#define BOO_SHORTCUT_DESCRIPTION "Toggle Boo recording"
#define BOO_SHORTCUT_TRIGGER "CTRL+SHIFT+space"

typedef enum {
    BOO_METHOD_CREATE_SESSION,
    BOO_METHOD_BIND_SHORTCUTS,
} BooPortalMethod;

struct BooGlobalShortcut {
    BooShortcutCallback on_activated;
    BooShortcutUnavailableCallback on_unavailable; // may be NULL
    gpointer user_data;

    GDBusConnection *dbus; // owned ref; NULL when the session bus is unavailable
    char *session_handle;  // owned; NULL until CreateSession succeeds

    guint response_subscription; // 0 == no request in flight
    guint activate_subscription; // 0 == not subscribed
    gboolean reported_unavailable; // report at most once
};

// Tell the frontend the hotkey is dead, so it can say so instead of leaving the
// user pressing a key that does nothing.
static void boo_report_unavailable(BooGlobalShortcut *gs, const char *reason) {
    if (!gs || gs->reported_unavailable) return;
    gs->reported_unavailable = TRUE;

    g_message("Boo: global shortcut unavailable — %s", reason);
    if (gs->on_unavailable) gs->on_unavailable(reason, gs->user_data);
}

static void boo_portal_request(BooGlobalShortcut *gs, BooPortalMethod method);

// Token used both in the request payload and to predict the Request object path.
// Must be a valid D-Bus object path component, so [A-Za-z0-9_] only.
static char *boo_generate_token(void) {
    return g_strdup_printf("boo_%08x", g_random_int());
}

// Rebuild the object path the portal will use for this request, from our unique
// bus name (":1.42" -> "1_42") and the handle_token we chose.
static char *boo_request_path(GDBusConnection *dbus, const char *token) {
    const char *unique = g_dbus_connection_get_unique_name(dbus);
    if (!unique || unique[0] != ':') return NULL;

    char *name = g_strdup(unique + 1); // strip the leading ':'
    for (char *p = name; *p; p++) {
        if (*p == '.') *p = '_';
    }

    char *path = g_strdup_printf("%s/request/%s/%s", PORTAL_OBJECT_PATH, name, token);
    g_free(name);
    return path;
}

// org.freedesktop.portal.GlobalShortcuts.Activated
static void on_shortcut_activated(GDBusConnection *dbus, const char *sender,
                                  const char *object_path, const char *iface,
                                  const char *signal, GVariant *params,
                                  gpointer user_data) {
    (void)dbus; (void)sender; (void)object_path; (void)iface; (void)signal;
    BooGlobalShortcut *gs = user_data;

    // (osa{sv}) — child 1 is the ID of the shortcut that fired.
    const char *shortcut_id = NULL;
    g_variant_get_child(params, 1, "&s", &shortcut_id);
    if (!shortcut_id || !g_str_equal(shortcut_id, BOO_SHORTCUT_ID)) return;

    // Signals dispatch on the main context we subscribed from — the GTK main
    // loop — so touching the UI from here is safe.
    if (gs->on_activated) gs->on_activated(gs->user_data);
}

static void boo_on_session_created(BooGlobalShortcut *gs, GVariant *results) {
    const char *handle = NULL;
    if (!g_variant_lookup(results, "session_handle", "&s", &handle) || !handle) {
        g_warning("Boo: CreateSession returned no session_handle");
        return;
    }

    gs->session_handle = g_strdup(handle);
    g_debug("Boo: global shortcuts session=%s", gs->session_handle);

    // Subscribe to activations before binding, so an early activation can't be
    // missed.
    gs->activate_subscription = g_dbus_connection_signal_subscribe(
        gs->dbus, NULL, PORTAL_IFACE_GLOBAL_SHORTCUTS, "Activated",
        PORTAL_OBJECT_PATH, gs->session_handle,
        G_DBUS_SIGNAL_FLAGS_MATCH_ARG0_PATH, on_shortcut_activated, gs, NULL);

    boo_portal_request(gs, BOO_METHOD_BIND_SHORTCUTS);
}

// org.freedesktop.portal.Request.Response
static void on_portal_response(GDBusConnection *dbus, const char *sender,
                               const char *object_path, const char *iface,
                               const char *signal, GVariant *params,
                               gpointer user_data) {
    (void)sender; (void)object_path; (void)iface; (void)signal;
    BooGlobalShortcut *gs = user_data;

    // Response fires once per request; drop the subscription right away so the
    // next request can install its own.
    if (gs->response_subscription != 0) {
        g_dbus_connection_signal_unsubscribe(dbus, gs->response_subscription);
        gs->response_subscription = 0;
    }

    guint32 response = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &response, &results);

    switch (response) {
    case 0:
        // CreateSession is the only reply with a payload we need. We know which
        // request this is by whether a session exists yet.
        if (!gs->session_handle) {
            boo_on_session_created(gs, results);
        } else {
            g_debug("Boo: global shortcut bound");
        }
        break;
    case 1:
        boo_report_unavailable(gs, "the shortcut was declined");
        break;
    default:
        boo_report_unavailable(gs, "the desktop rejected the shortcut request");
        break;
    }

    if (results) g_variant_unref(results);
}

// The method call's own reply carries nothing we use — the payload arrives via
// the Response signal — but it still surfaces transport errors.
static void on_call_done(GObject *source, GAsyncResult *res, gpointer user_data) {
    BooGlobalShortcut *gs = user_data;

    GError *error = NULL;
    GVariant *reply =
        g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);

    if (reply) {
        g_variant_unref(reply);
        return;
    }

    // The call failed, so no Response signal is coming. Drop the subscription we
    // installed for it — otherwise it lingers and blocks any later request.
    if (gs && gs->response_subscription != 0) {
        g_dbus_connection_signal_unsubscribe(gs->dbus, gs->response_subscription);
        gs->response_subscription = 0;
    }

    // The common case by far, and worth naming precisely: GNOME only shipped a
    // GlobalShortcuts backend in 48, so on 46 (Ubuntu 24.04 LTS) and 47 the
    // interface is absent outright and D-Bus answers UnknownMethod.
    const gboolean unsupported =
        error && (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) ||
                  g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE) ||
                  g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN));

    if (unsupported) {
        boo_report_unavailable(
            gs, "this desktop has no global-shortcuts portal "
                "(needs GNOME 48+, KDE Plasma, or Hyprland)");
    } else {
        boo_report_unavailable(gs, error ? error->message : "portal call failed");
    }

    g_clear_error(&error);
}

// Returns a floating GVariant, or NULL if the method cannot be built yet.
static GVariant *boo_make_payload(BooGlobalShortcut *gs, BooPortalMethod method,
                                  const char *request_token) {
    switch (method) {
    case BOO_METHOD_CREATE_SESSION: {
        char *session_token = boo_generate_token();
        GVariant *payload = g_variant_new_parsed(
            "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
            request_token, session_token);
        g_free(session_token);
        return payload;
    }

    case BOO_METHOD_BIND_SHORTCUTS: {
        if (!gs->session_handle) return NULL;

        GVariantBuilder binds;
        g_variant_builder_init(&binds, G_VARIANT_TYPE("a(sa{sv})"));
        g_variant_builder_add_parsed(
            &binds, "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
            BOO_SHORTCUT_ID, BOO_SHORTCUT_DESCRIPTION, BOO_SHORTCUT_TRIGGER);

        // Empty parent-window handle leaves the portal dialog unparented.
        // Parenting needs an xdg-foreign exported handle, which is async and
        // per-backend; Ghostty ships the same tradeoff.
        return g_variant_new_parsed("(%o, %*, '', {'handle_token': <%s>})",
                                    gs->session_handle,
                                    g_variant_builder_end(&binds), request_token);
    }
    }
    return NULL;
}

static void boo_portal_request(BooGlobalShortcut *gs, BooPortalMethod method) {
    if (!gs->dbus) return;
    if (gs->response_subscription != 0) {
        g_warning("Boo: a portal request is already in flight; skipping");
        return;
    }

    char *request_token = boo_generate_token();
    GVariant *payload = boo_make_payload(gs, method, request_token);
    if (!payload) {
        g_free(request_token);
        return;
    }

    char *request_path = boo_request_path(gs->dbus, request_token);
    if (!request_path) {
        g_warning("Boo: no D-Bus unique name; global shortcut disabled");
        g_variant_unref(g_variant_ref_sink(payload)); // payload was floating
        g_free(request_token);
        return;
    }

    // Subscribe BEFORE calling — see the file header. Skipping this is the
    // classic portal bug: it passes against a slow portal and hangs on a fast one.
    gs->response_subscription = g_dbus_connection_signal_subscribe(
        gs->dbus, NULL, PORTAL_IFACE_REQUEST, "Response", request_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, on_portal_response, gs, NULL);

    g_dbus_connection_call(
        gs->dbus, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
        PORTAL_IFACE_GLOBAL_SHORTCUTS,
        method == BOO_METHOD_CREATE_SESSION ? "CreateSession" : "BindShortcuts",
        payload, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, on_call_done, gs);

    g_free(request_path);
    g_free(request_token);
}

BooGlobalShortcut *boo_global_shortcut_new(
    GtkWindow *parent_window, BooShortcutCallback on_activated,
    BooShortcutUnavailableCallback on_unavailable, gpointer user_data) {
    BooGlobalShortcut *gs = g_new0(BooGlobalShortcut, 1);
    gs->on_activated = on_activated;
    gs->on_unavailable = on_unavailable;
    gs->user_data = user_data;

    // Reuse GApplication's session bus connection: the predicted request path is
    // derived from its unique name, so it must be the connection the portal sees.
    GApplication *app =
        parent_window ? G_APPLICATION(gtk_window_get_application(parent_window)) : NULL;
    GDBusConnection *dbus = app ? g_application_get_dbus_connection(app) : NULL;

    if (!dbus) {
        boo_report_unavailable(gs, "no session bus");
        return gs; // Still a valid handle; it just never fires.
    }

    gs->dbus = g_object_ref(dbus);
    boo_portal_request(gs, BOO_METHOD_CREATE_SESSION);
    return gs;
}

void boo_global_shortcut_free(BooGlobalShortcut *gs) {
    if (!gs) return;

    if (gs->dbus) {
        if (gs->response_subscription != 0) {
            g_dbus_connection_signal_unsubscribe(gs->dbus, gs->response_subscription);
        }
        if (gs->activate_subscription != 0) {
            g_dbus_connection_signal_unsubscribe(gs->dbus, gs->activate_subscription);
        }

        if (gs->session_handle) {
            g_dbus_connection_call(gs->dbus, PORTAL_BUS_NAME, gs->session_handle,
                                   PORTAL_IFACE_SESSION, "Close", NULL, NULL,
                                   G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
        }

        g_object_unref(gs->dbus);
    }

    g_free(gs->session_handle);
    g_free(gs);
}
