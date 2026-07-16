// C glue for the PipeWire backend.
//
// This header is the only thing pipewire.zig @cImports, and it is deliberately
// self-contained: no PipeWire or SPA includes. Newer SPA headers (PipeWire
// 1.4+, as shipped by the GNOME 50 runtime) contain static_asserts that Zig's
// translate-c cannot evaluate, so the real headers must never reach @cImport.
// All PipeWire/SPA API use lives in pipewire_glue.c, which a real C compiler
// handles fine. Same idea as the hand-declared AudioQueue surface in
// coreaudio.zig.

#ifndef BOO_PIPEWIRE_GLUE_H
#define BOO_PIPEWIRE_GLUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque to Zig; pipewire_glue.c owns the real types.
typedef struct boo_pw_thread_loop boo_pw_thread_loop;
typedef struct boo_pw_stream boo_pw_stream;
typedef struct boo_pw_buffer boo_pw_buffer;

// pw_init/pw_deinit are refcounted internally, safe to call repeatedly.
void boo_pw_init(void);
void boo_pw_deinit(void);

boo_pw_thread_loop *boo_pw_thread_loop_new(const char *name);
void boo_pw_thread_loop_destroy(boo_pw_thread_loop *loop);
int boo_pw_thread_loop_start(boo_pw_thread_loop *loop);
void boo_pw_thread_loop_stop(boo_pw_thread_loop *loop);
void boo_pw_thread_loop_lock(boo_pw_thread_loop *loop);
void boo_pw_thread_loop_unlock(boo_pw_thread_loop *loop);

// Create a capture stream on `loop` with Boo's standard routing properties,
// register `process` (invoked on PipeWire's realtime thread with `user_data`),
// build the f32/mono format param at `sample_rate` and connect autoconnected,
// buffer-mapped, realtime, and inactive (the mic stays off until
// boo_pw_stream_set_active). Caller must hold the loop lock.
boo_pw_stream *boo_pw_capture_stream_new(
    boo_pw_thread_loop *loop,
    const char *name,
    uint32_t sample_rate,
    void (*process)(void *user_data),
    void *user_data);

// Caller must hold the loop lock, same rule as pw_stream_destroy.
void boo_pw_capture_stream_destroy(boo_pw_stream *stream);

int boo_pw_stream_set_active(boo_pw_stream *stream, bool active);

// For the process callback: dequeue the next buffer. On success *samples and
// *n_samples describe the f32 payload (n_samples may be 0 when the buffer
// carries no usable data). Returns null when no buffer is available. Every
// dequeued buffer must be returned via boo_pw_stream_queue_buffer.
boo_pw_buffer *boo_pw_stream_dequeue_buffer(
    boo_pw_stream *stream,
    const float **samples,
    size_t *n_samples);
void boo_pw_stream_queue_buffer(boo_pw_stream *stream, boo_pw_buffer *buffer);

#ifdef __cplusplus
}
#endif

#endif // BOO_PIPEWIRE_GLUE_H
