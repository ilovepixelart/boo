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
              boo_init() · boo_start_recording()
              boo_stop_recording() · boo_get_waveform()
              boo_transcribe() · boo_deinit()
```

## Why

Most dictation tools either send audio to the cloud or feel foreign on each OS. Boo runs [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) on-device and ships a native frontend per platform, no WebView, no Electron, no shared lowest-common-denominator UI toolkit.

The architecture is heavily inspired by [Ghostty](https://github.com/ghostty-org/ghostty): a portable Zig core (`libboo-core`) exposed through a stable C API, plus a separate "apprt" (application runtime) per OS. Same philosophy, *cross-platform shouldn't mean foreign*.

## Status

| Platform | Audio backend | Frontend | Build path | Status |
|---|---|---|---|---|
| macOS 14+ (Apple Silicon + Intel) | CoreAudio | Swift + AppKit | xcodegen → Xcode | ✅ Working |
| Linux (Wayland/X11) | PipeWire (native) | GTK4 + libadwaita | `zig build app` | ⚠️ Preview |
| Windows 10+ (x86_64) | WASAPI | Win32 (C) | `zig build app` | 🧪 Experimental |

**Preview** means machine-verified but not yet human-verified: on Linux, audio capture and both portal handshakes pass real end-to-end tests, but nobody has driven the UI on a real desktop. **Experimental** is one notch below: Windows compiles, links and passes the core's tests on real Windows runners in CI, but nobody has dictated on real hardware yet. The precise verified/unverified ledger is in [docs/platform-status.md](docs/platform-status.md); working through [`windows/tests/manual.md`](windows/tests/manual.md) on a real machine is what promotes Windows to preview, and bug reports count.

## Quick start

### macOS

**1. Install.** Grab the `.dmg` for your Mac from [Releases](https://github.com/ilovepixelart/boo/releases), `arm64` for Apple Silicon, `x86_64` for Intel, and drag Boo to Applications.

Boo is **ad-hoc signed, not notarized** (notarization needs a paid Apple Developer ID). So on first launch macOS blocks it with:

> Apple could not verify "Boo" is free of malware that may harm your Mac or compromise your privacy.

That is expected. Clear the quarantine flag once, and it opens normally from then on:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

Prefer not to run a shell command? Double-click Boo, dismiss the dialog, then go to **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway**. Note that button only appears for about an hour after the blocked launch, if you don't see it, double-click Boo again first.

> Control-clicking the app and choosing **Open** does **not** work: [Apple removed that bypass in macOS 15](https://developer.apple.com/news/?id=saqachfa). Most guides on the internet still tell you to do it.

**2. Get a model.** Boo needs a `whisper.cpp` GGML model, none is bundled (they're 140 MB+). `base.en` is a good default:

```sh
mkdir -p ~/.boo/models
curl -L -o ~/.boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Boo also checks `./models/` and, when run from a source checkout, the repo's own `models/`. See [Choosing a model](#choosing-a-model) for the alternatives.

**3. Launch it and grant permissions.** Boo asks for the microphone on first launch, and for Accessibility (used to paste into apps). See [Permissions](#permissions). If you skip these, Boo records but nothing lands anywhere.

**4. Dictate.** Focus any app, press **Ctrl+Shift+Space**, speak, press it again. The text appears where your cursor is.

### Linux (preview)

> **Preview.** Recording, transcription and both portal grants are verified, but nobody has yet run Boo on a real GNOME/KDE desktop, so the grant dialogs you'll see are untested. See [Status](#status). Bug reports welcome.

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

### Windows (experimental)

> **Experimental.** Compiles and passes the core tests in CI, but has not yet been run on real Windows hardware. See [Status](#status).

**1. Install.** Grab `boo-<version>-windows-x86_64.zip` from [Releases](https://github.com/ilovepixelart/boo/releases) and extract it anywhere. The exe is unsigned, so the first launch shows SmartScreen's "Windows protected your PC": click **More info → Run anyway**. That is the Windows analog of the macOS quarantine note above, and just as expected.

**2. Get a model.** curl ships with Windows 10 1803+:

```bat
mkdir "%USERPROFILE%\.boo\models"
curl.exe -L -o "%USERPROFILE%\.boo\models\ggml-base.en.bin" ^
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

**3. Launch it.** Boo lives in the notification area (tray); Windows 11 hides new tray icons in the overflow flyout by default, so drag it out to pin it. There are no permission prompts: desktop apps use the mic unless the global toggle in **Settings → Privacy & security → Microphone** blocks them, and pasting needs no permission at all.

**4. Dictate.** Focus any app, press **Ctrl+Shift+Space**, speak, press it again. The text is pasted where your cursor is and stays on the clipboard.

## Using Boo

On macOS, Boo lives in the menu bar (a waveform icon) plus a small overlay window. On Linux it's a single window. On Windows it's a tray icon plus a small always-on-top overlay that never takes focus. The settings dialog and theme picker are macOS-only for now.

| Action | macOS | Linux | Windows |
|---|---|---|---|
| Start / stop dictation | **Ctrl+Shift+Space** | **Ctrl+Shift+Space** | **Ctrl+Shift+Space** |
| …from the app | Menu-bar icon, Record button, or waveform | Record button | Record button or tray menu |
| Recording elapsed time | Live timer in the menu bar |, |, |
| Past transcripts | Stack up in the window; click a bubble to copy | Last transcript shown | Last transcript shown |
| Settings | **⌘,** |, |, |

Every transcript is **copied to the clipboard** and **pasted into whatever app was focused** when you started recording. Boo deliberately targets the app you came from, never itself, so triggering it from its own window still delivers the text to the right place.

**Settings (⌘,, macOS)** has two things worth knowing:

- **Auto-type** (on by default). Turn it off to make Boo clipboard-only: it will transcribe and copy, but never type into other apps.
- **Theme**, 486 [Ghostty-format](https://ghostty.org) color themes, searchable. Defaults to Ghostty's own.

## Choosing a model

Any GGML model from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) works, 33 of them, plus NVIDIA Parakeet from [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF). Point Boo at one by dropping it in `~/.boo/models/` (`%USERPROFILE%\.boo\models` on Windows), or set `BOO_MODEL=/path/to/model.bin` (Linux and Windows).

The ones worth knowing about:

| Model | Size | Notes |
|---|---|---|
| `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | 669 MB | **The best pick.** Near large-v3 accuracy at base.en speed; 25 European languages, auto-detected. |
| `ggml-base.en.bin` | 148 MB | **The default.** English-only, fast, good enough for dictation. |
| `ggml-base.en-q5_1.bin` | 60 MB | Same model, quantized. Nearly as accurate, less than half the size. |
| `ggml-tiny.en-q5_1.bin` | 32 MB | Fastest, noticeably worse. For weak hardware. |
| `ggml-small.en.bin` | 488 MB | Clearly better than base; still quick on Apple Silicon. |
| `ggml-large-v3-turbo-q5_0.bin` | 574 MB | **Best whisper accuracy per byte.** Multilingual, far faster than large-v3. |

With several models installed, Boo picks the most capable one it recognizes: `parakeet`, then `large-v3-turbo` (either flavor), then `small.en`, then `base.en`, before falling back alphabetically. On an Apple Silicon GPU, Parakeet transcribes at ~120x realtime (11s of audio in under 100ms); turbo runs at ~20x.

The `.en` models are English-only. Everything else is multilingual, but see below, or they'll silently produce English.

### Streaming transcription (optional)

Drop a Silero VAD model next to your speech model and Boo transcribes each phrase *while you're still talking*, at the natural pauses. Committed text appears live in the overlay, and stopping only waits for the final phrase instead of the whole recording, so long dictations land near-instantly:

```sh
curl -L -o ~/.boo/models/ggml-silero-v6.2.0.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
```

It's less than 1 MB. Without it, Boo transcribes the whole recording after you stop, as before. `BOO_VAD_MODEL=/path/to/model.bin` overrides the search, matching `BOO_MODEL`.

### Non-English dictation

Boo transcribes in **English by default**, because the recommended model is English-only. With a multilingual model, that default would silently *translate* your speech into English rather than transcribe it. Override it:

```sh
BOO_LANG=de   boo-app      # German
BOO_LANG=auto boo-app      # let whisper detect the language
```

`BOO_LANG` has no effect on `.en` models: they can only ever produce English. It also has no effect on Parakeet models, which auto-detect the language on their own.

## Ghostty integration

Boo is a companion for [Ghostty](https://ghostty.org). On macOS it injects text through Ghostty's own AppleScript API: no clipboard involved, it keeps working under Secure Input (password prompts), and it needs only the one-time Automation permission instead of Accessibility. On Linux and Windows it uses the regular clipboard + paste path, which Ghostty and the stock terminals handle fine. The full story, including the Linux paste-chord nuances: [docs/ghostty.md](docs/ghostty.md).

## Permissions

Boo can't do its job without these, and the failure mode is silent: it records fine and the text simply never arrives.

**macOS**

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** | Everything | First launch |
| **Automation** → Ghostty | The Ghostty fast path; falls back to ⌘V | First dictation into Ghostty |
| **Accessibility** | Auto-paste into apps other than Ghostty | First time it's actually needed |

Boo asks for **Accessibility only when it first has to synthesize a ⌘V**, never at launch. Dictating into Ghostty uses its AppleScript API instead, so if that's all you do, you'll never see the "Boo would like to control this computer" prompt at all. Decline it and Boo still transcribes and copies to the clipboard; it just won't paste for you.

Grant them under **System Settings → Privacy & Security**. If you dismissed a prompt, add Boo manually there.

> **If you build from source:** ad-hoc signed builds get a *new code identity every rebuild*, so macOS treats each build as a different app and quietly drops the permissions you granted the last one. Symptom: dictation that worked yesterday silently stops typing. Re-grant, or sign with a stable identity (`BOO_CODESIGN_IDENTITY=... ./bundle.sh`).

**Linux**, all mediated by portals, so you'll see desktop dialogs rather than a settings pane:

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** (PipeWire) | Everything | First recording |
| **GlobalShortcuts** portal | The Ctrl+Shift+Space hotkey | First launch |
| **RemoteDesktop** portal | Auto-paste into other apps | First launch |

**You approve each of these exactly once, ever.** For auto-paste, Boo stores the portal's restore token and replays it. For the hotkey, it asks the portal what it already has (`ListShortcuts`) before asking to bind anything, so a shortcut approved on a previous run is reused silently rather than re-prompting you at every launch. Decline either and Boo stays usable: it falls back to the Record button and the clipboard.

> ### ⚠️ The global hotkey needs GNOME 48+, KDE Plasma, or Hyprland
>
> GNOME only shipped a GlobalShortcuts portal backend in **version 48** (Feb 2025). On **GNOME 46 (what Ubuntu 24.04 LTS ships) and GNOME 47, the interface does not exist at all**, so no application can register a global hotkey, Boo included. Verified against a real GNOME 46 desktop: the D-Bus call comes back `No such interface "org.freedesktop.portal.GlobalShortcuts"`.
>
> Boo detects this and tells you, rather than leaving you pressing a key that does nothing. **Auto-paste still works**, GNOME 46 does implement RemoteDesktop, so Boo remains fully usable from the Record button, and the transcript still lands in your focused app.
>
> Check yours with `gnome-shell --version`, or use KDE Plasma / Hyprland, which have had GlobalShortcuts for longer.

Note the hotkey is a *request*: the portal dialog lets you rebind it, and some desktops ignore the preference. Whatever you end up with is what fires.

**Windows**: no prompts at all, which cuts both ways:

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** (global toggle) | Everything | Never; desktop apps are allowed unless **Settings → Privacy & security → Microphone** blocks them all |
| Paste / hotkey | n/a | Never; `SendInput` and `RegisterHotKey` need no grant |

Two Windows-specific caveats. **Elevated windows**: pasting into an admin terminal or regedit is silently blocked by Windows (UIPI); the transcript is still on the clipboard and Boo's status line says to press Ctrl+V yourself. **The hotkey**: while Boo runs, Ctrl+Shift+Space is global, so Word/Outlook's nonbreaking-space shortcut won't reach them, and on multi-language systems Ctrl+Shift alone may still switch keyboard layout. If another app grabbed the combo first, Boo says so and the Record button keeps working.

## Troubleshooting

**"Apple could not verify Boo is free of malware"**, expected; the app is ad-hoc signed rather than notarized. Run `xattr -dr com.apple.quarantine /Applications/Boo.app`, or use **System Settings → Privacy & Security → Open Anyway**. Control-click → Open does *not* work on macOS 15+.

**Recording works, but no text appears anywhere**, Accessibility isn't granted (macOS), or the RemoteDesktop portal was declined (Linux). The transcript is still on your clipboard, so paste it manually to confirm that's the issue.

**Text stopped appearing after I rebuilt**, see the ad-hoc signing note under [Permissions](#permissions). Re-grant Accessibility.

**Nothing types at a `sudo` / password prompt**, macOS Secure Input blocks synthesized keystrokes by design. Dictating into **Ghostty** works anyway (it uses Ghostty's API, not keystrokes); other apps can't be worked around.

**"Model not found"**, on macOS Boo looks in `~/.boo/models/`, `./models/`, and the repo checkout. On Linux it looks at `$BOO_MODEL`, `./models/`, `$XDG_DATA_HOME/boo/models/`, then `/usr/share/boo/models/`. Under Flatpak that means `~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin`.

**The hotkey does nothing (Linux)**, most likely your desktop has no GlobalShortcuts portal at all. GNOME only gained one in **48**, so on Ubuntu 24.04 LTS (GNOME 46) the hotkey cannot work for any app. Boo says so on launch. Everything else still works, use the Record button; the transcript is still pasted into your focused app. See [Permissions](#permissions). Otherwise: the grant was declined (restart Boo to be re-asked), or your desktop rebound the trigger, which it is free to do.

**Boo records but the transcript is empty (Linux)**, most likely the known gap: audio capture is unverified on Linux (see [Status](#status)). Check Boo is picking up your default PipeWire source (`pactl info`, `wpctl status`). A bug report with your desktop, compositor and PipeWire version is genuinely useful.

**Transcripts are garbage**, `base.en` is small and English-only. Try a bigger model (`small`, `medium`), and check your input device is the mic you think it is.

**"Windows protected your PC"**: expected; the exe is unsigned, so SmartScreen warns on the first launch of each release. **More info → Run anyway**. The `SHA256SUMS` file on the release page is the integrity check that replaces a signature.

**No text arrives in an admin window (Windows)**: Windows blocks synthesized input into elevated apps (UIPI) by design. The transcript is on the clipboard; press Ctrl+V yourself.

**The tray icon is missing (Windows 11)**: it's in the taskbar overflow flyout (the ^ chevron); drag it onto the taskbar to pin it. Windows hides new tray icons by default and offers apps no way around that.

## Developing

```sh
zig build test                             # core unit tests, any OS
zig build app                              # native app (Linux/Windows; macOS needs one extra step)
zig build run -- models/ggml-base.en.bin   # bare-bones CLI REPL, no GUI
```

Per-platform build guides, packaging, the release checklist, the full test-suite map, and the project layout live in [docs/development.md](docs/development.md).

## Inspiration

[Ghostty](https://github.com/ghostty-org/ghostty) is the most coherent example of "Zig core + native apprt per OS" in the wild. Boo borrows the pattern wholesale: stable C API as the contract, comptime-dispatched OS backends, no shared GUI toolkit. The trade-off is more code per platform; the payoff is each frontend feeling truly native instead of a webview pretending to be one.

## Security

Boo has no network code, your audio never leaves the machine, and there's nothing to verify that against because there's nothing there. The text-injection paths (which do hold real capabilities) and the sandbox permissions are documented in [SECURITY.md](SECURITY.md), along with how to report an issue.

## License

[MIT](LICENSE), same as whisper.cpp and Ghostty, the projects Boo stands on.
