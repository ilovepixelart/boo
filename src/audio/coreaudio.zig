const std = @import("std");
const common = @import("common.zig");

const WHISPER_SAMPLE_RATE = common.WHISPER_SAMPLE_RATE;
const WAVEFORM_BARS = common.WAVEFORM_BARS;
const PREROLL_SAMPLES = common.PREROLL_SAMPLES;

const NUM_BUFFERS: usize = 3;
const BUFFER_DURATION_MS: u32 = 100;

// ── Apple AudioToolbox / CoreAudio ABI (manual extern decls) ──
// We declare the AudioQueue surface by hand instead of via @cImport because
// Zig 0.16's translate-c can't parse macOS 26.4 SDK headers (Objective-C block
// syntax in CoreMIDI; opaque mach_msg types failing static-size assertions).
// The framework symbols are still pulled in by `linkFramework("AudioToolbox")`
// and `linkFramework("CoreAudio")` in build.zig.

const OpaqueAudioQueue = opaque {};
const AudioQueueRef = ?*OpaqueAudioQueue;

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

const SMPTETime = extern struct {
    mSubframes: i16,
    mSubframeDivisor: i16,
    mCounter: u32,
    mType: u32,
    mFlags: u32,
    mHours: i16,
    mMinutes: i16,
    mSeconds: i16,
    mFrames: i16,
};

const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: SMPTETime,
    mFlags: u32,
    mReserved: u32,
};

const AudioStreamPacketDescription = extern struct {
    mStartOffset: i64,
    mVariableFramesInPacket: u32,
    mDataByteSize: u32,
};

const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: ?*anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?[*]AudioStreamPacketDescription,
    mPacketDescriptionCount: u32,
};
const AudioQueueBufferRef = *AudioQueueBuffer;

const AudioQueueInputCallback = *const fn (
    inUserData: ?*anyopaque,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inStartTime: ?*const AudioTimeStamp,
    inNumberPacketDescriptions: u32,
    inPacketDescs: ?[*]const AudioStreamPacketDescription,
) callconv(.c) void;

extern fn AudioQueueNewInput(
    inFormat: *const AudioStreamBasicDescription,
    inCallbackProc: AudioQueueInputCallback,
    inUserData: ?*anyopaque,
    inCallbackRunLoop: ?*anyopaque,
    inCallbackRunLoopMode: ?*anyopaque,
    inFlags: u32,
    outAQ: *AudioQueueRef,
) i32;

extern fn AudioQueueAllocateBuffer(
    inAQ: AudioQueueRef,
    inBufferByteSize: u32,
    outBuffer: *AudioQueueBufferRef,
) i32;

extern fn AudioQueueEnqueueBuffer(
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inNumPacketDescs: u32,
    inPacketDescs: ?[*]const AudioStreamPacketDescription,
) i32;

extern fn AudioQueueStart(
    inAQ: AudioQueueRef,
    inStartTime: ?*const AudioTimeStamp,
) i32;

extern fn AudioQueueStop(
    inAQ: AudioQueueRef,
    inImmediate: u8,
) i32;

extern fn AudioQueueDispose(
    inAQ: AudioQueueRef,
    inImmediate: u8,
) i32;

const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

// ── AudioCapture ──

pub const AudioCapture = struct {
    queue: AudioQueueRef = null,
    buffers: [NUM_BUFFERS]AudioQueueBufferRef = undefined,
    format: AudioStreamBasicDescription = undefined,

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

        // 16kHz mono float32
        self.format = std.mem.zeroes(AudioStreamBasicDescription);
        self.format.mSampleRate = @floatFromInt(WHISPER_SAMPLE_RATE);
        self.format.mFormatID = kAudioFormatLinearPCM;
        self.format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        self.format.mBytesPerPacket = @sizeOf(f32);
        self.format.mFramesPerPacket = 1;
        self.format.mBytesPerFrame = @sizeOf(f32);
        self.format.mChannelsPerFrame = 1;
        self.format.mBitsPerChannel = 32;

        // The errdefer above owns `self` — don't destroy it by hand here, or the
        // later failure paths would double-free.
        if (AudioQueueNewInput(&self.format, audioCallback, self, null, null, 0, &self.queue) != 0) {
            return error.AudioQueueCreateFailed;
        }
        errdefer _ = AudioQueueDispose(self.queue, 1);

        const buf_size: u32 = WHISPER_SAMPLE_RATE * BUFFER_DURATION_MS / 1000 * @sizeOf(f32);
        for (&self.buffers) |*buf| {
            if (AudioQueueAllocateBuffer(self.queue, buf_size, buf) != 0) return error.BufferAllocFailed;
            if (AudioQueueEnqueueBuffer(self.queue, buf.*, 0, null) != 0) return error.BufferEnqueueFailed;
        }

        // Queue is built but NOT started — mic stays off until recording begins
        return self;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.queue) |_| {
            _ = AudioQueueStop(self.queue, 1);
            _ = AudioQueueDispose(self.queue, 1);
        }
        self.audio_buf.deinit(self.allocator);
        self.preroll.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Warm up the mic — start the queue but don't record yet.
    /// Call this ~500ms before startRecording() to eliminate cold-start lag.
    pub fn warmUp(self: *AudioCapture) void {
        // Reserve ~60s up front so the audio callback never has to reallocate
        // mid-recording. This MUST hold the mutex: growing the buffer moves it,
        // and the audio thread may be appending to it at the same time — the
        // callback would then write through a dangling pointer. The frontends
        // happen to call warmUp only while stopped, but boo_warm_up is public C
        // API and nothing enforces that.
        self.mutex.lock();
        self.audio_buf.ensureTotalCapacity(self.allocator, WHISPER_SAMPLE_RATE * 60) catch {};
        self.mutex.unlock();

        if (self.queue) |_| {
            _ = AudioQueueStart(self.queue, null);
        }
        // Audio callback will run but `recording` is false,
        // so samples go into the preroll buffer
    }

    pub fn startRecording(self: *AudioCapture) void {
        // If not already warmed up, start the queue now
        if (self.queue) |_| {
            _ = AudioQueueStart(self.queue, null);
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Move preroll data into the recording buffer — captures the warm-up audio
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

        // Stop the audio queue — mic turns OFF
        if (self.queue) |_| {
            _ = AudioQueueStop(self.queue, 0);
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

    fn audioCallback(
        user_data: ?*anyopaque,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        _: ?*const AudioTimeStamp,
        num_packets: u32,
        _: ?[*]const AudioStreamPacketDescription,
    ) callconv(.c) void {
        const self: *AudioCapture = @ptrCast(@alignCast(user_data));
        const samples: [*]const f32 = @ptrCast(@alignCast(buffer.mAudioData));
        const count: usize = @intCast(num_packets);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.recording) {
            self.audio_buf.appendSlice(self.allocator, samples[0..count]) catch {};
            common.computeWaveform(self.audio_buf.items, &self.waveform);
            common.updatePeakRms(&self.peak_rms, &self.waveform);
        } else {
            // Warm-up phase: capture into preroll (last 500ms)
            self.preroll.appendSlice(self.allocator, samples[0..count]) catch {};
            if (self.preroll.items.len > PREROLL_SAMPLES) {
                const excess = self.preroll.items.len - PREROLL_SAMPLES;
                self.preroll.replaceRange(self.allocator, 0, excess, &.{}) catch {};
            }
        }

        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
    }
};
