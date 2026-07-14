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
| macOS 14+ | CoreAudio | Swift + AppKit | xcodegen → Xcode | ✅ Working |
| Linux (Wayland/X11) | PipeWire (native) | GTK4 + libadwaita | `zig build app` | ⚠️ Implemented, needs on-device verification |
| Windows | — | — | — | Not planned |

On Linux the global hotkey (XDG GlobalShortcuts portal) and auto-paste into the focused app (XDG RemoteDesktop portal) are implemented, and CI builds and links the GTK4 frontend on every push. What's **not** yet proven is behavior against a live compositor: no one has run it on a real GNOME/KDE session, so the portal grant flows are verified only at the payload level. Treat Linux as "should work, unconfirmed" — and please report what you find.

**Still deferred on Linux:** the 486-theme port from macOS, settings dialog, layer-shell always-on-top.

## Quick start (macOS)

**1. Install.** Grab the `.dmg` from [Releases](https://github.com/ilovepixelart/boo/releases) and drag Boo to Applications.

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

## Using Boo

Boo lives in the menu bar (a waveform icon) and in a small overlay window.

| Action | How |
|---|---|
| Start / stop dictation | **Ctrl+Shift+Space**, anywhere |
| Same, from the menu bar | Click the waveform icon |
| Same, from the window | Click the Record button, or the waveform |
| See how long you've been recording | The menu bar icon shows a live timer |
| Review past transcripts | They stack up in the overlay window |
| Copy an old transcript | Click its bubble |
| Settings | **⌘,** |

Every transcript is **copied to the clipboard** and **typed into whatever app was focused** when you started recording. Boo deliberately targets the app you were in — not itself — so you can trigger it from the overlay window without the text landing back in Boo.

**Settings (⌘,)** has two things worth knowing:

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

Note the hotkey is a *request*: the portal dialog lets you rebind it, and some desktops ignore the preference. Whatever you end up with is what fires.

## Troubleshooting

**"Boo is damaged and can't be opened" / "unidentified developer"** — expected; the app isn't notarized. Run `xattr -dr com.apple.quarantine /Applications/Boo.app`, or right-click → Open.

**Recording works, but no text appears anywhere** — Accessibility isn't granted (macOS), or the RemoteDesktop portal was declined (Linux). The transcript is still on your clipboard, so paste it manually to confirm that's the issue.

**Text stopped appearing after I rebuilt** — see the ad-hoc signing note under [Permissions](#permissions). Re-grant Accessibility.

**Nothing types at a `sudo` / password prompt** — macOS Secure Input blocks synthesized keystrokes by design. Dictating into **Ghostty** works anyway (it uses Ghostty's API, not keystrokes); other apps can't be worked around.

**"Model not found"** — Boo looked in `~/.boo/models/`, `./models/`, and the repo checkout. Put `ggml-base.en.bin` in one of them, or set `BOO_MODEL=/path/to/model.bin` (Linux).

**The hotkey does nothing (Linux)** — the GlobalShortcuts portal was declined, or your desktop rebound it. Use the Record button; re-approve by restarting Boo.

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

```sh
zig build app -Doptimize=ReleaseFast
./bundle.sh              # -> zig-out/Boo.app
./scripts/make-dmg.sh    # -> zig-out/Boo-<version>-<arch>.dmg
```

`make-dmg.sh` mounts the image and checks the bundle before declaring success, so a broken DMG fails here rather than on someone else's machine.

Pushing a `v*` tag runs the release workflow, which builds the DMG and publishes a GitHub Release. Bump the version in `build.zig.zon`, `macos/project.yml`, and `bundle.sh` first — then:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Tests

```sh
zig build test           # Zig core
./linux/tests/run.sh     # XDG portal payloads (needs gtk4; runs on macOS too)
```

The portal tests matter more than they look: GVariant format strings are parsed at *runtime*, so a malformed D-Bus payload compiles cleanly and then aborts on a user's desktop. These assert the exact signature each portal method expects.

CI builds both platforms on every push. The Linux job is what actually proves the GTK4 frontend links — it can't be linked on a macOS dev box.

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
  tests/            XDG portal payload tests
  flatpak/          Manifest, .desktop entry, AppStream metainfo

themes/             486 Ghostty-format color themes (consumed by the macOS
                    frontend; Linux port pending)
assets/             App icons, Metal shader, mel filterbank

scripts/
  build-zig-libs.sh Repacks Zig's whisper archive for macOS ld
  make-dmg.sh       Packages Boo.app into a distributable DMG

.github/workflows/  CI (build both platforms, portal tests) + release

build.zig           OS-conditional Zig build orchestration
bundle.sh           macOS: ad-hoc / re-sign helper
```

## Inspiration

[Ghostty](https://github.com/ghostty-org/ghostty) is the most coherent example of "Zig core + native apprt per OS" in the wild. Boo borrows the pattern wholesale: stable C API as the contract, comptime-dispatched OS backends, no shared GUI toolkit. The trade-off is more code per platform; the payoff is each frontend feeling truly native instead of a webview pretending to be one.

## License

[MIT](LICENSE) — same as whisper.cpp and Ghostty, the projects Boo stands on.
