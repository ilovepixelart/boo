const std = @import("std");
const Whisper = @import("whisper.zig").WhisperContext;
const AudioCapture = @import("audio.zig").AudioCapture;

const WAVEFORM_BARS = @import("audio.zig").WAVEFORM_BARS;
const MIN_AUDIO_SAMPLES = 8000; // ~0.5s at 16kHz

const BooContext = struct {
    whisper: Whisper,
    audio: *AudioCapture,
    allocator: std.mem.Allocator,
    transcribing: bool = false,
    /// Owned null-terminated transcript string, or null if none.
    last_transcript: ?[]u8 = null,
    waveform_buf: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS,

    fn freeTranscript(self: *BooContext) void {
        if (self.last_transcript) |t| {
            self.allocator.free(t);
            self.last_transcript = null;
        }
    }
};

const c_allocator = std.heap.c_allocator;

export fn boo_init(model_path: [*:0]const u8) ?*BooContext {
    const ctx = c_allocator.create(BooContext) catch return null;
    errdefer c_allocator.destroy(ctx);

    const path: [:0]const u8 = std.mem.span(model_path);
    var whisper = Whisper.init(path) catch return null;
    errdefer whisper.deinit();

    const audio = AudioCapture.init(c_allocator) catch return null;

    ctx.* = .{
        .whisper = whisper,
        .audio = audio,
        .allocator = c_allocator,
    };
    return ctx;
}

export fn boo_deinit(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.freeTranscript();
    c.audio.deinit();
    c.whisper.deinit();
    c.allocator.destroy(c);
}

export fn boo_start_recording(ctx: ?*BooContext) void {
    const c = ctx orelse return;
    c.freeTranscript();
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
    if (out_bars) |p| p.* = WAVEFORM_BARS;
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

    const samples = c.audio.getAudioData(c.allocator) catch return null;
    defer c.allocator.free(samples);

    if (samples.len < MIN_AUDIO_SAMPLES) return null;

    const text = c.whisper.transcribe(c.allocator, samples) catch return null;

    if (text.len == 0) {
        c.allocator.free(text);
        return null;
    }

    // Allocate null-terminated copy: text + null byte as one contiguous allocation
    const buf = c.allocator.alloc(u8, text.len + 1) catch {
        c.allocator.free(text);
        return null;
    };
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    c.allocator.free(text);

    // Replace previous transcript
    c.freeTranscript();
    c.last_transcript = buf;

    return @ptrCast(buf.ptr);
}
