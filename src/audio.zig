// Audio capture module, public surface for the rest of the Zig core.
// Selects a platform-specific backend at compile time.

const builtin = @import("builtin");
const common = @import("audio/common.zig");

pub const WHISPER_SAMPLE_RATE = common.WHISPER_SAMPLE_RATE;
pub const WAVEFORM_BARS = common.WAVEFORM_BARS;

pub const AudioCapture = switch (builtin.os.tag) {
    .macos => @import("audio/coreaudio.zig").AudioCapture,
    .linux => @import("audio/pipewire.zig").AudioCapture,
    else => @compileError("Boo audio backend not yet implemented for this OS"),
};
