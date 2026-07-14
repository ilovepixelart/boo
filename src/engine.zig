// Speech-to-text engine dispatch: whisper or parakeet, chosen by model
// filename. Both ship inside the whisper.cpp package, ride the same ggml
// runtime and backends, and expose mirror-image C APIs; this union keeps the
// rest of the core engine-agnostic.

const std = @import("std");
pub const whisper = @import("whisper.zig");
pub const parakeet = @import("parakeet.zig");

/// Silence both engines' load-time logging.
pub fn setLogSilent() void {
    whisper.setLogSilent();
    parakeet.setLogSilent();
}

pub const Engine = union(enum) {
    whisper: whisper.WhisperContext,
    parakeet: parakeet.ParakeetContext,

    pub const Options = struct {
        use_gpu: bool = true,
    };

    /// Converted Parakeet models carry "parakeet" in the filename
    /// (ggml-parakeet-tdt-0.6b-v3-*.bin, per ggml-org/parakeet-GGUF);
    /// everything else is a whisper model.
    pub fn init(model_path: [:0]const u8, options: Options) !Engine {
        const basename = std.fs.path.basename(model_path);
        if (std.mem.indexOf(u8, basename, "parakeet") != null) {
            return .{ .parakeet = try parakeet.ParakeetContext.init(model_path, .{ .use_gpu = options.use_gpu }) };
        }
        return .{ .whisper = try whisper.WhisperContext.init(model_path, .{ .use_gpu = options.use_gpu }) };
    }

    pub fn deinit(self: *Engine) void {
        switch (self.*) {
            inline else => |*e| e.deinit(),
        }
    }

    /// Transcribe PCM f32 audio at 16kHz mono. Returns allocated string.
    pub fn transcribe(self: *Engine, allocator: std.mem.Allocator, samples: []const f32) ![]const u8 {
        return switch (self.*) {
            inline else => |*e| e.transcribe(allocator, samples),
        };
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Engine: routes by filename without touching the filesystem first" {
    // Both inits fail on a missing file, but the error proves which engine
    // was chosen is irrelevant; what matters is neither path crashes.
    setLogSilent();
    try testing.expectError(error.ModelLoadFailed, Engine.init("/nonexistent/ggml-base.en.bin", .{}));
    try testing.expectError(error.ModelLoadFailed, Engine.init("/nonexistent/ggml-parakeet-tdt-0.6b-v3-q8_0.bin", .{}));
}
