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

    pub fn init(model_path: [:0]const u8) !WhisperContext {
        var params = c.whisper_context_default_params();
        params.use_gpu = true; // Metal GPU acceleration on Apple Silicon
        params.flash_attn = false;
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
        params.language = language();
        params.n_threads = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));

        const result = c.whisper_full(self.ctx, params, samples.ptr, @intCast(samples.len));
        if (result != 0) return error.TranscriptionFailed;

        const n_segments = c.whisper_full_n_segments(self.ctx);
        var text: std.ArrayListAligned(u8, null) = .empty;
        errdefer text.deinit(allocator);

        for (0..@intCast(n_segments)) |i| {
            const segment_text = c.whisper_full_get_segment_text(self.ctx, @intCast(i));
            if (segment_text != null) {
                const slice = std.mem.span(segment_text);
                try text.appendSlice(allocator, slice);
            }
        }

        return text.toOwnedSlice(allocator);
    }
};
