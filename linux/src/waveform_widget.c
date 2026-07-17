// Cairo-rendered waveform, mirroring macos/Sources/WaveformView.swift: 40
// center-symmetric capsule bars, lerp-smoothed, three states (idle dim cyan /
// recording red / transcribing yellow sine-breathing). Colors are the
// reference default theme's tokens (docs/ui-spec.md); Cairo has real alpha,
// so the per-bar alpha matches the reference exactly.

#include "waveform_widget.h"

#include <cairo.h>
#include <math.h>

typedef struct {
    BooContext *ctx;
    float smoothed[64];
    gboolean was_active;
    // State colors (0xRRGGBB) from the active theme; default-theme tokens until
    // a theme is applied: idle #70C0B1, recording #D54E53, thinking #E7C547.
    guint32 idle;
    guint32 rec;
    guint32 think;
} WaveformState;

static void rounded_bar(cairo_t *cr, double x, double cy, double w, double h) {
    if (h < 2.0) h = 2.0;
    const double r = MIN(w / 2.0, h / 2.0);
    const double top = cy - h / 2.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + r, top + r, r, G_PI, 3 * G_PI / 2);
    cairo_arc(cr, x + w - r, top + r, r, 3 * G_PI / 2, 2 * G_PI);
    cairo_arc(cr, x + w - r, top + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, top + h - r, r, G_PI / 2, G_PI);
    cairo_close_path(cr);
    cairo_fill(cr);
}

static void waveform_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height,
                          gpointer user_data) {
    WaveformState *st = user_data;

    int n_bars = 0;
    const float *bars = boo_get_waveform(st->ctx, &n_bars);
    if (!bars || n_bars <= 0) return;
    if (n_bars > (int)G_N_ELEMENTS(st->smoothed)) n_bars = G_N_ELEMENTS(st->smoothed);

    const gboolean recording = boo_is_recording(st->ctx);
    const gboolean transcribing = boo_is_transcribing(st->ctx);

    // Reference smoothing: fast attack while recording, slow settle otherwise.
    const float lerp = recording ? 0.25f : 0.1f;
    for (int i = 0; i < n_bars; i++)
        st->smoothed[i] += (bars[i] - st->smoothed[i]) * lerp;

    // Colors come from the active theme (set via boo_waveform_widget_set_colors).
    guint32 rgb = st->idle;
    if (recording) {
        rgb = st->rec;
    } else if (transcribing) {
        rgb = st->think;
    }
    const double r = ((rgb >> 16) & 0xFF) / 255.0;
    const double g = ((rgb >> 8) & 0xFF) / 255.0;
    const double b = (rgb & 0xFF) / 255.0;

    const double gap = 3.0;
    const double bar_w = MAX((width - gap * (n_bars - 1)) / n_bars, 2.0);
    const double cy = height / 2.0;
    const double max_h = height * 0.75;
    const float peak = boo_get_peak_rms(st->ctx);
    // Microsecond frame time drives the transcribing sine.
    GdkFrameClock *clock = gtk_widget_get_frame_clock(GTK_WIDGET(area));
    const double phase =
        clock ? (double)gdk_frame_clock_get_frame_time(clock) / 1e6 : 0.0;

    for (int i = 0; i < n_bars; i++) {
        const double x = i * (bar_w + gap);
        const double center =
            1.0 - fabs((double)i / n_bars - 0.5) * (transcribing ? 0.6 : 0.4);
        double h;
        double alpha;
        if (recording) {
            const double norm = peak > 0.001f ? MIN(st->smoothed[i] / peak, 1.0) : 0.0;
            h = norm * max_h;
            alpha = (0.3 + norm * 0.7) * center;
        } else if (transcribing) {
            const double wave = (sin(phase * 2.0 + i * 0.12) + 1.0) / 2.0;
            h = wave * max_h * 0.25 + 3.0;
            alpha = (0.2 + wave * 0.4) * center;
        } else {
            h = 3.0;
            alpha = 0.2;
        }
        cairo_set_source_rgba(cr, r, g, b, alpha);
        rounded_bar(cr, x, cy, bar_w, h);
    }
}

static gboolean waveform_tick(GtkWidget *widget, GdkFrameClock *clock,
                              gpointer user_data) {
    (void)clock;
    WaveformState *st = user_data;
    // Repaint while there is motion to show: recording, the transcribing
    // animation, and the peak decay after a stop. Idle bars are static, so a
    // full-refresh-rate redraw would be pure battery drain. One extra frame
    // after going inactive repaints the bars in their idle color; without it
    // a stop that captured no audio freezes on the last recording-red frame.
    const gboolean active = boo_is_recording(st->ctx) || boo_is_transcribing(st->ctx) ||
                            boo_get_peak_rms(st->ctx) > 0.01f;
    if (active || st->was_active) gtk_widget_queue_draw(widget);
    st->was_active = active;
    return G_SOURCE_CONTINUE;
}

GtkWidget *boo_waveform_widget_new(BooContext *ctx) {
    GtkWidget *area = gtk_drawing_area_new();

    WaveformState *st = g_new0(WaveformState, 1);
    st->ctx = ctx;
    st->idle = 0x70C0B1;  // palette[14]
    st->rec = 0xD54E53;   // palette[9]
    st->think = 0xE7C547; // palette[11]
    g_object_set_data_full(G_OBJECT(area), "boo-waveform-state", st, g_free);

    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), waveform_draw, st, NULL);
    gtk_widget_add_tick_callback(area, waveform_tick, st, NULL);

    return area;
}

void boo_waveform_widget_set_colors(GtkWidget *widget, uint32_t idle, uint32_t recording,
                                    uint32_t thinking) {
    WaveformState *st = g_object_get_data(G_OBJECT(widget), "boo-waveform-state");
    if (!st) return;
    st->idle = idle;
    st->rec = recording;
    st->think = thinking;
    gtk_widget_queue_draw(widget);
}
