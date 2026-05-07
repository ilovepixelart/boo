#pragma once

#include <gtk/gtk.h>

#include "boo.h"

// Returns a GtkDrawingArea that polls boo_get_waveform() every frame and
// renders the bars via Cairo. Owned by the parent container.
GtkWidget *boo_waveform_widget_new(BooContext *ctx);
