const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("Boo 👻 v0.1.0\n", .{});
    std.debug.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});
    std.debug.print("Arch: {s}\n", .{@tagName(builtin.cpu.arch)});
}
