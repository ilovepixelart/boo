// Minimal RIFF/WAVE reader for the benchmark harness. Parses only what a
// whisper input needs: 16-bit PCM, and enough chunk-walking to find fmt/data
// wherever they sit (some encoders put LIST or fact chunks in between).

const std = @import("std");

pub const ParseError = error{
    NotRiff,
    NoFmtChunk,
    NoDataChunk,
    UnsupportedFormat,
    Truncated,
};

pub const Wav = struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    /// Raw little-endian PCM16 payload of the data chunk.
    data: []const u8,

    pub fn sampleCount(self: Wav) usize {
        return self.data.len / 2 / self.channels;
    }

    pub fn durationSeconds(self: Wav) f64 {
        return @as(f64, @floatFromInt(self.sampleCount())) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

pub fn parse(bytes: []const u8) ParseError!Wav {
    if (bytes.len < 12 or
        !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotRiff;

    var sample_rate: ?u32 = null;
    var channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var data: ?[]const u8 = null;

    var i: usize = 12;
    while (i + 8 <= bytes.len) {
        const id = bytes[i .. i + 4];
        const size = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        const payload_start = i + 8;
        // Phrased so an attacker-controlled size can't overflow the addition
        // (payload_start <= bytes.len is guaranteed by the loop condition).
        if (size > bytes.len - payload_start) return error.Truncated;
        const payload = bytes[payload_start .. payload_start + size];

        if (std.mem.eql(u8, id, "fmt ")) {
            if (payload.len < 16) return error.Truncated;
            const audio_format = std.mem.readInt(u16, payload[0..2], .little);
            if (audio_format != 1) return error.UnsupportedFormat; // PCM only
            channels = std.mem.readInt(u16, payload[2..4], .little);
            sample_rate = std.mem.readInt(u32, payload[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, payload[14..16], .little);
            if (bits_per_sample != 16) return error.UnsupportedFormat;
        } else if (std.mem.eql(u8, id, "data")) {
            data = payload;
        }

        // Chunks are word-aligned; odd sizes carry a pad byte.
        i = payload_start + size + (size & 1);
    }

    return .{
        .sample_rate = sample_rate orelse return error.NoFmtChunk,
        .channels = channels,
        .bits_per_sample = bits_per_sample,
        .data = data orelse return error.NoDataChunk,
    };
}

/// Convert the PCM16 payload to f32 samples in [-1, 1), interleaved as-is.
/// Caller owns the returned slice.
pub fn toF32(allocator: std.mem.Allocator, wav: Wav) ![]f32 {
    const n = wav.data.len / 2;
    const out = try allocator.alloc(f32, n);
    for (0..n) |s| {
        const v = std.mem.readInt(i16, wav.data[s * 2 ..][0..2], .little);
        out[s] = @as(f32, @floatFromInt(v)) / 32768.0;
    }
    return out;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a canonical little WAV in memory: header + fmt + data.
fn makeWav(comptime samples: []const i16) [44 + samples.len * 2]u8 {
    var buf: [44 + samples.len * 2]u8 = undefined;
    const data_size: u32 = samples.len * 2;
    buf[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    buf[8..12].* = "WAVE".*;
    buf[12..16].* = "fmt ".*;
    std.mem.writeInt(u32, buf[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buf[24..28], 16000, .little); // sample rate
    std.mem.writeInt(u32, buf[28..32], 32000, .little); // byte rate
    std.mem.writeInt(u16, buf[32..34], 2, .little); // block align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits
    buf[36..40].* = "data".*;
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    for (samples, 0..) |v, s| {
        std.mem.writeInt(i16, buf[44 + s * 2 ..][0..2], v, .little);
    }
    return buf;
}

test "parse: canonical 16kHz mono PCM16" {
    const buf = makeWav(&.{ 0, 16384, -16384, 32767 });
    const wav = try parse(&buf);
    try testing.expectEqual(@as(u32, 16000), wav.sample_rate);
    try testing.expectEqual(@as(u16, 1), wav.channels);
    try testing.expectEqual(@as(u16, 16), wav.bits_per_sample);
    try testing.expectEqual(@as(usize, 4), wav.sampleCount());
}

test "toF32: values land in [-1, 1) with correct scaling" {
    const buf = makeWav(&.{ 0, 16384, -32768 });
    const wav = try parse(&buf);
    const samples = try toF32(testing.allocator, wav);
    defer testing.allocator.free(samples);
    try testing.expectApproxEqAbs(@as(f32, 0.0), samples[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), samples[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), samples[2], 0.0001);
}

test "parse: rejects non-RIFF garbage" {
    try testing.expectError(error.NotRiff, parse("not a wav file at all........"));
}

test "parse: rejects a truncated data chunk rather than reading past the end" {
    var buf = makeWav(&.{ 1, 2, 3, 4 });
    // Claim more data than the file holds.
    std.mem.writeInt(u32, buf[40..44], 9999, .little);
    try testing.expectError(error.Truncated, parse(&buf));
}

test "parse: duration math" {
    const buf = makeWav(&([_]i16{0} ** 1600)); // 0.1s at 16kHz
    const wav = try parse(&buf);
    try testing.expectApproxEqAbs(@as(f64, 0.1), wav.durationSeconds(), 0.0001);
}

test "parse: survives hostile bytes without crashing" {
    // RIFF chunk walkers are a recurring real-world bug class: unchecked
    // chunk sizes and truncated fields caused heap overflows in dr_wav
    // (miniaudio #1101) and the 2024 GGUF CVE cluster followed the same
    // untrusted-length pattern. parse() must return an error for any garbage,
    // never read out of bounds (the test runner's checked builds would trap).
    var prng = std.Random.DefaultPrng.init(0xb00);
    const random = prng.random();

    // Pure noise, various sizes including the header-boundary edges.
    var noise: [512]u8 = undefined;
    for (0..2000) |_| {
        const len = random.intRangeAtMost(usize, 0, noise.len);
        random.bytes(noise[0..len]);
        _ = parse(noise[0..len]) catch continue;
    }

    // Structured attack: a valid WAV with random bytes stomped over it, so
    // the walker gets plausible magic values with corrupt sizes and offsets.
    const valid = makeWav(&([_]i16{ 100, -200, 300, -400 } ** 8));
    var corrupt: [valid.len]u8 = undefined;
    for (0..2000) |_| {
        corrupt = valid;
        for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
            corrupt[random.intRangeAtMost(usize, 0, corrupt.len - 1)] = random.int(u8);
        }
        const wav = parse(&corrupt) catch continue;
        // Whatever parsed must still be self-consistent enough to convert.
        const samples = toF32(testing.allocator, wav) catch continue;
        testing.allocator.free(samples);
    }
}
