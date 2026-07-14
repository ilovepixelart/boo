# Boo 👻

Local-first speech-to-text overlay for **macOS** and **Linux**. Press a hotkey, speak, get text — your audio never leaves the machine.

```
              C API (include/boo.h)
                       │
    Zig Core ──────────┼────────── Native UI per platform
    src/               │           ├── macos/  Swift + AppKit
                       │           └── linux/  GTK4 + libadwaita
                       ▼
              boo_init() · boo_start_recording()
              boo_stop_recording() · boo_get_waveform()
              boo_transcribe() · boo_deinit()
```

## Why

Most dictation tools either send audio to the cloud or feel foreign on each OS. Boo runs `whisper.cpp` on-device and ships a native frontend per platform — no WebView, no Electron, no shared lowest-common-denominator UI toolkit.

The architecture is heavily inspired by [Ghostty](https://github.com/ghostty-org/ghostty): a portable Zig core (`libboo-core`) exposed through a stable C API, plus a separate "apprt" (application runtime) per OS. Same philosophy — *cross-platform shouldn't mean foreign*.

## Status

| Platform | Audio backend | Frontend | Build path | Status |
|---|---|---|---|---|
| macOS 14+ | CoreAudio | Swift + AppKit | xcodegen → Xcode | ✅ Working |
| Linux (Wayland/X11) | PipeWire (native) | GTK4 + libadwaita | `zig build app` | ⚠️ Implemented, needs on-device verification |
| Windows | — | — | — | Not planned |

On Linux the global hotkey (XDG GlobalShortcuts portal) and auto-paste into the focused app (XDG RemoteDesktop portal) are implemented; the code compiles and its portal payloads are test-verified, but it has not yet been exercised against a live compositor. **Still deferred on Linux:** the 487-theme port from macOS, settings dialog, layer-shell always-on-top.

## Ghostty integration

Boo is a companion for [Ghostty](https://ghostty.org), and gets text into it differently per platform:

- **macOS** — Ghostty 1.3+ ships an AppleScript API, and Boo uses it: `input text` writes straight into the focused terminal's pty. No clipboard clobber, works under Secure Input (i.e. at password prompts), and needs only the one-time Automation permission. Older Ghostty versions and all other apps get the generic clipboard + ⌘V fallback (Accessibility permission).
- **Linux** — Ghostty has no injection API (its D-Bus surface only opens windows), so Boo copies the transcript to the clipboard and synthesizes `Ctrl+Shift+V` — Ghostty's default paste binding — through the XDG RemoteDesktop portal. One permission grant, persisted across runs with a restore token. Works in any app that pastes on `Ctrl+Shift+V`, inside or outside Flatpak, on GNOME and KDE alike.

Transcripts that contain newlines may trigger Ghostty's paste-protection prompt on Linux (the macOS path is exempt); at a shell with bracketed paste — any modern shell — no prompt appears.

## Get a model

Boo uses `whisper.cpp`'s GGML-format models. Grab `base.en` (~140 MB):

```sh
mkdir -p models
curl -L -o models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Other sizes (`tiny`, `small`, `medium`, `large-v3`) work too — accuracy/CPU tradeoff.

## Build — macOS

```sh
brew install zig xcodegen
xcodegen --spec macos/project.yml --project macos/

# Either: open in Xcode and hit Run
open macos/Boo.xcodeproj

# Or: build from CLI
xcodebuild -project macos/Boo.xcodeproj -scheme Boo -configuration Release
open build/xcode-derived/Build/Products/Release/Boo.app
```

The Xcode pre-build phase invokes `scripts/build-zig-libs.sh`, which runs `zig build -Doptimize=ReleaseFast` and repacks `libwhisper.a` so Apple's linker accepts the alignment.

By default the build is ad-hoc signed (good for local dev). For a properly-signed build:

```sh
xcodebuild ... \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  DEVELOPMENT_TEAM=TEAMID
```

Or re-sign post-build:

```sh
BOO_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./bundle.sh
```

### Without Xcode (Command Line Tools only)

```sh
zig build app -Doptimize=ReleaseFast   # ReleaseFast required: Debug C objects
./bundle.sh                            # reference the UBSan runtime, which
open zig-out/Boo.app                   # swiftc's link step doesn't provide
```

## Build — Linux

System packages (Debian/Ubuntu):

```sh
sudo apt install zig libpipewire-0.3-dev libgtk-4-dev libadwaita-1-dev pkg-config
```

```sh
zig build app
./zig-out/bin/boo-app
```

### Flatpak

```sh
flatpak install --user flathub org.gnome.Platform//47 org.gnome.Sdk//47
flatpak-builder --user --install --force-clean build-dir \
  linux/flatpak/com.boo.app.yaml
flatpak run com.boo.app
```

Inside the Flatpak sandbox, place the model at `~/.var/app/com.boo.app/data/models/ggml-base.en.bin`.

## Build — Zig core only (CLI test binary)

```sh
zig build run -- models/ggml-base.en.bin
```

A bare-bones REPL: hit Enter to record, hit Enter again to stop and transcribe. Useful for verifying the core without the GUI layer.

## Project layout

```
src/                Zig core
  audio.zig         Comptime-dispatched backend selector
  audio/
    common.zig      Shared constants, helpers, Mutex shim
    coreaudio.zig   macOS audio backend
    pipewire.zig    Linux audio backend
    pipewire_glue.{c,h}  C helper for SPA POD format builder
  whisper.zig       whisper.cpp Zig wrapper
  c_api.zig         C ABI surface (consumed by frontends)

include/boo.h       The C API contract — single source of truth

macos/
  Sources/          Swift / AppKit
  project.yml       xcodegen spec
  Boo.entitlements

linux/
  src/              C / GTK4 + libadwaita frontend
  flatpak/          Manifest, .desktop entry, AppStream metainfo

scripts/
  build-zig-libs.sh Repacks Zig's whisper archive for macOS ld

build.zig           OS-conditional Zig build orchestration
bundle.sh           macOS: ad-hoc / re-sign helper
```

## Inspiration

[Ghostty](https://github.com/ghostty-org/ghostty) is the most coherent example of "Zig core + native apprt per OS" in the wild. Boo borrows the pattern wholesale: stable C API as the contract, comptime-dispatched OS backends, no shared GUI toolkit. The trade-off is more code per platform; the payoff is each frontend feeling truly native instead of a webview pretending to be one.

## License

[MIT](LICENSE) — same as whisper.cpp and Ghostty, the projects Boo stands on.
