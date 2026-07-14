# Boo 👻

[![CI](https://github.com/ilovepixelart/boo/actions/workflows/ci.yml/badge.svg)](https://github.com/ilovepixelart/boo/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

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
| macOS 14+ (Apple Silicon + Intel) | CoreAudio | Swift + AppKit | xcodegen → Xcode | ✅ Working |
| Linux (Wayland/X11) | PipeWire (native) | GTK4 + libadwaita | `zig build app` | ⚠️ Preview — portals verified, audio untested |
| Windows | — | — | — | Not planned |

Linux ships as a **preview** Flatpak. Being precise about what that means, because "preview" usually isn't:

**Verified:**
- Builds and links against GTK4 / libadwaita / PipeWire (CI, every push).
- **Audio actually works.** In a real Ubuntu VM, Boo's PipeWire backend captured 6 s of speech (96,568 samples @ 16 kHz, RMS tracking the signal) and whisper transcribed it correctly. Reproduce with [`linux/tests/audio.sh`](linux/tests/audio.sh).
- **GlobalShortcuts portal**: CreateSession → BindShortcuts (`toggle-record`, `CTRL+SHIFT+space`) → an `Activated` signal reaches Boo's callback. *(CI, every push.)*
- **RemoteDesktop portal**: CreateSession → SelectDevices (keyboard, persisted grant) → Start, and a paste emits exactly `Ctrl↓ Shift↓ V↓ V↑ Shift↑ Ctrl↑`. *(CI, every push.)*
- The restore token persists, so the permission prompt appears **once**, not every launch.

**Verified against a real GNOME 46 desktop** (not just the mock): the RemoteDesktop portal is present and reachable, and the GlobalShortcuts portal is **absent** — so Boo now detects that and says so. See the hotkey warning under [Permissions](#permissions).

**Not verified:**
- KDE Plasma and Hyprland, which do implement GlobalShortcuts — the hotkey path has only been exercised against the mock portal.
- The GTK4 UI has not been driven by a human on a real desktop.

**Still deferred on Linux:** the 486-theme port from macOS, settings dialog, layer-shell always-on-top.

## Quick start

### macOS

**1. Install.** Grab the `.dmg` for your Mac from [Releases](https://github.com/ilovepixelart/boo/releases) — `arm64` for Apple Silicon, `x86_64` for Intel — and drag Boo to Applications.

Boo is ad-hoc signed, not notarized — Apple notarization needs a paid Developer ID. macOS will refuse to open it on first launch ("Boo is damaged" or "unidentified developer"). Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

Or right-click the app → **Open** → **Open**. You only do this once.

**2. Get a model.** Boo needs a `whisper.cpp` GGML model — none is bundled (they're 140 MB+). Put `base.en` where Boo looks for it:

```sh
mkdir -p ~/.boo/models
curl -L -o ~/.boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Other sizes (`tiny`, `small`, `medium`, `large-v3`) work too — accuracy vs. CPU. Boo also checks `./models/` and, when run from a source checkout, the repo's own `models/`.

**3. Launch it and grant permissions.** Boo asks for the microphone on first launch, and for Accessibility (used to paste into apps). See [Permissions](#permissions) — if you skip these, Boo records but nothing lands anywhere.

**4. Dictate.** Focus any app, press **Ctrl+Shift+Space**, speak, press it again. The text appears where your cursor is.

### Linux (preview)

> **Preview.** Recording, transcription and both portal grants are verified — but nobody has yet run Boo on a real GNOME/KDE desktop, so the grant dialogs you'll see are untested. See [Status](#status). Bug reports welcome.

```sh
flatpak install --user boo-<version>-x86_64.flatpak
```

The model goes inside the sandbox's data dir:

```sh
mkdir -p ~/.var/app/com.boo.app/data/boo/models
curl -L -o ~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

flatpak run com.boo.app
```

Your desktop will ask once to allow the global shortcut, and once to allow remote input (used to paste). Both grants persist. Decline either and Boo still works from the Record button, copying to the clipboard.

## Using Boo

On macOS, Boo lives in the menu bar (a waveform icon) plus a small overlay window. On Linux it's a single window — the menu-bar item, settings dialog and theme picker are macOS-only for now.

| Action | macOS | Linux |
|---|---|---|
| Start / stop dictation | **Ctrl+Shift+Space** | **Ctrl+Shift+Space** |
| …from the app | Menu-bar icon, Record button, or waveform | Record button |
| Recording elapsed time | Live timer in the menu bar | — |
| Past transcripts | Stack up in the window; click a bubble to copy | Last transcript shown |
| Settings | **⌘,** | — |

Every transcript is **copied to the clipboard** and **pasted into whatever app was focused** when you started recording. Boo deliberately targets the app you came from — never itself — so triggering it from its own window still delivers the text to the right place.

**Settings (⌘, — macOS)** has two things worth knowing:

- **Auto-type** (on by default). Turn it off to make Boo clipboard-only — it will transcribe and copy, but never type into other apps.
- **Theme** — 486 [Ghostty-format](https://ghostty.org) color themes, searchable. Defaults to Ghostty's own.

## Ghostty integration

Boo is a companion for [Ghostty](https://ghostty.org), and gets text into it differently on each platform — because Ghostty's capabilities differ sharply between the two.

**macOS — through Ghostty's own API.** Ghostty 1.3+ ships an AppleScript interface, and Boo uses it: `input text` writes straight into the focused terminal's pty. This is strictly better than synthesizing keystrokes:

- it never touches your clipboard;
- it keeps working under **Secure Input** — the mode macOS enters at password prompts, which silently swallows synthesized keystrokes and breaks most dictation tools;
- it applies bracketed paste correctly and skips Ghostty's unsafe-paste confirmation;
- it needs only the one-time **Automation** permission, not Accessibility.

Everything else (older Ghostty, other apps) falls back to clipboard + ⌘V, which needs Accessibility.

**Linux — through the clipboard, because Ghostty has no injection API there.** Its D-Bus surface only opens windows; there's no way to hand it text. So Boo copies the transcript and synthesizes a single `Ctrl+Shift+V` — Ghostty's default paste binding — via the XDG RemoteDesktop portal. This works in any app that pastes on `Ctrl+Shift+V`, on GNOME and KDE alike, inside or outside Flatpak.

Boo pastes rather than types out each character on purpose: synthesized keystrokes are resolved against your active keyboard layout, so any character the layout can't produce (accents, smart quotes, em dashes) is silently dropped. One paste chord sidesteps that entirely.

One rough edge: on Linux, a transcript containing a newline can trip Ghostty's paste-protection prompt. At a normal shell prompt (which enables bracketed paste) you won't see it. The macOS path is exempt.

## Permissions

Boo can't do its job without these, and the failure mode is silent — it records fine and the text simply never arrives.

**macOS**

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** | Everything | First launch |
| **Accessibility** | Typing into apps (the ⌘V fallback) | First launch |
| **Automation** → Ghostty | The Ghostty fast path; falls back to ⌘V | First dictation into Ghostty |

Grant them under **System Settings → Privacy & Security**. If you dismissed a prompt, add Boo manually there.

> **If you build from source:** ad-hoc signed builds get a *new code identity every rebuild*, so macOS treats each build as a different app and quietly drops the permissions you granted the last one. Symptom: dictation that worked yesterday silently stops typing. Re-grant, or sign with a stable identity (`BOO_CODESIGN_IDENTITY=... ./bundle.sh`).

**Linux** — all mediated by portals, so you'll see desktop dialogs rather than a settings pane:

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** (PipeWire) | Everything | First recording |
| **GlobalShortcuts** portal | The Ctrl+Shift+Space hotkey | First launch |
| **RemoteDesktop** portal | Auto-paste into other apps | First launch |

Both portal grants persist across restarts (Boo stores a restore token), so you approve them once. Decline either and Boo stays usable — it just falls back to the Record button and clipboard-only.

> ### ⚠️ The global hotkey needs GNOME 48+, KDE Plasma, or Hyprland
>
> GNOME only shipped a GlobalShortcuts portal backend in **version 48** (Feb 2025). On **GNOME 46 — which is what Ubuntu 24.04 LTS ships — and GNOME 47, the interface does not exist at all**, so no application can register a global hotkey, Boo included. Verified against a real GNOME 46 desktop: the D-Bus call comes back `No such interface "org.freedesktop.portal.GlobalShortcuts"`.
>
> Boo detects this and tells you, rather than leaving you pressing a key that does nothing. **Auto-paste still works** — GNOME 46 does implement RemoteDesktop — so Boo remains fully usable from the Record button, and the transcript still lands in your focused app.
>
> Check yours with `gnome-shell --version`, or use KDE Plasma / Hyprland, which have had GlobalShortcuts for longer.

Note the hotkey is a *request*: the portal dialog lets you rebind it, and some desktops ignore the preference. Whatever you end up with is what fires.

## Troubleshooting

**"Boo is damaged and can't be opened" / "unidentified developer"** — expected; the app isn't notarized. Run `xattr -dr com.apple.quarantine /Applications/Boo.app`, or right-click → Open.

**Recording works, but no text appears anywhere** — Accessibility isn't granted (macOS), or the RemoteDesktop portal was declined (Linux). The transcript is still on your clipboard, so paste it manually to confirm that's the issue.

**Text stopped appearing after I rebuilt** — see the ad-hoc signing note under [Permissions](#permissions). Re-grant Accessibility.

**Nothing types at a `sudo` / password prompt** — macOS Secure Input blocks synthesized keystrokes by design. Dictating into **Ghostty** works anyway (it uses Ghostty's API, not keystrokes); other apps can't be worked around.

**"Model not found"** — on macOS Boo looks in `~/.boo/models/`, `./models/`, and the repo checkout. On Linux it looks at `$BOO_MODEL`, `./models/`, `$XDG_DATA_HOME/boo/models/`, then `/usr/share/boo/models/`. Under Flatpak that means `~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin`.

**The hotkey does nothing (Linux)** — most likely your desktop has no GlobalShortcuts portal at all. GNOME only gained one in **48**, so on Ubuntu 24.04 LTS (GNOME 46) the hotkey cannot work for any app. Boo says so on launch. Everything else still works — use the Record button; the transcript is still pasted into your focused app. See [Permissions](#permissions). Otherwise: the grant was declined (restart Boo to be re-asked), or your desktop rebound the trigger, which it is free to do.

**Boo records but the transcript is empty (Linux)** — most likely the known gap: audio capture is unverified on Linux (see [Status](#status)). Check Boo is picking up your default PipeWire source (`pactl info`, `wpctl status`). A bug report with your desktop, compositor and PipeWire version is genuinely useful.

**Transcripts are garbage** — `base.en` is small and English-only. Try a bigger model (`small`, `medium`), and check your input device is the mic you think it is.

## Build — macOS

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

## Build — Linux

System packages (Debian/Ubuntu):

```sh
sudo apt install libpipewire-0.3-dev libgtk-4-dev libadwaita-1-dev pkg-config
```

Zig ≥ 0.16 is required (`build.zig.zon` enforces it) and distro packages lag —
grab a tarball from [ziglang.org/download](https://ziglang.org/download/) or use
`snap install zig --classic --beta`.

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

Inside the Flatpak sandbox, place the model at `~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin` (the app reads `$XDG_DATA_HOME/boo/models/`, and Flatpak maps `XDG_DATA_HOME` to `~/.var/app/com.boo.app/data/`).

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

Pushing a `v*` tag runs the release workflow, which builds **two DMGs on native runners** (`macos-14` → arm64, `macos-13` → Intel; cross-compiling Swift + Zig + whisper and lipo-ing them is far more fragile) plus the Linux Flatpak, then publishes a GitHub Release. Bump the version in `build.zig.zon`, `macos/project.yml`, `bundle.sh`, and the metainfo `<release>` entry first — then:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Tests

```sh
zig build test                  # Zig core — audio maths + the C ABI contract
./linux/tests/run.sh            # portal payloads — needs gtk4; runs on macOS too
./linux/tests/integration.sh    # portal handshakes — Linux only, needs a D-Bus
./linux/tests/audio.sh MODEL WAV  # PipeWire capture -> whisper — needs a real
                                  # PipeWire graph, so a VM or desktop, NOT a
                                  # container (WirePlumber needs systemd-logind)
```

**`zig build test`** covers the pure audio maths (waveform windowing, RMS, clamping, peak attack/decay) and the C ABI contract every frontend depends on: that a failed `boo_init` frees what it allocated, and that every entry point survives a null context — which a frontend whose init failed will absolutely hand it, since its timers and buttons keep firing regardless.

The leak test earns its keep. `boo_init` returns an *optional*, and Zig's `errdefer` only fires on an **error** return — so its cleanup silently never ran, and a failure to open the microphone leaked the entire ~150 MB whisper model. Tested with a leak-checking allocator, so the regression fails the build rather than quietly bloating memory.

**`run.sh`** checks the D-Bus payloads are well-formed. That matters more than it looks: GVariant format strings are parsed at *runtime*, so a malformed payload compiles cleanly and then aborts on a user's desktop.

**`integration.sh`** runs both portal clients end to end against a live session bus, driven by a stand-in portal (`mock_portal.py`) that speaks the real Request/Response protocol. It asserts the hotkey is bound as `toggle-record`/`CTRL+SHIFT+space`, that an `Activated` signal reaches Boo's callback, that RemoteDesktop requests the keyboard with a persisted grant, and that a paste emits exactly `Ctrl↓ Shift↓ V↓ V↑ Shift↑ Ctrl↑`.

Its real value is subtler. The portal's Request/Response protocol requires a client to *predict* the reply's object path and subscribe **before** issuing the call — subscribe after and you race the portal and lose the reply permanently. The mock derives that path independently, exactly as a real portal does, so a passing run proves Boo's prediction is correct. That bug is invisible to a compiler and impossible to reproduce on macOS.

**`audio.sh`** is the one that can't run in CI. It needs a real PipeWire graph, and WirePlumber — PipeWire's session manager — refuses to start without systemd-logind. In a container it dies, no nodes get linked, and Boo's stream captures nothing. So this wants a VM or a desktop:

```sh
brew install lima
limactl start --name=boo template://ubuntu-lts
# inside: install pipewire wireplumber gtk4 libadwaita, then
./linux/tests/audio.sh ggml-base.en.bin speech.wav
```

Given a WAV it builds a virtual microphone out of a null sink's monitor, plays the file into it, and asserts a transcript comes back — so it runs unattended. Given no WAV it records from your default source and you just speak.

Still untested: the platform audio backends themselves (`coreaudio.zig`, `pipewire.zig`) have no unit tests — they're driven by hardware callbacks and are covered only end-to-end, by `audio.sh` and by actually using the app.

CI runs everything except `audio.sh` on every push. The Linux job is what actually proves the GTK4 frontend links and that the portals work — neither can be checked on a macOS dev box.

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
    global_shortcut.c  GlobalShortcuts portal — the Ctrl+Shift+Space hotkey
    text_inject.c      RemoteDesktop portal — synthesizes the paste chord
  tests/
    portal_payloads.c  D-Bus payload signatures (runs anywhere with gtk4)
    portal_harness.c   Drives both portal clients (Linux)
    mock_portal.py     Stand-in xdg-desktop-portal speaking the real protocol
    run.sh             Payload tests
    integration.sh     End-to-end portal handshakes against a live D-Bus
  flatpak/          Manifest, .desktop entry, AppStream metainfo

themes/             486 Ghostty-format color themes (consumed by the macOS
                    frontend; Linux port pending)
assets/             App icons, Metal shader, mel filterbank

scripts/
  build-zig-libs.sh Repacks Zig's whisper archive for macOS ld
  make-dmg.sh       Packages Boo.app into a distributable DMG

.github/workflows/  CI (both platforms, portal tests) + multi-platform release

build.zig           OS-conditional Zig build orchestration
bundle.sh           macOS: ad-hoc / re-sign helper
```

## Inspiration

[Ghostty](https://github.com/ghostty-org/ghostty) is the most coherent example of "Zig core + native apprt per OS" in the wild. Boo borrows the pattern wholesale: stable C API as the contract, comptime-dispatched OS backends, no shared GUI toolkit. The trade-off is more code per platform; the payoff is each frontend feeling truly native instead of a webview pretending to be one.

## License

[MIT](LICENSE) — same as whisper.cpp and Ghostty, the projects Boo stands on.
