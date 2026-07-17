#pragma once

#include <gtk/gtk.h>

#include "boo.h"

// Returns a GtkDrawingArea that polls boo_get_waveform() every frame and
// renders the bars via Cairo. Owned by the parent container.
GtkWidget *boo_waveform_widget_new(BooContext *ctx);

// Set the three state colors (0xRRGGBB) from the active theme: idle
// (palette[14]), recording (palette[9]), transcribing (palette[11]).
void boo_waveform_widget_set_colors(GtkWidget *widget, uint32_t idle, uint32_t recording,
                                    uint32_t thinking);
