// Tiny C helper for the PipeWire backend.
// `spa_format_audio_raw_build` is `static inline`, so it can't be linked from Zig.
// We expose a regular extern function that wraps it.

#include "pipewire_glue.h"

#include <spa/param/audio/format-utils.h>
#include <spa/param/param.h>

const struct spa_pod *boo_pw_build_f32_mono_format(
    struct spa_pod_builder *builder,
    uint32_t sample_rate
) {
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_F32,
        .channels = 1,
        .rate = sample_rate
    );
    return spa_format_audio_raw_build(builder, SPA_PARAM_EnumFormat, &info);
}
