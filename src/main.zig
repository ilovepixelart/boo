const std = @import("std");
const builtin = @import("builtin");
const Whisper = @import("whisper.zig").WhisperContext;
const AudioCapture = @import("audio.zig").AudioCapture;

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("Boo 👻 v0.1.0\n", .{});
    std.debug.print("Platform: {s} / {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_iter = std.process.Args.Iterator.init(init.args);
    _ = arg_iter.skip(); // program name
    const model_path: [:0]const u8 = arg_iter.next() orelse "models/ggml-base.en.bin";

    // Load whisper model
    std.debug.print("Loading model: {s}\n", .{model_path});
    var ctx = Whisper.init(model_path) catch |err| {
        std.debug.print("Failed to load model: {}\n", .{err});
        std.debug.print("\nDownload a model first:\n  mkdir -p models\n  curl -L -o models/ggml-base.en.bin \\\n    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin\n", .{});
        return;
    };
    defer ctx.deinit();
    std.debug.print("Model loaded.\n", .{});

    // Init audio capture
    const audio = AudioCapture.init(allocator) catch |err| {
        std.debug.print("Failed to init audio: {}\n", .{err});
        return;
    };
    defer audio.deinit();
    std.debug.print("Audio ready. Mic is listening (preroll active).\n\n", .{});

    const c_stdin = @cImport(@cInclude("stdio.h"));

    // Simple CLI loop for now — will be replaced by Swift GUI later
    while (true) {
        std.debug.print("Press ENTER to start recording (or 'q' to quit): ", .{});

        const ch = c_stdin.getchar();
        if (ch == 'q') break;

        // Start recording
        audio.startRecording();
        std.debug.print("Recording... Press ENTER to stop.\n", .{});

        // Wait for stop
        _ = c_stdin.getchar();
        audio.stopRecording();

        // Get audio data
        const samples = audio.getAudioData(allocator) catch {
            std.debug.print("Failed to get audio data\n", .{});
            continue;
        };
        defer allocator.free(samples);

        const duration = @as(f32, @floatFromInt(samples.len)) / 16000.0;
        std.debug.print("Recorded {d:.1}s ({d} samples). Transcribing...\n", .{ duration, samples.len });

        if (samples.len < 8000) {
            std.debug.print("Too short, skipping.\n\n", .{});
            continue;
        }

        // Transcribe
        const text = ctx.transcribe(allocator, samples) catch |err| {
            std.debug.print("Transcription error: {}\n\n", .{err});
            continue;
        };
        defer allocator.free(text);

        if (text.len == 0) {
            std.debug.print("(no speech detected)\n\n", .{});
        } else {
            std.debug.print("\n> {s}\n\n", .{text});
        }
    }

    std.debug.print("Bye! 👻\n", .{});
}
