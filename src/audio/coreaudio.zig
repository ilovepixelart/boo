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

    /// Buffers, locking, preroll and the recording cap, shared with the
    /// PipeWire backend so the two cannot drift apart. See common.Capture.
    capture: common.Capture,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*AudioCapture {
        const self = try allocator.create(AudioCapture);
        errdefer allocator.destroy(self);
        self.* = .{
            .capture = .{ .allocator = allocator },
            .allocator = allocator,
        };

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

        // The errdefer above owns `self`, don't destroy it by hand here, or the
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

        // Queue is built but NOT started, mic stays off until recording begins
        return self;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.queue) |_| {
            _ = AudioQueueStop(self.queue, 1);
            _ = AudioQueueDispose(self.queue, 1);
        }
        self.capture.deinit();
        self.allocator.destroy(self);
    }

    /// Warm up the mic, start the queue but don't record yet.
    /// Call this ~500ms before startRecording() to eliminate cold-start lag.
    pub fn warmUp(self: *AudioCapture) void {
        self.capture.reserve(WHISPER_SAMPLE_RATE * 60);
        if (self.queue) |q| _ = AudioQueueStart(q, null);
        // The callback runs, but `recording` is false, so samples land in preroll.
    }

    pub fn startRecording(self: *AudioCapture) void {
        if (self.queue) |q| _ = AudioQueueStart(q, null); // no-op if warmed up
        self.capture.begin();
    }

    pub fn stopRecording(self: *AudioCapture) void {
        self.capture.end();
        if (self.queue) |q| _ = AudioQueueStop(q, 0); // mic off
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

        // Everything that happens to these samples, preroll, the recording cap,
        // the waveform, is shared with the PipeWire backend.
        self.capture.push(samples[0..count]);

        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
    }
};
