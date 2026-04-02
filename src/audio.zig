const std = @import("std");
const c = @cImport({
    @cInclude("AudioToolbox/AudioToolbox.h");
    @cInclude("CoreAudio/CoreAudio.h");
});

const WHISPER_SAMPLE_RATE: u32 = 16000;
const WAVEFORM_BARS: usize = 40;
const NUM_BUFFERS: usize = 3;
const BUFFER_DURATION_MS: u32 = 100; // 100ms per buffer
const PREROLL_SAMPLES: usize = WHISPER_SAMPLE_RATE / 2; // 500ms

pub const AudioCapture = struct {
    queue: c.AudioQueueRef = null,
    buffers: [NUM_BUFFERS]c.AudioQueueBufferRef = .{ null, null, null },
    format: c.AudioStreamBasicDescription = undefined,

    // Shared state protected by mutex
    mutex: std.Thread.Mutex = .{},
    recording: bool = false,
    audio_buf: std.ArrayListAligned(f32, null) = .empty,
    preroll: std.ArrayListAligned(f32, null) = .empty,
    waveform: [WAVEFORM_BARS]f32 = .{0.0} ** WAVEFORM_BARS,
    peak_rms: f32 = 0.0,
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) !*AudioCapture {
        const self = try allocator.create(AudioCapture);
        self.* = .{
            .allocator = allocator,
        };

        // Set up audio format: 16kHz mono float32
        self.format = std.mem.zeroes(c.AudioStreamBasicDescription);
        self.format.mSampleRate = @floatFromInt(WHISPER_SAMPLE_RATE);
        self.format.mFormatID = c.kAudioFormatLinearPCM;
        self.format.mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked;
        self.format.mBytesPerPacket = @sizeOf(f32);
        self.format.mFramesPerPacket = 1;
        self.format.mBytesPerFrame = @sizeOf(f32);
        self.format.mChannelsPerFrame = 1;
        self.format.mBitsPerChannel = 32;

        // Create audio queue for input
        const status = c.AudioQueueNewInput(
            &self.format,
            audioCallback,
            self,
            null, // run loop
            null, // run loop mode
            0, // flags
            &self.queue,
        );
        if (status != 0) {
            allocator.destroy(self);
            return error.AudioQueueCreateFailed;
        }

        // Allocate and enqueue buffers
        const buf_size: u32 = WHISPER_SAMPLE_RATE * BUFFER_DURATION_MS / 1000 * @sizeOf(f32);
        for (&self.buffers) |*buf| {
            var st = c.AudioQueueAllocateBuffer(self.queue, buf_size, buf);
            if (st != 0) return error.BufferAllocFailed;
            st = c.AudioQueueEnqueueBuffer(self.queue, buf.*, 0, null);
            if (st != 0) return error.BufferEnqueueFailed;
        }

        // Start the queue — it runs but we only capture to preroll until recording starts
        const start_status = c.AudioQueueStart(self.queue, null);
        if (start_status != 0) return error.AudioQueueStartFailed;

        return self;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.queue) |q| {
            _ = c.AudioQueueStop(q, 1); // immediate stop
            _ = c.AudioQueueDispose(q, 1);
        }
        self.audio_buf.deinit(self.allocator);
        self.preroll.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn startRecording(self: *AudioCapture) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Prepend preroll so first word isn't lost
        self.audio_buf.clearRetainingCapacity();
        self.audio_buf.appendSlice(self.allocator, self.preroll.items) catch {};
        self.preroll.clearRetainingCapacity();
        self.waveform = .{0.0} ** WAVEFORM_BARS;
        self.peak_rms = 0.0;
        self.recording = true;
    }

    pub fn stopRecording(self: *AudioCapture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.recording = false;
    }

    /// Get a copy of the recorded audio. Caller owns the returned slice.
    pub fn getAudioData(self: *AudioCapture, allocator: std.mem.Allocator) ![]f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = try allocator.alloc(f32, self.audio_buf.items.len);
        @memcpy(copy, self.audio_buf.items);
        return copy;
    }

    /// Get current waveform snapshot (no allocation).
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

    fn audioCallback(
        user_data: ?*anyopaque,
        queue: c.AudioQueueRef,
        buffer: c.AudioQueueBufferRef,
        _: [*c]const c.AudioTimeStamp,
        num_packets: u32,
        _: [*c]const c.AudioStreamPacketDescription,
    ) callconv(.c) void {
        const self: *AudioCapture = @ptrCast(@alignCast(user_data));
        const samples: [*]const f32 = @ptrCast(@alignCast(buffer.*.mAudioData));
        const count: usize = @intCast(num_packets);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.recording) {
            // Append to main buffer
            self.audio_buf.appendSlice(self.allocator, samples[0..count]) catch {};

            // Update waveform
            computeWaveform(self.audio_buf.items, &self.waveform);

            // Update peak RMS with fast attack / slow decay
            var max_rms: f32 = 0;
            for (&self.waveform) |v| {
                if (v > max_rms) max_rms = v;
            }
            if (max_rms > self.peak_rms) {
                self.peak_rms = max_rms;
            } else {
                self.peak_rms *= 0.995;
            }
        } else {
            // Not recording — maintain rolling preroll buffer
            self.preroll.appendSlice(self.allocator, samples[0..count]) catch {};
            if (self.preroll.items.len > PREROLL_SAMPLES) {
                const excess = self.preroll.items.len - PREROLL_SAMPLES;
                self.preroll.replaceRange(self.allocator, 0, excess, &.{}) catch {};
            }
        }

        // Re-enqueue the buffer
        _ = c.AudioQueueEnqueueBuffer(queue, buffer, 0, null);
    }
};

fn computeWaveform(samples: []const f32, out: *[WAVEFORM_BARS]f32) void {
    const window = WHISPER_SAMPLE_RATE / 2; // last 500ms
    const start = if (samples.len > window) samples.len - window else 0;
    const slice = samples[start..];

    if (slice.len == 0) {
        out.* = .{0.0} ** WAVEFORM_BARS;
        return;
    }

    const chunk_size = @max(slice.len / WAVEFORM_BARS, 1);
    for (0..WAVEFORM_BARS) |i| {
        const begin = i * chunk_size;
        const end = @min(begin + chunk_size, slice.len);
        if (begin >= slice.len) {
            out[i] = 0;
            continue;
        }
        var sum: f32 = 0;
        for (slice[begin..end]) |s| {
            sum += s * s;
        }
        const rms = @sqrt(sum / @as(f32, @floatFromInt(end - begin)));
        out[i] = @min(rms, 1.0);
    }
}
