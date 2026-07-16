// All PipeWire/SPA API use for the audio backend lives here, behind the
// self-contained pipewire_glue.h. See the header for why the real headers
// must not reach Zig's @cImport.

#include "pipewire_glue.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>

#include <stdlib.h>

// pw_stream_add_listener (inside pw_stream_new_simple) keeps a pointer to the
// events struct, so it needs storage that outlives the stream. Bundling it
// with the stream pointer gives both one lifetime.
struct boo_pw_stream {
    struct pw_stream *stream;
    struct pw_stream_events events;
};

void boo_pw_init(void) {
    pw_init(NULL, NULL);
}

void boo_pw_deinit(void) {
    pw_deinit();
}

boo_pw_thread_loop *boo_pw_thread_loop_new(const char *name) {
    return (boo_pw_thread_loop *)pw_thread_loop_new(name, NULL);
}

void boo_pw_thread_loop_destroy(boo_pw_thread_loop *loop) {
    pw_thread_loop_destroy((struct pw_thread_loop *)loop);
}

int boo_pw_thread_loop_start(boo_pw_thread_loop *loop) {
    return pw_thread_loop_start((struct pw_thread_loop *)loop);
}

void boo_pw_thread_loop_stop(boo_pw_thread_loop *loop) {
    pw_thread_loop_stop((struct pw_thread_loop *)loop);
}

void boo_pw_thread_loop_lock(boo_pw_thread_loop *loop) {
    pw_thread_loop_lock((struct pw_thread_loop *)loop);
}

void boo_pw_thread_loop_unlock(boo_pw_thread_loop *loop) {
    pw_thread_loop_unlock((struct pw_thread_loop *)loop);
}

boo_pw_stream *boo_pw_capture_stream_new(
    boo_pw_thread_loop *loop,
    const char *name,
    uint32_t sample_rate,
    void (*process)(void *user_data),
    void *user_data
) {
    struct boo_pw_stream *self = calloc(1, sizeof(*self));
    if (self == NULL) return NULL;

    self->events.version = PW_VERSION_STREAM_EVENTS;
    self->events.process = process;

    // Stream metadata properties, tells PipeWire how to route us.
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Communication",
        PW_KEY_NODE_NAME, "Boo",
        NULL);
    if (props == NULL) {
        free(self);
        return NULL;
    }

    // pw_stream_new_simple takes ownership of `props`, so no free on failure.
    self->stream = pw_stream_new_simple(
        pw_thread_loop_get_loop((struct pw_thread_loop *)loop),
        name,
        props,
        &self->events,
        user_data);
    if (self->stream == NULL) {
        free(self);
        return NULL;
    }

    // Fixed format param: f32 mono at the requested rate.
    uint8_t buffer[1024];
    struct spa_pod_builder builder;
    spa_pod_builder_init(&builder, buffer, sizeof(buffer));

    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_F32,
        .channels = 1,
        .rate = sample_rate);
    const struct spa_pod *params[1] = {
        spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info),
    };
    if (params[0] == NULL) {
        pw_stream_destroy(self->stream);
        free(self);
        return NULL;
    }

    enum pw_stream_flags flags = PW_STREAM_FLAG_AUTOCONNECT |
        PW_STREAM_FLAG_MAP_BUFFERS |
        PW_STREAM_FLAG_RT_PROCESS |
        PW_STREAM_FLAG_INACTIVE;

    if (pw_stream_connect(self->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          flags, params, 1) < 0) {
        pw_stream_destroy(self->stream);
        free(self);
        return NULL;
    }

    return self;
}

void boo_pw_capture_stream_destroy(boo_pw_stream *stream) {
    if (stream == NULL) return;
    pw_stream_destroy(stream->stream);
    free(stream);
}

int boo_pw_stream_set_active(boo_pw_stream *stream, bool active) {
    return pw_stream_set_active(stream->stream, active);
}

boo_pw_buffer *boo_pw_stream_dequeue_buffer(
    boo_pw_stream *stream,
    const float **samples,
    size_t *n_samples
) {
    *samples = NULL;
    *n_samples = 0;

    struct pw_buffer *buf = pw_stream_dequeue_buffer(stream->stream);
    if (buf == NULL) return NULL;

    struct spa_buffer *spa_buf = buf->buffer;
    if (spa_buf != NULL && spa_buf->n_datas > 0) {
        struct spa_data *data = &spa_buf->datas[0];
        if (data->data != NULL && data->chunk != NULL) {
            *samples = (const float *)data->data;
            *n_samples = data->chunk->size / sizeof(float);
        }
    }
    return (boo_pw_buffer *)buf;
}

void boo_pw_stream_queue_buffer(boo_pw_stream *stream, boo_pw_buffer *buffer) {
    pw_stream_queue_buffer(stream->stream, (struct pw_buffer *)buffer);
}
