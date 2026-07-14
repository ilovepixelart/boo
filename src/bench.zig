// Transcription performance benchmark.
//
//   zig build bench                        # GPU, defaults
//   zig build bench -- --cpu               # CPU baseline for comparison
//   zig build bench -- --runs 10           # more warm iterations
//   zig build bench -- --assert-rtf 20     # exit 1 if median falls below 20x
//   zig build bench -- --stream            # VAD-chunked streaming vs batch
//   zig build bench -- <model.bin> <audio.wav>
//
// Defaults: ~/.boo/models/ggml-base.en.bin and the jfk.wav sample that ships
// inside the whisper.cpp package, so a fresh checkout can bench with no setup
// beyond downloading the model.
//
// The cold run is reported separately: on Metal it includes one-time shader
// pipeline compilation that steady-state dictation never pays again.

const std = @import("std");
const whisper = @import("whisper.zig");
const wav = @import("wav.zig");
const stream = @import("stream.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("time.h");
});

const WHISPER_SAMPLE_RATE = 16000;
const DEFAULT_WARM_RUNS = 5;
const MAX_WAV_BYTES = 512 * 1024 * 1024;

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

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cpu")) {
            use_gpu = false;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            stream_mode = true;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            const v = args.next() orelse fatal("--runs needs a number", .{});
            warm_runs = std.fmt.parseInt(usize, v, 10) catch fatal("bad --runs value: {s}", .{v});
            if (warm_runs == 0) fatal("--runs must be at least 1", .{});
        } else if (std.mem.eql(u8, arg, "--assert-rtf")) {
            const v = args.next() orelse fatal("--assert-rtf needs a number", .{});
            assert_rtf = std.fmt.parseFloat(f64, v) catch fatal("bad --assert-rtf value: {s}", .{v});
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

    const model_path = model_arg orelse blk: {
        const home = std.c.getenv("HOME") orelse fatal("no HOME and no model path given", .{});
        const joined = try std.mem.concat(allocator, u8, &.{ std.mem.span(home), "/.boo/models/ggml-base.en.bin" });
        defer allocator.free(joined);
        break :blk try allocator.dupeZ(u8, joined);
    };
    const wav_path = wav_arg orelse try allocator.dupeZ(u8, build_options.jfk_wav);

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
    whisper.setLogSilent();

    var timer = Timer.start();
    var ctx = whisper.WhisperContext.init(model_path, .{ .use_gpu = use_gpu }) catch
        fatal("cannot load model {s}\nDownload one first:\n  mkdir -p ~/.boo/models\n  curl -L -o ~/.boo/models/ggml-base.en.bin \\\n    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin", .{model_path});
    defer ctx.deinit();
    const load_ns = timer.lap();

    std.debug.print(
        \\Boo transcription benchmark
        \\  model:  {s}
        \\  audio:  {s} ({d:.1}s)
        \\  device: {s}
        \\
        \\  model load: {d:.0} ms
        \\
    , .{ model_path, wav_path, audio_seconds, if (use_gpu) "gpu" else "cpu", msFromNs(load_ns) });

    if (stream_mode) {
        try runStreamBench(allocator, &ctx, samples);
        return;
    }

    // Cold run: includes Metal pipeline warm-up, worth knowing but not
    // representative of dictation steady state.
    _ = timer.lap();
    const cold_text = ctx.transcribe(allocator, samples) catch fatal("transcription failed", .{});
    const cold_ns = timer.lap();
    if (cold_text.len == 0) fatal("empty transcript; model or audio is broken", .{});
    std.debug.print("  cold run:   {d:.0} ms (includes backend warm-up)\n", .{msFromNs(cold_ns)});

    const times = try allocator.alloc(u64, warm_runs);
    defer allocator.free(times);
    std.debug.print("  warm runs: ", .{});
    for (times) |*t| {
        _ = timer.lap();
        const text = ctx.transcribe(allocator, samples) catch fatal("transcription failed", .{});
        t.* = timer.lap();
        allocator.free(text);
        std.debug.print(" {d:.0}", .{msFromNs(t.*)});
    }
    std.debug.print(" ms\n", .{});

    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const median_ms = msFromNs(times[times.len / 2]);
    const rtf = audio_seconds * std.time.ms_per_s / median_ms;
    std.debug.print("  median:     {d:.0} ms -> {d:.1}x realtime\n\ntranscript:{s}\n", .{ median_ms, rtf, cold_text });
    allocator.free(cold_text);

    if (assert_rtf) |threshold| {
        if (rtf < threshold) {
            std.debug.print("\nFAIL: {d:.1}x realtime is below the required {d:.1}x\n", .{ rtf, threshold });
            std.process.exit(1);
        }
        std.debug.print("\nOK: {d:.1}x realtime meets the required {d:.1}x\n", .{ rtf, threshold });
    }
}

/// Simulate a dictation session: several utterances separated by pauses,
/// fed to the VAD chunker in 250ms ticks exactly as a frontend would, then
/// "stop". The number that matters is stop-to-text: what the user waits for
/// after releasing the hotkey, streaming vs batch.
fn runStreamBench(allocator: std.mem.Allocator, ctx: *whisper.WhisperContext, utterance: []const f32) !void {
    const home = std.c.getenv("HOME") orelse fatal("no HOME; cannot find VAD model", .{});
    const vad_joined = try std.mem.concat(allocator, u8, &.{ std.mem.span(home), "/.boo/models/ggml-silero-v6.2.0.bin" });
    defer allocator.free(vad_joined);
    const vad_path = try allocator.dupeZ(u8, vad_joined);
    defer allocator.free(vad_path);

    var vad = whisper.Vad.init(vad_path) catch
        fatal("cannot load VAD model {s}\nDownload it first:\n  curl -L -o ~/.boo/models/ggml-silero-v6.2.0.bin \\\n    https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin", .{vad_path});
    defer vad.deinit();

    // The take: three utterances with 1.5s pauses, stop right at speech end.
    const gap = WHISPER_SAMPLE_RATE * 3 / 2;
    var take: std.ArrayList(f32) = .empty;
    defer take.deinit(allocator);
    for (0..3) |i| {
        if (i != 0) try take.appendNTimes(allocator, 0.0, gap);
        try take.appendSlice(allocator, utterance);
    }
    const take_seconds = @as(f64, @floatFromInt(take.items.len)) / WHISPER_SAMPLE_RATE;

    // Pay the backend warm-up outside the measurements.
    const warmup = ctx.transcribe(allocator, utterance) catch fatal("warm-up transcription failed", .{});
    allocator.free(warmup);

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

    _ = timer.lap();
    const batch = ctx.transcribe(allocator, take.items) catch fatal("batch transcription failed", .{});
    const batch_ms = msFromNs(timer.lap());
    allocator.free(batch);

    std.debug.print(
        \\  streaming simulation ({d:.1}s take, 3 utterances):
        \\  ticks:        {d} (250ms cadence), {d} commits
        \\  worst tick:   {d:.0} ms (must stay well under the cadence)
        \\  stop-to-text: {d:.0} ms streaming vs {d:.0} ms batch ({d:.1}x faster)
        \\
        \\transcript:{s}
        \\
    , .{ take_seconds, ticks, commits, worst_tick_ms, stop_ms, batch_ms, batch_ms / stop_ms, final });
}
