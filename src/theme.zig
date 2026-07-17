// Ghostty-format theme parsing for the core, shared by every frontend so the
// Ghostty format is parsed once, not re-implemented per OS (see the "Theme
// selection" requirement in docs/ui-spec.md). Each frontend enumerates its
// themes directory (trivial per-OS: g_dir, FindFirstFile, FileManager) and
// calls boo_theme_parse_file per file; the format parsing here is the shared,
// non-trivial part. Mirrors macos/Sources/Theme.swift.

const std = @import("std");

/// C ABI colors: 0xRRGGBB per channel, no alpha (the frontend applies opacity).
pub const Colors = extern struct {
    bg: u32 = 0,
    fg: u32 = 0,
    palette: [16]u32 = .{0} ** 16,
};

// libc file IO declared by hand rather than via @cImport: Zig 0.16 removed
// std.fs.cwd and reworked file IO, and @cImport of <stdio.h>/<dirent.h> does
// not translate cleanly for the mingw (Windows) target (unused-constant and
// signature errors from the fortified inlines). These are ABI-stable across
// every libc Boo links.
const FILE = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fseek(f: *FILE, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(f: *FILE) c_long;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
const MAX_THEME_BYTES: c_long = 1 << 20;

/// One `#RRGGBB` (the `#` optional) to 0xRRGGBB, or null if malformed.
pub fn parseHex(text: []const u8) ?u32 {
    var h = std.mem.trim(u8, text, " \t\r\n");
    if (h.len > 0 and h[0] == '#') h = h[1..];
    if (h.len != 6) return null;
    return std.fmt.parseInt(u32, h, 16) catch null;
}

/// A Ghostty theme file's contents to Colors, or null when it lacks a
/// background, a foreground, or any of the 16 palette entries, matching the
/// reference parser which drops such files rather than guessing.
pub fn parseContent(content: []const u8) ?Colors {
    var colors = Colors{};
    var have_bg = false;
    var have_fg = false;
    var have_pal = [_]bool{false} ** 16;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "background")) {
            if (parseHex(value)) |col| {
                colors.bg = col;
                have_bg = true;
            }
        } else if (std.mem.eql(u8, key, "foreground")) {
            if (parseHex(value)) |col| {
                colors.fg = col;
                have_fg = true;
            }
        } else if (std.mem.eql(u8, key, "palette")) {
            // value is "N=#hex"
            const peq = std.mem.indexOfScalar(u8, value, '=') orelse continue;
            const idx = std.fmt.parseInt(usize, std.mem.trim(u8, value[0..peq], " \t"), 10) catch continue;
            if (idx >= 16) continue;
            if (parseHex(value[peq + 1 ..])) |col| {
                colors.palette[idx] = col;
                have_pal[idx] = true;
            }
        }
    }

    if (!have_bg or !have_fg) return null;
    for (have_pal) |p| if (!p) return null;
    return colors;
}

/// Read and parse one Ghostty theme file. Null when it cannot be read, is empty
/// or oversized, or is not a complete theme. `allocator` holds the file only for
/// the duration of the call.
pub fn parseFile(allocator: std.mem.Allocator, path: [*:0]const u8) ?Colors {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return null;
    const size = ftell(f);
    if (size <= 0 or size > MAX_THEME_BYTES) return null;
    if (fseek(f, 0, SEEK_SET) != 0) return null;
    const buf = allocator.alloc(u8, @intCast(size)) catch return null;
    defer allocator.free(buf);
    if (fread(buf.ptr, 1, buf.len, f) != buf.len) return null;
    return parseContent(buf);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// A complete 16-color palette plus bg/fg, the shape every real theme file has.
const full_theme =
    \\palette = 0=#000000
    \\palette = 1=#111111
    \\palette = 2=#222222
    \\palette = 3=#333333
    \\palette = 4=#444444
    \\palette = 5=#555555
    \\palette = 6=#666666
    \\palette = 7=#777777
    \\palette = 8=#888888
    \\palette = 9=#999999
    \\palette = 10=#aaaaaa
    \\palette = 11=#bbbbbb
    \\palette = 12=#cccccc
    \\palette = 13=#dddddd
    \\palette = 14=#eeeeee
    \\palette = 15=#ffffff
    \\background = #282c34
    \\foreground = #fafafa
;

test "parseHex: optional hash, rejects wrong length and non-hex" {
    try testing.expectEqual(@as(?u32, 0x282C34), parseHex("#282c34"));
    try testing.expectEqual(@as(?u32, 0x282C34), parseHex("282C34"));
    try testing.expectEqual(@as(?u32, 0x70C0B1), parseHex("  #70c0b1  "));
    try testing.expectEqual(@as(?u32, null), parseHex("#28"));
    try testing.expectEqual(@as(?u32, null), parseHex("#gggggg"));
}

test "parseContent: a complete theme resolves bg, fg and all 16 palette slots" {
    const colors = parseContent(full_theme).?;
    try testing.expectEqual(@as(u32, 0x282C34), colors.bg);
    try testing.expectEqual(@as(u32, 0xFAFAFA), colors.fg);
    try testing.expectEqual(@as(u32, 0x000000), colors.palette[0]);
    try testing.expectEqual(@as(u32, 0x888888), colors.palette[8]); // dim
    try testing.expectEqual(@as(u32, 0xEEEEEE), colors.palette[14]); // wave.idle
    try testing.expectEqual(@as(u32, 0xFFFFFF), colors.palette[15]);
}

test "parseContent: comments and blank lines are ignored" {
    const src = "# a comment\n\n  \n" ++ full_theme;
    try testing.expect(parseContent(src) != null);
}

test "parseContent: missing foreground is rejected" {
    const src = "background = #282c34\npalette = 0=#000000";
    try testing.expect(parseContent(src) == null);
}

test "parseFile: the real default theme reads back its spec colors" {
    // Runs from the repo root under `zig build test`; skips elsewhere so a
    // checkout without the themes/ dir stays green (mirrors the model tests).
    const colors = parseFile(testing.allocator, "themes/Ghostty Default Style Dark") orelse return;
    // The exact tokens docs/ui-spec.md §2 documents for the default theme.
    try testing.expectEqual(@as(u32, 0x282C34), colors.bg);
    try testing.expectEqual(@as(u32, 0xFFFFFF), colors.fg);
    try testing.expectEqual(@as(u32, 0x666666), colors.palette[8]); // dim
    try testing.expectEqual(@as(u32, 0x70C0B1), colors.palette[14]); // wave.idle
}

test "parseContent: a gap in the 16 palette entries is rejected" {
    // palette 0..14 present (15 of 16), plus bg/fg: still incomplete.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 15) : (i += 1)
        try buf.print(testing.allocator, "palette = {d}=#010101\n", .{i});
    try buf.appendSlice(testing.allocator, "background = #282c34\nforeground = #ffffff\n");
    try testing.expect(parseContent(buf.items) == null);
}
