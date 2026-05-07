#pragma once

#include <gtk/gtk.h>

#include "boo.h"

// Construct the main overlay window. The returned window is owned by the
// GtkApplication; the caller does not need to free it.
GtkWindow *boo_overlay_window_new(GtkApplication *app, BooContext *ctx);
