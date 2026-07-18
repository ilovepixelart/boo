#include "portal.h"

#include <sys/random.h>

// One in-flight request. The Response signal and the method-call reply each
// complete once, in either order; the request is freed only once BOTH have.
// Freeing on the first (the old model) left the other handler holding a dangling
// request when a portal delivered the Response before the method reply.
typedef struct {
    GDBusConnection *dbus; // borrowed; outlives the request
    guint *subscription;   // caller's slot, so it can tear down on free
    BooPortalResponseFn on_response;
    BooPortalErrorFn on_error;
    gpointer user_data;
    GCancellable *cancellable; // own ref (may be NULL); cancelled == client gone
    gboolean signal_pending;   // the Response signal has not completed yet
    gboolean call_pending;     // the method-call reply has not completed yet
} PortalRequest;

// A valid D-Bus object-path component ([A-Za-z0-9_] only), unpredictable.
//
// The CSPRNG (getrandom), not g_random_int's Mersenne Twister: the client
// subscribes to the Response object path *before* issuing the call, and that
// path embeds this token. For RemoteDesktop the Response carries a restore
// token that is a keyboard-injection capability, so a co-resident same-user
// process must not be able to predict the path and race for the payload.
char *boo_portal_new_token(void) {
    guint64 r = 0;
    // getrandom is Linux-only; macOS, where run.sh compiles this file too,
    // spells the same CSPRNG syscall getentropy.
#ifdef __APPLE__
    const gboolean seeded = getentropy(&r, sizeof(r)) == 0;
#else
    const gboolean seeded = getrandom(&r, sizeof(r), 0) == (gssize)sizeof(r);
#endif
    if (!seeded) {
        // getrandom only fails this early-boot; a desktop session is long
        // seeded. Fall back to non-crypto rather than block: still a unique,
        // valid path component.
        r = ((guint64)g_random_int() << 32) | g_random_int();
    }
    return g_strdup_printf("boo_%016" G_GINT64_MODIFIER "x", r);
}

// Rebuild the object path the portal will reply on, from our unique bus name
// (":1.42" -> "1_42") and the token we chose. See the header for why.
static char *portal_request_path(GDBusConnection *dbus, const char *token) {
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

// Drop the Response subscription: the signal fired, or the call failed so none
// is coming. Safe to call once; clears the caller's slot.
static void portal_request_drop_subscription(PortalRequest *req) {
    if (req->subscription && *req->subscription != 0) {
        g_dbus_connection_signal_unsubscribe(req->dbus, *req->subscription);
        *req->subscription = 0;
    }
}

// Free the request once both the Response signal and the method-call reply have
// completed; whichever handler runs last frees it.
static void portal_request_release(PortalRequest *req) {
    if (req->signal_pending || req->call_pending) return;
    if (req->cancellable) g_object_unref(req->cancellable);
    g_free(req);
}

// org.freedesktop.portal.Request.Response
static void on_response(GDBusConnection *dbus, const char *sender,
                        const char *object_path, const char *iface, const char *signal,
                        GVariant *params, gpointer user_data) {
    (void)dbus;
    (void)sender;
    (void)object_path;
    (void)iface;
    (void)signal;
    PortalRequest *req = user_data;

    // A wrong-signature Response is dropped rather than fed to g_variant_get
    // (which would emit a GLib-CRITICAL, fatal under G_DEBUG=fatal-criticals);
    // completing the request keeps the state machine from stalling.
    if (!g_variant_is_of_type(params, G_VARIANT_TYPE("(ua{sv})"))) {
        req->signal_pending = FALSE;
        portal_request_drop_subscription(req);
        portal_request_release(req);
        return;
    }

    guint32 response = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &response, &results);

    // Response fires once. Drop the subscription before the callback so a
    // callback that issues the next request finds the slot free. The request
    // struct outlives this handler if the method-call reply has not landed yet.
    req->signal_pending = FALSE;
    portal_request_drop_subscription(req);
    BooPortalResponseFn cb = req->on_response;
    gpointer data = req->user_data;
    portal_request_release(req);

    if (cb) cb(response, results, data);
    if (results) g_variant_unref(results);
}

// The method call's own reply carries nothing we use, the payload arrives via
// the Response signal, but it is how transport errors surface.
static void on_call_done(GObject *source, GAsyncResult *res, gpointer user_data) {
    PortalRequest *req = user_data;

    GError *error = NULL;
    GVariant *reply =
        g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);

    req->call_pending = FALSE;

    // The client was torn down while this call was in flight: it already
    // unsubscribed the Response, so no signal is coming. Invoke no callback,
    // account for the (never-arriving) signal, and drop the request.
    if (req->cancellable && g_cancellable_is_cancelled(req->cancellable)) {
        if (reply) g_variant_unref(reply);
        g_clear_error(&error);
        req->signal_pending = FALSE;
        portal_request_release(req);
        return;
    }

    if (reply) {
        // Success: the Response signal carries the payload and completes the
        // request. Account only for this reply; it frees req only if the signal
        // has already fired (a portal that reordered signal-before-reply).
        g_variant_unref(reply);
        portal_request_release(req);
        return;
    }

    // The call failed, so no Response is coming. Tear down the subscription we
    // installed for it, leaving it dangling would leak it and block the next
    // request, which is precisely the bug the duplicated copies of this code
    // drifted into.
    //
    // UnknownMethod/UnknownInterface/ServiceUnknown mean the desktop has no such
    // portal at all, GNOME, for instance, only gained GlobalShortcuts in 48 ,
    // which is worth reporting differently from a call the user declined.
    portal_request_drop_subscription(req);
    req->signal_pending = FALSE;

    const gboolean unsupported =
        error && (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) ||
                  g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE) ||
                  g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN));

    BooPortalErrorFn cb = req->on_error;
    gpointer data = req->user_data;
    const char *reason = error && error->message ? error->message : "portal call failed";

    if (cb) cb(reason, unsupported, data);
    portal_request_release(req);
    g_clear_error(&error);
}

void boo_portal_call(GDBusConnection *dbus, guint *subscription, const char *iface,
                     const char *method, const BooPortalHandlers *handlers) {
    g_return_if_fail(dbus != NULL);
    g_return_if_fail(subscription != NULL);
    g_return_if_fail(handlers != NULL);

    if (*subscription != 0) {
        g_warning("Boo: a %s request is already in flight; skipping", iface);
        return;
    }

    g_autofree const char *token = boo_portal_new_token();

    GVariant *payload = handlers->make_payload
                            ? handlers->make_payload(handlers->user_data, token)
                            : NULL;
    if (!payload) return;

    g_autofree const char *request_path = portal_request_path(dbus, token);
    if (!request_path) {
        g_variant_unref(g_variant_ref_sink(payload)); // payload was floating
        if (handlers->on_error)
            handlers->on_error("no D-Bus unique name", FALSE, handlers->user_data);
        return;
    }

    PortalRequest *req = g_new0(PortalRequest, 1);
    req->dbus = dbus;
    req->subscription = subscription;
    req->on_response = handlers->on_response;
    req->on_error = handlers->on_error;
    req->user_data = handlers->user_data;
    // Own ref, so the object survives the client's teardown until this request's
    // own completion drops it (the client cancels then unrefs its ref at free).
    req->cancellable = handlers->cancellable ? g_object_ref(handlers->cancellable) : NULL;
    // Both completions are outstanding; whichever of on_response/on_call_done
    // runs last frees req.
    req->signal_pending = TRUE;
    req->call_pending = TRUE;

    // Subscribe BEFORE calling, see the header. Skipping this is the classic
    // portal bug: it passes against a slow portal and hangs against a fast one.
    // Filter to the portal's bus name (not any sender): the CSPRNG token in the
    // path already stops a co-resident process racing for the reply, this is
    // belt-and-suspenders so only the portal can drive on_response at all.
    *subscription = g_dbus_connection_signal_subscribe(
        dbus, PORTAL_BUS_NAME, PORTAL_IFACE_REQUEST, "Response", request_path, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, on_response, req, NULL);

    g_dbus_connection_call(dbus, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, iface, method,
                           payload, NULL, G_DBUS_CALL_FLAGS_NONE, -1, req->cancellable,
                           on_call_done, req);
}

void boo_portal_close_session(GDBusConnection *dbus, const char *session_handle) {
    if (!dbus || !session_handle) return;

    g_dbus_connection_call(dbus, PORTAL_BUS_NAME, session_handle, PORTAL_IFACE_SESSION,
                           "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL,
                           NULL);
}
