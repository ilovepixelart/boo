const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});

pub const WhisperContext = struct {
    ctx: *c.whisper_context,

    pub fn init(model_path: [:0]const u8) !WhisperContext {
        var params = c.whisper_context_default_params();
        params.use_gpu = false; // CPU only — no Metal dependency
        params.flash_attn = false;
        const ctx = c.whisper_init_from_file_with_params(model_path.ptr, params);
        if (ctx == null) return error.ModelLoadFailed;
        return .{ .ctx = ctx.? };
    }

    pub fn deinit(self: *WhisperContext) void {
        c.whisper_free(self.ctx);
    }

    /// Transcribe PCM f32 audio at 16kHz mono. Returns allocated string.
    pub fn transcribe(self: *WhisperContext, allocator: std.mem.Allocator, samples: []const f32) ![]const u8 {
        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        params.print_progress = false;
        params.print_special = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.single_segment = false;
        params.language = "en";
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
