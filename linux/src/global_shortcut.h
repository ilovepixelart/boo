#pragma once

#include <gtk/gtk.h>

// Interface for the global hotkey (Ctrl+Shift+Space toggle).
//
// On Wayland, the only sandbox-friendly path is the XDG GlobalShortcuts portal
// (org.freedesktop.portal.GlobalShortcuts). On X11, XGrabKey works but is
// deprecated and wouldn't survive in a Flatpak sandbox. We use the portal
// uniformly for forward-compat.
//
// The requested trigger is a *preference*, not a guarantee: the portal shows a
// confirmation dialog that lets the user rebind it, and some desktops ignore the
// preference entirely. Treat the hotkey as a bonus and keep the Record button
// working as the primary control.

typedef struct BooGlobalShortcut BooGlobalShortcut;

typedef void (*BooShortcutCallback)(gpointer user_data);

// Called when the shortcut definitively cannot be registered. `reason` is a
// short, human-readable explanation fit for a toast.
//
// This is not a rare path. GNOME only gained a GlobalShortcuts backend in
// version 48 (Feb 2025), so on GNOME 46 — Ubuntu 24.04 LTS, i.e. a large slice
// of desktop Linux — the interface does not exist at all and the hotkey simply
// cannot work. Without this callback the failure is invisible: the user presses
// the hotkey and nothing happens.
typedef void (*BooShortcutUnavailableCallback)(const char *reason, gpointer user_data);

// Register the global shortcut. `parent_window` supplies the GApplication whose
// session bus connection the portal request rides on. `on_unavailable` may be
// NULL. The returned handle is owned by the caller and must be freed with
// boo_global_shortcut_free().
//
// Never returns NULL. Registration is asynchronous and may still fail (no
// session bus, no GlobalShortcuts support, user declines the binding); in that
// case the handle is inert, on_unavailable fires, and the activation callback
// never does. Callers must not treat a non-NULL return as proof the hotkey is
// live.
BooGlobalShortcut *boo_global_shortcut_new(GtkWindow *parent_window,
                                           BooShortcutCallback on_activated,
                                           BooShortcutUnavailableCallback on_unavailable,
                                           gpointer user_data);

void boo_global_shortcut_free(BooGlobalShortcut *gs);
