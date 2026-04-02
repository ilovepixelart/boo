const std = @import("std");
const Whisper = @import("whisper.zig").WhisperContext;
const AudioCapture = @import("audio.zig").AudioCapture;

const BooContext = struct {
    whisper: Whisper,
    audio: *AudioCapture,
    allocator: std.mem.Allocator,
    transcribing: bool = false,
    last_transcript: ?[:0]const u8 = null,
    waveform_buf: [40]f32 = .{0.0} ** 40,
};

// Use the C allocator for interop with Swift
const c_allocator = std.heap.c_allocator;

export fn boo_init(model_path: [*:0]const u8) ?*BooContext {
    const ctx = c_allocator.create(BooContext) catch return null;

    const path: [:0]const u8 = std.mem.span(model_path);
    const whisper = Whisper.init(path) catch return null;

    const audio = AudioCapture.init(c_allocator) catch {
        var w = whisper;
        w.deinit();
        c_allocator.destroy(ctx);
        return null;
    };

    ctx.* = .{
        .whisper = whisper,
        .audio = audio,
        .allocator = c_allocator,
    };

    return ctx;
}

export fn boo_deinit(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    if (c.last_transcript) |t| c.allocator.free(t[0 .. t.len + 1]); // free with null terminator
    c.audio.deinit();
    c.whisper.deinit();
    c.allocator.destroy(c);
}

export fn boo_start_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    // Free previous transcript
    if (c.last_transcript) |t| {
        c.allocator.free(t[0 .. t.len + 1]);
        c.last_transcript = null;
    }
    c.audio.startRecording();
}

export fn boo_stop_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.audio.stopRecording();
}

export fn boo_is_recording(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.audio.isRecording();
}

export fn boo_is_transcribing(ctx: ?*BooContext) bool {
    const c = ctx orelse return false;
    return c.transcribing;
}

export fn boo_get_waveform(ctx: ?*BooContext, out_bars: ?*c_int) ?[*]const f32 {
    const c = ctx orelse return null;
    c.waveform_buf = c.audio.getWaveform();
    if (out_bars) |p| p.* = 40;
    return &c.waveform_buf;
}

export fn boo_get_peak_rms(ctx: ?*BooContext) f32 {
    const c = ctx orelse return 0;
    return c.audio.getPeakRms();
}

export fn boo_get_audio_samples(ctx: ?*BooContext) c_int {
    const c = ctx orelse return 0;
    c.audio.mutex.lock();
    defer c.audio.mutex.unlock();
    return @intCast(c.audio.audio_buf.items.len);
}

export fn boo_transcribe(ctx: ?*BooContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    c.transcribing = true;
    defer c.transcribing = false;

    // Get audio data
    const samples = c.audio.getAudioData(c.allocator) catch return null;
    defer c.allocator.free(samples);

    if (samples.len < 8000) return null;

    // Transcribe
    const text = c.whisper.transcribe(c.allocator, samples) catch return null;

    if (text.len == 0) {
        c.allocator.free(text);
        return null;
    }

    // Convert to null-terminated string
    const result = c.allocator.allocSentinel(u8, text.len, 0) catch {
        c.allocator.free(text);
        return null;
    };
    @memcpy(result[0..text.len], text);
    c.allocator.free(text);

    // Store for later free
    if (c.last_transcript) |t| c.allocator.free(t[0 .. t.len + 1]);
    c.last_transcript = result;

    return result.ptr;
}

export fn boo_free_string(str: ?[*:0]const u8) void {
    _ = str; // Strings are freed when context is freed or new transcript replaces old
}
