const std = @import("std");
const log = @import("log.zig");
const engine_mod = @import("engine.zig");
const whisper_mod = engine_mod.whisper;
const Engine = engine_mod.Engine;
const AudioCapture = @import("audio.zig").AudioCapture;
const stream = @import("stream.zig");
const postprocess = @import("postprocess.zig");
const crash = @import("crash.zig");
const common = @import("audio/common.zig");

const WAVEFORM_BARS = @import("audio.zig").WAVEFORM_BARS;
const MIN_AUDIO_SAMPLES = common.MIN_AUDIO_SAMPLES;

const BooContext = struct {
    engine: Engine,
    // null when no microphone/audio backend could be acquired: Boo still runs
    // (the model is loaded, the UI shows), recording is just a no-op. See
    // boo_has_microphone.
    audio: ?*AudioCapture,
    allocator: std.mem.Allocator,
    /// Atomic: boo_transcribe runs on a worker thread (it blocks for seconds),
    /// while the UI polls boo_is_transcribing from the main thread. A plain bool
    /// would be a data race.
    transcribing: std.atomic.Value(bool) = .init(false),
    /// Owned null-terminated transcript string, or null if none.
    last_transcript: ?[:0]u8 = null,
    waveform_buf: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS,

    // Streaming (VAD-chunked) state; stays absent unless boo_load_vad succeeds,
    // in which case boo_stream_tick transcribes utterances during recording and
    // boo_transcribe only pays for the final one.
    vad: ?whisper_mod.Vad = null,
    chunker: ?stream.Chunker = null,
    /// Serializes whisper inference between boo_stream_tick (a background
    /// thread, while recording) and boo_transcribe (a worker thread, after).
    whisper_mutex: common.Mutex = .{},
    /// Committed-so-far text handed out via boo_get_live_transcript. Replaced
    /// or superseded buffers are retired, never freed before deinit: a
    /// frontend thread may still be copying a pointer it fetched a moment
    /// ago, after the lock that published it was released. Retention is one
    /// small string per committed utterance, reclaimed at boo_deinit.
    live_transcript: ?[:0]u8 = null,
    retired_transcripts: std.ArrayList([:0]u8) = .empty,
    /// The pointer boo_get_live_transcript hands out, published atomically so
    /// the getter is safe from any thread without taking (and potentially
    /// blocking seconds on) whisper_mutex.
    live_ptr: std.atomic.Value(?[*:0]const u8) = .init(null),

    fn freeTranscript(self: *BooContext) void {
        if (self.last_transcript) |t| {
            self.allocator.free(t);
            self.last_transcript = null;
        }
    }

    /// Take the current live buffer out of service without freeing it; a
    /// reader that fetched the pointer moments ago keeps a valid target. On
    /// the (OOM) failure to record it for later freeing, leak it: a leaked
    /// string beats freeing under a live reader.
    fn retireLiveTranscript(self: *BooContext) void {
        self.live_ptr.store(null, .release);
        if (self.live_transcript) |t| {
            self.retired_transcripts.append(self.allocator, t) catch {};
            self.live_transcript = null;
        }
    }

    fn freeLiveTranscripts(self: *BooContext) void {
        self.live_ptr.store(null, .release);
        if (self.live_transcript) |t| {
            self.allocator.free(t);
            self.live_transcript = null;
        }
        for (self.retired_transcripts.items) |t| self.allocator.free(t);
        self.retired_transcripts.clearRetainingCapacity();
    }

    /// Snapshot the chunker's committed text into a fresh nul-terminated
    /// buffer for the UI. Allocation failure just skips the update; the UI
    /// keeps showing the previous state.
    fn publishLiveTranscript(self: *BooContext) void {
        const ch = if (self.chunker) |*it| it else return;
        const buf = self.allocator.dupeZ(u8, ch.committed.items) catch return;
        if (self.live_transcript) |old| {
            // On OOM, leak `old` rather than free it: a frontend thread may
            // still be copying the pointer it fetched from live_ptr.
            self.retired_transcripts.append(self.allocator, old) catch {};
        }
        self.live_transcript = buf;
        self.live_ptr.store(buf.ptr, .release);
    }
};

const c_allocator = std.heap.c_allocator;

/// The real body of boo_init. Returns an error union rather than an optional so
/// that `errdefer` actually works: errdefer fires on an *error* return, not on a
/// `return null`, so an optional-returning init silently skips its own cleanup.
/// Taking the allocator as a parameter also lets the failure paths be tested
/// with a leak-checking allocator.
fn initContext(allocator: std.mem.Allocator, model_path: [:0]const u8) !*BooContext {
    const ctx = try allocator.create(BooContext);
    errdefer allocator.destroy(ctx);

    var engine = try Engine.init(model_path, .{});
    errdefer engine.deinit();

    // Best-effort: an unavailable microphone/audio backend must not strand the
    // model. Run without capture (audio = null) if it fails; the frontend checks
    // boo_has_microphone and says so rather than refusing to start.
    const audio = AudioCapture.init(allocator) catch null;

    ctx.* = .{
        .engine = engine,
        .audio = audio,
        .allocator = allocator,
    };
    return ctx;
}

export fn boo_init(model_path: [*:0]const u8) ?*BooContext {
    return initContext(c_allocator, std.mem.span(model_path)) catch null;
}

export fn boo_deinit(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    // Flush any in-flight inference: a straggling boo_stream_tick or a
    // boo_transcribe the frontend failed to join still holds the mutex and is
    // reading the state torn down below. Held only across the frees; calls
    // arriving after deinit returns are use-after-free by contract.
    c.whisper_mutex.lock();
    c.freeTranscript();
    c.freeLiveTranscripts();
    c.retired_transcripts.deinit(c.allocator);
    if (c.chunker) |*ch| ch.deinit();
    if (c.vad) |*v| v.deinit();
    c.whisper_mutex.unlock();
    if (c.audio) |a| a.deinit();
    c.engine.deinit();
    c.allocator.destroy(c);
}

/// Load a Silero VAD model, enabling incremental transcription during
/// recording (boo_stream_tick / boo_get_live_transcript). Without it, Boo
/// behaves exactly as before: one batch transcription on stop. Idempotent.
///
/// Safe to call at any time, including mid-recording (the macOS frontend
/// downloads the model in the background on first run): the mutex orders the
/// chunker's appearance against ticks and transcriptions, and a chunker born
/// mid-take simply starts consuming from the take's beginning.
export fn boo_load_vad(ctx: ?*BooContext, vad_model_path: [*:0]const u8) bool {
    const c = ctx orelse return false;
    if (c.vad != null) return true;
    var vad = whisper_mod.Vad.init(std.mem.span(vad_model_path)) catch return false;

    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();
    if (c.vad != null) {
        // Lost a load race; keep the winner.
        vad.deinit();
        return true;
    }
    c.vad = vad;
    // Pointing into the optional's payload is safe: BooContext lives on the
    // heap and vad is never reassigned after this.
    c.chunker = stream.Chunker.init(c.allocator, &c.engine, &c.vad.?);
    return true;
}

/// Swap the speech model in place; the context pointer stays valid, so
/// frontends switch models without rebuilding anything. The new engine loads
/// before the old one is touched: on failure the context is untouched and
/// keeps serving with the old model. VAD and chunker survive the swap, the
/// chunker aims at the engine slot, not the engine value. Safe against
/// concurrent ticks/transcriptions (mutex), though frontends should refuse
/// mid-recording swaps for UX reasons.
export fn boo_reload_model(ctx: ?*BooContext, model_path: [*:0]const u8) bool {
    const c = ctx orelse return false;
    const new_engine = Engine.init(std.mem.span(model_path), .{}) catch return false;
    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();
    c.engine.deinit();
    c.engine = new_engine;
    log.logf(.info, "model reloaded", .{});
    return true;
}

export fn boo_start_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    // One take at a time. Starting while the previous take is still being
    // transcribed (a multi-second window the frontends' hotkeys can hit) or
    // while a stream tick is mid-inference would mutate the chunker and the
    // transcript buffers under a running inference. Reject rather than block:
    // this runs on UI threads, and waiting here would freeze the app for the
    // duration of a whisper decode.
    if (c.transcribing.load(.acquire)) return;
    if (!c.whisper_mutex.tryLock()) return;
    defer c.whisper_mutex.unlock();

    // last_transcript is deliberately NOT freed here: the pointer returned by
    // boo_transcribe stays valid until the next boo_transcribe/boo_deinit, so
    // a frontend worker still copying it cannot race a fresh recording.
    c.retireLiveTranscript();
    if (c.chunker) |*ch| ch.reset();
    if (c.audio) |a| a.startRecording();
}

export fn boo_warm_up(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    if (c.audio) |a| a.warmUp();
}

export fn boo_stop_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    if (c.audio) |a| a.stopRecording();
}

export fn boo_is_recording(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return if (c.audio) |a| a.isRecording() else false;
}

/// Whether a working microphone/audio backend was acquired at init. When false,
/// recording is a no-op; the frontend should say "no microphone" rather than
/// pretend to record.
export fn boo_has_microphone(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.audio != null;
}

export fn boo_is_transcribing(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.transcribing.load(.acquire);
}

export fn boo_get_waveform(ctx: ?*BooContext, out_bars: ?*c_int) ?[*]const f32 {
    const c = ctx orelse return null;
    c.waveform_buf = if (c.audio) |a| a.getWaveform() else .{0.0} ** WAVEFORM_BARS;
    if (out_bars) |p| p.* = WAVEFORM_BARS;
    return &c.waveform_buf;
}

export fn boo_get_peak_rms(ctx: ?*BooContext) f32 {
    const c = ctx orelse return 0;
    return if (c.audio) |a| a.getPeakRms() else 0;
}

export fn boo_get_audio_samples(ctx: ?*BooContext) c_int {
    const c = ctx orelse return 0;
    return if (c.audio) |a| @intCast(a.sampleCount()) else 0;
}

/// Detect and transcribe finished utterances while recording. Call every
/// 200-500ms from one background thread; each call either commits nothing
/// (cheap VAD scan) or blocks for one utterance's inference. Returns true
/// when new text was committed (see boo_get_live_transcript).
export fn boo_stream_tick(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    const a = c.audio orelse return false;
    if (!a.isRecording()) return false;
    if (c.transcribing.load(.acquire)) return false;

    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();

    // Checked under the lock: boo_load_vad may install the chunker at any
    // moment (the frontend downloads the VAD model in the background).
    const ch = if (c.chunker) |*it| it else return false;

    const pending = a.copyAudioFrom(c.allocator, ch.consumed) catch return false;
    defer c.allocator.free(pending);

    const committed = ch.tick(pending) catch |err| {
        log.logf(.warn, "stream tick failed: {s}", .{@errorName(err)});
        return false;
    };
    if (committed) c.publishLiveTranscript();
    return committed;
}

/// Text committed so far in the current take, or null. Owned by Boo; the
/// pointer stays valid until boo_deinit (superseded buffers are retired, not
/// freed). Reads an atomically published pointer, so it is callable from any
/// thread without contending on the inference mutex.
export fn boo_get_live_transcript(ctx: ?*BooContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    return c.live_ptr.load(.acquire);
}

export fn boo_transcribe(ctx: ?*BooContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const a = c.audio orelse return null; // no mic: nothing was captured
    c.transcribing.store(true, .release);
    defer c.transcribing.store(false, .release);

    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();

    const raw: []const u8 = blk: {
        // Streaming path: everything but the tail is already transcribed.
        if (c.chunker) |*ch| {
            const tail = a.copyAudioFrom(c.allocator, ch.consumed) catch return null;
            defer c.allocator.free(tail);
            break :blk ch.finalize(tail, MIN_AUDIO_SAMPLES) catch |err| {
                log.logf(.warn, "finalize failed: {s}", .{@errorName(err)});
                return null;
            };
        }

        // Batch path: no VAD model loaded, transcribe the whole take.
        const samples = a.getAudioData(c.allocator) catch return null;
        defer c.allocator.free(samples);
        if (samples.len < MIN_AUDIO_SAMPLES) return null;
        // Decoding a silent take hallucinates filler, see SILENCE_RMS_FLOOR.
        if (common.maxWindowRms(samples, common.RMS_WINDOW_SAMPLES) <
            common.SILENCE_RMS_FLOOR) return null;
        break :blk c.engine.transcribe(c.allocator, samples, true) catch |err| {
            // Without this a persistently failing engine is indistinguishable
            // from a quiet microphone in the log. Metadata only, never text.
            log.logf(.warn, "transcription failed: {s}", .{@errorName(err)});
            return null;
        };
    };

    // Collapse residual whisper repetition loops and normalize whitespace
    // before the transcript reaches any frontend (see src/postprocess.zig).
    const text = postprocess.clean(c.allocator, raw) catch {
        c.allocator.free(raw);
        return null;
    };
    c.allocator.free(raw);

    if (text.len == 0) {
        c.allocator.free(text);
        return null;
    }

    const buf = c.allocator.dupeZ(u8, text) catch {
        c.allocator.free(text);
        return null;
    };
    c.allocator.free(text);

    // Replace previous transcript
    c.freeTranscript();
    c.last_transcript = buf;

    // Metadata only, never the text (see src/log.zig privacy note).
    log.logf(.info, "transcribed {d} chars", .{buf.len});
    return buf.ptr;
}

// ── themes ─────────────────────────────────────────────────────────────────
// Independent of the audio context: the frontend enumerates its themes
// directory and calls boo_theme_parse_file per file (Ghostty-format parsing is
// shared; directory listing is trivial per-OS). See src/theme.zig.

const theme = @import("theme.zig");

export fn boo_theme_parse_file(path: [*:0]const u8, out: ?*theme.Colors) bool {
    const o = out orelse return false;
    if (theme.parseFile(c_allocator, path)) |colors| {
        o.* = colors;
        return true;
    }
    return false;
}

// ── recommended speech models ─────────────────────────────────────────────────
// The single source of truth for the model preference order all three frontends
// use to pick the most capable installed model. Directory listing stays per-OS
// (each frontend uses its native API); only this policy is shared. Most capable
// first; keep in step with docs/models.md.
const recommended_models = [_][]const u8{
    "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
    "ggml-parakeet-tdt-0.6b-v3-f16.bin",
    "ggml-large-v3-turbo-q5_0.bin",
    "ggml-large-v3-turbo.bin",
    "ggml-small.en.bin",
    "ggml-base.en.bin",
    "ggml-base.en-q5_1.bin",
    "ggml-tiny.en-q5_1.bin",
};

// The basename after either separator: std.fs.path.basename only splits the
// target's own, but a frontend may hand us a foreign-looking path (same reason
// boo_model_classify does this).
fn modelBasename(name: [*:0]const u8) []const u8 {
    const full = std.mem.span(name);
    if (std.mem.lastIndexOfAny(u8, full, "/\\")) |i| return full[i + 1 ..];
    return full;
}

// Rank of a model filename in the recommended order (best == 0); the list length
// for anything unrecognized, so a caller can take "lowest rank wins, alphabetical
// breaks ties among the rest" and always prefer a recognized model.
fn rankSlice(n: []const u8) u32 {
    for (recommended_models, 0..) |m, i| {
        if (std.mem.eql(u8, n, m)) return @intCast(i);
    }
    return recommended_models.len;
}

export fn boo_model_rank(name: [*:0]const u8) u32 {
    return rankSlice(std.mem.span(name));
}

// The most capable usable speech model among `paths`: keeps the speech models
// (boo_model_classify) that are not truncated (boo_model_verify), then takes the
// lowest boo_model_rank, breaking ties by basename so the pick is deterministic.
// Returns the index into `paths`, or -1 when none qualifies. The per-OS directory
// walk stays in each frontend; this is the shared selection policy the three used
// to each reimplement.
export fn boo_best_model(paths: [*]const [*:0]const u8, count: c_int) c_int {
    var best: c_int = -1;
    var best_rank: u32 = 0;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const path = paths[@intCast(i)];
        if (boo_model_classify(path) != BOO_MODEL_SPEECH) continue;
        if (boo_model_verify(path) == BOO_MODEL_FILE_TRUNCATED) continue;
        const r = rankSlice(modelBasename(path));
        if (best < 0 or r < best_rank or
            (r == best_rank and std.mem.order(u8, modelBasename(path), modelBasename(paths[@intCast(best)])) == .lt))
        {
            best = i;
            best_rank = r;
        }
    }
    return best;
}

// What kind of model a filename names, so the "ggml-*.bin is a speech model,
// ggml-silero* is the VAD, everything else is neither" policy lives here once
// instead of drifting across three frontends. Judged on the basename, so a
// full path works too; case-sensitive, matching the pinned manifest names.
pub const BOO_MODEL_OTHER: c_int = 0;
pub const BOO_MODEL_SPEECH: c_int = 1;
pub const BOO_MODEL_VAD: c_int = 2;

export fn boo_model_classify(name: [*:0]const u8) c_int {
    const full = std.mem.span(name);
    // Basename after either separator: std.fs.path.basename only splits on the
    // target's own, but a frontend may hand us a foreign-looking path.
    var base = full;
    if (std.mem.lastIndexOfAny(u8, full, "/\\")) |i| base = full[i + 1 ..];
    if (!std.mem.startsWith(u8, base, "ggml-")) return BOO_MODEL_OTHER;
    if (!std.mem.endsWith(u8, base, ".bin")) return BOO_MODEL_OTHER;
    if (std.mem.startsWith(u8, base, "ggml-silero")) return BOO_MODEL_VAD;
    return BOO_MODEL_SPEECH;
}

// The curated download manifest: what the model-onboarding dialog offers, one
// source for every frontend. This is display order (best pick first), not rank
// order; the capability ranking is boo_model_rank's job. SHA-256s are pinned
// (the HF LFS oids); a download must verify against them. Keep in step with
// docs/models.md, and every speech entry must be rankable (asserted below).
const BooModelInfo = extern struct {
    filename: [*:0]const u8,
    url: [*:0]const u8,
    sha256: [*:0]const u8,
    label: [*:0]const u8,
    note: [*:0]const u8,
    size: u64,
};

const hf = "https://huggingface.co/";
const models_list = [_]BooModelInfo{
    .{
        .filename = "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        .url = hf ++ "ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        .sha256 = "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e",
        .label = "Parakeet TDT",
        .note = "669 MB, best accuracy, 25 languages",
        .size = 668757119,
    },
    .{
        .filename = "ggml-base.en.bin",
        .url = hf ++ "ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
        .sha256 = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        .label = "base.en",
        .note = "148 MB, fast, English only",
        .size = 147964211,
    },
    .{
        .filename = "ggml-base.en-q5_1.bin",
        .url = hf ++ "ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin",
        .sha256 = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
        .label = "base.en (quantized)",
        .note = "60 MB, English, nearly as accurate",
        .size = 59721011,
    },
    .{
        .filename = "ggml-tiny.en-q5_1.bin",
        .url = hf ++ "ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin",
        .sha256 = "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
        .label = "tiny.en",
        .note = "32 MB, fastest, for weak hardware",
        .size = 32166155,
    },
    .{
        .filename = "ggml-small.en.bin",
        .url = hf ++ "ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
        .sha256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        .label = "small.en",
        .note = "488 MB, English, clearly better than base",
        .size = 487614201,
    },
    .{
        .filename = "ggml-large-v3-turbo-q5_0.bin",
        .url = hf ++ "ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        .sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        .label = "large-v3-turbo",
        .note = "574 MB, best whisper accuracy, multilingual",
        .size = 574041195,
    },
};

export fn boo_models(out_count: ?*usize) [*]const BooModelInfo {
    if (out_count) |cnt| cnt.* = models_list.len;
    return &models_list;
}

// The Silero VAD model: deliberately not in boo_models (it is not a speech
// model the pickers should offer), but every frontend auto-fetches it with
// the same download machinery, so the pinned entry lives here once instead
// of three constant triplets drifting apart.
const vad_model = BooModelInfo{
    .filename = "ggml-silero-v6.2.0.bin",
    .url = hf ++ "ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
    .sha256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
    .label = "Silero VAD",
    .note = "under 1 MB, enables streaming transcription",
    .size = 885098,
};

export fn boo_vad_model() *const BooModelInfo {
    return &vad_model;
}

// Completeness check for a model file already on disk. Our own downloads
// verify SHA-256 and move into place atomically, but a hand-run curl can be
// interrupted and leave a truncated file that lists as usable and only fails
// (slowly, with a generic message) at load time. For files named like a
// manifest entry, comparing the on-disk size against the pinned size catches
// truncation with one stat-priced call; a full hash here would cost seconds
// per file on every enumeration. Files not in the manifest cannot be judged.
pub const BOO_MODEL_FILE_OK: c_int = 0;
pub const BOO_MODEL_FILE_TRUNCATED: c_int = 1;
pub const BOO_MODEL_FILE_UNKNOWN: c_int = 2;

const libc = @import("libc.zig");

export fn boo_model_verify(path: [*:0]const u8) c_int {
    const basename = std.fs.path.basename(std.mem.span(path));
    const expected: u64 = for (models_list ++ [_]BooModelInfo{vad_model}) |m| {
        if (std.mem.eql(u8, basename, std.mem.span(m.filename))) break m.size;
    } else return BOO_MODEL_FILE_UNKNOWN;

    // Every manifest size fits c_long even on mingw (all under 2 GB).
    const f = libc.fopen(path, "rb") orelse return BOO_MODEL_FILE_TRUNCATED;
    defer _ = libc.fclose(f);
    if (libc.fseek(f, 0, libc.SEEK_END) != 0) return BOO_MODEL_FILE_TRUNCATED;
    const size = libc.ftell(f);
    if (size < 0) return BOO_MODEL_FILE_TRUNCATED;
    return if (@as(u64, @intCast(size)) == expected)
        BOO_MODEL_FILE_OK
    else
        BOO_MODEL_FILE_TRUNCATED;
}

// Hex-encode the SHA-256 of the file at `path` into `out`. False on an open
// error. Streams in fixed chunks, so a multi-hundred-MB model never lands in
// memory; a read cut short just yields a non-matching digest, never a false OK.
fn sha256FileHex(path: [*:0]const u8, out: *[64]u8) bool {
    const f = libc.fopen(path, "rb") orelse return false;
    defer _ = libc.fclose(f);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = libc.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
    return true;
}

// Verify a file against a pinned SHA-256 (`expected`, 64 hex chars). Unlike
// boo_model_verify (a size-only completeness check for enumeration), this reads
// the whole file, so it is for a just-finished download. The file is the staging
// or .part copy, whose name is not yet a manifest entry, so the caller passes the
// pinned digest from boo_models. Single-sources the hash check the three
// frontends used to each reimplement (CryptoKit / GChecksum / BCrypt).
pub const BOO_MODEL_SHA_OK: c_int = 0;
pub const BOO_MODEL_SHA_MISMATCH: c_int = 1;
pub const BOO_MODEL_SHA_UNREADABLE: c_int = 2; // could not open the file

export fn boo_model_verify_sha256(path: [*:0]const u8, expected: [*:0]const u8) c_int {
    var got: [64]u8 = undefined;
    if (!sha256FileHex(path, &got)) return BOO_MODEL_SHA_UNREADABLE;
    return if (std.ascii.eqlIgnoreCase(&got, std.mem.span(expected)))
        BOO_MODEL_SHA_OK
    else
        BOO_MODEL_SHA_MISMATCH;
}

// ── diagnostic logging ────────────────────────────────────────────────────────
// See src/log.zig. The frontend passes the per-OS log file path (or null for
// stderr only) and the minimum level (0=error 1=warn 2=info 3=debug). Never log
// recognized text; the core's own points log metadata only.

export fn boo_log_init(path: ?[*:0]const u8, min_level: c_int) void {
    log.init(path, min_level);
}

// Local crash capture, see src/crash.zig. No-op on Windows, whose frontend
// installs its own SEH minidump writer instead.
export fn boo_crash_init(dump_dir: [*:0]const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    crash.init(std.mem.span(dump_dir));
}

export fn boo_log(level: c_int, msg: [*:0]const u8) void {
    log.write(level, std.mem.span(msg));
}

// ── tests ────────────────────────────────────────────────────────────────────

test {
    // Pull the audio maths, WAV parser, and stream chunker tests in, so
    // `zig build test` covers them too.
    _ = @import("audio/common.zig");
    _ = @import("theme.zig");
    _ = @import("wav.zig");
    _ = @import("stream.zig");
    _ = @import("engine.zig");
    _ = @import("whisper.zig");
    // The WASAPI backend's format/downmix maths is pure and runs everywhere,
    // even though the backend itself is only selected on Windows.
    _ = @import("audio/wasapi.zig");
    _ = @import("wer.zig");
    _ = @import("log.zig");
    _ = @import("postprocess.zig");
    _ = @import("crash.zig");
    _ = @import("sync.zig");
    _ = @import("libc.zig");
}

const testing = std.testing;

test "boo_model_rank orders the recommended models best-first" {
    try testing.expectEqual(@as(u32, 0), boo_model_rank("ggml-parakeet-tdt-0.6b-v3-q8_0.bin"));
    try testing.expectEqual(@as(u32, 5), boo_model_rank("ggml-base.en.bin"));
    // Unknown models rank last (== the list length), so a recognized model
    // always beats an unrecognized one.
    try testing.expectEqual(recommended_models.len, boo_model_rank("ggml-something-else.bin"));
    try testing.expect(boo_model_rank("ggml-small.en.bin") < boo_model_rank("ggml-base.en.bin"));
}

test "boo_model_classify sorts speech, VAD, and non-models" {
    // Speech: any ggml-*.bin that is not the VAD, path or bare name.
    try testing.expectEqual(BOO_MODEL_SPEECH, boo_model_classify("ggml-base.en.bin"));
    try testing.expectEqual(BOO_MODEL_SPEECH, boo_model_classify("ggml-parakeet-tdt-0.6b-v3-q8_0.bin"));
    try testing.expectEqual(BOO_MODEL_SPEECH, boo_model_classify("/home/u/.boo/models/ggml-small.en.bin"));
    try testing.expectEqual(BOO_MODEL_SPEECH, boo_model_classify("C:\\Users\\u\\ggml-tiny.en-q5_1.bin"));
    // VAD: the silero family, which pickers must never offer as speech.
    try testing.expectEqual(BOO_MODEL_VAD, boo_model_classify("ggml-silero-v6.2.0.bin"));
    try testing.expectEqual(BOO_MODEL_VAD, boo_model_classify("/x/ggml-silero-v5.1.2.bin"));
    // The pinned VAD entry must classify as VAD, or streaming discovery breaks.
    try testing.expectEqual(BOO_MODEL_VAD, boo_model_classify(boo_vad_model().filename));
    // Neither: wrong prefix, wrong suffix, or unrelated files.
    try testing.expectEqual(BOO_MODEL_OTHER, boo_model_classify("model.bin"));
    try testing.expectEqual(BOO_MODEL_OTHER, boo_model_classify("ggml-base.en.txt"));
    try testing.expectEqual(BOO_MODEL_OTHER, boo_model_classify("README.md"));
    try testing.expectEqual(BOO_MODEL_OTHER, boo_model_classify("ggml-silero.txt"));
}

test "the download manifest is well-formed" {
    var count: usize = 0;
    const list = boo_models(&count);
    try testing.expect(count > 0);
    for (0..count) |i| {
        const m = list[i];
        // A pinned SHA-256 is 64 hex chars; a blank one would defeat verification.
        try testing.expectEqual(@as(usize, 64), std.mem.span(m.sha256).len);
        try testing.expect(m.size > 0);
        try testing.expect(std.mem.startsWith(u8, std.mem.span(m.url), "https://"));
        // Every speech model offered for download must be rankable, or it ranks
        // as "unknown" (recommended_models.len) and an arbitrary ggml-*.bin can
        // beat this app-offered model in the frontends' auto-selection. The
        // reverse is allowed: a rankable model need not be downloadable.
        if (boo_model_classify(m.filename) == BOO_MODEL_SPEECH)
            try testing.expect(boo_model_rank(m.filename) < recommended_models.len);
    }
    // Recommended first: Parakeet also tops boo_model_rank.
    try testing.expectEqual(@as(u32, 0), boo_model_rank(list[0].filename));

    // The VAD entry holds itself to the same manifest standards, and the
    // completeness check must recognize it (a truncated silero would
    // otherwise load-fail with no explanation).
    const vad = boo_vad_model();
    try testing.expectEqual(@as(usize, 64), std.mem.span(vad.sha256).len);
    try testing.expect(vad.size > 0);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(vad.url), "https://"));
    try testing.expectEqual(
        BOO_MODEL_FILE_TRUNCATED,
        boo_model_verify("/nonexistent/ggml-silero-v6.2.0.bin"),
    );
}

test "boo_model_verify_sha256 streams the file and checks the pinned digest" {
    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    // The canonical SHA-256("abc") vector: OK only if the streamed hash is right.
    const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    var pbuf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pbuf, "{s}/boo-sha-abc", .{tmp}, 0);
    const f = libc.fopen(path, "wb") orelse return error.SkipZigTest;
    _ = libc.fwrite("abc", 1, 3, f);
    _ = libc.fclose(f);
    defer _ = libc.remove(path);

    try testing.expectEqual(BOO_MODEL_SHA_OK, boo_model_verify_sha256(path, abc_sha));
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectEqual(BOO_MODEL_SHA_MISMATCH, boo_model_verify_sha256(path, wrong));

    // An absent file is unreadable, never reported as verified.
    try testing.expectEqual(
        BOO_MODEL_SHA_UNREADABLE,
        boo_model_verify_sha256("/nonexistent/model.bin", abc_sha),
    );
}

test "boo_best_model applies the shared selection policy" {
    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");

    // A sparse file of `size` bytes: boo_model_verify checks the on-disk size, so
    // a sparse file of the pinned size passes as non-truncated without the real
    // hundreds of MB.
    const Sized = struct {
        fn make(buf: []u8, dir: []const u8, name: []const u8, size: i64) ![:0]u8 {
            const path = try std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0);
            const f = libc.fopen(path, "wb") orelse return error.SkipZigTest;
            defer _ = libc.fclose(f);
            if (size > 0) {
                if (libc.fseek(f, @intCast(size - 1), libc.SEEK_SET) != 0) return error.SkipZigTest;
                _ = libc.fwrite("\x00", 1, 1, f);
            }
            return path;
        }
    };

    var bb: [256]u8 = undefined;
    var bs: [256]u8 = undefined;
    var bt: [256]u8 = undefined;
    const base_en = try Sized.make(&bb, tmp, "ggml-base.en.bin", 147964211);
    defer _ = libc.remove(base_en);
    const small_en = try Sized.make(&bs, tmp, "ggml-small.en.bin", 487614201);
    defer _ = libc.remove(small_en);
    const truncated = try Sized.make(&bt, tmp, "ggml-tiny.en-q5_1.bin", 5); // wrong size
    defer _ = libc.remove(truncated);

    // base.en on its own is a valid pick: this pins that its sparse fixture
    // verifies as non-truncated, so the ranking case below genuinely tests that
    // small.en OUTRANKS a usable base.en rather than base.en being filtered out.
    const base_only = [_][*:0]const u8{base_en};
    try testing.expectEqual(@as(c_int, 0), boo_best_model(&base_only, 1));

    // small.en outranks base.en, so it wins even when base is listed first.
    const ranked = [_][*:0]const u8{ base_en, small_en };
    try testing.expectEqual(@as(c_int, 1), boo_best_model(&ranked, 2));

    // The VAD (a non-speech name, no file needed) and the truncated model are both
    // filtered out; the best of what remains is small.en.
    const mixed = [_][*:0]const u8{ "/x/ggml-silero-v6.2.0.bin", truncated, base_en, small_en };
    try testing.expectEqual(@as(c_int, 3), boo_best_model(&mixed, 4));

    // Unrecognized speech models all rank the same (verify returns UNKNOWN without
    // opening, so no file is needed); the alphabetically-first name breaks the tie.
    const unrecognized = [_][*:0]const u8{ "/x/ggml-zzz.bin", "/x/ggml-aaa.bin", "/x/ggml-mmm.bin" };
    try testing.expectEqual(@as(c_int, 1), boo_best_model(&unrecognized, 3));

    // Nothing usable, or an empty list, is -1.
    const none = [_][*:0]const u8{ "/x/ggml-silero-v6.2.0.bin", "/x/notes.txt" };
    try testing.expectEqual(@as(c_int, -1), boo_best_model(&none, 2));
    try testing.expectEqual(@as(c_int, -1), boo_best_model(&none, 0));
}

test "a failed init frees everything it had already allocated" {
    // This is the regression that motivated splitting initContext out.
    //
    // boo_init returns an optional, and `errdefer` only fires on an *error*
    // return, so its cleanup never ran on the `return null` paths. A bad model
    // path leaked the context, and a failure to open the microphone leaked the
    // whole ~150MB whisper model along with it. Both are silent: the caller just
    // sees null.
    //
    // testing.allocator fails the test if a single byte is left behind, so this
    // would have caught it.
    whisper_mod.setLogSilent();
    try testing.expectError(
        error.ModelLoadFailed,
        initContext(testing.allocator, "/nonexistent/model.bin"),
    );
}

test "boo_init reports a missing model as null rather than crashing" {
    whisper_mod.setLogSilent();
    try testing.expect(boo_init("/nonexistent/model.bin") == null);
}

test "every C entry point tolerates a null context" {
    // A frontend whose boo_init failed still has a live UI, and its timers and
    // button handlers keep firing against a null context. Every one of these is
    // reachable in that state, so none may dereference it.
    boo_deinit(null);
    boo_warm_up(null);
    boo_start_recording(null);
    boo_stop_recording(null);

    try testing.expect(boo_is_recording(null) == false);
    try testing.expect(boo_is_transcribing(null) == false);
    try testing.expectEqual(@as(f32, 0.0), boo_get_peak_rms(null));
    try testing.expectEqual(@as(c_int, 0), boo_get_audio_samples(null));
    try testing.expect(boo_transcribe(null) == null);
    try testing.expect(boo_load_vad(null, "/nonexistent/vad.bin") == false);
    try testing.expect(boo_reload_model(null, "/nonexistent/model.bin") == false);
    try testing.expect(boo_stream_tick(null) == false);
    try testing.expect(boo_get_live_transcript(null) == null);

    var bars: c_int = -1;
    try testing.expect(boo_get_waveform(null, &bars) == null);

    // boo_get_waveform may also be called with a null out-param.
    try testing.expect(boo_get_waveform(null, null) == null);
}

test "the transcribing flag is atomic, not a plain bool" {
    // boo_transcribe blocks for seconds on a worker thread while the UI polls
    // boo_is_transcribing from the main thread. If this ever regresses to a
    // plain bool, that is a data race, so pin the type.
    const Field = @FieldType(BooContext, "transcribing");
    try testing.expectEqual(std.atomic.Value(bool), Field);
}

test "boo_model_verify flags truncated manifest models, cannot judge unknowns" {
    // Not in the manifest: no pinned size to compare against.
    try testing.expectEqual(
        BOO_MODEL_FILE_UNKNOWN,
        boo_model_verify("/nonexistent/ggml-mystery.bin"),
    );
    // Manifest-named but unreadable: unusable either way.
    try testing.expectEqual(
        BOO_MODEL_FILE_TRUNCATED,
        boo_model_verify("/nonexistent/ggml-base.en.bin"),
    );

    // A manifest-named file with the wrong size is a partial download. An
    // empty file with the exact manifest name is the cheapest stand-in.
    const tmp = std.c.getenv("TMPDIR") orelse "/tmp";
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(
        &buf,
        "{s}/ggml-base.en.bin",
        .{std.mem.span(tmp)},
        0,
    );
    const f = libc.fopen(path, "wb") orelse return error.SkipZigTest;
    _ = libc.fclose(f);
    defer _ = libc.remove(path);
    try testing.expectEqual(BOO_MODEL_FILE_TRUNCATED, boo_model_verify(path));

    // A real, complete download passes. Skips on checkouts without models.
    const home = std.c.getenv("HOME") orelse return;
    var hbuf: [512]u8 = undefined;
    const model = std.fmt.bufPrintSentinel(
        &hbuf,
        "{s}/.boo/models/ggml-base.en.bin",
        .{std.mem.span(home)},
        0,
    ) catch return;
    const probe = libc.fopen(model, "rb") orelse return;
    _ = libc.fclose(probe);
    try testing.expectEqual(BOO_MODEL_FILE_OK, boo_model_verify(model));
}

test "boo_reload_model swaps the engine in place and survives a bad path" {
    // Runs only when the standard local model exists (~/.boo/models), like the
    // stream tests; skips otherwise so CI checkouts stay green.
    whisper_mod.setLogSilent();
    const home = std.c.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const model = std.fmt.bufPrintSentinel(
        &buf,
        "{s}/.boo/models/ggml-base.en.bin",
        .{std.mem.span(home)},
        0,
    ) catch return error.SkipZigTest;

    const ctx = boo_init(model) orelse return error.SkipZigTest;
    defer boo_deinit(ctx);
    const engine_before = &ctx.engine;

    // A bad path (the user deleted the file, say) must leave the context
    // serving with the old engine, and serving means decoding, not merely
    // existing: push a second of audio through it after the failed swap.
    try testing.expect(!boo_reload_model(ctx, "/nonexistent/model.bin"));
    const silence = try testing.allocator.alloc(f32, 16000);
    defer testing.allocator.free(silence);
    @memset(silence, 0.0);
    const text = try ctx.engine.transcribe(testing.allocator, silence, false);
    testing.allocator.free(text);

    // A good path swaps in place: same slot, same context pointer.
    try testing.expect(boo_reload_model(ctx, model));
    try testing.expectEqual(engine_before, &ctx.engine);
}

test "boo_deinit is safe to call twice via a nulled-out handle" {
    // The frontends null their pointer after deinit; a second shutdown path
    // (window close, then app quit) must not double-free.
    var ctx: ?*BooContext = null;
    boo_deinit(ctx);
    ctx = null;
    boo_deinit(ctx);
}
