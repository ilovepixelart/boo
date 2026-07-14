#ifndef BOO_PIPEWIRE_GLUE_H
#define BOO_PIPEWIRE_GLUE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct spa_pod;
struct spa_pod_builder;

// Build a fixed audio format param: f32 mono at the given sample rate.
// `builder` must be initialized via spa_pod_builder_init() first.
// Returns a pointer into the builder's buffer, valid until the builder is reset.
const struct spa_pod *boo_pw_build_f32_mono_format(
    struct spa_pod_builder *builder,
    uint32_t sample_rate
);

#ifdef __cplusplus
}
#endif

#endif // BOO_PIPEWIRE_GLUE_H
