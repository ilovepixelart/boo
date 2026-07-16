# Development

## Build, macOS

```sh
brew install zig xcodegen
xcodegen --spec macos/project.yml --project macos/

# Either: open in Xcode and hit Run
open macos/Boo.xcodeproj

# Or: build from CLI
xcodebuild -project macos/Boo.xcodeproj -scheme Boo -configuration Release \
  -derivedDataPath build/xcode-derived
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

## Build, Linux

System packages (Debian/Ubuntu):

```sh
sudo apt install libpipewire-0.3-dev libgtk-4-dev libadwaita-1-dev libsoup-3.0-dev pkg-config
```

Zig ≥ 0.16 is required (`build.zig.zon` enforces it) and distro packages lag , 
grab a tarball from [ziglang.org/download](https://ziglang.org/download/) or use
`snap install zig --classic --beta`.

```sh
zig build app
./zig-out/bin/boo-app
```

### Flatpak

```sh
flatpak install --user flathub org.gnome.Platform//50 org.gnome.Sdk//50
flatpak-builder --user --install --force-clean build-dir \
  linux/flatpak/com.boo.app.yaml
flatpak run com.boo.app
```

Inside the Flatpak sandbox, place the model at `~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin` (the app reads `$XDG_DATA_HOME/boo/models/`, and Flatpak maps `XDG_DATA_HOME` to `~/.var/app/com.boo.app/data/`).

## Build, Windows

Zig bundles the mingw-w64 headers, import libraries and a Windows resource compiler, so there is nothing to install beyond Zig itself, no Visual Studio, no Windows SDK:

```bat
zig build app -Doptimize=ReleaseFast
zig-out\bin\boo-app.exe
```

The same command cross-compiles from macOS or Linux with `-Dtarget=x86_64-windows-gnu` (or `aarch64-windows-gnu`), icon, version resources and manifest included; CI uses exactly that as its guard job. The binary is self-contained: mingw's runtime and winpthreads link statically against the UCRT that ships with Windows 10+, so there is no redistributable to install.

## Packaging a release

macOS DMG:

```sh
zig build app -Doptimize=ReleaseFast
./bundle.sh              # -> zig-out/Boo.app
./scripts/make-dmg.sh    # -> zig-out/Boo-<version>-<arch>.dmg
```

`make-dmg.sh` mounts the image and checks the bundle before declaring success, so a broken DMG fails here rather than on someone else's machine.

Linux Flatpak bundle:

```sh
flatpak-builder --user --force-clean --repo=repo build-dir \
  linux/flatpak/com.boo.app.yaml
flatpak build-bundle repo boo.flatpak com.boo.app
```

Windows zip:

```bat
zig build app -Doptimize=ReleaseFast
:: zip zig-out\bin\boo-app.exe + LICENSE; the release workflow uses Compress-Archive
```

Pushing a `v*` tag runs the release workflow, which builds **two DMGs on native runners** (`macos-15` → arm64, `macos-15-intel` → Intel; cross-compiling Swift + Zig + whisper and lipo-ing them is far more fragile), the Linux Flatpak, and **two Windows zips** (`windows-latest`, x86_64 native + aarch64 cross, each PE-machine-checked), then publishes a GitHub Release with `SHA256SUMS`.

To cut a release, edit the version in **`build.zig.zon`** (the single source of truth, `bundle.sh` derives from it) and add a `<release>` entry to the metainfo changelog. `macos/project.yml` carries it for the Xcode dev build, and `windows/res/boo.rc` + `boo.manifest` carry it for the Windows resources; `scripts/check-version.sh` runs in CI and fails if any of these drift. Then:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Tests

```sh
zig build test                  # Zig core, audio maths + the C ABI contract
./linux/tests/run.sh            # portal payloads, needs gtk4; runs on macOS too
./linux/tests/integration.sh    # portal handshakes, Linux only, needs a D-Bus
./linux/tests/audio.sh MODEL WAV  # PipeWire capture -> whisper, needs a real
                                  # PipeWire graph, so a VM or desktop, NOT a
                                  # container (WirePlumber needs systemd-logind)
cc -I windows/src windows/tests/inject_plan_test.c \
   windows/src/inject_plan.c -o t && ./t   # Windows paste chord, runs anywhere
```

**`zig build test`** covers the pure audio maths (waveform windowing, RMS, clamping, peak attack/decay) and the C ABI contract every frontend depends on: that a failed `boo_init` frees what it allocated, and that every entry point survives a null context, which a frontend whose init failed will absolutely hand it, since its timers and buttons keep firing regardless.

The leak test earns its keep. `boo_init` returns an *optional*, and Zig's `errdefer` only fires on an **error** return, so its cleanup silently never ran, and a failure to open the microphone leaked the entire ~150 MB whisper model. Tested with a leak-checking allocator, so the regression fails the build rather than quietly bloating memory.

**`run.sh`** checks the D-Bus payloads are well-formed. That matters more than it looks: GVariant format strings are parsed at *runtime*, so a malformed payload compiles cleanly and then aborts on a user's desktop.

**`integration.sh`** runs both portal clients end to end against a live session bus, driven by a stand-in portal (`mock_portal.py`) that speaks the real Request/Response protocol. It asserts the hotkey is bound as `toggle-record`/`CTRL+SHIFT+space`, that an `Activated` signal reaches Boo's callback, that RemoteDesktop requests the keyboard with a persisted grant, and that a paste emits exactly `Ctrl↓ Shift↓ V↓ V↑ Shift↑ Ctrl↑`.

Its real value is subtler. The portal's Request/Response protocol requires a client to *predict* the reply's object path and subscribe **before** issuing the call, subscribe after and you race the portal and lose the reply permanently. The mock derives that path independently, exactly as a real portal does, so a passing run proves Boo's prediction is correct. That bug is invisible to a compiler and impossible to reproduce on macOS.

**`audio.sh`** is the one that can't run in CI. It needs a real PipeWire graph, and WirePlumber, PipeWire's session manager, refuses to start without systemd-logind. In a container it dies, no nodes get linked, and Boo's stream captures nothing. So this wants a VM or a desktop:

```sh
brew install lima
limactl start --name=boo template://ubuntu-lts
# inside: install pipewire wireplumber gtk4 libadwaita, then
./linux/tests/audio.sh ggml-base.en.bin speech.wav
```

Given a WAV it builds a virtual microphone out of a null sink's monitor, plays the file into it, and asserts a transcript comes back, so it runs unattended. Given no WAV it records from your default source and you just speak.

**`inject_plan_test.c`** pins the Windows paste chord: exactly Ctrl+V reaches the target app, with any physically held Shift/Alt/Win released first, else a user still holding the hotkey would deliver Ctrl+Shift+V instead. The planner is pure C with no windows.h, so this runs on the Linux lint runner.

Still untested: the platform audio backends themselves (`coreaudio.zig`, `pipewire.zig`, `wasapi.zig`) have no unit tests for their hardware paths, they're driven by device callbacks and are covered only end-to-end, by `audio.sh`, by [`windows/tests/manual.md`](../windows/tests/manual.md), and by actually using the app. The WASAPI backend's format and downmix maths, being pure, is unit-tested on every platform.

CI runs everything except `audio.sh` and `manual.md` on every push. The Linux job proves the GTK4 frontend links and the portals work; the Windows jobs prove the Win32 frontend links (natively and cross-compiled) and that the core's tests pass on Windows, none of which can be checked on a macOS dev box.

## Build, Zig core only (CLI test binary)

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
    wasapi.zig      Windows audio backend (hand-declared COM, ole32 only)
  whisper.zig       whisper.cpp Zig wrapper
  c_api.zig         C ABI surface (consumed by frontends)

include/boo.h       The C API contract, single source of truth

macos/
  Sources/          Swift / AppKit
  project.yml       xcodegen spec
  Boo.entitlements

linux/
  src/              C / GTK4 + libadwaita frontend
    global_shortcut.c  GlobalShortcuts portal, the Ctrl+Shift+Space hotkey
    text_inject.c      RemoteDesktop portal, synthesizes the paste chord
  tests/
    portal_payloads.c  D-Bus payload signatures (runs anywhere with gtk4)
    portal_harness.c   Drives both portal clients (Linux)
    mock_portal.py     Stand-in xdg-desktop-portal speaking the real protocol
    run.sh             Payload tests
    integration.sh     End-to-end portal handshakes against a live D-Bus
  flatpak/          Manifest, .desktop entry, AppStream metainfo

windows/
  src/              C / Win32 frontend
    overlay.c       The overlay window; never takes focus, by construction
    tray.c          Notification-area icon (version-4 protocol)
    hotkey.c        RegisterHotKey, the Ctrl+Shift+Space hotkey
    inject.c        Clipboard + synthesized Ctrl+V delivery
    inject_plan.c   Pure paste-chord planner (host-testable)
    model.c         Model discovery under %USERPROFILE%\.boo\models
  res/              .ico, version resources, UTF-8 + PerMonitorV2 manifest
  tests/
    inject_plan_test.c  Pins the exact chord; runs on any OS
    manual.md           Real-hardware checklist gating the experimental label

themes/             486 Ghostty-format color themes (used by the macOS frontend)
assets/             App icons, Metal shader, mel filterbank

scripts/
  build-zig-libs.sh Repacks Zig's whisper archive for macOS ld
  make-dmg.sh       Packages Boo.app into a distributable DMG
  make-ico.py       Packs the PNG icons into windows/res/boo.ico

.github/workflows/  CI (all three platforms, portal tests) + release

build.zig           OS-conditional Zig build orchestration
bundle.sh           macOS: ad-hoc / re-sign helper
```

