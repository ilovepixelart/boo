const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const whisper_dep = b.dependency("whisper_cpp", .{});

    const c_flags = &[_][]const u8{ "-DGGML_USE_ACCELERATE", "-DNDEBUG", "-O2", "-pthread" };
    const cpp_flags = c_flags ++ &[_][]const u8{"-std=c++11"};

    // ── whisper C library ──
    const whisper_lib = b.addLibrary(.{
        .name = "whisper",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    whisper_lib.root_module.addIncludePath(whisper_dep.path("."));
    whisper_lib.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-backend.c", "ggml-quants.c" },
        .flags = c_flags,
    });
    whisper_lib.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{"whisper.cpp"},
        .flags = cpp_flags,
    });
    whisper_lib.root_module.linkFramework("Accelerate", .{});

    // ── Boo core static library (Zig → C API for Swift) ──
    const boo_lib = b.addLibrary(.{
        .name = "boo-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    boo_lib.linkLibrary(whisper_lib);
    boo_lib.root_module.addIncludePath(whisper_dep.path("."));
    boo_lib.root_module.addIncludePath(b.path("include"));
    boo_lib.root_module.linkFramework("Accelerate", .{});
    boo_lib.root_module.linkFramework("Foundation", .{});
    boo_lib.root_module.linkFramework("CoreAudio", .{});
    boo_lib.root_module.linkFramework("AudioToolbox", .{});
    b.installArtifact(boo_lib);

    // ── CLI executable (for testing) ──
    const exe = b.addExecutable(.{
        .name = "boo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    exe.linkLibrary(whisper_lib);
    exe.root_module.addIncludePath(whisper_dep.path("."));
    exe.root_module.linkFramework("Accelerate", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("CoreAudio", .{});
    exe.root_module.linkFramework("AudioToolbox", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run Boo CLI").dependOn(&run_cmd.step);

    // ── macOS app bundle ──
    const bundle_step = b.step("app", "Build macOS Boo.app");
    const swift_compile = b.addSystemCommand(&.{
        "swiftc",
        "-O",
        "-import-objc-header",
    });
    swift_compile.addFileArg(b.path("include/boo.h"));
    swift_compile.addArgs(&.{
        "-L",
    });
    swift_compile.addDirectoryArg(boo_lib.getEmittedBinDirectory());
    swift_compile.addArgs(&.{
        "-lboo-core",
        "-lwhisper",
        "-lc++",
        "-framework", "Cocoa",
        "-framework", "Accelerate",
        "-framework", "CoreAudio",
        "-framework", "AudioToolbox",
        "-framework", "Carbon",
        "-o",
    });
    swift_compile.addArg(b.fmt("{s}/Boo", .{b.install_path}));

    // Add all Swift source files
    swift_compile.addFileArg(b.path("macos/Sources/AppDelegate.swift"));
    swift_compile.addFileArg(b.path("macos/Sources/OverlayWindow.swift"));
    swift_compile.addFileArg(b.path("macos/Sources/WaveformView.swift"));
    swift_compile.addFileArg(b.path("macos/Sources/main.swift"));

    swift_compile.step.dependOn(&boo_lib.step);
    bundle_step.dependOn(&swift_compile.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}
