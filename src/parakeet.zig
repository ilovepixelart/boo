const std = @import("std");
const c = @cImport({
    @cInclude("parakeet.h");
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

/// Silence parakeet's logging; same rationale as whisper.setLogSilent.
pub fn setLogSilent() void {
    c.parakeet_log_set(silentLog, null);
}

/// NVIDIA Parakeet TDT via whisper.cpp's parakeet library (shipped since
/// v1.9.0, same ggml runtime and backends). Compared to whisper models it
/// decodes roughly an order of magnitude faster at comparable accuracy,
/// which is why fast dictation apps converged on it.
pub const ParakeetContext = struct {
    ctx: *c.parakeet_context,

    pub const Options = struct {
        use_gpu: bool = true,
    };

    pub fn init(model_path: [:0]const u8, options: Options) !ParakeetContext {
        var params = c.parakeet_context_default_params();
        params.use_gpu = options.use_gpu;
        const ctx = c.parakeet_init_from_file_with_params(model_path.ptr, params) orelse
            return error.ModelLoadFailed;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *ParakeetContext) void {
        c.parakeet_free(self.ctx);
    }

    /// Transcribe PCM f32 audio at 16kHz mono. Returns allocated string.
    ///
    /// Parakeet TDT v3 is multilingual (25 European languages) with automatic
    /// language detection and no language parameter, so unlike the whisper
    /// engine, $BOO_LANG has no effect here.
    pub fn transcribe(self: *ParakeetContext, allocator: std.mem.Allocator, samples: []const f32) ![]const u8 {
        var params = c.parakeet_full_default_params(c.PARAKEET_SAMPLING_GREEDY);
        params.n_threads = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));

        const result = c.parakeet_full(self.ctx, params, samples.ptr, @intCast(samples.len));
        if (result != 0) return error.TranscriptionFailed;

        const n_segments = c.parakeet_full_n_segments(self.ctx);
        var text: std.ArrayListAligned(u8, null) = .empty;
        errdefer text.deinit(allocator);

        for (0..@intCast(n_segments)) |i| {
            const segment_text = c.parakeet_full_get_segment_text(self.ctx, @intCast(i));
            if (segment_text != null) {
                try text.appendSlice(allocator, std.mem.span(segment_text));
            }
        }

        return text.toOwnedSlice(allocator);
    }
};
