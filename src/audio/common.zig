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
