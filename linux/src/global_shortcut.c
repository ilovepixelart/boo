// XDG GlobalShortcuts portal client — STUB.
//
// The full implementation needs to:
//   1. Connect to org.freedesktop.portal.Desktop on the session bus.
//   2. Call GlobalShortcuts.CreateSession with a handle_token; the response
//      arrives asynchronously on org.freedesktop.portal.Request.Response.
//   3. From the Response payload, extract the session handle (object path).
//   4. Subscribe to Activated and Deactivated signals on the session.
//   5. Call BindShortcuts with [{"toggle-record", {description: "Boo
//      record toggle", preferred_trigger: "CTRL+SHIFT+space"}}]; portal opens
//      a user-confirmation dialog. Wait for Response again.
//   6. On Activated signal whose shortcut_id == "toggle-record", invoke the
//      callback on the GTK main loop.
//
// References:
//   - https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
//   - https://docs.gtk.org/gio/class.DBusConnection.html
//
// Until this is implemented, the app falls back to the on-screen Record
// button only — no global hotkey. The clipboard auto-copy in
// overlay_window.c keeps it usable without a hotkey.

#include "global_shortcut.h"

struct BooGlobalShortcut {
    BooShortcutCallback on_activated;
    gpointer user_data;
};

BooGlobalShortcut *boo_global_shortcut_new(
    GtkWindow *parent_window,
    BooShortcutCallback on_activated,
    gpointer user_data) {
    (void)parent_window;
    g_message("Boo: global shortcut registration not yet implemented "
              "(see linux/src/global_shortcut.c). Use the on-screen Record "
              "button.");

    BooGlobalShortcut *gs = g_new0(BooGlobalShortcut, 1);
    gs->on_activated = on_activated;
    gs->user_data = user_data;
    return gs;
}

void boo_global_shortcut_free(BooGlobalShortcut *gs) {
    if (!gs) return;
    g_free(gs);
}
