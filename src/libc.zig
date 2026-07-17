//! The libc surface the core needs beyond what std.c declares, hand-declared
//! ONCE: @cImport of stdio.h/time.h does not translate for the mingw target,
//! and four modules had grown their own drifting copies. std.c already
//! declares fopen/fclose/fread (stream.zig proved it); only the stragglers
//! live here, typed against std.c.FILE so the two sources mix cleanly.

const std = @import("std");

pub const FILE = std.c.FILE;
pub const fopen = std.c.fopen;
pub const fclose = std.c.fclose;
pub const fread = std.c.fread;

pub extern "c" fn fseek(f: *FILE, off: c_long, whence: c_int) c_int;
pub extern "c" fn ftell(f: *FILE) c_long;
pub extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *FILE) usize;
pub extern "c" fn fflush(f: ?*FILE) c_int;
pub extern "c" fn remove(path: [*:0]const u8) c_int;
/// Wall-clock seconds since the epoch; time_t is 64-bit on all three targets.
pub extern "c" fn time(tloc: ?*i64) i64;

pub const SEEK_SET: c_int = 0;
pub const SEEK_END: c_int = 2;

/// Read a whole file (at most `max_bytes`) through libc, the portable route
/// across macOS/Linux/mingw. Caller owns the slice.
pub fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8, max_bytes: usize) ![]u8 {
    const f = fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return error.ReadFailed;
    const size = ftell(f);
    if (size < 0) return error.ReadFailed;
    if (@as(usize, @intCast(size)) > max_bytes) return error.FileTooBig;
    if (fseek(f, 0, SEEK_SET) != 0) return error.ReadFailed;

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    if (fread(buf.ptr, 1, buf.len, f) != buf.len) return error.ReadFailed;
    return buf;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "readFile round-trips bytes and enforces the cap" {
    const tmp = std.c.getenv("TMPDIR") orelse "/tmp";
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/boo-readfile-test", .{std.mem.span(tmp)}, 0);
    const f = fopen(path, "wb") orelse return error.SkipZigTest;
    _ = fwrite("hello", 1, 5, f);
    _ = fclose(f);
    defer _ = remove(path);

    const bytes = try readFile(testing.allocator, path, 64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);

    try testing.expectError(error.FileTooBig, readFile(testing.allocator, path, 4));
    try testing.expectError(error.FileNotFound, readFile(testing.allocator, "/nonexistent/x", 4));
}
