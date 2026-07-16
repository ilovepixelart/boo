// Audio constants, helpers, and a thin Mutex shim shared across all platform backends.

const std = @import("std");
const builtin = @import("builtin");

pub const WHISPER_SAMPLE_RATE: u32 = 16000;
pub const WAVEFORM_BARS: usize = 40;

pub const PREROLL_SAMPLES: usize = WHISPER_SAMPLE_RATE / 2; // 500ms
pub const PEAK_DECAY_FACTOR: f32 = 0.995; // ~1s half-life

/// Hard cap on a single recording.
///
/// The capture buffer is otherwise unbounded (~3.8MB/min), and boo_transcribe
/// runs whisper synchronously over the whole of it, so a recording left running
/// by accident would balloon memory and then freeze the app for minutes. On
/// reaching the cap the backend simply stops capturing; the frontends poll
/// boo_is_recording(), notice, and transcribe what was captured. Nothing is
/// silently discarded, and the user sees the recording end rather than the app
/// hang.
pub const MAX_RECORDING_SECONDS: usize = 600; // 10 minutes
pub const MAX_RECORDING_SAMPLES: usize = WHISPER_SAMPLE_RATE * MAX_RECORDING_SECONDS;

/// How many of `incoming` samples may still be appended before hitting the cap.
/// Returns 0 once the buffer is full, so the audio callback can stop cleanly on
/// an exact boundary rather than overshooting by a buffer.
pub fn samplesUntilCap(captured: usize, incoming: usize) usize {
    if (captured >= MAX_RECORDING_SAMPLES) return 0;
    return @min(MAX_RECORDING_SAMPLES - captured, incoming);
}

// OS-primitive mutex. `std.Thread.Mutex` was removed in Zig 0.16 in favor of
// `std.Io.Mutex`, which threads an Io context through every call site, too
// invasive for our audio callback path. pthread covers macOS and Linux; on
// Windows std.c has no pthread types, so that arm uses SRWLOCK: one
// zero-initialized pointer-sized word, no destroy call exists or is needed.
pub const Mutex = switch (builtin.os.tag) {
    .windows => struct {
        handle: SRWLOCK = .{},

        // Declared by hand rather than via std.os.windows.ntdll, which is not
        // a stability-guaranteed API surface.
        const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
        extern "ntdll" fn RtlAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
        extern "ntdll" fn RtlReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
        extern "ntdll" fn RtlTryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;

        pub fn lock(self: *@This()) void {
            RtlAcquireSRWLockExclusive(&self.handle);
        }

        pub fn unlock(self: *@This()) void {
            RtlReleaseSRWLockExclusive(&self.handle);
        }

        pub fn tryLock(self: *@This()) bool {
            return RtlTryAcquireSRWLockExclusive(&self.handle) != 0;
        }
    },
    else => struct {
        handle: std.c.pthread_mutex_t = .{},

        pub fn lock(self: *@This()) void {
            _ = std.c.pthread_mutex_lock(&self.handle);
        }

        pub fn unlock(self: *@This()) void {
            _ = std.c.pthread_mutex_unlock(&self.handle);
        }

        pub fn tryLock(self: *@This()) bool {
            return std.c.pthread_mutex_trylock(&self.handle) == .SUCCESS;
        }
    },
};

pub fn computeWaveform(samples: []const f32, out: *[WAVEFORM_BARS]f32) void {
    const window = WHISPER_SAMPLE_RATE / 2;
    const start = if (samples.len > window) samples.len - window else 0;
    const slice = samples[start..];

    if (slice.len == 0) {
        out.* = .{0.0} ** WAVEFORM_BARS;
        return;
    }

    const chunk_size = @max(slice.len / WAVEFORM_BARS, 1);
    for (0..WAVEFORM_BARS) |i| {
        const begin = i * chunk_size;
        const end = @min(begin + chunk_size, slice.len);
        if (begin >= slice.len) {
            out[i] = 0;
            continue;
        }
        var sum: f32 = 0;
        for (slice[begin..end]) |s| {
            sum += s * s;
        }
        const rms = @sqrt(sum / @as(f32, @floatFromInt(end - begin)));
        out[i] = @min(rms, 1.0);
    }
}

pub fn updatePeakRms(peak: *f32, waveform: *const [WAVEFORM_BARS]f32) void {
    var max_rms: f32 = 0;
    for (waveform) |v| {
        if (v > max_rms) max_rms = v;
    }
    if (max_rms > peak.*) {
        peak.* = max_rms; // instant attack
    } else {
        peak.* *= PEAK_DECAY_FACTOR; // slow decay
    }
}

/// Silence gate for transcription. Whisper hallucinates filler ("you",
/// "Thank you.") on silent input, and the no_speech_prob/avg_logprob filters
/// do not reliably catch it, so a take whose loudest window never reaches
/// this RMS floor is not decoded at all. Real speech in tests/eval bottoms
/// out at 0.07 max-window RMS; a mic at rest stays under 0.001. The floor
/// sits 14x under the quietest eval sample so it cannot eat soft speech.
pub const SILENCE_RMS_FLOOR: f32 = 0.005;
/// The gate is windowed rather than whole-take: one short word inside an
/// otherwise silent take must pass, and whole-take RMS would dilute it
/// below any workable floor.
pub const RMS_WINDOW_SAMPLES: usize = WHISPER_SAMPLE_RATE / 10; // 100ms

/// RMS of the loudest `window`-sized chunk of `samples`. 0.0 when empty.
pub fn maxWindowRms(samples: []const f32, window: usize) f32 {
    std.debug.assert(window > 0);
    var best: f32 = 0.0;
    var begin: usize = 0;
    while (begin < samples.len) : (begin += window) {
        const end = @min(begin + window, samples.len);
        var sum: f32 = 0;
        for (samples[begin..end]) |s| {
            sum += s * s;
        }
        const rms = @sqrt(sum / @as(f32, @floatFromInt(end - begin)));
        if (rms > best) best = rms;
    }
    return best;
}

/// Everything the two audio backends share: the buffers, the lock that guards
/// them, and the rules for what happens to an incoming block of samples.
///
/// CoreAudio and PipeWire differ only in how they open a device and hand us
/// audio. Everything after that, preroll, the recording cap, the waveform, the
/// mutex discipline, is identical, and when it was written out twice the two
/// copies drifted: one backend gained an errdefer the other never got, and
/// leaked. So it lives here once.
///
/// Locking: `push` is called from a realtime audio thread; every other method is
/// called from the UI thread. All of them take the mutex.
pub const Capture = struct {
    mutex: Mutex = .{},
    recording: bool = false,
    audio_buf: std.ArrayList(f32) = .empty,
    preroll: std.ArrayList(f32) = .empty,
    waveform: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS,
    peak_rms: f32 = 0.0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Capture) void {
        self.audio_buf.deinit(self.allocator);
        self.preroll.deinit(self.allocator);
    }

    /// Reserve capacity up front so the audio thread never has to reallocate.
    /// Takes the lock: growing the list moves it, and the audio thread may be
    /// appending to it at the same moment.
    pub fn reserve(self: *Capture, samples: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.audio_buf.ensureTotalCapacity(self.allocator, samples) catch {};
    }

    /// Start a take: keep the preroll (the half-second captured during warm-up,
    /// which holds the beginning of the first word) and reset the meters.
    pub fn begin(self: *Capture) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.audio_buf.clearRetainingCapacity();
        if (self.preroll.items.len > 0) {
            self.audio_buf.appendSlice(self.allocator, self.preroll.items) catch {};
            self.preroll.clearRetainingCapacity();
        }
        self.waveform = .{0.0} ** WAVEFORM_BARS;
        self.peak_rms = 0.0;
        self.recording = true;
    }

    pub fn end(self: *Capture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.recording = false;
    }

    /// Take a block of samples from the audio thread.
    ///
    /// While recording they land in the take, up to MAX_RECORDING_SAMPLES ,
    /// after which capture simply stops and the frontend, which polls
    /// isRecording(), transcribes what it has. Otherwise they roll through the
    /// preroll ring, so warm-up audio is there when recording starts.
    pub fn push(self: *Capture, samples: []const f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.recording) {
            self.preroll.appendSlice(self.allocator, samples) catch {};
            if (self.preroll.items.len > PREROLL_SAMPLES) {
                const excess = self.preroll.items.len - PREROLL_SAMPLES;
                self.preroll.replaceRange(self.allocator, 0, excess, &.{}) catch {};
            }
            return;
        }

        const take = samplesUntilCap(self.audio_buf.items.len, samples.len);
        if (take > 0) {
            self.audio_buf.appendSlice(self.allocator, samples[0..take]) catch {};
            computeWaveform(self.audio_buf.items, &self.waveform);
            updatePeakRms(&self.peak_rms, &self.waveform);
        }

        // Stopping the device from inside its own callback is unsafe, on
        // PipeWire it would deadlock on the thread-loop lock we are already
        // under, so just drop the flag and let the frontend finish up.
        if (self.audio_buf.items.len >= MAX_RECORDING_SAMPLES) {
            self.recording = false;
        }
    }

    /// Caller owns the returned slice.
    pub fn takeAudio(self: *Capture, allocator: std.mem.Allocator) ![]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const copy = try allocator.alloc(f32, self.audio_buf.items.len);
        @memcpy(copy, self.audio_buf.items);
        return copy;
    }

    /// Copy the take from `start` onward, for the streaming transcriber which
    /// has already consumed everything before its watermark. A start beyond
    /// the take yields an empty slice rather than an error: the caller races
    /// against the audio thread by design. Caller owns the returned slice.
    pub fn copyFrom(self: *Capture, allocator: std.mem.Allocator, start: usize) ![]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const items = self.audio_buf.items;
        const from = @min(start, items.len);
        const copy = try allocator.alloc(f32, items.len - from);
        @memcpy(copy, items[from..]);
        return copy;
    }

    pub fn sampleCount(self: *Capture) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.audio_buf.items.len;
    }

    pub fn getWaveform(self: *Capture) [WAVEFORM_BARS]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waveform;
    }

    pub fn getPeakRms(self: *Capture) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peak_rms;
    }

    pub fn isRecording(self: *Capture) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.recording;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────
// These run on every platform: the maths here is pure, and it drives the
// waveform the user actually watches while dictating.

const testing = std.testing;

test "maxWindowRms: empty and silent takes read zero" {
    try testing.expectEqual(@as(f32, 0.0), maxWindowRms(&.{}, RMS_WINDOW_SAMPLES));
    const silence = [_]f32{0.0} ** (WHISPER_SAMPLE_RATE * 2);
    try testing.expectEqual(@as(f32, 0.0), maxWindowRms(&silence, RMS_WINDOW_SAMPLES));
}

test "maxWindowRms: a constant signal reads back as its own amplitude" {
    const samples = [_]f32{0.05} ** (WHISPER_SAMPLE_RATE * 2);
    try testing.expectApproxEqAbs(
        @as(f32, 0.05),
        maxWindowRms(&samples, RMS_WINDOW_SAMPLES),
        0.001,
    );
}

test "maxWindowRms: one quiet word in a long silent take clears the floor" {
    // 60s of silence around a single 100ms word at 0.05. Whole-take RMS is
    // ~0.002, under the floor; the windowed maximum must still find the word.
    const samples = try testing.allocator.alloc(f32, WHISPER_SAMPLE_RATE * 60);
    defer testing.allocator.free(samples);
    @memset(samples, 0.0);
    @memset(samples[8000 .. 8000 + RMS_WINDOW_SAMPLES], 0.05);
    try testing.expect(maxWindowRms(samples, RMS_WINDOW_SAMPLES) >= SILENCE_RMS_FLOOR);
}

test "maxWindowRms: a mic at rest stays under the silence floor" {
    // Alternating +-0.001 has RMS 0.001: noise-floor input must gate rather
    // than reach the decoder, that is the hallucination this floor exists for.
    var noise: [WHISPER_SAMPLE_RATE]f32 = undefined;
    for (&noise, 0..) |*s, i| {
        s.* = if (i % 2 == 0) 0.001 else -0.001;
    }
    try testing.expect(maxWindowRms(&noise, RMS_WINDOW_SAMPLES) < SILENCE_RMS_FLOOR);
}

test "computeWaveform: silence in, silence out" {
    var bars: [WAVEFORM_BARS]f32 = .{1.0} ** WAVEFORM_BARS; // pre-dirtied
    computeWaveform(&.{}, &bars);
    for (bars) |bar| try testing.expectEqual(@as(f32, 0.0), bar);
}

test "computeWaveform: a constant signal reads back as its own amplitude" {
    // RMS of a constant is |a|, so this pins the maths, not just the shape.
    const samples = [_]f32{0.5} ** 8000;
    var bars: [WAVEFORM_BARS]f32 = undefined;
    computeWaveform(&samples, &bars);
    for (bars) |bar| try testing.expectApproxEqAbs(@as(f32, 0.5), bar, 0.001);
}

test "computeWaveform: clamps, so a loud burst cannot overdraw the UI" {
    const samples = [_]f32{9.0} ** 4000;
    var bars: [WAVEFORM_BARS]f32 = undefined;
    computeWaveform(&samples, &bars);
    for (bars) |bar| try testing.expectEqual(@as(f32, 1.0), bar);
}

test "computeWaveform: shows only the most recent 500ms" {
    // Three seconds of loud audio followed by half a second of silence must
    // display as silence, otherwise the meter lags behind what's being said.
    const window = WHISPER_SAMPLE_RATE / 2;
    var samples: [WHISPER_SAMPLE_RATE * 3]f32 = .{0.8} ** (WHISPER_SAMPLE_RATE * 3);
    @memset(samples[samples.len - window ..], 0.0);

    var bars: [WAVEFORM_BARS]f32 = undefined;
    computeWaveform(&samples, &bars);
    for (bars) |bar| try testing.expectApproxEqAbs(@as(f32, 0.0), bar, 0.001);
}

test "computeWaveform: fewer samples than bars stays in bounds" {
    // The first moments of a recording have far fewer samples than there are
    // bars; the tail must read as zero rather than off the end of the slice.
    const samples = [_]f32{1.0} ** 5;
    var bars: [WAVEFORM_BARS]f32 = undefined;
    computeWaveform(&samples, &bars);

    for (bars[0..5]) |bar| try testing.expectApproxEqAbs(@as(f32, 1.0), bar, 0.001);
    for (bars[5..]) |bar| try testing.expectEqual(@as(f32, 0.0), bar);
}

test "computeWaveform: a single sample does not divide by zero" {
    const samples = [_]f32{0.25};
    var bars: [WAVEFORM_BARS]f32 = undefined;
    computeWaveform(&samples, &bars);
    try testing.expectApproxEqAbs(@as(f32, 0.25), bars[0], 0.001);
}

test "samplesUntilCap: takes everything while there is room" {
    try testing.expectEqual(@as(usize, 1024), samplesUntilCap(0, 1024));
    try testing.expectEqual(@as(usize, 1024), samplesUntilCap(MAX_RECORDING_SAMPLES - 5000, 1024));
}

test "samplesUntilCap: truncates the final buffer to land exactly on the cap" {
    // Without this the last append would overshoot by up to one audio buffer,
    // so the cap would only be approximate.
    const nearly_full = MAX_RECORDING_SAMPLES - 100;
    try testing.expectEqual(@as(usize, 100), samplesUntilCap(nearly_full, 1024));
}

test "samplesUntilCap: refuses everything once full" {
    try testing.expectEqual(@as(usize, 0), samplesUntilCap(MAX_RECORDING_SAMPLES, 1024));
    // Defensive: must not underflow if the buffer somehow ran past the cap.
    try testing.expectEqual(@as(usize, 0), samplesUntilCap(MAX_RECORDING_SAMPLES + 999, 1024));
}

test "the recording cap is a sane duration" {
    try testing.expectEqual(@as(usize, 600), MAX_RECORDING_SECONDS);
    // ~38MB of f32, bounded, and small enough that whisper still finishes.
    try testing.expectEqual(@as(usize, 9_600_000), MAX_RECORDING_SAMPLES);
}

// The buffer rules used to live inside two hardware-driven audio callbacks, so
// they could not be tested at all. Now they can.

test "Capture: warm-up audio is kept, so the first word isn't clipped" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    // Warm-up: not recording yet, so samples roll through the preroll.
    const warm = [_]f32{0.3} ** 1000;
    cap.push(&warm);
    try testing.expectEqual(@as(usize, 0), cap.sampleCount());

    // Hitting record must carry that preroll into the take, it holds the
    // beginning of the first word.
    cap.begin();
    try testing.expectEqual(@as(usize, 1000), cap.sampleCount());
}

test "Capture: the preroll is a ring, not an unbounded buffer" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    // Idle for a long time, far more than the preroll window.
    const block = [_]f32{0.1} ** 4000;
    for (0..10) |_| cap.push(&block);

    cap.begin();
    try testing.expectEqual(PREROLL_SAMPLES, cap.sampleCount());
}

test "Capture: recording stops exactly on the cap" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    cap.begin();
    try testing.expect(cap.isRecording());

    // Push past the cap in blocks that don't divide it evenly.
    const block = [_]f32{0.4} ** 4096;
    var pushed: usize = 0;
    while (pushed < MAX_RECORDING_SAMPLES + 4096 * 2) : (pushed += block.len) {
        cap.push(&block);
    }

    try testing.expectEqual(MAX_RECORDING_SAMPLES, cap.sampleCount());
    try testing.expect(!cap.isRecording()); // auto-stopped, not still running
}

test "Capture: samples after the cap are dropped, not silently appended" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    cap.begin();
    const block = [_]f32{0.4} ** 4096;
    while (cap.isRecording()) cap.push(&block);

    const at_cap = cap.sampleCount();
    cap.push(&block); // long after the cap
    try testing.expectEqual(at_cap, cap.sampleCount());
}

test "Capture: end() stops recording but keeps the audio for transcription" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    cap.begin();
    const block = [_]f32{0.5} ** 800;
    cap.push(&block);
    cap.end();

    try testing.expect(!cap.isRecording());

    const audio = try cap.takeAudio(testing.allocator);
    defer testing.allocator.free(audio);
    try testing.expectEqual(@as(usize, 800), audio.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), audio[0], 0.0001);
}

test "Capture: copyFrom returns only the unconsumed region" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    cap.begin();
    const block = [_]f32{0.5} ** 800;
    cap.push(&block);

    const tail = try cap.copyFrom(testing.allocator, 300);
    defer testing.allocator.free(tail);
    try testing.expectEqual(@as(usize, 500), tail.len);
}

test "Capture: copyFrom past the end is empty, not an error" {
    var cap: Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();

    cap.begin();
    const block = [_]f32{0.5} ** 100;
    cap.push(&block);

    const tail = try cap.copyFrom(testing.allocator, 5000);
    defer testing.allocator.free(tail);
    try testing.expectEqual(@as(usize, 0), tail.len);
}

test "Mutex: tryLock acquires when free and fails when held" {
    var m: Mutex = .{};

    // Uncontended: acquires and can be released.
    try testing.expect(m.tryLock());
    m.unlock();

    // Contended: a second thread must see the lock as taken, without blocking.
    m.lock();
    const Prober = struct {
        fn run(mu: *Mutex, got_it: *bool) void {
            got_it.* = mu.tryLock();
            if (got_it.*) mu.unlock();
        }
    };
    var got_it = true;
    const t = try std.Thread.spawn(.{}, Prober.run, .{ &m, &got_it });
    t.join();
    try testing.expect(!got_it);
    m.unlock();

    // Released again: acquirable once more.
    try testing.expect(m.tryLock());
    m.unlock();
}

test "Mutex: provides mutual exclusion across threads" {
    // Exercises whichever OS arm this platform selected (SRWLOCK on Windows,
    // pthread elsewhere). A broken shim, a no-op lock or a bad extern, loses
    // increments here rather than corrupting a user's recording buffer.
    var m: Mutex = .{};
    var counter: usize = 0; // guarded by m

    const Worker = struct {
        fn run(mu: *Mutex, n: *usize) void {
            for (0..10_000) |_| {
                mu.lock();
                n.* += 1;
                mu.unlock();
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &counter });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 40_000), counter);
}

test "updatePeakRms: attacks instantly" {
    // The level meter must jump the moment you speak, not ease in.
    var peak: f32 = 0.0;
    var waveform: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS;
    waveform[7] = 0.9;

    updatePeakRms(&peak, &waveform);
    try testing.expectEqual(@as(f32, 0.9), peak);
}

test "updatePeakRms: decays smoothly toward zero, never below it" {
    var peak: f32 = 1.0;
    const silence: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS;

    updatePeakRms(&peak, &silence);
    try testing.expectApproxEqAbs(PEAK_DECAY_FACTOR, peak, 0.0001);

    // Long silence should approach zero without undershooting into negatives,
    // which would render as an inverted bar.
    for (0..2000) |_| updatePeakRms(&peak, &silence);
    try testing.expect(peak >= 0.0);
    try testing.expect(peak < 0.01);
}
