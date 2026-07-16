# Boo 👻

[![CI](https://github.com/ilovepixelart/boo/actions/workflows/ci.yml/badge.svg)](https://github.com/ilovepixelart/boo/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Local-first speech-to-text overlay for **macOS**, **Linux**, and (experimentally) **Windows**. Press a hotkey, speak, get text, your audio never leaves the machine.

```
              C API (include/boo.h)
                       │
    Zig Core ──────────┼────────── Native UI per platform
    src/               │           ├── macos/    Swift + AppKit
                       │           ├── linux/    GTK4 + libadwaita
                       ▼           └── windows/  Win32 (C)
              boo_init()
              boo_start_recording()
              boo_stop_recording()
              boo_get_waveform()
              boo_transcribe()
              boo_deinit()
```

## Why

Most dictation tools either send audio to the cloud or feel foreign on each OS. Boo runs [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) on-device and ships a native frontend per platform, no WebView, no Electron, no shared lowest-common-denominator UI toolkit.

The architecture is borrowed wholesale from [Ghostty](https://github.com/ghostty-org/ghostty): a portable Zig core (`libboo-core`) exposed through a stable C API, plus a separate "apprt" (application runtime) per OS. Same philosophy, *cross-platform shouldn't mean foreign*.

## Status

| Platform | Audio backend | Frontend | Status |
|---|---|---|---|
| macOS 14+ (Apple Silicon + Intel) | CoreAudio | Swift + AppKit | ✅ Working |
| Linux (Wayland/X11) | PipeWire (native) | GTK4 + libadwaita | ⚠️ Preview |
| Windows 10+ (x86_64) | WASAPI | Win32 (C) | 🧪 Experimental |

**Preview** means machine-verified but not yet human-verified. **Experimental** is one notch below: it compiles, links and passes the core's tests on real Windows runners in CI, but nobody has dictated on real hardware yet. The precise ledger is in [docs/platform-status.md](docs/platform-status.md); working through [`windows/tests/manual.md`](windows/tests/manual.md) on a real machine is what promotes Windows to preview, and bug reports count.

## Install

Each guide is self-contained: download, model, permissions, and the
troubleshooting for that OS. You never need another platform's page.

| Your OS | Guide | The one gotcha to expect |
|---|---|---|
| macOS | **[docs/install-macos.md](docs/install-macos.md)** | Ad-hoc signed: clear quarantine once, and re-grant Accessibility after every update |
| Linux | **[docs/install-linux.md](docs/install-linux.md)** | The global hotkey needs GNOME 48+, KDE Plasma, or Hyprland |
| Windows | **[docs/install-windows.md](docs/install-windows.md)** | Unsigned exe: SmartScreen → More info → Run anyway |

All three need a speech model (none is bundled, they're 140 MB+). Each guide
has the one-liner; the full menu, streaming transcription, and non-English
dictation live in [docs/models.md](docs/models.md).

## Using Boo

The whole loop is three steps:

1. Put your cursor where you want the text, in any app: an editor, a chat box, a terminal, a browser field.
2. Press **Ctrl+Shift+Space** and talk. A small overlay shows a live waveform so you can see it is listening.
3. Press **Ctrl+Shift+Space** again. Boo transcribes on-device and the text appears at your cursor, and is also copied to the clipboard.

That is it, there is nothing to sign into and nothing leaves your machine. You can also click the record button in Boo's window (or the tray/menu-bar item where the OS has one). Past transcripts stack up as cards in the window, each with copy and dismiss.

Every transcript is **copied to the clipboard** and **pasted into whatever app was focused** when you started recording. Boo deliberately targets the app you came from, never itself. The settings window (opacity, auto-type toggle, 486 [Ghostty-format](https://ghostty.org) themes) is macOS-only for now; the full per-feature matrix is [docs/features.md](docs/features.md).

## Ghostty integration

Boo is a companion for [Ghostty](https://ghostty.org). On macOS it injects text through Ghostty's own AppleScript API: no clipboard, works under Secure Input, needs only the one-time Automation permission. Details: [docs/ghostty.md](docs/ghostty.md).

## Developing

```sh
zig build test                             # core unit tests, any OS
zig build app                              # native app (Linux/Windows; macOS needs one extra step)
zig build run -- models/ggml-base.en.bin   # bare-bones CLI REPL, no GUI
```

Per-platform build guides, packaging, the release checklist, the full test-suite map, and the project layout live in [docs/development.md](docs/development.md).

## Security

Your audio and transcripts never leave the machine: nothing Boo records or produces is ever uploaded. Boo makes exactly one kind of outbound request, downloading the optional Silero VAD model from Hugging Face on first run (verified against a pinned SHA-256), and never sends anything. Transcription is fully local. The text-injection paths (which do hold real capabilities) and the sandbox permissions are documented in [SECURITY.md](SECURITY.md), along with how to report an issue.

## License

[MIT](LICENSE), same as whisper.cpp and Ghostty, the projects Boo stands on.
