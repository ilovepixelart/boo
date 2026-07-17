// A tiny leveled logger for diagnostics: one format, one file sink, shared by
// the core and (via the C API) the frontends, so the redaction policy lives in
// one place. See docs/logging-and-crash-reporting.md.
//
// PRIVACY: never pass recognized/transcript text to this. Log metadata only,
// lengths, durations, counts, state names. The core's own call sites obey this
// (e.g. boo_transcribe logs the character count, never the characters).
//
// The frontend owns the per-OS file path (it knows its data dir) and passes it
// to init(); with no path we log to stderr only. libc FILE* is used for the file
// (same reason theme.zig hand-declares libc: portable across the mingw build
// without translate-c).

const std = @import("std");
const common = @import("audio/common.zig");

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fflush(stream: *anyopaque) c_int;
// Wall-clock seconds since the epoch. Zig 0.16 moved the std time helpers into
// std.Io; libc time() is portable across all three targets (time_t is 64-bit on
// modern Linux/macOS/mingw).
extern "c" fn time(tloc: ?*i64) i64;

pub const Level = enum(c_int) { err = 0, warn = 1, info = 2, debug = 3 };

var file: ?*anyopaque = null;
var min_level: c_int = @intFromEnum(Level.info);
var mutex: common.Mutex = .{};

fn tag(level: c_int) []const u8 {
    return switch (level) {
        0 => "ERROR",
        1 => "WARN",
        2 => "INFO",
        else => "DEBUG",
    };
}

/// Open (or replace) the file sink and set the minimum level. A null path means
/// stderr only. Idempotent; safe to call again to re-point the file.
pub fn init(path: ?[*:0]const u8, level: c_int) void {
    mutex.lock();
    defer mutex.unlock();
    if (file) |f| {
        _ = fclose(f);
        file = null;
    }
    min_level = level;
    if (path) |p| file = fopen(p, "a");
}

/// Write one already-formatted line at `level`. Below the minimum level it is
/// dropped. Goes to the file (if open) and always to stderr.
pub fn write(level: c_int, msg: []const u8) void {
    if (level > min_level) return;
    mutex.lock();
    defer mutex.unlock();

    var head: [48]u8 = undefined;
    // Seconds since epoch keeps the header allocation-free and timezone-free;
    // a human can convert.
    const h = std.fmt.bufPrint(&head, "[{d}] {s} ", .{ time(null), tag(level) }) catch return;

    // stderr for the CLI / tests; the frontends also have their native console
    // sinks (os_log / journald / OutputDebugString).
    std.debug.print("{s}{s}\n", .{ h, msg });

    if (file) |f| {
        _ = fwrite(h.ptr, 1, h.len, f);
        _ = fwrite(msg.ptr, 1, msg.len, f);
        _ = fwrite("\n", 1, 1, f);
        _ = fflush(f);
    }
}

/// Format and write a line. For the core's own metadata log points.
pub fn logf(level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write(@intFromEnum(level), msg);
}

const testing = std.testing;

test "level filter drops messages below the minimum" {
    // Default minimum is info; debug should be filtered, info kept. We can only
    // assert the filter arithmetic here (the sink writes to stderr), so verify
    // the comparison the filter uses rather than captured output.
    init(null, @intFromEnum(Level.info));
    try testing.expect(@intFromEnum(Level.debug) > min_level); // filtered
    try testing.expect(@intFromEnum(Level.warn) <= min_level); // kept
    try testing.expect(@intFromEnum(Level.err) <= min_level); // kept
}

test "tag names each level" {
    try testing.expectEqualStrings("ERROR", tag(0));
    try testing.expectEqualStrings("INFO", tag(2));
    try testing.expectEqualStrings("DEBUG", tag(9));
}
