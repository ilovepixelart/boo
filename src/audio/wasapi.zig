const std = @import("std");
const common = @import("common.zig");

const WHISPER_SAMPLE_RATE = common.WHISPER_SAMPLE_RATE;
const WAVEFORM_BARS = common.WAVEFORM_BARS;

// Engine-side buffer between polls. Generous on purpose: dictation has no
// latency pressure, and at 16kHz mono f32 (64KB/s) half a second is 32KB.
const BUFFER_DURATION_MS: u32 = 500;
const POLL_INTERVAL_MS: u32 = 50;

// ── Windows COM / WASAPI ABI (manual extern decls) ──
// Declared by hand for the same reason coreaudio.zig declares the AudioQueue
// surface by hand: no binding dependency, and only the handful of methods Boo
// actually calls. GUID values verified against mmdeviceapi.h/audioclient.h
// (via Wine's IDL mirrors). Only ole32 needs linking; everything past
// CoCreateInstance is reached through COM vtables.

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const HRESULT = i32;

fn hresult(comptime value: u32) HRESULT {
    return @bitCast(value);
}

const CLSID_MMDeviceEnumerator = GUID{
    .data1 = 0xBCDE0395,
    .data2 = 0xE52F,
    .data3 = 0x467C,
    .data4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E },
};
const IID_IMMDeviceEnumerator = GUID{
    .data1 = 0xA95664D2,
    .data2 = 0x9614,
    .data3 = 0x4F35,
    .data4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 },
};
const IID_IAudioClient = GUID{
    .data1 = 0x1CB9AD4C,
    .data2 = 0xDBFA,
    .data3 = 0x4C32,
    .data4 = .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 },
};
const IID_IAudioCaptureClient = GUID{
    .data1 = 0xC8ADBD64,
    .data2 = 0xE71E,
    .data3 = 0x48A0,
    .data4 = .{ 0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17 },
};

const COINIT_MULTITHREADED: u32 = 0x0;
const CLSCTX_ALL: u32 = 0x17;
const eCapture: u32 = 1;
const eConsole: u32 = 0;

const AUDCLNT_SHAREMODE_SHARED: u32 = 0;
// The audio engine inserts a sample-rate converter and channel matrixer so we
// can ask for whisper's 16kHz mono f32 directly, the same shape the CoreAudio
// and PipeWire backends request.
const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: u32 = 0x80000000;
const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: u32 = 0x08000000;
const AUDCLNT_BUFFERFLAGS_SILENT: u32 = 0x2;

const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;

const E_ACCESSDENIED = hresult(0x80070005);
const AUDCLNT_E_UNSUPPORTED_FORMAT = hresult(0x88890008);
// Balancing rule: every successful CoInitializeEx (including S_FALSE "already
// initialized") must be paired with CoUninitialize; RPC_E_CHANGED_MODE is the
// one failure that must NOT be.
const RPC_E_CHANGED_MODE = hresult(0x80010106);

// REFERENCE_TIME is in 100ns units.
const REFTIMES_PER_MS: i64 = 10_000;

const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

const IMMDeviceEnumerator = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        EnumAudioEndpoints: *const anyopaque,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, u32, u32, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: *const anyopaque,
        RegisterEndpointNotificationCallback: *const anyopaque,
        UnregisterEndpointNotificationCallback: *const anyopaque,
    };
};

const IMMDevice = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDevice) callconv(.winapi) u32,
        Activate: *const fn (*IMMDevice, *const GUID, u32, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: *const anyopaque,
        GetId: *const anyopaque,
        GetState: *const anyopaque,
    };
};

const IAudioClient = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IAudioClient) callconv(.winapi) u32,
        Initialize: *const fn (*IAudioClient, u32, u32, i64, i64, *const WAVEFORMATEX, ?*const GUID) callconv(.winapi) HRESULT,
        GetBufferSize: *const anyopaque,
        GetStreamLatency: *const anyopaque,
        GetCurrentPadding: *const anyopaque,
        IsFormatSupported: *const anyopaque,
        GetMixFormat: *const fn (*IAudioClient, *?*WAVEFORMATEX) callconv(.winapi) HRESULT,
        GetDevicePeriod: *const anyopaque,
        Start: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Reset: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        SetEventHandle: *const anyopaque,
        GetService: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

const IAudioCaptureClient = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IAudioCaptureClient) callconv(.winapi) u32,
        GetBuffer: *const fn (*IAudioCaptureClient, *?[*]u8, *u32, *u32, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioCaptureClient, u32) callconv(.winapi) HRESULT,
        GetNextPacketSize: *const fn (*IAudioCaptureClient, *u32) callconv(.winapi) HRESULT,
    };
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) HRESULT;
extern "ole32" fn CoUninitialize() void;
extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    cls_ctx: u32,
    iid: *const GUID,
    out: *?*anyopaque,
) HRESULT;
extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) void;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// ── pure helpers (unit-tested on every platform) ──

/// The uncompressed float PCM format Boo asks the audio engine for.
fn waveFormat(sample_rate: u32, channels: u16) WAVEFORMATEX {
    const block_align: u16 = channels * @sizeOf(f32);
    return .{
        .wFormatTag = WAVE_FORMAT_IEEE_FLOAT,
        .nChannels = channels,
        .nSamplesPerSec = sample_rate,
        .nAvgBytesPerSec = sample_rate * block_align,
        .nBlockAlign = block_align,
        .wBitsPerSample = 32,
        .cbSize = 0,
    };
}

/// Average interleaved multi-channel f32 frames into mono. `src` is the
/// engine's buffer, which carries no alignment guarantee for f32.
fn downmix(dst: []f32, src: [*]align(1) const f32, channels: usize) void {
    for (dst, 0..) |*out, i| {
        var sum: f32 = 0;
        const base = i * channels;
        for (0..channels) |c| sum += src[base + c];
        out.* = sum / @as(f32, @floatFromInt(channels));
    }
}

// ── AudioCapture ──

pub const AudioCapture = struct {
    audio_client: *IAudioClient,
    capture_client: *IAudioCaptureClient,
    /// Channels the engine delivers: 1 on the AUTOCONVERTPCM happy path, the
    /// device mix count on the fallback path (downmixed in the capture loop).
    channels: u16,
    /// Whether this context owes a CoUninitialize for the init thread.
    com_initialized: bool,
    device_started: bool = false,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    /// Buffers, locking, preroll and the recording cap, shared with the other
    /// backends so they cannot drift apart. See common.Capture.
    capture: common.Capture,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*AudioCapture {
        const self = try allocator.create(AudioCapture);
        errdefer allocator.destroy(self);

        const com_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (!succeeded(com_hr) and com_hr != RPC_E_CHANGED_MODE) {
            return error.ComInitFailed;
        }
        const com_initialized = com_hr != RPC_E_CHANGED_MODE;
        errdefer if (com_initialized) CoUninitialize();

        var enumerator_raw: ?*anyopaque = null;
        if (!succeeded(CoCreateInstance(
            &CLSID_MMDeviceEnumerator,
            null,
            CLSCTX_ALL,
            &IID_IMMDeviceEnumerator,
            &enumerator_raw,
        ))) return error.DeviceEnumeratorFailed;
        const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enumerator_raw));
        defer _ = enumerator.vtable.Release(enumerator);

        var device: ?*IMMDevice = null;
        if (!succeeded(enumerator.vtable.GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, &device))) {
            return error.NoMicrophone;
        }
        const dev = device.?;
        defer _ = dev.vtable.Release(dev);

        var channels: u16 = 1;
        const client = try initClient(dev, &channels);
        errdefer _ = client.vtable.Release(client);

        var capture_raw: ?*anyopaque = null;
        if (!succeeded(client.vtable.GetService(client, &IID_IAudioCaptureClient, &capture_raw))) {
            return error.CaptureClientFailed;
        }
        const capture_client: *IAudioCaptureClient = @ptrCast(@alignCast(capture_raw));

        self.* = .{
            .audio_client = client,
            .capture_client = capture_client,
            .channels = channels,
            .com_initialized = com_initialized,
            .capture = .{ .allocator = allocator },
            .allocator = allocator,
        };

        // Client is built but NOT started, mic stays off until recording begins.
        return self;
    }

    /// Activate an IAudioClient on `dev` and Initialize it for shared-mode
    /// capture at 16kHz f32. Mono first (the engine matrixes channels down for
    /// us); if the driver refuses, retry with the device's own channel count
    /// and let the capture loop downmix. A failed Initialize leaves a client
    /// in an unspecified state, so the retry activates a fresh one.
    fn initClient(dev: *IMMDevice, channels: *u16) !*IAudioClient {
        var last_hr: HRESULT = 0;
        for (0..2) |attempt| {
            var client_raw: ?*anyopaque = null;
            if (!succeeded(dev.vtable.Activate(dev, &IID_IAudioClient, CLSCTX_ALL, null, &client_raw))) {
                return error.AudioClientFailed;
            }
            const client: *IAudioClient = @ptrCast(@alignCast(client_raw));

            if (attempt == 1) {
                var mix: ?*WAVEFORMATEX = null;
                if (!succeeded(client.vtable.GetMixFormat(client, &mix)) or mix == null) {
                    _ = client.vtable.Release(client);
                    return error.AudioFormatRejected;
                }
                channels.* = mix.?.nChannels;
                CoTaskMemFree(mix);
                if (channels.* < 2) {
                    // Mono was already rejected; nothing new to try.
                    _ = client.vtable.Release(client);
                    return error.AudioFormatRejected;
                }
            }

            const format = waveFormat(WHISPER_SAMPLE_RATE, channels.*);
            const hr = client.vtable.Initialize(
                client,
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                BUFFER_DURATION_MS * REFTIMES_PER_MS,
                0,
                &format,
                null,
            );
            if (succeeded(hr)) return client;

            _ = client.vtable.Release(client);
            last_hr = hr;
            if (hr != AUDCLNT_E_UNSUPPORTED_FORMAT) break;
        }

        // The Windows privacy toggle (Settings > Privacy > Microphone) blocks
        // capture here; surface it as its own error so the frontend can say so.
        if (last_hr == E_ACCESSDENIED) return error.MicrophoneAccessDenied;
        return error.AudioFormatRejected;
    }

    pub fn deinit(self: *AudioCapture) void {
        self.stopDevice();
        _ = self.capture_client.vtable.Release(self.capture_client);
        _ = self.audio_client.vtable.Release(self.audio_client);
        if (self.com_initialized) CoUninitialize();
        self.capture.deinit();
        self.allocator.destroy(self);
    }

    /// Warm up the mic, start the stream but don't record yet.
    /// Call this ~500ms before startRecording() to eliminate cold-start lag.
    pub fn warmUp(self: *AudioCapture) void {
        self.capture.reserve(WHISPER_SAMPLE_RATE * 60);
        self.startDevice();
        // The loop runs, but `recording` is false, so samples land in preroll.
    }

    pub fn startRecording(self: *AudioCapture) void {
        self.startDevice(); // no-op if warmed up
        self.capture.begin();
    }

    pub fn stopRecording(self: *AudioCapture) void {
        self.capture.end();
        self.stopDevice(); // mic off
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

    fn startDevice(self: *AudioCapture) void {
        if (self.device_started) return;
        if (!succeeded(self.audio_client.vtable.Start(self.audio_client))) return;
        self.device_started = true;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, captureLoop, .{self}) catch blk: {
            _ = self.audio_client.vtable.Stop(self.audio_client);
            self.device_started = false;
            self.running.store(false, .release);
            break :blk null;
        };
    }

    fn stopDevice(self: *AudioCapture) void {
        if (!self.device_started) return;
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        _ = self.audio_client.vtable.Stop(self.audio_client);
        // Drop whatever is still queued so a later start begins clean.
        _ = self.audio_client.vtable.Reset(self.audio_client);
        self.device_started = false;
    }

    /// Dedicated capture thread: drain every pending packet, sleep, repeat.
    /// Microsoft's canonical shared-mode capture pattern (polling, not event
    /// driven: events wake every ~10ms engine period for nothing).
    fn captureLoop(self: *AudioCapture) void {
        // COM rule: every thread that calls COM initializes it. MTA matches
        // the init thread, so the interfaces are shared freely. Uninitialize
        // only balances a successful init (S_FALSE included, hence not just
        // checking for RPC_E_CHANGED_MODE).
        const com_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        defer if (succeeded(com_hr)) CoUninitialize();

        while (self.running.load(.acquire)) {
            if (!self.drainPackets()) {
                // Device unplugged, reconfigured, or access revoked mid-take
                // (e.g. AUDCLNT_E_DEVICE_INVALIDATED). Finish the take with
                // what was captured; the frontend's poll notices recording
                // ended and transcribes it, same as hitting the cap. The
                // invalidated client stays around until stopDevice tears it
                // down; recovery needs a fresh context (v1 limitation, see
                // windows/tests/manual.md).
                self.running.store(false, .release);
                self.capture.end();
                return;
            }
            Sleep(POLL_INTERVAL_MS);
        }
    }

    /// Returns false on a fatal device error.
    fn drainPackets(self: *AudioCapture) bool {
        const cc = self.capture_client;
        var packet_frames: u32 = 0;
        if (!succeeded(cc.vtable.GetNextPacketSize(cc, &packet_frames))) return false;

        while (packet_frames != 0) {
            var data: ?[*]u8 = null;
            var frames: u32 = 0;
            var flags: u32 = 0;
            if (!succeeded(cc.vtable.GetBuffer(cc, &data, &frames, &flags, null, null))) return false;

            self.pushFrames(data, frames, flags);

            if (!succeeded(cc.vtable.ReleaseBuffer(cc, frames))) return false;
            if (!succeeded(cc.vtable.GetNextPacketSize(cc, &packet_frames))) return false;
        }
        return true;
    }

    /// Convert one engine packet to mono f32 and hand it to common.Capture.
    /// Chunked through a stack buffer: the engine's pointer has no alignment
    /// guarantee, and packets on the fallback path need channel averaging.
    fn pushFrames(self: *AudioCapture, data: ?[*]u8, frames: u32, flags: u32) void {
        var chunk: [1024]f32 = undefined;
        var remaining: usize = frames;
        var offset: usize = 0;

        while (remaining > 0) {
            const n = @min(remaining, chunk.len);
            if (data == null or (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
                @memset(chunk[0..n], 0.0);
            } else {
                const samples: [*]align(1) const f32 = @ptrCast(data.? + offset * self.channels * @sizeOf(f32));
                if (self.channels == 1) {
                    for (chunk[0..n], 0..) |*out, i| out.* = samples[i];
                } else {
                    downmix(chunk[0..n], samples, self.channels);
                }
            }
            // Everything that happens to these samples, preroll, the recording
            // cap, the waveform, is shared with the other backends.
            self.capture.push(chunk[0..n]);
            offset += n;
            remaining -= n;
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────────
// The pure format/conversion maths runs on every platform; the COM plumbing is
// covered by the Windows CI build and by real-hardware dictation
// (windows/tests/manual.md), the same split the other backends live with.

const testing = std.testing;

test "waveFormat: mono 16kHz f32 derives sizes whisper depends on" {
    const f = waveFormat(16000, 1);
    try testing.expectEqual(WAVE_FORMAT_IEEE_FLOAT, f.wFormatTag);
    try testing.expectEqual(@as(u16, 4), f.nBlockAlign);
    try testing.expectEqual(@as(u32, 64000), f.nAvgBytesPerSec);
    try testing.expectEqual(@as(u16, 32), f.wBitsPerSample);
    try testing.expectEqual(@as(u16, 0), f.cbSize);
}

test "waveFormat: fallback stereo keeps the frame size consistent" {
    const f = waveFormat(16000, 2);
    try testing.expectEqual(@as(u16, 8), f.nBlockAlign);
    try testing.expectEqual(@as(u32, 128000), f.nAvgBytesPerSec);
}

test "downmix: averages interleaved stereo into mono" {
    const src = [_]f32{ 0.2, 0.4, -1.0, 1.0, 0.5, 0.5 };
    var dst: [3]f32 = undefined;
    downmix(&dst, &src, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.3), dst[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dst[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dst[2], 0.0001);
}

test "downmix: four channels, one frame" {
    const src = [_]f32{ 1.0, 0.0, 0.5, 0.5 };
    var dst: [1]f32 = undefined;
    downmix(&dst, &src, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dst[0], 0.0001);
}
