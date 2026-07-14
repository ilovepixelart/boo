// Audio constants, helpers, and a thin Mutex shim shared across all platform backends.

const std = @import("std");

pub const WHISPER_SAMPLE_RATE: u32 = 16000;
pub const WAVEFORM_BARS: usize = 40;

pub const PREROLL_SAMPLES: usize = WHISPER_SAMPLE_RATE / 2; // 500ms
pub const PEAK_DECAY_FACTOR: f32 = 0.995; // ~1s half-life

// pthread-backed mutex. `std.Thread.Mutex` was removed in Zig 0.16 in favor of
// `std.Io.Mutex`, which threads an Io context through every call site — too
// invasive for our audio callback path. pthread works on macOS and Linux alike.
pub const Mutex = struct {
    handle: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.handle);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.handle);
    }
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

// ── tests ────────────────────────────────────────────────────────────────────
// These run on every platform: the maths here is pure, and it drives the
// waveform the user actually watches while dictating.

const testing = std.testing;

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
    // display as silence — otherwise the meter lags behind what's being said.
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
