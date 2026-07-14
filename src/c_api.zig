const std = @import("std");
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
    audio: *AudioCapture,
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
    /// buffers are retired, not freed, until the next take starts: a frontend
    /// may still be reading the pointer it fetched a moment ago.
    live_transcript: ?[:0]u8 = null,
    retired_transcripts: std.ArrayList([:0]u8) = .empty,

    fn freeTranscript(self: *BooContext) void {
        if (self.last_transcript) |t| {
            self.allocator.free(t);
            self.last_transcript = null;
        }
    }

    fn freeLiveTranscripts(self: *BooContext) void {
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
            self.retired_transcripts.append(self.allocator, old) catch self.allocator.free(old);
        }
        self.live_transcript = buf;
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

    // If this fails, the errdefer above frees the model, otherwise a missing
    // microphone would strand the whole (hundreds of MB) model context.
    const audio = try AudioCapture.init(allocator);

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
    c.freeTranscript();
    c.freeLiveTranscripts();
    c.retired_transcripts.deinit(c.allocator);
    if (c.chunker) |*ch| ch.deinit();
    if (c.vad) |*v| v.deinit();
    c.audio.deinit();
    c.engine.deinit();
    c.allocator.destroy(c);
}

/// Load a Silero VAD model, enabling incremental transcription during
/// recording (boo_stream_tick / boo_get_live_transcript). Without it, Boo
/// behaves exactly as before: one batch transcription on stop. Idempotent.
export fn boo_load_vad(ctx: ?*BooContext, vad_model_path: [*:0]const u8) bool {
    const c = ctx orelse return false;
    if (c.vad != null) return true;
    c.vad = whisper_mod.Vad.init(std.mem.span(vad_model_path)) catch return false;
    // Pointing into the optional's payload is safe: BooContext lives on the
    // heap and vad is never reassigned after this.
    c.chunker = stream.Chunker.init(c.allocator, &c.engine, &c.vad.?);
    return true;
}

export fn boo_start_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.freeTranscript();
    c.freeLiveTranscripts();
    if (c.chunker) |*ch| ch.reset();
    c.audio.startRecording();
}

export fn boo_warm_up(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.audio.warmUp();
}

export fn boo_stop_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.audio.stopRecording();
}

export fn boo_is_recording(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.audio.isRecording();
}

export fn boo_is_transcribing(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.transcribing.load(.acquire);
}

export fn boo_get_waveform(ctx: ?*BooContext, out_bars: ?*c_int) ?[*]const f32 {
    const c = ctx orelse return null;
    c.waveform_buf = c.audio.getWaveform();
    if (out_bars) |p| p.* = WAVEFORM_BARS;
    return &c.waveform_buf;
}

export fn boo_get_peak_rms(ctx: ?*BooContext) f32 {
    const c = ctx orelse return 0;
    return c.audio.getPeakRms();
}

export fn boo_get_audio_samples(ctx: ?*BooContext) c_int {
    const c = ctx orelse return 0;
    return @intCast(c.audio.sampleCount());
}

/// Detect and transcribe finished utterances while recording. Call every
/// 200-500ms from one background thread; each call either commits nothing
/// (cheap VAD scan) or blocks for one utterance's inference. Returns true
/// when new text was committed (see boo_get_live_transcript).
export fn boo_stream_tick(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    const ch = if (c.chunker) |*it| it else return false;
    if (!c.audio.isRecording()) return false;
    if (c.transcribing.load(.acquire)) return false;

    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();

    const pending = c.audio.copyAudioFrom(c.allocator, ch.consumed) catch return false;
    defer c.allocator.free(pending);

    const committed = ch.tick(pending) catch return false;
    if (committed) c.publishLiveTranscript();
    return committed;
}

/// Text committed so far in the current take, or null. Owned by Boo; the
/// pointer stays valid until the next boo_start_recording or boo_deinit.
export fn boo_get_live_transcript(ctx: ?*BooContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const live = c.live_transcript orelse return null;
    return live.ptr;
}

export fn boo_transcribe(ctx: ?*BooContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    c.transcribing.store(true, .release);
    defer c.transcribing.store(false, .release);

    c.whisper_mutex.lock();
    defer c.whisper_mutex.unlock();

    const text: []const u8 = blk: {
        // Streaming path: everything but the tail is already transcribed.
        if (c.chunker) |*ch| {
            const tail = c.audio.copyAudioFrom(c.allocator, ch.consumed) catch return null;
            defer c.allocator.free(tail);
            break :blk ch.finalize(tail, MIN_AUDIO_SAMPLES) catch return null;
        }

        // Batch path: no VAD model loaded, transcribe the whole take.
        const samples = c.audio.getAudioData(c.allocator) catch return null;
        defer c.allocator.free(samples);
        if (samples.len < MIN_AUDIO_SAMPLES) return null;
        break :blk c.engine.transcribe(c.allocator, samples) catch return null;
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

    return @ptrCast(buf.ptr);
}

// ── tests ────────────────────────────────────────────────────────────────────

test {
    // Pull the audio maths, WAV parser, and stream chunker tests in, so
    // `zig build test` covers them too.
    _ = @import("audio/common.zig");
    _ = @import("wav.zig");
    _ = @import("stream.zig");
    _ = @import("engine.zig");
}

const testing = std.testing;

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
