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
// Whether a microphone/audio backend was acquired at init. When false, Boo
// still runs (the model is loaded, the UI shows) but recording is a no-op;
// the frontend should say "no microphone" rather than appear to record.
bool boo_has_microphone(BooContext *ctx);

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

// Themes (Ghostty format), independent of the audio context. The frontend
// enumerates its themes directory (trivial per-OS), sorts the names, and calls
// this per file to get the colors; the Ghostty-format parsing is shared here so
// it is not reimplemented three times. Colors are packed 0xRRGGBB; alpha (window
// opacity) and the current selection are the frontend's business.
typedef struct {
    uint32_t bg;
    uint32_t fg;
    uint32_t palette[16]; // 16 ANSI colors; [8]=dim, [9]=red, [11]=yellow, [14]=cyan
} BooThemeColors;

// Parse one Ghostty theme file at `path` into `*out`. Returns false when the
// file cannot be read or is not a complete theme (missing bg/fg or fewer than
// 16 palette entries), so the caller can skip it.
bool boo_theme_parse_file(const char *path, BooThemeColors *out);

// Rank of a model filename in the shared recommended order (best == 0); a value
// equal to the recommended-list length for anything unrecognized. The three
// frontends call this to pick the most capable installed model, so the
// preference order lives in one place. Directory listing stays per-OS.
uint32_t boo_model_rank(const char *name);

// Diagnostic logging (see docs/logging-and-crash-reporting.md). boo_log_init
// sets the file sink (per-OS path from the frontend; NULL == stderr only) and
// the minimum level; boo_log writes one line. Levels below.
// PRIVACY: never pass recognized/transcript text, log metadata only.
enum {
    BOO_LOG_ERROR = 0,
    BOO_LOG_WARN = 1,
    BOO_LOG_INFO = 2,
    BOO_LOG_DEBUG = 3,
};
void boo_log_init(const char *path, int min_level);
void boo_log(int level, const char *msg);

#ifdef __cplusplus
}
#endif

#endif // BOO_H
