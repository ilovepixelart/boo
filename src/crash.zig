// Local crash capture (docs/logging-and-crash-reporting.md): fatal-signal
// handlers that append a backtrace to boo-crash.txt next to the log, then
// hand the signal back to the OS default so the system report (.ips on
// macOS, core dumps on Linux) still happens. POSIX only; the Windows
// frontend owns its own SEH minidump writer (windows/src/crash.c). Nothing
// is ever uploaded.
//
// Async-signal-safety: the dump path is pre-formatted at init, and the
// handler uses only open/write/backtrace_symbols_fd, no allocation, no
// locks, no stdio.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn backtrace(buffer: [*]?*anyopaque, size: c_int) c_int;
extern "c" fn backtrace_symbols_fd(buffer: [*]?*anyopaque, size: c_int, fd: c_int) void;
// Variadic exactly as libc declares it: on arm64 macOS variadic arguments are
// passed on the stack, so a fixed three-argument declaration hands libc a
// garbage mode and the report file comes out with random permission bits.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn raise(sig: c_int) c_int;

const O_WRONLY: c_int = 0x1;
const O_CREAT: c_int = if (builtin.os.tag == .macos) 0x200 else 0x40;
const O_APPEND: c_int = if (builtin.os.tag == .macos) 0x8 else 0x400;

/// Pre-formatted at init so the handler never formats a path.
var dump_path: [1024:0]u8 = undefined;
var installed = false;

// The handler's parameter type as Sigaction declares it (a SIG enum on
// current Zig; keep it derived so a std change cannot silently mismatch).
const HandlerFn = @typeInfo(std.posix.Sigaction.handler_fn).pointer.child;
const SigParam = @typeInfo(HandlerFn).@"fn".params[0].type.?;

fn sigNum(sig: SigParam) c_int {
    return if (@typeInfo(SigParam) == .@"enum")
        @intCast(@intFromEnum(sig))
    else
        @intCast(sig);
}

const fatal_signals = [_]SigParam{
    std.posix.SIG.SEGV,
    std.posix.SIG.ABRT,
    std.posix.SIG.BUS,
    std.posix.SIG.ILL,
    std.posix.SIG.FPE,
};

fn writeAll(fd: c_int, bytes: []const u8) void {
    _ = write(fd, bytes.ptr, bytes.len);
}

fn writeReport(fd: c_int, sig: c_int) void {
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "\n== Boo crash: signal {d} ==\n", .{sig}) catch
        "\n== Boo crash ==\n";
    writeAll(fd, head);
    var frames: [64]?*anyopaque = undefined;
    const n = backtrace(&frames, frames.len);
    backtrace_symbols_fd(&frames, n, fd);
}

fn handler(sig: SigParam) callconv(.c) void {
    const num = sigNum(sig);
    const fd = open(&dump_path, O_WRONLY | O_CREAT | O_APPEND, @as(c_int, 0o600));
    if (fd >= 0) {
        writeReport(fd, num);
        _ = close(fd);
    }
    writeReport(2, num); // stderr, for a terminal launch
    // SA_RESETHAND restored the default action; re-raise so the OS ends the
    // process with the real signal (and writes its own report).
    _ = raise(num);
}

/// Install the handlers, dumping into `dir` (the log directory). Idempotent
/// enough for one process: a second call just re-points the path.
pub fn init(dir: []const u8) void {
    const written = std.fmt.bufPrint(&dump_path, "{s}/boo-crash.txt", .{dir}) catch return;
    dump_path[written.len] = 0;

    if (installed) return;
    installed = true;
    // Warm the unwinder now: glibc's first backtrace() call dlopens libgcc_s,
    // which allocates, so a handler-time first call can deadlock on the very
    // heap-corruption crashes this exists to report (the mitigation the glibc
    // man page prescribes).
    var warm: [1]?*anyopaque = undefined;
    _ = backtrace(&warm, 1);
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        // One shot: the default action is restored before the handler runs,
        // so the re-raise above terminates instead of recursing.
        .flags = std.posix.SA.RESETHAND,
    };
    for (fatal_signals) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

extern "c" fn remove(path: [*:0]const u8) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn fork() c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;

test "a fatal signal leaves a backtrace file behind" {
    // Fork a child, crash it, and check the report it wrote. The child dies
    // on the re-raised signal before returning to the test runner.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const tmp = std.c.getenv("TMPDIR") orelse "/tmp";
    var dbuf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dbuf, "{s}", .{std.mem.span(tmp)});
    var pbuf: [1024:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pbuf, "{s}/boo-crash.txt", .{dir}, 0);
    _ = remove(path);

    const pid = fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        // Child: install and die. The handler's re-raise ends the process,
        // so the runner never sees a second copy of itself.
        init(dir);
        _ = raise(sigNum(std.posix.SIG.SEGV));
        _exit(0); // unreachable when the handler re-raises correctly
    }

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // The child must have died from the signal (low bits, classic wait
    // encoding), never exited cleanly.
    const exited_clean = (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
    try testing.expect(!exited_clean);

    const f = fopen(path, "rb") orelse return error.TestUnexpectedResult;
    var content: [4096]u8 = undefined;
    const n = fread(&content, 1, content.len, f);
    _ = fclose(f);
    try testing.expect(std.mem.indexOf(u8, content[0..n], "Boo crash: signal") != null);
    _ = remove(path);
}
