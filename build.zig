const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    const whisper_dep = b.dependency("whisper_cpp", .{});

    // whisper.cpp v1.9.x splits ggml into a core plus pluggable backends. We
    // mirror upstream's CMake targets: ggml-base, the backend registry, the CPU
    // backend (always), and on macOS the Metal + Accelerate-BLAS backends.
    //
    // GGML_VERSION/GGML_COMMIT are what upstream stamps from git; ggml.c
    // returns them from ggml_version()/ggml_commit() and fails to compile
    // without them. 0.15.1 is the ggml version pinned by whisper.cpp v1.9.1.
    const ggml_version_defines = [_][]const u8{
        "-DGGML_VERSION=\"0.15.1\"",
        "-DGGML_COMMIT=\"whisper.cpp-v1.9.1\"",
    };
    // -fno-sanitize=undefined: Zig compiles C with UBSan in debug builds, and
    // ggml deliberately computes buffer layouts by offsetting a NULL pointer
    // (ggml_graph_nbytes), which UBSan traps at runtime. Upstream never builds
    // with UBSan; without this flag every debug-mode model load aborts.
    const base_flags_macos = [_][]const u8{ "-DNDEBUG", "-O2", "-pthread", "-fno-sanitize=undefined", "-D_DARWIN_C_SOURCE" } ++ ggml_version_defines;
    // _GNU_SOURCE is required on Linux: ggml pins threads with CPU_ZERO,
    // CPU_ALLOC, pthread_setaffinity_np and getcpu, and glibc only declares
    // those behind it. Without it every ggml build fails with "call to
    // undeclared function". macOS never sees this, the affinity code is
    // Linux-only.
    const base_flags_linux = [_][]const u8{ "-DNDEBUG", "-O2", "-pthread", "-fno-sanitize=undefined", "-D_GNU_SOURCE" } ++ ggml_version_defines;
    const cpp_std = [_][]const u8{"-std=c++17"};

    // The CPU backend gets runtime weight repacking and llamafile's sgemm, both
    // on by default upstream; on macOS it additionally routes matmuls through
    // Accelerate.
    const cpu_defines = [_][]const u8{ "-DGGML_USE_CPU_REPACK", "-DGGML_USE_LLAMAFILE" };
    const accelerate_defines = [_][]const u8{ "-DGGML_USE_ACCELERATE", "-DACCELERATE_NEW_LAPACK", "-DACCELERATE_LAPACK_ILP64" };
    // GGML_USE_* tells the backend registry which statically-linked backends to
    // register; only ggml-backend-reg.cpp looks at these.
    const registry_defines_macos = [_][]const u8{ "-DGGML_USE_CPU", "-DGGML_USE_METAL", "-DGGML_USE_BLAS" };
    const registry_defines_linux = [_][]const u8{"-DGGML_USE_CPU"};

    const is_macos = target_os == .macos;
    const c_flags: []const []const u8 = if (is_macos) &base_flags_macos else &base_flags_linux;
    const cpp_flags: []const []const u8 = if (is_macos) &(base_flags_macos ++ cpp_std) else &(base_flags_linux ++ cpp_std);
    const cpu_c_flags: []const []const u8 = if (is_macos)
        &(base_flags_macos ++ cpu_defines ++ accelerate_defines)
    else
        &(base_flags_linux ++ cpu_defines);
    const cpu_cpp_flags: []const []const u8 = if (is_macos)
        &(base_flags_macos ++ cpp_std ++ cpu_defines ++ accelerate_defines)
    else
        &(base_flags_linux ++ cpp_std ++ cpu_defines);
    const registry_flags: []const []const u8 = if (is_macos)
        &(base_flags_macos ++ cpp_std ++ registry_defines_macos)
    else
        &(base_flags_linux ++ cpp_std ++ registry_defines_linux);

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
    whisper_lib.root_module.addIncludePath(whisper_dep.path("include"));
    whisper_lib.root_module.addIncludePath(whisper_dep.path("ggml/include"));
    whisper_lib.root_module.addIncludePath(whisper_dep.path("ggml/src"));
    whisper_lib.root_module.addIncludePath(whisper_dep.path("ggml/src/ggml-cpu"));
    whisper_lib.root_module.addIncludePath(whisper_dep.path("src"));

    // ggml core (upstream target: ggml-base)
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{ "ggml/src/ggml.c", "ggml/src/ggml-alloc.c", "ggml/src/ggml-quants.c" },
        .flags = c_flags,
    });
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{
            "ggml/src/ggml.cpp",
            "ggml/src/ggml-backend.cpp",
            "ggml/src/ggml-backend-meta.cpp",
            "ggml/src/ggml-opt.cpp",
            "ggml/src/ggml-threading.cpp",
            "ggml/src/gguf.cpp",
        },
        .flags = cpp_flags,
    });

    // backend registry (upstream target: ggml)
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{ "ggml/src/ggml-backend-dl.cpp", "ggml/src/ggml-backend-reg.cpp" },
        .flags = registry_flags,
    });

    // CPU backend (upstream target: ggml-cpu)
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{ "ggml/src/ggml-cpu/ggml-cpu.c", "ggml/src/ggml-cpu/quants.c" },
        .flags = cpu_c_flags,
    });
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{
            "ggml/src/ggml-cpu/ggml-cpu.cpp",
            "ggml/src/ggml-cpu/repack.cpp",
            "ggml/src/ggml-cpu/hbm.cpp",
            "ggml/src/ggml-cpu/traits.cpp",
            "ggml/src/ggml-cpu/binary-ops.cpp",
            "ggml/src/ggml-cpu/unary-ops.cpp",
            "ggml/src/ggml-cpu/vec.cpp",
            "ggml/src/ggml-cpu/ops.cpp",
            "ggml/src/ggml-cpu/llamafile/sgemm.cpp",
        },
        .flags = cpu_cpp_flags,
    });
    switch (target.result.cpu.arch) {
        .aarch64 => {
            whisper_lib.root_module.addCSourceFiles(.{
                .root = whisper_dep.path("."),
                .files = &.{"ggml/src/ggml-cpu/arch/arm/quants.c"},
                .flags = cpu_c_flags,
            });
            whisper_lib.root_module.addCSourceFiles(.{
                .root = whisper_dep.path("."),
                .files = &.{"ggml/src/ggml-cpu/arch/arm/repack.cpp"},
                .flags = cpu_cpp_flags,
            });
        },
        .x86_64 => {
            whisper_lib.root_module.addCSourceFiles(.{
                .root = whisper_dep.path("."),
                .files = &.{"ggml/src/ggml-cpu/arch/x86/quants.c"},
                .flags = cpu_c_flags,
            });
            whisper_lib.root_module.addCSourceFiles(.{
                .root = whisper_dep.path("."),
                .files = &.{
                    "ggml/src/ggml-cpu/arch/x86/repack.cpp",
                    "ggml/src/ggml-cpu/amx/amx.cpp",
                    "ggml/src/ggml-cpu/amx/mmq.cpp",
                },
                .flags = cpu_cpp_flags,
            });
        },
        else => {},
    }

    if (is_macos) {
        // Accelerate-backed BLAS backend (upstream target: ggml-blas)
        whisper_lib.root_module.addCSourceFiles(.{
            .root = whisper_dep.path("."),
            .files = &.{"ggml/src/ggml-blas/ggml-blas.cpp"},
            .flags = &(base_flags_macos ++ cpp_std ++ [_][]const u8{"-DGGML_BLAS_USE_ACCELERATE"} ++ accelerate_defines),
        });

        // Metal backend (upstream target: ggml-metal). This is what actually
        // puts whisper inference on the GPU; without it use_gpu is a no-op and
        // everything runs on CPU.
        const metal_embed_define = [_][]const u8{"-DGGML_METAL_EMBED_LIBRARY"};
        whisper_lib.root_module.addCSourceFiles(.{
            .root = whisper_dep.path("."),
            .files = &.{
                "ggml/src/ggml-metal/ggml-metal.cpp",
                "ggml/src/ggml-metal/ggml-metal-device.cpp",
                "ggml/src/ggml-metal/ggml-metal-common.cpp",
                "ggml/src/ggml-metal/ggml-metal-ops.cpp",
            },
            .flags = &(base_flags_macos ++ cpp_std ++ metal_embed_define),
        });
        whisper_lib.root_module.addCSourceFiles(.{
            .root = whisper_dep.path("."),
            .files = &.{
                "ggml/src/ggml-metal/ggml-metal-device.m",
                "ggml/src/ggml-metal/ggml-metal-context.m",
            },
            .flags = &(base_flags_macos ++ metal_embed_define),
        });

        // Embed the Metal shader source into the binary between the
        // _ggml_metallib_start/_ggml_metallib_end symbols, exactly as
        // upstream's CMake does: inline ggml-common.h and ggml-metal-impl.h
        // into the .metal source, then .incbin it from a generated .s file.
        // The runtime compiles the shaders on first load, so the .app needs no
        // loose ggml-metal.metal resource.
        const metal_embed = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\set -e
            \\COMMON="$0"; IMPL="$1"; METAL="$2"; OUT="$3"
            \\sed -e "/__embed_ggml-common.h__/r $COMMON" -e "/__embed_ggml-common.h__/d" < "$METAL" > "$OUT.tmp.metal"
            \\sed -e "/#include \"ggml-metal-impl.h\"/r $IMPL" -e "/#include \"ggml-metal-impl.h\"/d" < "$OUT.tmp.metal" > "$OUT.metal"
            \\{
            \\  echo '.section __DATA,__ggml_metallib'
            \\  echo '.globl _ggml_metallib_start'
            \\  echo '_ggml_metallib_start:'
            \\  echo ".incbin \"$OUT.metal\""
            \\  echo '.globl _ggml_metallib_end'
            \\  echo '_ggml_metallib_end:'
            \\} > "$OUT"
        });
        metal_embed.addFileArg(whisper_dep.path("ggml/src/ggml-common.h"));
        metal_embed.addFileArg(whisper_dep.path("ggml/src/ggml-metal/ggml-metal-impl.h"));
        metal_embed.addFileArg(whisper_dep.path("ggml/src/ggml-metal/ggml-metal.metal"));
        const metal_embed_s = metal_embed.addOutputFileArg("ggml-metal-embed.s");
        whisper_lib.root_module.addAssemblyFile(metal_embed_s);

        whisper_lib.root_module.linkFramework("Accelerate", .{});
        whisper_lib.root_module.linkFramework("Foundation", .{});
        whisper_lib.root_module.linkFramework("Metal", .{});
        whisper_lib.root_module.linkFramework("MetalKit", .{});

        // swiftc links the app against the SYSTEM libc++, which on macOS 15
        // lacks a symbol Zig's newer bundled libc++ headers emit calls to.
        // See src/libcxx_compat.cpp.
        whisper_lib.root_module.addCSourceFiles(.{
            .root = b.path("."),
            .files = &.{"src/libcxx_compat.cpp"},
            .flags = &(base_flags_macos ++ cpp_std),
        });
    }

    // whisper itself (upstream target: whisper)
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{"src/whisper.cpp"},
        .flags = if (is_macos)
            &(base_flags_macos ++ cpp_std ++ [_][]const u8{"-DWHISPER_VERSION=\"1.9.1\""})
        else
            &(base_flags_linux ++ cpp_std ++ [_][]const u8{"-DWHISPER_VERSION=\"1.9.1\""}),
    });

    // Parakeet TDT (upstream target: parakeet), the fast-ASR alternative that
    // rides the same ggml runtime. Same backends, separate model format.
    whisper_lib.root_module.addCSourceFiles(.{
        .root = whisper_dep.path("."),
        .files = &.{"src/parakeet.cpp"},
        .flags = if (is_macos)
            &(base_flags_macos ++ cpp_std ++ [_][]const u8{"-DPARAKEET_VERSION=\"1.9.1\""})
        else
            &(base_flags_linux ++ cpp_std ++ [_][]const u8{"-DPARAKEET_VERSION=\"1.9.1\""}),
    });

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
    boo_lib.root_module.addIncludePath(whisper_dep.path("include"));
    boo_lib.root_module.addIncludePath(whisper_dep.path("ggml/include"));
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
    exe.root_module.addIncludePath(whisper_dep.path("include"));
    exe.root_module.addIncludePath(whisper_dep.path("ggml/include"));
    linkPlatformAudio(b, exe.root_module, target_os);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run Boo CLI").dependOn(&run_cmd.step);

    // ── Benchmark (zig build bench) ──
    const bench = b.addExecutable(.{
        .name = "boo-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    bench.root_module.linkLibrary(whisper_lib);
    bench.root_module.addIncludePath(whisper_dep.path("include"));
    bench.root_module.addIncludePath(whisper_dep.path("ggml/include"));
    linkAudioSystemDepsOnly(bench.root_module, target_os);

    // Default benchmark audio: the jfk.wav sample that ships inside the
    // whisper.cpp package, so the bench needs no committed fixtures.
    const bench_options = b.addOptions();
    bench_options.addOptionPath("jfk_wav", whisper_dep.path("samples/jfk.wav"));
    bench.root_module.addOptions("build_options", bench_options);

    // Installed so CI can run it under valgrind directly (zig-out/bin/boo-bench).
    b.installArtifact(bench);

    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run transcription performance benchmark").dependOn(&bench_run.step);

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
        // Link flags only, the C glue is already inside boo_lib's archive.
        linkAudioSystemDepsOnly(linux_app.root_module, target_os);
        // libadwaita-1 pulls gtk4, glib, gobject, gio, cairo transitively via pkg-config.
        linux_app.root_module.linkSystemLibrary("libadwaita-1", .{});
        linux_app.root_module.linkSystemLibrary("gtk4", .{});
        // The first-run VAD model download; part of both desktop installs and
        // the GNOME Flatpak runtime.
        linux_app.root_module.linkSystemLibrary("libsoup-3.0", .{});
        linux_app.root_module.addIncludePath(b.path("include"));
        linux_app.root_module.addIncludePath(b.path("linux/src"));
        linux_app.root_module.addCSourceFiles(.{
            .root = b.path("linux/src"),
            .files = &.{
                "main.c",
                "models.c",
                "overlay_window.c",
                "waveform_widget.c",
                "portal.c",
                "global_shortcut.c",
                "text_inject.c",
            },
            // GTK's own warning set (see its meson.build), minus -Wconversion
            // which storms on GLib's gint/guint/gsize/gboolean conversions.
            // Boo's C is clean under all of these.
            .flags = &.{
                "-O2",                    "-std=c11",
                "-Wall",                  "-Wextra",
                "-Wshadow",               "-Wstrict-prototypes",
                "-Wmissing-prototypes",   "-Wpointer-arith",
                "-Wvla",                  "-Wformat=2",
                "-Wold-style-definition", "-Wcast-align",
                "-Wundef",
            },
        });
        // The flatpak manifest runs `zig build app --prefix $FLATPAK_DEST` and
        // expects bin/boo-app to be installed, so the app step must depend on
        // the install, not just the compile.
        const install_linux_app = b.addInstallArtifact(linux_app, .{});
        b.getInstallStep().dependOn(&install_linux_app.step);

        // The instrumented coverage build (scripts/coverage.sh, linux slice)
        // recompiles the frontend C with the system cc and links it against
        // these archives; hang them off the app step too, since CI builds
        // with `zig build app`, which skips the default install step.
        const install_core_lib = b.addInstallArtifact(boo_lib, .{});
        const install_whisper_lib = b.addInstallArtifact(whisper_lib, .{});
        b.getInstallStep().dependOn(&install_core_lib.step);
        b.getInstallStep().dependOn(&install_whisper_lib.step);

        const app_step = b.step("app", "Build Boo Linux app");
        app_step.dependOn(&install_linux_app.step);
        app_step.dependOn(&install_core_lib.step);
        app_step.dependOn(&install_whisper_lib.step);
    }

    // ── Windows Win32 app ──
    if (target_os == .windows) {
        const win_app = b.addExecutable(.{
            .name = "boo-app",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            // UTF-8 code page + PerMonitorV2 DPI awareness.
            .win32_manifest = b.path("windows/res/boo.manifest"),
        });
        // wWinMain + no console window. mingw's CRT provides the entry glue;
        // the unicode flag selects the wide (wWinMain) variant of it.
        win_app.subsystem = .windows;
        win_app.mingw_unicode_entry_point = true;
        win_app.root_module.linkLibrary(boo_lib);
        win_app.root_module.linkLibrary(whisper_lib);
        // Link flags only, the WASAPI backend lives inside boo_lib's archive.
        linkAudioSystemDepsOnly(win_app.root_module, target_os);
        // OS DLLs, resolved from Zig's bundled mingw import libraries, so
        // this cross-compiles from any host with no Windows SDK.
        // comctl32: the settings trackbar + download progress bars. shlwapi:
        // PathRemoveFileSpec for the exe-relative themes dir. advapi32: the
        // settings registry keys. winhttp + bcrypt: the model download and
        // its SHA-256 verification. comdlg32: the onboarding file picker.
        for ([_][]const u8{ "user32", "gdi32", "shell32", "dwmapi", "advapi32", "comctl32", "shlwapi", "winhttp", "bcrypt", "comdlg32", "dbghelp" }) |lib| {
            win_app.root_module.linkSystemLibrary(lib, .{});
        }
        win_app.root_module.addIncludePath(b.path("include"));
        win_app.root_module.addIncludePath(b.path("windows/src"));
        win_app.root_module.addCSourceFiles(.{
            .root = b.path("windows/src"),
            .files = &.{
                "main.c",
                "model.c",
                "download.c",
                "onboarding.c",
                "crash.c",
                "overlay.c",
                "settings.c",
                "waveform.c",
                "tray.c",
                "hotkey.c",
                "inject.c",
                "inject_plan.c",
            },
            // Same warning set as the Linux frontend; this C is clean under it.
            .flags = &.{
                "-O2",                    "-std=c11",
                "-Wall",                  "-Wextra",
                "-Wshadow",               "-Wstrict-prototypes",
                "-Wmissing-prototypes",   "-Wpointer-arith",
                "-Wvla",                  "-Wformat=2",
                "-Wold-style-definition", "-Wcast-align",
                "-Wundef",
            },
        });
        win_app.root_module.addWin32ResourceFile(.{
            .file = b.path("windows/res/boo.rc"),
        });

        const install_win_app = b.addInstallArtifact(win_app, .{});
        b.getInstallStep().dependOn(&install_win_app.step);

        const app_step = b.step("app", "Build Boo Windows app");
        app_step.dependOn(&install_win_app.step);
    }

    // ── macOS app bundle ──
    if (target_os == .macos) {
        const bundle_step = b.step("app", "Build macOS Boo.app");

        // Zig's archiver emits Mach-O members without the 8-byte alignment
        // Apple's ld requires, and the exact alignment is content-dependent, so
        // a source change can silently make libboo-core.a (or libwhisper.a)
        // unlinkable. Repack BOTH the same way scripts/build-zig-libs.sh does
        // for the Xcode path: merge each archive via `ld -r` into one aligned
        // object, re-archive.
        const macos_arch = switch (target.result.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS architecture"),
        };
        // -all_load merges the archive without extracting members first:
        // whisper v1.9 has colliding member basenames (ggml-cpu.c and
        // ggml-cpu.cpp both emit ggml-cpu.o), so an `ar -x` extraction
        // overwrites objects and silently drops symbols.
        const repack = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\set -e
            \\BOO="$0"; WHISPER="$1"; OUT="$2"; ARCH="$3"
            \\case "$BOO" in /*) ;; *) BOO="$PWD/$BOO" ;; esac
            \\case "$WHISPER" in /*) ;; *) WHISPER="$PWD/$WHISPER" ;; esac
            \\case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
            \\WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
            \\SDK=$(xcrun --sdk macosx --show-sdk-version)
            \\ld -r -arch "$ARCH" -platform_version macos 14.0 "$SDK" -all_load "$WHISPER" -o "$WORK/whisper-merged.o"
            \\ar -rcs "$OUT/libwhisper.a" "$WORK/whisper-merged.o"
            \\ld -r -arch "$ARCH" -platform_version macos 14.0 "$SDK" -all_load "$BOO" -o "$WORK/boo-merged.o"
            \\ar -rcs "$OUT/libboo-core.a" "$WORK/boo-merged.o"
        });
        repack.addFileArg(boo_lib.getEmittedBin());
        repack.addFileArg(whisper_lib.getEmittedBin());
        const repack_dir = repack.addOutputDirectoryArg("repacked");
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
        // Both aligned archives live in repack_dir now.
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
            "-framework",
            "Metal",
            "-framework",
            "MetalKit",
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
        swift_compile.addFileArg(b.path("macos/Sources/ModelOnboarding.swift"));
        swift_compile.addFileArg(b.path("macos/Sources/main.swift"));

        swift_compile.step.dependOn(&boo_lib.step);
        // Lands at zig-out/Boo, where bundle.sh picks it up.
        bundle_step.dependOn(&b.addInstallFile(swift_out, "Boo").step);
    }

    // ── Tests ──
    // Rooted at c_api.zig, not main.zig: main.zig is the CLI's entry point and
    // pulls in none of the C ABI, so a test step rooted there analyzed almost
    // nothing and passed vacuously. c_api.zig reaches the whisper wrapper and
    // the platform audio backend, and pulls in audio/common.zig's tests itself.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    unit_tests.root_module.linkLibrary(whisper_lib);
    unit_tests.root_module.addIncludePath(whisper_dep.path("include"));
    unit_tests.root_module.addIncludePath(whisper_dep.path("ggml/include"));
    unit_tests.root_module.addIncludePath(b.path("include"));
    linkPlatformAudio(b, unit_tests.root_module, target_os);

    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    // The same test binary, installed (zig-out/bin/boo-core-test) instead of
    // run, so coverage tooling (kcov in CI, see scripts/coverage.sh) can
    // execute it under instrumentation.
    const test_install = b.addInstallArtifact(unit_tests, .{ .dest_sub_path = "boo-core-test" });
    b.step("test-exe", "Install the unit-test binary for coverage tooling")
        .dependOn(&test_install.step);
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
            // The Metal-backed whisper library needs these in every binary
            // that links it, including the CLI and the test runner.
            mod.linkFramework("Metal", .{});
            mod.linkFramework("MetalKit", .{});
        },
        .linux => mod.linkSystemLibrary("pipewire-0.3", .{}),
        // COM entry points for the WASAPI backend; kernel32/ntdll are implicit.
        .windows => mod.linkSystemLibrary("ole32", .{}),
        else => {},
    }
}
