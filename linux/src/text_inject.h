#pragma once

#include <gtk/gtk.h>

// Auto-paste of the transcript into the focused window.
//
// There is no portable "type this text" API on Linux. Wayland has no XTEST, the
// virtual-keyboard protocol is missing on GNOME/Mutter, and uinput (ydotool)
// needs a privileged daemon that can't ship inside Flatpak. The one sanctioned,
// desktop-neutral path is the XDG RemoteDesktop portal
// (org.freedesktop.portal.RemoteDesktop), which lets us synthesize key events
// after a one-time user grant that persists across runs via a restore token.
//
// We deliberately do NOT type the transcript character by character: keysym
// injection depends on the active keyboard layout, so any character outside it
// (accented letters, smart quotes, em dashes) is silently dropped. Instead the
// transcript is already on the clipboard, overlay_window.c puts it there, and
// we synthesize a single Ctrl+Shift+V, the standard terminal paste chord and
// Ghostty's default binding. One universally-mappable chord, full Unicode.

typedef struct BooTextInject BooTextInject;

// Create the injector and start the portal session. On first run the desktop
// shows a one-time "allow remote input" dialog; the grant is persisted with a
// restore token, so later runs start silently. Never returns NULL, if the
// portal is missing or the user declines, the injector goes inert and
// boo_text_inject_paste() becomes a no-op.
BooTextInject *boo_text_inject_new(GtkWindow *parent_window);

// Synthesize Ctrl+Shift+V in the focused window, pasting the clipboard.
// Asynchronous and best-effort; if the session isn't ready yet the paste is
// queued and fires once it is. Caller must have set the clipboard first.
void boo_text_inject_paste(BooTextInject *ti);

void boo_text_inject_free(BooTextInject *ti);
