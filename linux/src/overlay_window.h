#pragma once

#include <gtk/gtk.h>

#include "boo.h"

// Construct the main overlay window. `model_path` is the speech model the app
// booted with (the settings model switcher shows and changes it). The returned
// window is owned by the GtkApplication; the caller does not need to free it.
GtkWindow *boo_overlay_window_new(GtkApplication *app, BooContext *ctx,
                                  const char *model_path);

// The model the user explicitly picked in Settings ("model" in settings.ini),
// or NULL. Readable before the window exists, for launch-time discovery.
// Caller frees.
char *boo_saved_model_read(void);
