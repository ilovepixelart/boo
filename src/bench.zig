// Transcription performance benchmark.
//
//   zig build bench                        # GPU, defaults
//   zig build bench -- --cpu               # CPU baseline for comparison
//   zig build bench -- --runs 10           # more warm iterations
//   zig build bench -- --assert-rtf 20     # exit 1 if median falls below 20x
//   zig build bench -- --stream            # VAD-chunked streaming vs batch
//   zig build bench -- --expect "text"     # score WER against a reference
//   zig build bench -- --assert-wer 5      # exit 1 if WER exceeds 5%
//   zig build bench -- --suite tests/eval  # multi-clip accuracy suite
//   zig build bench -- <model.bin> <audio.wav>
//
// With the default jfk.wav the reference transcript is built in, so
// --assert-wer works in CI with no extra plumbing. WER is the accuracy gate:
// a change that corrupts output (repetition loops, prompt echo, engine
// misrouting) fails it even when the speed numbers still look fine.
//
// Defaults: ~/.boo/models/ggml-base.en.bin and the jfk.wav sample that ships
// inside the whisper.cpp package, so a fresh checkout can bench with no setup
// beyond downloading the model.
//
// The cold run is reported separately: on Metal it includes one-time shader
// pipeline compilation that steady-state dictation never pays again.

const std = @import("std");
const engine_mod = @import("engine.zig");
const whisper = engine_mod.whisper;
const wav = @import("wav.zig");
const stream = @import("stream.zig");
const wer = @import("wer.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("dirent.h");
});

const WHISPER_SAMPLE_RATE = 16000;
const DEFAULT_WARM_RUNS = 5;
const MAX_WAV_BYTES = 512 * 1024 * 1024;

/// What jfk.wav actually says; the built-in reference for WER scoring when
/// benching the default sample.
const JFK_REFERENCE =
    "And so my fellow Americans, ask not what your country can do for you, " ++
    "ask what you can do for your country.";

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Read a whole file via C stdio. The rest of the core already talks to C for
/// I/O adjacent work, and this sidesteps the in-flux std.Io file API.
fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(f);
    if (c.fseek(f, 0, c.SEEK_END) != 0) return error.SeekFailed;
    const size = c.ftell(f);
    if (size < 0 or size > MAX_WAV_BYTES) return error.FileTooBig;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return error.SeekFailed;
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    if (c.fread(buf.ptr, 1, buf.len, f) != buf.len) return error.ReadFailed;
    return buf;
}

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Monotonic clock via libc. Zig 0.16 moved std.time.Timer into the std.Io
/// interface, which the core deliberately doesn't thread through (see
/// audio/common.zig); CLOCK_MONOTONIC is exactly what Timer wrapped anyway.
const Timer = struct {
    last: u64,

    fn nowNs() u64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
    }

    fn start() Timer {
        return .{ .last = nowNs() };
    }

    /// Nanoseconds since start() or the previous lap().
    fn lap(self: *Timer) u64 {
        const now = nowNs();
        const elapsed = now - self.last;
        self.last = now;
        return elapsed;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    var model_arg: ?[:0]const u8 = null;
    var wav_arg: ?[:0]const u8 = null;
    var use_gpu = true;
    var warm_runs: usize = DEFAULT_WARM_RUNS;
    var assert_rtf: ?f64 = null;
    var stream_mode = false;
    var expect_arg: ?[]const u8 = null;
    var assert_wer: ?f64 = null;
    var suite_arg: ?[:0]const u8 = null;
    // Streaming-simulation take length; CI's valgrind pass shrinks it because
    // memcheck runs ~25x slower than native.
    var utterances: usize = 3;
    // Coverage-not-timing mode for the valgrind job: one inference per path,
    // no warm-up, no warm runs, no stream batch comparison.
    var quick = false;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cpu")) {
            use_gpu = false;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            quick = true;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            stream_mode = true;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            const v = args.next() orelse fatal("--runs needs a number", .{});
            warm_runs = std.fmt.parseInt(usize, v, 10) catch fatal("bad --runs value: {s}", .{v});
            if (warm_runs == 0) fatal("--runs must be at least 1", .{});
        } else if (std.mem.eql(u8, arg, "--assert-rtf")) {
            const v = args.next() orelse fatal("--assert-rtf needs a number", .{});
            assert_rtf = std.fmt.parseFloat(f64, v) catch fatal("bad --assert-rtf value: {s}", .{v});
        } else if (std.mem.eql(u8, arg, "--suite")) {
            suite_arg = args.next() orelse fatal("--suite needs a directory", .{});
        } else if (std.mem.eql(u8, arg, "--utterances")) {
            const v = args.next() orelse fatal("--utterances needs a number", .{});
            utterances = std.fmt.parseInt(usize, v, 10) catch fatal("bad --utterances value: {s}", .{v});
            if (utterances == 0) fatal("--utterances must be at least 1", .{});
        } else if (std.mem.eql(u8, arg, "--expect")) {
            expect_arg = args.next() orelse fatal("--expect needs the reference text", .{});
        } else if (std.mem.eql(u8, arg, "--assert-wer")) {
            const v = args.next() orelse fatal("--assert-wer needs a percentage", .{});
            assert_wer = std.fmt.parseFloat(f64, v) catch fatal("bad --assert-wer value: {s}", .{v});
        } else if (std.mem.startsWith(u8, arg, "--")) {
            fatal("unknown flag: {s}", .{arg});
        } else if (model_arg == null) {
            model_arg = arg;
        } else if (wav_arg == null) {
            wav_arg = arg;
        } else {
            fatal("unexpected argument: {s}", .{arg});
        }
    }

    // Always duped (even when argv already provides the string) so both
    // paths are owned and freed uniformly; the valgrind CI gate sees any
    // sloppiness here as a definite leak.
    const model_path: [:0]u8 = blk: {
        if (model_arg) |m| break :blk try allocator.dupeZ(u8, m);
        const home = std.c.getenv("HOME") orelse fatal("no HOME and no model path given", .{});
        const joined = try std.mem.concat(allocator, u8, &.{ std.mem.span(home), "/.boo/models/ggml-base.en.bin" });
        defer allocator.free(joined);
        break :blk try allocator.dupeZ(u8, joined);
    };
    defer allocator.free(model_path);
    const wav_path: [:0]u8 = try allocator.dupeZ(u8, wav_arg orelse build_options.jfk_wav);
    defer allocator.free(wav_path);
    // The bundled sample has a known transcript; custom audio needs --expect.
    // A suite brings its own references per clip.
    const reference: ?[]const u8 = expect_arg orelse (if (wav_arg == null) JFK_REFERENCE else null);
    if (assert_wer != null and reference == null and suite_arg == null)
        fatal("--assert-wer needs --expect (only the default jfk.wav has a built-in reference)", .{});

    // Audio first: it's the cheap step, and a bad path shouldn't cost a model load.
    const bytes = readFile(allocator, wav_path) catch |err|
        fatal("cannot read {s}: {t}", .{ wav_path, err });
    defer allocator.free(bytes);
    const parsed = wav.parse(bytes) catch |err|
        fatal("cannot parse {s}: {t}", .{ wav_path, err });
    if (parsed.sample_rate != WHISPER_SAMPLE_RATE or parsed.channels != 1)
        fatal("{s} is {d} Hz / {d}ch; whisper needs 16000 Hz mono", .{ wav_path, parsed.sample_rate, parsed.channels });
    const samples = try wav.toF32(allocator, parsed);
    defer allocator.free(samples);
    const audio_seconds = parsed.durationSeconds();

    // Whisper's load/init logging would drown the report.
    engine_mod.setLogSilent();

    var timer = Timer.start();
    var ctx = engine_mod.Engine.init(model_path, .{ .use_gpu = use_gpu }) catch
        fatal("cannot load model {s}\nDownload one first:\n  mkdir -p ~/.boo/models\n  curl -L -o ~/.boo/models/ggml-base.en.bin \\\n    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin", .{model_path});
    defer ctx.deinit();
    const load_ns = timer.lap();

    std.debug.print(
        \\Boo transcription benchmark
        \\  model:  {s}
        \\  audio:  {s} ({d:.1}s)
        \\  engine: {s}, device: {s}
        \\
        \\  model load: {d:.0} ms
        \\
    , .{ model_path, if (suite_arg) |s| s else wav_path, audio_seconds, @tagName(ctx), if (use_gpu) "gpu" else "cpu", msFromNs(load_ns) });

    if (suite_arg) |suite_dir| {
        try runSuite(allocator, &ctx, suite_dir, assert_rtf, assert_wer);
        return;
    }

    if (stream_mode) {
        try runStreamBench(allocator, &ctx, samples, utterances, reference, assert_wer, quick);
        return;
    }

    // Cold run: includes Metal pipeline warm-up, worth knowing but not
    // representative of dictation steady state.
    _ = timer.lap();
    const cold_text = ctx.transcribe(allocator, samples) catch fatal("transcription failed", .{});
    const cold_ns = timer.lap();
    if (cold_text.len == 0) fatal("empty transcript; model or audio is broken", .{});
    std.debug.print("  cold run:   {d:.0} ms (includes backend warm-up)\n", .{msFromNs(cold_ns)});

    const times = try allocator.alloc(u64, if (quick) 0 else warm_runs);
    defer allocator.free(times);
    if (!quick) {
        std.debug.print("  warm runs: ", .{});
        for (times) |*t| {
            _ = timer.lap();
            const text = ctx.transcribe(allocator, samples) catch fatal("transcription failed", .{});
            t.* = timer.lap();
            allocator.free(text);
            std.debug.print(" {d:.0}", .{msFromNs(t.*)});
        }
        std.debug.print(" ms\n", .{});
    }

    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    // Quick mode has only the cold run to report against.
    const median_ms = if (quick) msFromNs(cold_ns) else msFromNs(times[times.len / 2]);
    const rtf = audio_seconds * std.time.ms_per_s / median_ms;
    std.debug.print("  median:     {d:.0} ms -> {d:.1}x realtime\n", .{ median_ms, rtf });

    const wer_pct = try scoreWer(allocator, cold_text, reference);
    std.debug.print("\ntranscript:{s}\n", .{cold_text});
    allocator.free(cold_text);

    var failed = false;
    if (assert_rtf) |threshold| {
        if (rtf < threshold) {
            std.debug.print("\nFAIL: {d:.1}x realtime is below the required {d:.1}x\n", .{ rtf, threshold });
            failed = true;
        } else {
            std.debug.print("\nOK: {d:.1}x realtime meets the required {d:.1}x\n", .{ rtf, threshold });
        }
    }
    checkWerGate(wer_pct, assert_wer, &failed);
    if (failed) std.process.exit(1);
}

/// Multi-clip accuracy suite: every NAME.wav in the directory is transcribed
/// and scored against its NAME.txt reference. The gate applies to the
/// aggregate WER (total errors over total reference words), so short clips
/// aren't over-weighted and one flaky token on one clip can't flip CI.
fn runSuite(
    allocator: std.mem.Allocator,
    ctx: *engine_mod.Engine,
    suite_dir: [:0]const u8,
    assert_rtf: ?f64,
    assert_wer: ?f64,
) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    const dir = c.opendir(suite_dir.ptr);
    if (dir == null) fatal("cannot open suite directory {s}", .{suite_dir});
    while (true) {
        const entry = c.readdir(dir);
        if (entry == null) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".wav")) continue;
        try names.append(allocator, try allocator.dupe(u8, name[0 .. name.len - 4]));
    }
    _ = c.closedir(dir);
    if (names.items.len == 0) fatal("no .wav clips in {s}", .{suite_dir});
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var total_errors: usize = 0;
    var total_ref_words: usize = 0;
    var total_audio_s: f64 = 0;
    var total_infer_ms: f64 = 0;
    var warmed_up = false;

    std.debug.print("  {s:<28} {s:>6} {s:>8} {s:>7}\n", .{ "clip", "audio", "time", "WER" });
    for (names.items) |name| {
        const wav_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.wav", .{ suite_dir, name }, 0);
        defer allocator.free(wav_path);
        const ref_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.txt", .{ suite_dir, name }, 0);
        defer allocator.free(ref_path);

        const bytes = readFile(allocator, wav_path) catch |err|
            fatal("cannot read {s}: {t}", .{ wav_path, err });
        defer allocator.free(bytes);
        const parsed = wav.parse(bytes) catch |err|
            fatal("cannot parse {s}: {t}", .{ wav_path, err });
        if (parsed.sample_rate != WHISPER_SAMPLE_RATE or parsed.channels != 1)
            fatal("{s} is {d} Hz / {d}ch; the suite needs 16000 Hz mono", .{ wav_path, parsed.sample_rate, parsed.channels });
        const samples = try wav.toF32(allocator, parsed);
        defer allocator.free(samples);

        const ref_raw = readFile(allocator, ref_path) catch |err|
            fatal("cannot read {s}: {t} (every clip needs a reference)", .{ ref_path, err });
        defer allocator.free(ref_raw);
        const ref = std.mem.trim(u8, ref_raw, " \t\r\n");

        // The first inference pays one-time backend warm-up; keep it out of
        // the timings by burning a run on the first clip.
        if (!warmed_up) {
            const warmup = ctx.transcribe(allocator, samples) catch fatal("warm-up failed", .{});
            allocator.free(warmup);
            warmed_up = true;
        }

        var timer = Timer.start();
        const text = ctx.transcribe(allocator, samples) catch fatal("transcription failed on {s}", .{name});
        defer allocator.free(text);
        const infer_ms = msFromNs(timer.lap());

        const counts = try wer.wordErrors(allocator, text, ref);
        total_errors += counts.errors;
        total_ref_words += counts.reference_words;
        total_audio_s += parsed.durationSeconds();
        total_infer_ms += infer_ms;

        std.debug.print("  {s:<28} {d:5.1}s {d:6.0}ms {d:6.1}%\n", .{
            name, parsed.durationSeconds(), infer_ms, counts.rate() * 100.0,
        });
    }

    const aggregate_pct = @as(f64, @floatFromInt(total_errors)) /
        @as(f64, @floatFromInt(total_ref_words)) * 100.0;
    const rtf = total_audio_s * std.time.ms_per_s / total_infer_ms;
    std.debug.print(
        "\n  aggregate: {d} clips, {d:.1}s audio, WER {d:.1}% ({d}/{d} words), {d:.1}x realtime\n",
        .{ names.items.len, total_audio_s, aggregate_pct, total_errors, total_ref_words, rtf },
    );

    var failed = false;
    if (assert_rtf) |threshold| {
        if (rtf < threshold) {
            std.debug.print("FAIL: {d:.1}x realtime is below the required {d:.1}x\n", .{ rtf, threshold });
            failed = true;
        } else {
            std.debug.print("OK: {d:.1}x realtime meets the required {d:.1}x\n", .{ rtf, threshold });
        }
    }
    checkWerGate(aggregate_pct, assert_wer, &failed);
    if (failed) std.process.exit(1);
}

/// Print and return the WER percentage when a reference is known.
fn scoreWer(allocator: std.mem.Allocator, transcript: []const u8, reference: ?[]const u8) !?f64 {
    const ref = reference orelse return null;
    const rate = try wer.wordErrorRate(allocator, transcript, ref);
    const pct = rate * 100.0;
    std.debug.print("  WER:        {d:.1}% vs reference\n", .{pct});
    return pct;
}

fn checkWerGate(wer_pct: ?f64, assert_wer: ?f64, failed: *bool) void {
    const threshold = assert_wer orelse return;
    const pct = wer_pct orelse return;
    if (pct > threshold) {
        std.debug.print("FAIL: {d:.1}% WER exceeds the allowed {d:.1}%\n", .{ pct, threshold });
        failed.* = true;
    } else {
        std.debug.print("OK: {d:.1}% WER is within the allowed {d:.1}%\n", .{ pct, threshold });
    }
}

/// Simulate a dictation session: several utterances separated by pauses,
/// fed to the VAD chunker in 250ms ticks exactly as a frontend would, then
/// "stop". The number that matters is stop-to-text: what the user waits for
/// after releasing the hotkey, streaming vs batch. WER against the repeated
/// reference guards the chunker itself: a seam bug (dropped or duplicated
/// words at utterance boundaries) shows up here and nowhere else.
fn runStreamBench(
    allocator: std.mem.Allocator,
    ctx: *engine_mod.Engine,
    utterance: []const f32,
    utterances: usize,
    reference: ?[]const u8,
    assert_wer: ?f64,
    quick: bool,
) !void {
    const home = std.c.getenv("HOME") orelse fatal("no HOME; cannot find VAD model", .{});
    const vad_joined = try std.mem.concat(allocator, u8, &.{ std.mem.span(home), "/.boo/models/ggml-silero-v6.2.0.bin" });
    defer allocator.free(vad_joined);
    const vad_path = try allocator.dupeZ(u8, vad_joined);
    defer allocator.free(vad_path);

    var vad = whisper.Vad.init(vad_path) catch
        fatal("cannot load VAD model {s}\nDownload it first:\n  curl -L -o ~/.boo/models/ggml-silero-v6.2.0.bin \\\n    https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin", .{vad_path});
    defer vad.deinit();

    // The take: utterances with 1.5s pauses, stop right at speech end.
    const gap = WHISPER_SAMPLE_RATE * 3 / 2;
    var take: std.ArrayList(f32) = .empty;
    defer take.deinit(allocator);
    for (0..utterances) |i| {
        if (i != 0) try take.appendNTimes(allocator, 0.0, gap);
        try take.appendSlice(allocator, utterance);
    }
    const take_seconds = @as(f64, @floatFromInt(take.items.len)) / WHISPER_SAMPLE_RATE;

    // Pay the backend warm-up outside the measurements; pointless in quick
    // mode, which measures coverage, not time.
    if (!quick) {
        const warmup = ctx.transcribe(allocator, utterance) catch fatal("warm-up transcription failed", .{});
        allocator.free(warmup);
    }

    var chunker = stream.Chunker.init(allocator, ctx, &vad);
    defer chunker.deinit();

    const step = WHISPER_SAMPLE_RATE / 4; // 250ms tick, like a frontend timer
    var pos: usize = 0;
    var ticks: usize = 0;
    var commits: usize = 0;
    var worst_tick_ms: f64 = 0;
    var timer = Timer.start();
    while (pos < take.items.len) {
        pos = @min(pos + step, take.items.len);
        _ = timer.lap();
        const committed = try chunker.tick(take.items[chunker.consumed..pos]);
        const ms = msFromNs(timer.lap());
        ticks += 1;
        if (committed) commits += 1;
        if (ms > worst_tick_ms) worst_tick_ms = ms;
    }

    _ = timer.lap();
    const final = try chunker.finalize(take.items[chunker.consumed..], 8000);
    const stop_ms = msFromNs(timer.lap());
    defer allocator.free(final);

    std.debug.print(
        \\  streaming simulation ({d:.1}s take, {d} utterances):
        \\  ticks:        {d} (250ms cadence), {d} commits
        \\  worst tick:   {d:.0} ms (must stay well under the cadence)
        \\  stop-to-text: {d:.0} ms streaming
        \\
    , .{ take_seconds, utterances, ticks, commits, worst_tick_ms, stop_ms });

    // Agreement with the batch output needs no ground truth and directly
    // measures what VAD chunking costs (the NeMo compare-vs-offline pattern):
    // a seam bug that drops or duplicates words at utterance boundaries
    // shows up here even on audio we have no reference for. Skipped in quick
    // mode: the comparison costs a second full-take inference.
    if (!quick) {
        _ = timer.lap();
        const batch = ctx.transcribe(allocator, take.items) catch fatal("batch transcription failed", .{});
        defer allocator.free(batch);
        const batch_ms = msFromNs(timer.lap());
        std.debug.print("  batch comparison: {d:.0} ms ({d:.1}x slower than streaming stop)\n", .{ batch_ms, batch_ms / stop_ms });
        const divergence = try wer.wordErrorRate(allocator, final, batch);
        std.debug.print("  streaming vs batch divergence: {d:.1}%\n", .{divergence * 100.0});
    }

    // The take repeats the utterance, so the reference repeats with it.
    var wer_pct: ?f64 = null;
    if (reference) |ref| {
        var ref_repeated: std.ArrayList(u8) = .empty;
        defer ref_repeated.deinit(allocator);
        for (0..utterances) |i| {
            if (i != 0) try ref_repeated.append(allocator, ' ');
            try ref_repeated.appendSlice(allocator, ref);
        }
        wer_pct = try scoreWer(allocator, final, ref_repeated.items);
    }
    std.debug.print("\ntranscript:{s}\n", .{final});

    var failed = false;
    checkWerGate(wer_pct, assert_wer, &failed);
    if (failed) std.process.exit(1);
}
