// Ghostty-format theme parsing for the core, shared by every frontend so the
// 486 theme files are parsed once, not re-implemented per OS (see the "Theme
// selection" requirement in docs/ui-spec.md). A frontend loads a set, drives
// its picker from the names, applies the colors of the selected index, and owns
// the current selection and its persistence. Mirrors macos/Sources/Theme.swift.

const std = @import("std");

// libc for directory listing and file reading: Zig 0.16 removed std.fs.cwd and
// reworked file IO, and the rest of the core already reaches for libc here
// (see bench.zig). dirent.h + stdio.h are portable, mingw provides both.
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("dirent.h");
});

const MAX_THEME_BYTES = 1 << 20;

/// C ABI colors: 0xRRGGBB per channel, no alpha (the frontend applies opacity).
pub const Colors = extern struct {
    bg: u32 = 0,
    fg: u32 = 0,
    palette: [16]u32 = .{0} ** 16,
};

const Theme = struct {
    name: [:0]u8,
    colors: Colors,
};

pub const ThemeSet = struct {
    themes: []Theme,
    default_index: c_int = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ThemeSet) void {
        const a = self.allocator;
        for (self.themes) |t| a.free(t.name);
        a.free(self.themes);
        a.destroy(self);
    }
};

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

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn readFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir_path, name }, 0);
    defer allocator.free(path);
    const f = c.fopen(path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(f);
    if (c.fseek(f, 0, c.SEEK_END) != 0) return error.SeekFailed;
    const size = c.ftell(f);
    if (size <= 0 or size > MAX_THEME_BYTES) return error.FileTooBig;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return error.SeekFailed;
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    if (c.fread(buf.ptr, 1, buf.len, f) != buf.len) return error.ReadFailed;
    return buf;
}

/// Parse every theme file in `dir_path` (sorted by name). Files that do not
/// parse, or aren't regular files, are skipped, never fatal. default_index
/// points at "Ghostty Default Style Dark" when present, else 0. Caller frees
/// via ThemeSet.deinit.
pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !*ThemeSet {
    const dir_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_z);
    const dir = c.opendir(dir_z.ptr) orelse return error.OpenDirFailed;
    defer _ = c.closedir(dir);

    // Collect names first and sort, so the list is alphabetical and stable
    // regardless of the order the filesystem hands entries back.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (name.len == 0 or name[0] == '.') continue; // skip ".", "..", dotfiles
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanName);

    var themes: std.ArrayList(Theme) = .empty;
    errdefer {
        for (themes.items) |t| allocator.free(t.name);
        themes.deinit(allocator);
    }
    for (names.items) |name| {
        // A subdirectory just fails to read here and is skipped, no kind check.
        const content = readFile(allocator, dir_path, name) catch continue;
        defer allocator.free(content);
        const colors = parseContent(content) orelse continue;
        const name_z = try allocator.dupeZ(u8, name);
        errdefer allocator.free(name_z);
        try themes.append(allocator, .{ .name = name_z, .colors = colors });
    }

    const set = try allocator.create(ThemeSet);
    set.* = .{ .themes = try themes.toOwnedSlice(allocator), .allocator = allocator };
    for (set.themes, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, "Ghostty Default Style Dark")) {
            set.default_index = @intCast(i);
            break;
        }
    }
    return set;
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

test "load: the real themes directory parses and the default matches the spec" {
    // Runs from the repo root under `zig build test`; skips elsewhere so a
    // checkout without the themes/ dir stays green (mirrors the model tests).
    var set = load(testing.allocator, "themes") catch return;
    defer set.deinit();

    // 485 of the 486 shipped files are complete Ghostty themes; a regression
    // that silently drops a chunk of them fails here.
    try testing.expect(set.themes.len >= 480);
    for (set.themes) |t| try testing.expect(t.name.len > 0);
    const def = set.themes[@intCast(set.default_index)];
    try testing.expectEqualStrings("Ghostty Default Style Dark", def.name);
    // The exact tokens docs/ui-spec.md §2 documents for the default theme.
    try testing.expectEqual(@as(u32, 0x282C34), def.colors.bg);
    try testing.expectEqual(@as(u32, 0xFFFFFF), def.colors.fg);
    try testing.expectEqual(@as(u32, 0x666666), def.colors.palette[8]); // dim
    try testing.expectEqual(@as(u32, 0x70C0B1), def.colors.palette[14]); // wave.idle
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
