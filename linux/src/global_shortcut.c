// XDG GlobalShortcuts portal client, the Ctrl+Shift+Space hotkey.
//
// The chain is:
//
//   CreateSession -> ListShortcuts -> BindShortcuts (only if not already bound)
//
// then Activated signals arrive on the session. The Request/Response plumbing ,
// including the subscribe-before-call dance the protocol requires, lives in
// portal.c, shared with the RemoteDesktop client.
//
// ListShortcuts is not an optimisation. BindShortcuts is the call that raises the
// approval dialog, and the portal remembers bindings per application, so binding
// unconditionally would re-prompt the user on every single launch.
//
// See:
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html

#include "global_shortcut.h"
#include "portal.h"

#define PORTAL_IFACE_GLOBAL_SHORTCUTS "org.freedesktop.portal.GlobalShortcuts"

// The ID is our own opaque key. The trigger is only a *preferred* one: the
// portal's dialog lets the user rebind it, and some desktops ignore the
// preference outright. Never assume the bound key is the one we asked for.
#define BOO_SHORTCUT_ID          "toggle-record"
#define BOO_SHORTCUT_DESCRIPTION "Toggle Boo recording"
#define BOO_SHORTCUT_TRIGGER     "CTRL+SHIFT+space"

typedef enum {
    BOO_GS_CREATE_SESSION,
    BOO_GS_LIST_SHORTCUTS,
    BOO_GS_BIND_SHORTCUTS,
} BooGsStep;

struct BooGlobalShortcut {
    BooShortcutCallback on_activated;
    BooShortcutUnavailableCallback on_unavailable; // may be NULL
    gpointer user_data;

    GDBusConnection *dbus; // owned ref; NULL when the session bus is unavailable
    char *session_handle;  // owned; NULL until CreateSession succeeds

    guint response_subscription; // 0 == no request in flight
    guint activate_subscription; // 0 == not subscribed

    BooGsStep step;                // which request is in flight
    gboolean reported_unavailable; // report at most once
};

static void request(BooGlobalShortcut *gs, BooGsStep step);

// Tell the frontend the hotkey is dead, so it can say so rather than leaving the
// user pressing a key that does nothing.
static void report_unavailable(BooGlobalShortcut *gs, const char *reason) {
    if (!gs || gs->reported_unavailable) return;
    gs->reported_unavailable = TRUE;

    g_message("Boo: global shortcut unavailable: %s", reason);
    if (gs->on_unavailable) gs->on_unavailable(reason, gs->user_data);
}

// org.freedesktop.portal.GlobalShortcuts.Activated
static void on_activated(GDBusConnection *dbus, const char *sender,
                         const char *object_path, const char *iface, const char *signal,
                         GVariant *params, gpointer user_data) {
    (void)dbus;
    (void)sender;
    (void)object_path;
    (void)iface;
    (void)signal;
    BooGlobalShortcut *gs = user_data;

    // (osa{sv}), child 1 is the ID of the shortcut that fired.
    const char *shortcut_id = NULL;
    g_variant_get_child(params, 1, "&s", &shortcut_id);
    if (!shortcut_id || !g_str_equal(shortcut_id, BOO_SHORTCUT_ID)) return;

    // Signals dispatch on the main context we subscribed from, the GTK main
    // loop, so touching the UI from here is safe.
    if (gs->on_activated) gs->on_activated(gs->user_data);
}

// Did an earlier run already bind our shortcut? If so we are done, and the user
// sees no dialog at all.
static gboolean already_bound(GVariant *results) {
    g_autoptr(GVariant) shortcuts =
        g_variant_lookup_value(results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
    if (!shortcuts) return FALSE;

    GVariantIter iter;
    const char *id = NULL;
    g_autoptr(GVariant) props = NULL;

    g_variant_iter_init(&iter, shortcuts);
    while (g_variant_iter_next(&iter, "(&s@a{sv})", &id, &props)) {
        g_autoptr(GVariant) owned = props; // freed each turn
        props = NULL;
        if (id && g_str_equal(id, BOO_SHORTCUT_ID)) return TRUE;
    }
    return FALSE;
}

static GVariant *make_payload(gpointer user_data, const char *handle_token) {
    BooGlobalShortcut *gs = user_data;

    switch (gs->step) {
    case BOO_GS_CREATE_SESSION: {
        g_autofree char *session_token = boo_portal_new_token();
        return g_variant_new_parsed(
            "({'handle_token': <%s>, 'session_handle_token': <%s>},)", handle_token,
            session_token);
    }

    case BOO_GS_LIST_SHORTCUTS:
        if (!gs->session_handle) return NULL;
        return g_variant_new_parsed("(%o, {'handle_token': <%s>})", gs->session_handle,
                                    handle_token);

    case BOO_GS_BIND_SHORTCUTS: {
        if (!gs->session_handle) return NULL;

        GVariantBuilder binds;
        g_variant_builder_init(&binds, G_VARIANT_TYPE("a(sa{sv})"));
        g_variant_builder_add_parsed(
            &binds, "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
            BOO_SHORTCUT_ID, BOO_SHORTCUT_DESCRIPTION, BOO_SHORTCUT_TRIGGER);

        // Empty parent-window handle: the portal dialog is unparented.
        return g_variant_new_parsed("(%o, %*, '', {'handle_token': <%s>})",
                                    gs->session_handle, g_variant_builder_end(&binds),
                                    handle_token);
    }
    }
    return NULL;
}

static void on_session_created(BooGlobalShortcut *gs, GVariant *results) {
    const char *handle = NULL;
    if (!g_variant_lookup(results, "session_handle", "&s", &handle) || !handle) {
        report_unavailable(gs, "CreateSession returned no session handle");
        return;
    }

    gs->session_handle = g_strdup(handle);
    g_debug("Boo: global shortcuts session=%s", gs->session_handle);

    // Subscribe to activations before binding, so an early one can't be missed.
    gs->activate_subscription = g_dbus_connection_signal_subscribe(
        gs->dbus, NULL, PORTAL_IFACE_GLOBAL_SHORTCUTS, "Activated", PORTAL_OBJECT_PATH,
        gs->session_handle, G_DBUS_SIGNAL_FLAGS_MATCH_ARG0_PATH, on_activated, gs, NULL);

    // Ask what we already have before asking for anything new.
    request(gs, BOO_GS_LIST_SHORTCUTS);
}

static void on_response(guint32 response, GVariant *results, gpointer user_data) {
    BooGlobalShortcut *gs = user_data;

    if (response != 0) {
        report_unavailable(gs, response == 1 ? "the shortcut was declined"
                                             : "the desktop rejected the request");
        return;
    }

    switch (gs->step) {
    case BOO_GS_CREATE_SESSION:
        on_session_created(gs, results);
        break;

    case BOO_GS_LIST_SHORTCUTS:
        if (already_bound(results)) {
            // Skipping BindShortcuts is the whole point: it is the call that
            // raises the approval dialog.
            g_debug("Boo: shortcut already bound, no dialog needed");
        } else {
            request(gs, BOO_GS_BIND_SHORTCUTS);
        }
        break;

    case BOO_GS_BIND_SHORTCUTS:
        g_debug("Boo: global shortcut bound");
        break;
    }
}

static void on_error(const char *reason, gboolean unsupported, gpointer user_data) {
    // By far the common case, and worth naming precisely: GNOME only shipped a
    // GlobalShortcuts backend in 48, so on 46 (Ubuntu 24.04 LTS) and 47 the
    // interface is absent outright and D-Bus answers UnknownMethod.
    report_unavailable(user_data, unsupported
                                      ? "this desktop has no global-shortcuts portal "
                                        "(needs GNOME 48+, KDE Plasma, or Hyprland)"
                                      : reason);
}

static void request(BooGlobalShortcut *gs, BooGsStep step) {
    static const char *const methods[] = {
        [BOO_GS_CREATE_SESSION] = "CreateSession",
        [BOO_GS_LIST_SHORTCUTS] = "ListShortcuts",
        [BOO_GS_BIND_SHORTCUTS] = "BindShortcuts",
    };

    gs->step = step; // make_payload and on_response both key off this
    boo_portal_call(gs->dbus, &gs->response_subscription, PORTAL_IFACE_GLOBAL_SHORTCUTS,
                    methods[step], make_payload, on_response, on_error, gs);
}

// ---------------------------------------------------------------------------
// Public API

BooGlobalShortcut *boo_global_shortcut_new(GtkWindow *parent_window,
                                           BooShortcutCallback on_activated_cb,
                                           BooShortcutUnavailableCallback on_unavailable,
                                           gpointer user_data) {
    BooGlobalShortcut *gs = g_new0(BooGlobalShortcut, 1);
    gs->on_activated = on_activated_cb;
    gs->on_unavailable = on_unavailable;
    gs->user_data = user_data;

    // Reuse GApplication's session bus connection: the predicted request path is
    // derived from its unique name, so it must be the connection the portal sees.
    GApplication *app =
        parent_window ? G_APPLICATION(gtk_window_get_application(parent_window)) : NULL;
    GDBusConnection *dbus = app ? g_application_get_dbus_connection(app) : NULL;

    if (!dbus) {
        report_unavailable(gs, "no session bus");
        return gs; // Still a valid handle; it just never fires.
    }

    gs->dbus = g_object_ref(dbus);
    request(gs, BOO_GS_CREATE_SESSION);
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
        boo_portal_close_session(gs->dbus, gs->session_handle);
        g_object_unref(gs->dbus);
    }

    g_free(gs->session_handle);
    g_free(gs);
}
