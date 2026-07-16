const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});

fn silentLog(
    level: c.ggml_log_level,
    text: [*c]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = level;
    _ = text;
    _ = user_data;
}

/// Silence whisper.cpp's own logging. It is chatty on load and writes to
/// stdout, which corrupts the Zig test runner's IPC stream, a passing test
/// binary then reports as a failed build step with no useful message.
pub fn setLogSilent() void {
    c.whisper_log_set(silentLog, null);
}

pub const WhisperContext = struct {
    ctx: *c.whisper_context,

    pub const Options = struct {
        /// Metal GPU acceleration on Apple Silicon. The benchmark flips this
        /// off to measure the CPU baseline; the app always leaves it on.
        use_gpu: bool = true,
    };

    pub fn init(model_path: [:0]const u8, options: Options) !WhisperContext {
        var params = c.whisper_context_default_params();
        params.use_gpu = options.use_gpu;
        // Flash attention is upstream's default since v1.8.0: ~10-20% faster
        // encoding on Metal and lower memory use. Keep it explicit so a future
        // default flip upstream can't silently change our performance profile.
        params.flash_attn = true;
        const ctx = c.whisper_init_from_file_with_params(model_path.ptr, params);
        if (ctx == null) return error.ModelLoadFailed;
        return .{ .ctx = ctx.? };
    }

    pub fn deinit(self: *WhisperContext) void {
        c.whisper_free(self.ctx);
    }

    /// Language whisper transcribes in.
    ///
    /// Defaults to English, because the model we tell people to fetch
    /// (ggml-base.en) is English-only. But whisper.cpp ships ~16 multilingual
    /// models too, and forcing "en" on those would transcribe German speech as
    /// garbled English, so $BOO_LANG overrides it. Use a language code
    /// ("de", "fr", …) or "auto" to let whisper detect it.
    ///
    /// Only meaningful for multilingual models: the .en models can only ever
    /// produce English, whatever this says.
    fn language() [*:0]const u8 {
        // std.c.getenv hands back a NUL-terminated C string owned by the
        // environment, which is exactly what whisper wants, no copy needed.
        const env = std.c.getenv("BOO_LANG") orelse return "en";
        if (env[0] == 0) return "en";
        return env;
    }

    /// Transcribe PCM f32 audio at 16kHz mono. Returns allocated string.
    pub fn transcribe(self: *WhisperContext, allocator: std.mem.Allocator, samples: []const f32) ![]const u8 {
        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        params.print_progress = false;
        params.print_special = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.single_segment = false;
        // Dictation never shows timestamps, and computing them is a known
        // repetition/accuracy hazard (ggml-org/whisper.cpp#1724).
        params.no_timestamps = true;
        // The upstream default today, pinned: carrying prior output as the
        // next decode's prompt is a classic repetition-loop vector.
        params.no_context = true;
        // Never emit the non-speech token set (music notes, sound-effect
        // annotations); on silence and noise those are pure hallucination.
        params.suppress_nst = true;
        params.language = language();
        params.n_threads = threadCount();

        const result = c.whisper_full(self.ctx, params, samples.ptr, @intCast(samples.len));
        if (result != 0) return error.TranscriptionFailed;

        const n_segments = c.whisper_full_n_segments(self.ctx);
        var text: std.ArrayListAligned(u8, null) = .empty;
        errdefer text.deinit(allocator);

        for (0..@intCast(n_segments)) |i| {
            const segment_text = c.whisper_full_get_segment_text(self.ctx, @intCast(i));
            if (segment_text == null) continue;
            const no_speech = c.whisper_full_get_segment_no_speech_prob(self.ctx, @intCast(i));
            if (!keepSegment(no_speech, self.segmentAvgLogprob(@intCast(i)))) continue;
            const slice = std.mem.span(segment_text);
            if (isAnnotation(slice)) continue;
            try text.appendSlice(allocator, slice);
        }

        return text.toOwnedSlice(allocator);
    }

    /// Mean log-probability of a segment's tokens, the decoder's own
    /// confidence in what it wrote.
    fn segmentAvgLogprob(self: *WhisperContext, segment: c_int) f32 {
        const n = c.whisper_full_n_tokens(self.ctx, segment);
        if (n <= 0) return 0.0;
        var sum: f32 = 0.0;
        for (0..@intCast(n)) |t| {
            sum += c.whisper_full_get_token_data(self.ctx, segment, @intCast(t)).plog;
        }
        return sum / @as(f32, @floatFromInt(n));
    }
};

/// Whether a decoded segment is real speech worth keeping.
///
/// Whisper is a generative model: fed silence or noise it happily produces
/// plausible filler ("Thank you."). Such segments are flagged by a high
/// no-speech probability COMBINED with low decoder confidence; requiring both
/// (OpenAI's own heuristic shape) means quiet-but-confident real speech and
/// mumbled-but-present real speech are never dropped.
pub fn keepSegment(no_speech_prob: f32, avg_logprob: f32) bool {
    return !(no_speech_prob > 0.6 and avg_logprob < -0.4);
}

/// Whether a segment is purely a non-speech annotation: "[BLANK_AUDIO]",
/// "[MUSIC]", "(wind blowing)". suppress_nst blocks most of these at the
/// token level but they still slip through on some models, so this is the
/// text-level backstop. Only a segment that is exactly ONE balanced bracketed
/// or parenthesized span counts; real dictation containing brackets survives.
pub fn isAnnotation(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2) return false;
    const close: u8 = switch (t[0]) {
        '[' => ']',
        '(' => ')',
        else => return false,
    };
    if (t[t.len - 1] != close) return false;
    // A closing bracket before the end means surrounding real text.
    return std.mem.indexOfScalar(u8, t[1 .. t.len - 1], close) == null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "keepSegment: confident speech is kept" {
    try testing.expect(keepSegment(0.1, -0.2));
}

test "keepSegment: classic silence hallucination is dropped" {
    // The "Thank you." on silence shape: the model is fairly sure there is no
    // speech AND has low confidence in what it generated anyway.
    try testing.expect(!keepSegment(0.9, -1.0));
}

test "keepSegment: high no-speech alone is not enough" {
    // Breathy or very quiet openings can score high on no-speech while the
    // decoded tokens are confident; dropping those would eat real first words.
    // OpenAI's own heuristic requires BOTH signals, so does this one.
    try testing.expect(keepSegment(0.9, -0.2));
}

test "keepSegment: low confidence alone is not enough" {
    // Mumbled but real speech decodes with low avg logprob; keep it rather
    // than silently deleting the user's words.
    try testing.expect(keepSegment(0.3, -0.9));
}

test "keepSegment: thresholds are exclusive at the boundary" {
    try testing.expect(keepSegment(0.6, -0.4));
    try testing.expect(keepSegment(0.6, -1.0));
    try testing.expect(keepSegment(0.9, -0.4));
}

test "isAnnotation: bracketed non-speech markers are annotations" {
    // The classics that leak into dictation transcripts on silence.
    try testing.expect(isAnnotation("[BLANK_AUDIO]"));
    try testing.expect(isAnnotation(" [BLANK_AUDIO]")); // whisper pads a space
    try testing.expect(isAnnotation("[MUSIC]"));
    try testing.expect(isAnnotation("(wind blowing)"));
    try testing.expect(isAnnotation(" (keyboard clacking) "));
}

test "isAnnotation: real speech is never an annotation" {
    try testing.expect(!isAnnotation("hello world"));
    try testing.expect(!isAnnotation(""));
    try testing.expect(!isAnnotation(" "));
    // Real text that merely contains or borders brackets must survive.
    try testing.expect(!isAnnotation("[a] and [b]"));
    try testing.expect(!isAnnotation("(so I said) let's go"));
    try testing.expect(!isAnnotation("[")); // too short / unbalanced
}

/// Decode thread count: min(cores, 8), overridable with $BOO_THREADS.
/// The valgrind CI job sets 1: memcheck serializes every thread onto a single
/// core, where ggml's spin-waiting workers starve the one doing the work and
/// a minutes-long job becomes hours.
pub fn threadCount() c_int {
    if (std.c.getenv("BOO_THREADS")) |env| {
        const n = std.fmt.parseInt(u8, std.mem.span(env), 10) catch 0;
        if (n > 0) return n;
    }
    return @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
}

/// whisper's VAD timestamps are centiseconds (the same 10ms unit as its
/// segment timestamps); at 16kHz that is 160 samples per tick.
const SAMPLES_PER_CS = 160;

/// Silero VAD (ggml-silero-*.bin, ~2MB): finds speech segments so the
/// streaming path can transcribe utterances at natural pauses instead of
/// batching the whole recording at the end.
pub const Vad = struct {
    ctx: *c.whisper_vad_context,

    pub fn init(model_path: [:0]const u8) !Vad {
        var params = c.whisper_vad_default_context_params();
        // Silero is a tiny LSTM: instant on CPU, and keeping it there leaves
        // the GPU free for whisper itself. The default context asks for 4
        // threads, which a 2MB model scanning 250ms ticks never needs, and
        // which reintroduced spin-waiting workers under the valgrind CI job
        // after $BOO_THREADS had removed them from transcription.
        params.use_gpu = false;
        params.n_threads = threadCount();
        const ctx = c.whisper_vad_init_from_file_with_params(model_path.ptr, params) orelse
            return error.ModelLoadFailed;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Vad) void {
        c.whisper_vad_free(self.ctx);
    }

    pub const Segment = struct {
        /// Sample offsets into the audio passed to segments().
        start: usize,
        end: usize,
    };

    /// Speech segments found in `samples` (16kHz mono f32), in order.
    /// Caller owns the returned slice.
    pub fn segments(self: *Vad, allocator: std.mem.Allocator, samples: []const f32) ![]Segment {
        const params = c.whisper_vad_default_params();
        const segs = c.whisper_vad_segments_from_samples(
            self.ctx,
            params,
            samples.ptr,
            @intCast(samples.len),
        ) orelse return error.VadFailed;
        defer c.whisper_vad_free_segments(segs);

        const n: usize = @intCast(c.whisper_vad_segments_n_segments(segs));
        const out = try allocator.alloc(Segment, n);
        errdefer allocator.free(out);
        for (out, 0..) |*seg, i| {
            const t0 = c.whisper_vad_segments_get_segment_t0(segs, @intCast(i));
            const t1 = c.whisper_vad_segments_get_segment_t1(segs, @intCast(i));
            const start: usize = @intFromFloat(@max(t0, 0) * SAMPLES_PER_CS);
            const end: usize = @intFromFloat(@max(t1, 0) * SAMPLES_PER_CS);
            seg.* = .{
                .start = @min(start, samples.len),
                .end = @min(end, samples.len),
            };
        }
        return out;
    }
};
