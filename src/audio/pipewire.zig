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

    mutex: common.Mutex = .{},
    recording: bool = false,
    audio_buf: std.ArrayList(f32) = .empty,
    preroll: std.ArrayList(f32) = .empty,
    waveform: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS,
    peak_rms: f32 = 0.0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*AudioCapture {
        const self = try allocator.create(AudioCapture);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };

        // Initialize PipeWire library (refcounted internally — safe to call repeatedly)
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

        // Stream metadata properties — tells PipeWire how to route us.
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

        // Connect inactive — mic stays off until warmUp() / startRecording().
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

        self.audio_buf.deinit(self.allocator);
        self.preroll.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Warm up the mic — activate the stream but stay in preroll mode.
    /// Call ~500ms before startRecording() to eliminate cold-start lag.
    pub fn warmUp(self: *AudioCapture) void {
        // Reserve ~60s up front so onProcess never has to reallocate mid-stream.
        // This MUST hold the mutex: growing the buffer moves it, and the
        // PipeWire realtime thread may be appending to it at the same time — it
        // would then write through a dangling pointer. The frontends happen to
        // call warmUp only while stopped, but boo_warm_up is public C API and
        // nothing enforces that.
        self.mutex.lock();
        self.audio_buf.ensureTotalCapacity(self.allocator, WHISPER_SAMPLE_RATE * 60) catch {};
        self.mutex.unlock();

        if (self.loop) |l| {
            c.pw_thread_loop_lock(l);
            defer c.pw_thread_loop_unlock(l);
            if (self.stream) |s| _ = c.pw_stream_set_active(s, true);
        }
        // onProcess will run but `recording` is false, so samples land in preroll.
    }

    pub fn startRecording(self: *AudioCapture) void {
        if (self.loop) |l| {
            c.pw_thread_loop_lock(l);
            if (self.stream) |s| _ = c.pw_stream_set_active(s, true);
            c.pw_thread_loop_unlock(l);
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        self.audio_buf.clearRetainingCapacity();
        if (self.preroll.items.len > 0) {
            self.audio_buf.appendSlice(self.allocator, self.preroll.items) catch {};
            self.preroll.clearRetainingCapacity();
        }
        self.waveform = .{0.0} ** WAVEFORM_BARS;
        self.peak_rms = 0.0;
        self.recording = true;
    }

    pub fn stopRecording(self: *AudioCapture) void {
        self.mutex.lock();
        self.recording = false;
        self.mutex.unlock();

        if (self.loop) |l| {
            c.pw_thread_loop_lock(l);
            defer c.pw_thread_loop_unlock(l);
            if (self.stream) |s| _ = c.pw_stream_set_active(s, false);
        }
    }

    pub fn getAudioData(self: *AudioCapture, allocator: std.mem.Allocator) ![]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = try allocator.alloc(f32, self.audio_buf.items.len);
        @memcpy(copy, self.audio_buf.items);
        return copy;
    }

    pub fn getWaveform(self: *AudioCapture) [WAVEFORM_BARS]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waveform;
    }

    pub fn getPeakRms(self: *AudioCapture) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peak_rms;
    }

    pub fn isRecording(self: *AudioCapture) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.recording;
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

        const byte_size = data.chunk.*.size;
        const n_samples: usize = byte_size / @sizeOf(f32);
        const samples: [*]const f32 = @ptrCast(@alignCast(data.data));

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.recording) {
            // Stop exactly on the cap rather than overshooting by a buffer.
            const take = common.samplesUntilCap(self.audio_buf.items.len, n_samples);
            if (take > 0) {
                self.audio_buf.appendSlice(self.allocator, samples[0..take]) catch {};
                common.computeWaveform(self.audio_buf.items, &self.waveform);
                common.updatePeakRms(&self.peak_rms, &self.waveform);
            }
            if (self.audio_buf.items.len >= common.MAX_RECORDING_SAMPLES) {
                // Cap reached. Just drop the recording flag — the frontend polls
                // isRecording(), notices, and transcribes what we captured.
                // Deactivating the stream from inside the realtime callback
                // would deadlock on the thread-loop lock, so leave that to the
                // frontend's stopRecording().
                self.recording = false;
            }
        } else {
            self.preroll.appendSlice(self.allocator, samples[0..n_samples]) catch {};
            if (self.preroll.items.len > PREROLL_SAMPLES) {
                const excess = self.preroll.items.len - PREROLL_SAMPLES;
                self.preroll.replaceRange(self.allocator, 0, excess, &.{}) catch {};
            }
        }

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
