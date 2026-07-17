const std = @import("std");
const log = @import("log.zig");
const engine_mod = @import("engine.zig");
const whisper_mod = engine_mod.whisper;
const Engine = engine_mod.Engine;
const AudioCapture = @import("audio.zig").AudioCapture;
const stream = @import("stream.zig");
const common = @import("audio/common.zig");

const WAVEFORM_BARS = @import("audio.zig").WAVEFORM_BARS;
const MIN_AUDIO_SAMPLES = 8000; // ~0.5s at 16kHz

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
    last_transcript: ?[]u8 = null,
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
        const buf = self.allocator.allocSentinel(u8, ch.committed.items.len, 0) catch return;
        @memcpy(buf[0..ch.committed.items.len], ch.committed.items);
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

    const committed = ch.tick(pending) catch return false;
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

    const text: []const u8 = blk: {
        // Streaming path: everything but the tail is already transcribed.
        if (c.chunker) |*ch| {
            const tail = a.copyAudioFrom(c.allocator, ch.consumed) catch return null;
            defer c.allocator.free(tail);
            break :blk ch.finalize(tail, MIN_AUDIO_SAMPLES) catch return null;
        }

        // Batch path: no VAD model loaded, transcribe the whole take.
        const samples = a.getAudioData(c.allocator) catch return null;
        defer c.allocator.free(samples);
        if (samples.len < MIN_AUDIO_SAMPLES) return null;
        // Decoding a silent take hallucinates filler, see SILENCE_RMS_FLOOR.
        if (common.maxWindowRms(samples, common.RMS_WINDOW_SAMPLES) <
            common.SILENCE_RMS_FLOOR) return null;
        break :blk c.engine.transcribe(c.allocator, samples, true) catch return null;
    };

    if (text.len == 0) {
        c.allocator.free(text);
        return null;
    }

    // Allocate null-terminated copy: text + null byte as one contiguous allocation
    const buf = c.allocator.alloc(u8, text.len + 1) catch {
        c.allocator.free(text);
        return null;
    };
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    c.allocator.free(text);

    // Replace previous transcript
    c.freeTranscript();
    c.last_transcript = buf;

    // Metadata only, never the text (see src/log.zig privacy note).
    log.logf(.info, "transcribed {d} chars", .{buf.len - 1});
    return @ptrCast(buf.ptr);
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
};

// Rank of a model filename in the recommended order (best == 0); the list length
// for anything unrecognized, so a caller can take "lowest rank wins, alphabetical
// breaks ties among the rest" and always prefer a recognized model.
export fn boo_model_rank(name: [*:0]const u8) u32 {
    const n = std.mem.span(name);
    for (recommended_models, 0..) |m, i| {
        if (std.mem.eql(u8, n, m)) return @intCast(i);
    }
    return recommended_models.len;
}

// The curated download manifest: what the model-onboarding dialog offers, one
// source for every frontend. Recommended first. SHA-256s are pinned (the HF LFS
// oids); a download must verify against them. Keep in step with docs/models.md
// and the recommended_models order above.
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

// ── diagnostic logging ────────────────────────────────────────────────────────
// See src/log.zig. The frontend passes the per-OS log file path (or null for
// stderr only) and the minimum level (0=error 1=warn 2=info 3=debug). Never log
// recognized text; the core's own points log metadata only.

export fn boo_log_init(path: ?[*:0]const u8, min_level: c_int) void {
    log.init(path, min_level);
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
    }
    // Recommended first: Parakeet also tops boo_model_rank.
    try testing.expectEqual(@as(u32, 0), boo_model_rank(list[0].filename));
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

test "boo_deinit is safe to call twice via a nulled-out handle" {
    // The frontends null their pointer after deinit; a second shutdown path
    // (window close, then app quit) must not double-free.
    var ctx: ?*BooContext = null;
    boo_deinit(ctx);
    ctx = null;
    boo_deinit(ctx);
}
