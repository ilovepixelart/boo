// Cairo-rendered waveform visualizer. Reads bars from boo_get_waveform() on
// every frame tick (driven by GdkFrameClock) and queues a redraw.

#include "waveform_widget.h"

#include <cairo.h>
#include <math.h>

typedef struct {
    BooContext *ctx;
} WaveformState;

static void waveform_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height,
                          gpointer user_data) {
    (void)area;
    WaveformState *st = user_data;

    int n_bars = 0;
    const float *bars = boo_get_waveform(st->ctx, &n_bars);
    if (!bars || n_bars == 0) return;

    // Background
    cairo_set_source_rgba(cr, 0.07, 0.08, 0.10, 1.0);
    cairo_paint(cr);

    // Bars: 70% width / 30% gap
    double total = (double)width / (double)n_bars;
    double bar_w = total * 0.65;
    double gap = total * 0.35;
    double base_x = gap * 0.5;

    cairo_set_source_rgba(cr, 0.42, 0.85, 0.95, 0.95);

    for (int i = 0; i < n_bars; i++) {
        double v = bars[i] * 4.0; // amplify for visibility
        if (v > 1.0) v = 1.0;
        double bar_h = v * (double)height * 0.85;
        if (bar_h < 2.0) bar_h = 2.0; // minimum visible bar
        double x = base_x + (double)i * total;
        double y = ((double)height - bar_h) * 0.5;
        cairo_rectangle(cr, x, y, bar_w, bar_h);
    }
    cairo_fill(cr);
}

static gboolean waveform_tick(GtkWidget *widget, GdkFrameClock *clock,
                              gpointer user_data) {
    (void)clock;
    WaveformState *st = user_data;
    // Only repaint while there is motion to show: during recording, and while
    // the peak is still decaying after a stop. When idle the bars are static,
    // so a full-refresh-rate redraw every frame is pure battery drain.
    if (boo_is_recording(st->ctx) || boo_get_peak_rms(st->ctx) > 0.01f) {
        gtk_widget_queue_draw(widget);
    }
    return G_SOURCE_CONTINUE;
}

GtkWidget *boo_waveform_widget_new(BooContext *ctx) {
    GtkWidget *area = gtk_drawing_area_new();

    WaveformState *st = g_new0(WaveformState, 1);
    st->ctx = ctx;
    g_object_set_data_full(G_OBJECT(area), "boo-waveform-state", st, g_free);

    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), waveform_draw, st, NULL);
    gtk_widget_add_tick_callback(area, waveform_tick, st, NULL);

    return area;
}
