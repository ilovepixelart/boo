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
// Ignored while a transcription or an utterance inference is in flight: one
// take at a time, and rejecting beats blocking a UI thread on a decode.
void boo_start_recording(BooContext *ctx);
void boo_stop_recording(BooContext *ctx);
bool boo_is_recording(BooContext *ctx);
bool boo_is_transcribing(BooContext *ctx);

// Audio data
const float *boo_get_waveform(BooContext *ctx, int *out_bars);
float boo_get_peak_rms(BooContext *ctx);
int boo_get_audio_samples(BooContext *ctx);

// Transcription, returns null-terminated string owned by context.
// Valid until the next boo_transcribe() or boo_deinit(); starting a new
// recording does NOT free it, so a worker still copying the result can never
// race a fresh take.
const char *boo_transcribe(BooContext *ctx);

// Streaming transcription (optional). Load a Silero VAD model
// (ggml-silero-*.bin) to enable transcribing utterances at natural pauses
// while still recording; boo_transcribe then only pays for the final
// utterance. Without it Boo keeps the plain batch behavior.
// Idempotent; returns false if the model cannot be loaded.
bool boo_load_vad(BooContext *ctx, const char *vad_model_path);

// Call every 200-500ms from ONE background thread while recording. Cheap
// when nothing ended; blocks for one utterance's inference when it did.
// Returns true when new committed text is available.
bool boo_stream_tick(BooContext *ctx);

// Text committed so far in the current take, or NULL. Owned by Boo; the
// pointer stays valid until boo_deinit() (superseded buffers are retired,
// not freed). Callable from any thread.
const char *boo_get_live_transcript(BooContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // BOO_H
