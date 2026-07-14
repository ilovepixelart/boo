const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    const whisper_dep = b.dependency("whisper_cpp", .{});

    // Apple's Accelerate framework is the preferred BLAS backend on macOS.
    // On Linux, ggml falls back to its own CPU code path unless CUDA/Vulkan is wired in (later).
    const c_flags_macos = &[_][]const u8{ "-DGGML_USE_ACCELERATE", "-DNDEBUG", "-O2", "-pthread" };
    const c_flags_other = &[_][]const u8{ "-DNDEBUG", "-O2", "-pthread" };
    const c_flags: []const []const u8 = if (target_os == .macos) c_flags_macos else c_flags_other;
    const cpp_flags: []const []const u8 = if (target_os == .macos)
        c_flags_macos ++ &[_][]const u8{"-std=c++11"}
    else
        c_flags_other ++ &[_][]const u8{"-std=c++11"};

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
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-backend.c", "ggml-quants.c" },
        .flags = c_flags,
    });
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{"whisper.cpp"},
        .flags = cpp_flags,
    });
    if (target_os == .macos) {
        whisper_lib.root_module.linkFramework("Accelerate", .{});
    }

    // ── Boo core static library (Zig → C API for the platform frontend) ──
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
    boo_lib.root_module.linkLibrary(whisper_lib);
    boo_lib.root_module.addIncludePath(whisper_dep.path("."));
    boo_lib.root_module.addIncludePath(b.path("include"));
    linkPlatformAudio(b, boo_lib.root_module, target_os);
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
    exe.root_module.linkLibrary(whisper_lib);
    exe.root_module.addIncludePath(whisper_dep.path("."));
    linkPlatformAudio(b, exe.root_module, target_os);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run Boo CLI").dependOn(&run_cmd.step);

    // ── Linux GTK4 + libadwaita app ──
    if (target_os == .linux) {
        const linux_app = b.addExecutable(.{
            .name = "boo-app",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        linux_app.root_module.linkLibrary(boo_lib);
        linux_app.root_module.linkLibrary(whisper_lib);
        // Link flags only — the C glue is already inside boo_lib's archive.
        linkAudioSystemDepsOnly(linux_app.root_module, target_os);
        // libadwaita-1 pulls gtk4, glib, gobject, gio, cairo transitively via pkg-config.
        linux_app.root_module.linkSystemLibrary("libadwaita-1", .{});
        linux_app.root_module.linkSystemLibrary("gtk4", .{});
        linux_app.root_module.addIncludePath(b.path("include"));
        linux_app.root_module.addIncludePath(b.path("linux/src"));
        linux_app.root_module.addCSourceFiles(.{
            .root = b.path("linux/src"),
            .files = &.{
                "main.c",
                "overlay_window.c",
                "waveform_widget.c",
                "global_shortcut.c",
                "text_inject.c",
            },
            .flags = &.{ "-O2", "-std=c11", "-Wall", "-Wextra" },
        });
        // The flatpak manifest runs `zig build app --prefix $FLATPAK_DEST` and
        // expects bin/boo-app to be installed — so the app step must depend on
        // the install, not just the compile.
        const install_linux_app = b.addInstallArtifact(linux_app, .{});
        b.getInstallStep().dependOn(&install_linux_app.step);

        const app_step = b.step("app", "Build Boo Linux app");
        app_step.dependOn(&install_linux_app.step);
    }

    // ── macOS app bundle ──
    if (target_os == .macos) {
        const bundle_step = b.step("app", "Build macOS Boo.app");

        // Zig's archiver emits Mach-O members without the 8-byte alignment
        // Apple's ld requires, and linkLibrary does not merge whisper's
        // objects into libboo-core.a — so repack libwhisper.a the same way
        // scripts/build-zig-libs.sh does for the Xcode path: extract, merge
        // via `ld -r` into one aligned object, re-archive.
        const macos_arch = switch (target.result.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS architecture"),
        };
        const repack = b.addSystemCommand(&.{ "/bin/sh", "-c",
            \\set -e
            \\ARCHIVE="$0"; OUT="$1"; ARCH="$2"
            \\case "$ARCHIVE" in /*) ;; *) ARCHIVE="$PWD/$ARCHIVE" ;; esac
            \\case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
            \\WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
            \\cd "$WORK"; ar -x "$ARCHIVE"; chmod u+r ./*.o
            \\ld -r -arch "$ARCH" ./*.o -o whisper-merged.o
            \\ar -rcs "$OUT/libwhisper.a" whisper-merged.o
        });
        repack.addFileArg(whisper_lib.getEmittedBin());
        const repack_dir = repack.addOutputDirectoryArg("whisper-repacked");
        repack.addArg(macos_arch);

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
        swift_compile.addArg("-L");
        swift_compile.addDirectoryArg(repack_dir);
        swift_compile.addArgs(&.{
            "-lboo-core",
            "-lwhisper",
            "-lc++",
            "-framework",
            "Cocoa",
            "-framework",
            "Accelerate",
            "-framework",
            "CoreAudio",
            "-framework",
            "AudioToolbox",
            "-framework",
            "Carbon",
            "-o",
        });
        const swift_out = swift_compile.addOutputFileArg("Boo");

        // Add all Swift source files
        swift_compile.addFileArg(b.path("macos/Sources/AppDelegate.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/GhosttyInjector.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/OverlayWindow.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/WaveformView.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/Theme.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/SettingsWindow.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/Permissions.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/main.swift"));

        swift_compile.step.dependOn(&boo_lib.step);
        // Lands at zig-out/Boo, where bundle.sh picks it up.
        bundle_step.dependOn(&b.addInstallFile(swift_out, "Boo").step);
    }

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

fn linkPlatformAudio(b: *std.Build, mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    // Adds C glue sources AND system link flags. Use for modules that compile
    // the audio backend directly (boo-core lib, CLI exe).
    linkAudioSystemDepsOnly(mod, os_tag);
    switch (os_tag) {
        .linux => {
            // System dependency: apt install libpipewire-0.3-dev
            //                    / pacman -S libpipewire
            mod.addIncludePath(b.path("src"));
            mod.addCSourceFile(.{
                .file = b.path("src/audio/pipewire_glue.c"),
                .flags = &.{ "-O2", "-fPIC" },
            });
        },
        else => {},
    }
}

fn linkAudioSystemDepsOnly(mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    // Just system library link flags. Use for binaries that already pull in
    // the glue indirectly (e.g. by linking boo-core static lib).
    switch (os_tag) {
        .macos => {
            mod.linkFramework("Accelerate", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
        },
        .linux => mod.linkSystemLibrary("pipewire-0.3", .{}),
        else => {},
    }
}
