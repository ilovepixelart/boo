#ifndef BOO_H
#define BOO_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context
typedef struct BooContext BooContext;

// Lifecycle
BooContext *boo_init(const char *model_path);
void boo_deinit(BooContext *ctx);

// Recording control
void boo_warm_up(BooContext *ctx); // Start mic early to avoid cold-start word loss
void boo_start_recording(BooContext *ctx);
void boo_stop_recording(BooContext *ctx);
bool boo_is_recording(BooContext *ctx);
bool boo_is_transcribing(BooContext *ctx);

// Audio data
const float *boo_get_waveform(BooContext *ctx, int *out_bars);
float boo_get_peak_rms(BooContext *ctx);
int boo_get_audio_samples(BooContext *ctx);

// Transcription, returns null-terminated string owned by context.
// Valid until the next boo_start_recording(), boo_transcribe(), or
// boo_deinit(), each of these frees the previous transcript.
const char *boo_transcribe(BooContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // BOO_H
