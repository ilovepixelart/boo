#pragma once

#include <gio/gio.h>

// Shared plumbing for the XDG desktop portals Boo talks to.
//
// Both portal clients — GlobalShortcuts for the hotkey, RemoteDesktop for
// auto-paste — speak the same Request/Response protocol, and they used to
// implement it separately. The copies drifted: one learned to clean up its
// dangling Response subscription and report failures to the user, the other
// silently didn't. So it lives here once.
//
// The protocol has a race that is easy to get wrong. The naive reading is:
//
//   1. Call the method; it returns the object path of a Request.
//   2. Subscribe to Response on that path.
//   3. Handle the reply.
//
// That does not work. The portal may emit Response before step 2 completes, and
// Response fires exactly once, so a lost signal stalls the exchange forever. The
// protocol therefore expects clients to *predict* the request path — a pure
// function of our D-Bus unique name and a caller-chosen handle_token — and to
// subscribe BEFORE issuing the call, which makes the method's own return value
// redundant. This is documented only in passing, under the Request interface.
//
// boo_portal_call() does all of that, so neither client has to remember it.
//
// See:
//   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html

#define PORTAL_BUS_NAME      "org.freedesktop.portal.Desktop"
#define PORTAL_OBJECT_PATH   "/org/freedesktop/portal/desktop"
#define PORTAL_IFACE_REQUEST "org.freedesktop.portal.Request"
#define PORTAL_IFACE_SESSION "org.freedesktop.portal.Session"

/// Build the method payload. `handle_token` must be embedded in the call's
/// options dict — it is what ties the reply to the path we subscribed to.
/// Return a floating GVariant, or NULL to abort the call.
typedef GVariant *(*BooPortalPayloadFn)(gpointer user_data, const char *handle_token);

/// A Response arrived. `response` is 0 on success, 1 if the user declined.
typedef void (*BooPortalResponseFn)(guint32 response, GVariant *results,
                                    gpointer user_data);

/// The call itself failed, so no Response is coming. `unsupported` means the
/// desktop does not implement this portal at all — worth saying differently,
/// since it is not something the user can fix by clicking Allow.
typedef void (*BooPortalErrorFn)(const char *reason, gboolean unsupported,
                                 gpointer user_data);

/// Issue a portal request: subscribe to Response on the predicted path, then
/// call the method.
///
/// `subscription` is where the Response subscription id is kept — the caller
/// owns it so it can be torn down on free. It must be 0 (no request in flight)
/// on entry; the callbacks run with it already cleared.
void boo_portal_call(GDBusConnection *dbus, guint *subscription, const char *iface,
                     const char *method, BooPortalPayloadFn make_payload,
                     BooPortalResponseFn on_response, BooPortalErrorFn on_error,
                     gpointer user_data);

/// Close a portal session. Safe with a NULL handle.
void boo_portal_close_session(GDBusConnection *dbus, const char *session_handle);
