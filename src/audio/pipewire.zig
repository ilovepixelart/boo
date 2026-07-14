// PipeWire audio backend for Linux. Mirrors the CoreAudio backend's surface.
//
// Threading model: PipeWire's pw_thread_loop spawns its own realtime thread that
// runs the event loop and invokes onProcess() on each buffer. We protect shared
// state (audio_buf, preroll, recording flag, waveform) with a pthread mutex
// shared with the rest of the audio module (see common.zig).

const std = @import("std");
const common = @import("common.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("spa/param/audio/format-utils.h");
    @cInclude("spa/pod/builder.h");
    @cInclude("audio/pipewire_glue.h");
});

const WHISPER_SAMPLE_RATE = common.WHISPER_SAMPLE_RATE;
const WAVEFORM_BARS = common.WAVEFORM_BARS;
const PREROLL_SAMPLES = common.PREROLL_SAMPLES;

const FORMAT_BUF_SIZE: usize = 1024;

pub const AudioCapture = struct {
    loop: ?*c.pw_thread_loop = null,
    stream: ?*c.pw_stream = null,
    pw_initialized: bool = false,
    stream_listener: c.spa_hook = undefined,
    stream_events: c.pw_stream_events = std.mem.zeroes(c.pw_stream_events),

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
        c.pw_init(null, null);
        self.pw_initialized = true;
        errdefer if (self.pw_initialized) c.pw_deinit();

        self.loop = c.pw_thread_loop_new("boo-audio", null) orelse return error.ThreadLoopCreateFailed;
        errdefer if (self.loop) |l| c.pw_thread_loop_destroy(l);

        // Configure event callbacks. We zero-init the struct above so unused
        // callbacks remain null pointers.
        self.stream_events.version = c.PW_VERSION_STREAM_EVENTS;
        self.stream_events.process = onProcess;
        self.stream_events.state_changed = onStateChanged;

        // Stream metadata properties, tells PipeWire how to route us.
        const props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Communication",
            c.PW_KEY_NODE_NAME,
            "Boo",
            @as(?*const anyopaque, null),
        ) orelse return error.PropertiesAllocFailed;
        // pw_stream_new_simple takes ownership of `props`, so no defer-free.

        c.pw_thread_loop_lock(self.loop.?);
        defer c.pw_thread_loop_unlock(self.loop.?);

        self.stream = c.pw_stream_new_simple(
            c.pw_thread_loop_get_loop(self.loop.?),
            "Boo Capture",
            props,
            &self.stream_events,
            self,
        ) orelse return error.StreamCreateFailed;
        errdefer if (self.stream) |s| c.pw_stream_destroy(s);

        // Build the format param using the C glue helper.
        var format_buffer: [FORMAT_BUF_SIZE]u8 = undefined;
        var builder: c.spa_pod_builder = undefined;
        c.spa_pod_builder_init(&builder, &format_buffer, format_buffer.len);

        var params: [1]?*const c.spa_pod = .{
            c.boo_pw_build_f32_mono_format(&builder, WHISPER_SAMPLE_RATE),
        };
        if (params[0] == null) return error.FormatBuildFailed;

        // Connect inactive, mic stays off until warmUp() / startRecording().
        const flags = c.PW_STREAM_FLAG_AUTOCONNECT |
            c.PW_STREAM_FLAG_MAP_BUFFERS |
            c.PW_STREAM_FLAG_RT_PROCESS |
            c.PW_STREAM_FLAG_INACTIVE;

        const rc = c.pw_stream_connect(
            self.stream.?,
            c.PW_DIRECTION_INPUT,
            c.PW_ID_ANY,
            flags,
            &params,
            params.len,
        );
        if (rc < 0) return error.StreamConnectFailed;

        if (c.pw_thread_loop_start(self.loop.?) < 0) return error.ThreadLoopStartFailed;

        return self;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.loop) |l| {
            c.pw_thread_loop_stop(l);
            if (self.stream) |s| {
                c.pw_thread_loop_lock(l);
                c.pw_stream_destroy(s);
                c.pw_thread_loop_unlock(l);
            }
            c.pw_thread_loop_destroy(l);
        }
        if (self.pw_initialized) c.pw_deinit();

        self.capture.deinit();
        self.allocator.destroy(self);
    }

    fn setStreamActive(self: *AudioCapture, active: bool) void {
        const loop = self.loop orelse return;
        c.pw_thread_loop_lock(loop);
        defer c.pw_thread_loop_unlock(loop);
        if (self.stream) |s| _ = c.pw_stream_set_active(s, active);
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

        const pw_buffer = c.pw_stream_dequeue_buffer(stream) orelse return;
        const spa_buf = pw_buffer.*.buffer;
        if (spa_buf == null or spa_buf.*.n_datas == 0) {
            _ = c.pw_stream_queue_buffer(stream, pw_buffer);
            return;
        }

        const data = &spa_buf.*.datas[0];
        if (data.data == null or data.chunk == null) {
            _ = c.pw_stream_queue_buffer(stream, pw_buffer);
            return;
        }

        const n_samples: usize = data.chunk.*.size / @sizeOf(f32);
        const samples: [*]const f32 = @ptrCast(@alignCast(data.data));

        // Everything that happens to these samples, preroll, the recording cap,
        // the waveform, is shared with the CoreAudio backend.
        self.capture.push(samples[0..n_samples]);

        _ = c.pw_stream_queue_buffer(stream, pw_buffer);
    }

    fn onStateChanged(
        _: ?*anyopaque,
        _: c.pw_stream_state,
        _: c.pw_stream_state,
        _: [*c]const u8,
    ) callconv(.c) void {
        // Reserved for diagnostics. State transitions are surfaced via
        // pw_stream_get_state(stream, &error) when needed.
    }
};
