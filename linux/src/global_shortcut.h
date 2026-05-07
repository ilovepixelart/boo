#pragma once

#include <gtk/gtk.h>

// Interface for the global hotkey (Ctrl+Shift+Space toggle).
//
// On Wayland, only sandbox-friendly path is the XDG GlobalShortcuts portal
// (org.freedesktop.portal.GlobalShortcuts). On X11, XGrabKey works but is
// deprecated and wouldn't survive in a Flatpak sandbox. We use the portal
// uniformly for forward-compat.
//
// IMPLEMENTATION STATUS (2026-05-06): interface only. The .c file currently
// stubs the calls — the portal D-Bus sequence (CreateSession → BindShortcuts
// → subscribe to Activated signal) is non-trivial GDBus boilerplate and
// needs to be authored against a live Linux session.

typedef struct BooGlobalShortcut BooGlobalShortcut;

typedef void (*BooShortcutCallback)(gpointer user_data);

// Register the global shortcut. `parent_window` is used as the parent for any
// portal confirmation dialog. The returned handle is owned by the caller and
// must be freed with boo_global_shortcut_free().
//
// Returns NULL if the portal is unavailable or the user denies the binding.
BooGlobalShortcut *boo_global_shortcut_new(
    GtkWindow *parent_window,
    BooShortcutCallback on_activated,
    gpointer user_data);

void boo_global_shortcut_free(BooGlobalShortcut *gs);
