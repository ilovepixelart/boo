// PipeWire audio backend for Linux. Mirrors the CoreAudio backend's surface.
//
// Threading model: PipeWire's pw_thread_loop spawns its own realtime thread that
// runs the event loop and invokes onProcess() on each buffer. We protect shared
// state (audio_buf, preroll, recording flag, waveform) with a pthread mutex
// shared with the rest of the audio module (see common.zig).
//
// All PipeWire/SPA API use lives behind pipewire_glue.h; the real headers
// break Zig's translate-c (see the glue header for the details).

const std = @import("std");
const common = @import("common.zig");

const c = @cImport({
    @cInclude("audio/pipewire_glue.h");
});

const WHISPER_SAMPLE_RATE = common.WHISPER_SAMPLE_RATE;
const WAVEFORM_BARS = common.WAVEFORM_BARS;

pub const AudioCapture = struct {
    loop: ?*c.boo_pw_thread_loop = null,
    stream: ?*c.boo_pw_stream = null,
    pw_initialized: bool = false,

    /// Buffers, locking, preroll and the recording cap, shared with the
    /// CoreAudio backend so the two cannot drift apart. See common.Capture.
    capture: common.Capture,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*AudioCapture {
        const self = try allocator.create(AudioCapture);
        errdefer allocator.destroy(self);
        self.* = .{
            .capture = .{ .allocator = allocator },
            .allocator = allocator,
        };

        // Initialize PipeWire library (refcounted internally, safe to call repeatedly)
        c.boo_pw_init();
        self.pw_initialized = true;
        errdefer if (self.pw_initialized) c.boo_pw_deinit();

        self.loop = c.boo_pw_thread_loop_new("boo-audio") orelse return error.ThreadLoopCreateFailed;
        errdefer if (self.loop) |l| c.boo_pw_thread_loop_destroy(l);

        c.boo_pw_thread_loop_lock(self.loop.?);
        defer c.boo_pw_thread_loop_unlock(self.loop.?);

        // Connects inactive, the mic stays off until warmUp() / startRecording().
        self.stream = c.boo_pw_capture_stream_new(
            self.loop.?,
            "Boo Capture",
            WHISPER_SAMPLE_RATE,
            onProcess,
            self,
        ) orelse return error.StreamCreateFailed;
        errdefer if (self.stream) |s| c.boo_pw_capture_stream_destroy(s);

        if (c.boo_pw_thread_loop_start(self.loop.?) < 0) return error.ThreadLoopStartFailed;

        return self;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.loop) |l| {
            c.boo_pw_thread_loop_stop(l);
            if (self.stream) |s| {
                c.boo_pw_thread_loop_lock(l);
                c.boo_pw_capture_stream_destroy(s);
                c.boo_pw_thread_loop_unlock(l);
            }
            c.boo_pw_thread_loop_destroy(l);
        }
        if (self.pw_initialized) c.boo_pw_deinit();

        self.capture.deinit();
        self.allocator.destroy(self);
    }

    fn setStreamActive(self: *AudioCapture, active: bool) void {
        const loop = self.loop orelse return;
        c.boo_pw_thread_loop_lock(loop);
        defer c.boo_pw_thread_loop_unlock(loop);
        if (self.stream) |s| _ = c.boo_pw_stream_set_active(s, active);
    }

    /// Warm up the mic, activate the stream but stay in preroll mode.
    /// Call ~500ms before startRecording() to eliminate cold-start lag.
    pub fn warmUp(self: *AudioCapture) void {
        self.capture.reserve(WHISPER_SAMPLE_RATE * 60);
        self.setStreamActive(true);
        // onProcess runs, but `recording` is false, so samples land in preroll.
    }

    pub fn startRecording(self: *AudioCapture) void {
        self.setStreamActive(true); // no-op if warmUp already did it
        self.capture.begin();
    }

    pub fn stopRecording(self: *AudioCapture) void {
        self.capture.end();
        self.setStreamActive(false); // mic off
    }

    pub fn getAudioData(self: *AudioCapture, allocator: std.mem.Allocator) ![]f32 {
        return self.capture.takeAudio(allocator);
    }

    pub fn copyAudioFrom(self: *AudioCapture, allocator: std.mem.Allocator, start: usize) ![]f32 {
        return self.capture.copyFrom(allocator, start);
    }

    pub fn getWaveform(self: *AudioCapture) [WAVEFORM_BARS]f32 {
        return self.capture.getWaveform();
    }

    pub fn getPeakRms(self: *AudioCapture) f32 {
        return self.capture.getPeakRms();
    }

    pub fn isRecording(self: *AudioCapture) bool {
        return self.capture.isRecording();
    }

    pub fn sampleCount(self: *AudioCapture) usize {
        return self.capture.sampleCount();
    }

    fn onProcess(user_data: ?*anyopaque) callconv(.c) void {
        const self: *AudioCapture = @ptrCast(@alignCast(user_data));
        const stream = self.stream orelse return;

        var samples: [*c]const f32 = null;
        var n_samples: usize = 0;
        const buffer = c.boo_pw_stream_dequeue_buffer(stream, &samples, &n_samples) orelse return;

        // Everything that happens to these samples, preroll, the recording cap,
        // the waveform, is shared with the CoreAudio backend.
        if (n_samples > 0) self.capture.push(samples[0..n_samples]);

        c.boo_pw_stream_queue_buffer(stream, buffer);
    }
};
