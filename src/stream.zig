// Incremental transcription while recording.
//
// The batch pipeline transcribes the whole take after the user stops, so
// stop-to-text latency grows with recording length. The Chunker instead
// watches the take through Silero VAD as it grows: whenever an utterance has
// clearly ended (speech followed by enough silence), it transcribes just that
// span and commits the text. On stop, only the final utterance remains to
// transcribe, so long dictations stop paying for their own length.
//
// The Chunker is deliberately passive: it owns no thread and no audio. The
// frontend calls tick() periodically from one background thread with the
// not-yet-consumed audio, and finalize() once recording ends. This keeps the
// core free of threading (only a watermark and a text buffer) and works the
// same on macOS and Linux.

const std = @import("std");
const engine_mod = @import("engine.zig");
const whisper = engine_mod.whisper;
const Engine = engine_mod.Engine;

const WHISPER_SAMPLE_RATE = @import("audio/common.zig").WHISPER_SAMPLE_RATE;
const SAMPLES_PER_MS = WHISPER_SAMPLE_RATE / 1000;

/// Speech must be followed by this much silence before the chunker treats it
/// as a finished utterance. Shorter risks cutting mid-sentence pauses (worse
/// punctuation, split words); longer just delays the commit. Dictation apps
/// converge around 500-700ms.
pub const UTTERANCE_SILENCE_MS = 600;

/// Don't bother running VAD until the pending window could plausibly hold a
/// finished utterance: the VAD minimum speech length plus the silence gate.
const MIN_PENDING_SAMPLES = (250 + UTTERANCE_SILENCE_MS) * SAMPLES_PER_MS;

/// On long quiet stretches the pending window would grow without bound and
/// every tick would re-scan all of it. Beyond this much pure silence, discard
/// all but a short tail (kept so an utterance starting right at the cut is
/// not clipped).
const MAX_SILENT_PENDING_SAMPLES = 10 * WHISPER_SAMPLE_RATE;
const SILENT_KEEP_SAMPLES = 1 * WHISPER_SAMPLE_RATE;

pub const Chunker = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,
    vad: *whisper.Vad,
    /// Transcripts of finished utterances, space-joined as they complete.
    committed: std.ArrayList(u8) = .empty,
    /// Absolute sample index into the take; everything before it has been
    /// transcribed or discarded as silence.
    consumed: usize = 0,

    pub fn init(allocator: std.mem.Allocator, engine: *Engine, vad: *whisper.Vad) Chunker {
        return .{ .allocator = allocator, .engine = engine, .vad = vad };
    }

    pub fn deinit(self: *Chunker) void {
        self.committed.deinit(self.allocator);
    }

    /// Start a new take.
    pub fn reset(self: *Chunker) void {
        self.committed.clearRetainingCapacity();
        self.consumed = 0;
    }

    /// Look for a finished utterance in `pending`, the take from `consumed`
    /// onward (the caller fetches exactly that via copyAudioFrom). Transcribes
    /// and commits it if found. Returns true when new text was committed.
    pub fn tick(self: *Chunker, pending: []const f32) !bool {
        if (pending.len < MIN_PENDING_SAMPLES) return false;

        const segs = try self.vad.segments(self.allocator, pending);
        defer self.allocator.free(segs);

        if (segs.len == 0) {
            if (pending.len > MAX_SILENT_PENDING_SAMPLES) {
                self.consumed += pending.len - SILENT_KEEP_SAMPLES;
            }
            return false;
        }

        // The last utterance that has clearly ended: speech whose end is
        // followed by at least the silence gate within the pending window.
        // Everything up to that point is transcribed as one span; internal
        // pauses stay in, whisper handles them better than hard cuts would.
        const silence_samples = UTTERANCE_SILENCE_MS * SAMPLES_PER_MS;
        var cut: ?usize = null;
        for (segs) |seg| {
            if (pending.len >= seg.end + silence_samples) cut = seg.end;
        }
        const cut_at = cut orelse return false;

        // Each chunk is transcribed independently. Carrying the committed
        // text as initial_prompt was tried and reverted: whisper echoes the
        // prompt back into the output when consecutive utterances sound
        // alike, inserting text that was never spoken. Choppier punctuation
        // at chunk seams is the safer failure mode.
        const text = try self.engine.transcribe(self.allocator, pending[0..cut_at]);
        defer self.allocator.free(text);
        try self.appendCommitted(text);
        self.consumed += cut_at;
        return true;
    }

    /// Finish the take: transcribe the remaining tail and return the full
    /// transcript (committed utterances plus tail). Caller owns the slice.
    /// `tail` is the take from `consumed` onward. A tail below `min_samples`
    /// is skipped, so a too-short recording with nothing committed comes back
    /// empty, matching the batch path's "too short" behavior.
    pub fn finalize(self: *Chunker, tail: []const f32, min_samples: usize) ![]u8 {
        if (tail.len >= min_samples) {
            const text = try self.engine.transcribe(self.allocator, tail);
            defer self.allocator.free(text);
            try self.appendCommitted(text);
        }
        self.consumed += tail.len;
        return self.allocator.dupe(u8, self.committed.items);
    }

    fn appendCommitted(self: *Chunker, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\n");
        if (trimmed.len == 0) return;
        if (self.committed.items.len != 0) {
            try self.committed.append(self.allocator, ' ');
        }
        try self.committed.appendSlice(self.allocator, trimmed);
    }
};

// ── tests ────────────────────────────────────────────────────────────────────
// The chunker's cut logic is pure arithmetic over VAD segments, but exercising
// it for real needs models. These tests run when the standard local models
// exist (~/.boo/models) and skip otherwise, so `zig build test` stays green on
// checkouts without them.

const testing = std.testing;

fn homeModel(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const home = std.c.getenv("HOME") orelse return error.SkipZigTest;
    return std.fmt.allocPrintSentinel(allocator, "{s}/.boo/models/{s}", .{ std.mem.span(home), name }, 0);
}

test "Chunker: commits utterances during the take and finalizes the tail" {
    engine_mod.setLogSilent();
    const allocator = testing.allocator;

    const model_path = try homeModel(allocator, "ggml-base.en.bin");
    defer allocator.free(model_path);
    const vad_path = try homeModel(allocator, "ggml-silero-v6.2.0.bin");
    defer allocator.free(vad_path);

    var eng = Engine.init(model_path, .{}) catch return error.SkipZigTest;
    defer eng.deinit();
    var vad = whisper.Vad.init(vad_path) catch return error.SkipZigTest;
    defer vad.deinit();

    var chunker = Chunker.init(allocator, &eng, &vad);
    defer chunker.deinit();

    // Synthesize a take with an unambiguous utterance boundary: speech,
    // 1.5s of silence, speech again. Real speech comes from jfk.wav via the
    // wav module when available; otherwise skip.
    const wav = @import("wav.zig");
    const jfk_path = try homeModel(allocator, "jfk.wav");
    defer allocator.free(jfk_path);
    const f = std.c.fopen(jfk_path.ptr, "rb") orelse return error.SkipZigTest;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try bytes.appendSlice(allocator, buf[0..n]);
    }
    _ = std.c.fclose(f);

    const parsed = wav.parse(bytes.items) catch return error.SkipZigTest;
    const speech = try wav.toF32(allocator, parsed);
    defer allocator.free(speech);

    var take: std.ArrayList(f32) = .empty;
    defer take.deinit(allocator);
    try take.appendSlice(allocator, speech);
    try take.appendNTimes(allocator, 0.0, WHISPER_SAMPLE_RATE * 3 / 2);
    try take.appendSlice(allocator, speech);

    // Tick over the first utterance + silence: should commit.
    const first_span = speech.len + WHISPER_SAMPLE_RATE; // speech + 1s of the gap
    const committed = try chunker.tick(take.items[0..first_span]);
    try testing.expect(committed);
    try testing.expect(chunker.committed.items.len > 0);
    try testing.expect(chunker.consumed > 0);
    try testing.expect(chunker.consumed <= first_span);

    // Finalize with the rest: full transcript must contain both utterances.
    const tail = take.items[chunker.consumed..];
    const final = try chunker.finalize(tail, 8000);
    defer allocator.free(final);

    // jfk.wav: "...ask what you can do for your country." twice.
    const first_hit = std.mem.indexOf(u8, final, "country") orelse return error.TestUnexpectedResult;
    const second_hit = std.mem.lastIndexOf(u8, final, "country") orelse return error.TestUnexpectedResult;
    try testing.expect(first_hit != second_hit);
}

test "Chunker: pure silence commits nothing and bounds the pending window" {
    engine_mod.setLogSilent();
    const allocator = testing.allocator;

    const model_path = try homeModel(allocator, "ggml-base.en.bin");
    defer allocator.free(model_path);
    const vad_path = try homeModel(allocator, "ggml-silero-v6.2.0.bin");
    defer allocator.free(vad_path);

    var eng = Engine.init(model_path, .{}) catch return error.SkipZigTest;
    defer eng.deinit();
    var vad = whisper.Vad.init(vad_path) catch return error.SkipZigTest;
    defer vad.deinit();

    var chunker = Chunker.init(allocator, &eng, &vad);
    defer chunker.deinit();

    const silence = try allocator.alloc(f32, MAX_SILENT_PENDING_SAMPLES + WHISPER_SAMPLE_RATE);
    defer allocator.free(silence);
    @memset(silence, 0.0);

    try testing.expect(!try chunker.tick(silence));
    try testing.expectEqual(@as(usize, 0), chunker.committed.items.len);
    // The watermark advanced past the bulk of the silence.
    try testing.expect(chunker.consumed >= silence.len - SILENT_KEEP_SAMPLES);
}
