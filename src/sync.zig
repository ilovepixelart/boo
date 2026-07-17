//! Concurrency runtime shared across the core: the OS mutex shim (moved
//! verbatim from audio/common.zig, which re-exports it for the backends) and
//! the inference thread-count policy. Lives outside audio/ so base modules
//! like the logger do not depend upward on the audio subsystem for a lock.

const std = @import("std");
const builtin = @import("builtin");

// OS-primitive mutex. `std.Thread.Mutex` was removed in Zig 0.16 in favor of
// `std.Io.Mutex`, which threads an Io context through every call site, too
// invasive for our audio callback path. pthread covers macOS and Linux; on
// Windows std.c has no pthread types, so that arm uses SRWLOCK: one
// zero-initialized pointer-sized word, no destroy call exists or is needed.
pub const Mutex = switch (builtin.os.tag) {
    .windows => struct {
        handle: SRWLOCK = .{},

        // Declared by hand rather than via std.os.windows.ntdll, which is not
        // a stability-guaranteed API surface.
        const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
        extern "ntdll" fn RtlAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
        extern "ntdll" fn RtlReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
        extern "ntdll" fn RtlTryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;

        pub fn lock(self: *@This()) void {
            RtlAcquireSRWLockExclusive(&self.handle);
        }

        pub fn unlock(self: *@This()) void {
            RtlReleaseSRWLockExclusive(&self.handle);
        }

        pub fn tryLock(self: *@This()) bool {
            return RtlTryAcquireSRWLockExclusive(&self.handle) != 0;
        }
    },
    else => struct {
        handle: std.c.pthread_mutex_t = .{},

        pub fn lock(self: *@This()) void {
            _ = std.c.pthread_mutex_lock(&self.handle);
        }

        pub fn unlock(self: *@This()) void {
            _ = std.c.pthread_mutex_unlock(&self.handle);
        }

        pub fn tryLock(self: *@This()) bool {
            return std.c.pthread_mutex_trylock(&self.handle) == .SUCCESS;
        }
    },
};

/// Decode thread count: min(cores, 8), overridable with $BOO_THREADS.
/// The valgrind CI job sets 1: memcheck serializes every thread onto a single
/// core, where ggml's spin-waiting workers starve the one doing the work and
/// a minutes-long job becomes hours. Shared by both engines; nothing about it
/// is whisper-specific.
pub fn threadCount() c_int {
    if (std.c.getenv("BOO_THREADS")) |env| {
        const n = std.fmt.parseInt(u8, std.mem.span(env), 10) catch 0;
        if (n > 0) return n;
    }
    return @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Mutex locks, try-locks, and unlocks" {
    var m: Mutex = .{};
    m.lock();
    try testing.expect(!m.tryLock());
    m.unlock();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "threadCount is positive" {
    try testing.expect(threadCount() >= 1);
}
