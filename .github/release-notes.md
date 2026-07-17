### Downloads

| File | Platform |
|---|---|
| `Boo-<ver>-arm64.dmg` | macOS, Apple Silicon |
| `Boo-<ver>-x86_64.dmg` | macOS, Intel |
| `boo-<ver>-x86_64.flatpak` | Linux, x86_64, **preview, see below** |
| `boo-<ver>-windows-x86_64.zip` | Windows 10+, Intel/AMD, **experimental, see below** |
| `boo-<ver>-windows-arm64.zip` | Windows 10+, ARM (Copilot+ PCs, Surface, Apple Silicon VMs), **experimental** |
| `SHA256SUMS` | checksums for the above |

**Verify your download** (these builds aren't notarized, so this is your integrity check):

```sh
shasum -a 256 -c SHA256SUMS   # run in the folder you downloaded to
```

### macOS

Drag Boo to Applications. It is **ad-hoc signed, not notarized** (notarization needs a paid Apple Developer ID), so on first launch macOS blocks it with *"Apple could not verify Boo is free of malware…"*. That's expected. Clear the quarantine flag once and it opens normally from then on:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

…or double-click Boo, dismiss the dialog, then **System Settings → Privacy & Security → Open Anyway** (that button only shows for about an hour after the blocked launch).

Control-click → Open does **not** work, [Apple removed that bypass in macOS 15](https://developer.apple.com/news/?id=saqachfa).

### Linux, preview, and please read this

```sh
flatpak install --user boo-<ver>-x86_64.flatpak
flatpak run com.boo.app
```

**What is verified:** it builds and links; audio capture works (PipeWire → whisper, tested in a real VM); and the global hotkey and auto-paste complete their real XDG portal handshakes (GlobalShortcuts and RemoteDesktop), including the one-time permission grant that persists across restarts.

**What is not:** the portal handshakes are proven against a faithful mock portal rather than a real `xdg-desktop-portal-gnome`/`-kde`, and nobody has yet driven the GTK4 UI on a real desktop. So the protocol is right, but your desktop's actual grant dialogs are untested. Bug reports very welcome; that's why it's a preview.

The hotkey is **Ctrl+Shift+Space**. Your desktop will ask once to allow the shortcut and once to allow remote input; decline either and Boo still works from the Record button, copying to the clipboard.

> **⚠️ The hotkey needs GNOME 48+, KDE Plasma, or Hyprland.** GNOME only shipped a GlobalShortcuts portal in version 48, so on **Ubuntu 24.04 LTS (GNOME 46)** the interface does not exist and no app can register a global hotkey. Boo detects this and tells you. Auto-paste still works, so Boo is fully usable from the Record button.

### Windows, experimental, expectations first

Extract the zip anywhere and run `boo-app.exe`. It is **unsigned**, so SmartScreen shows *"Windows protected your PC"* on first launch: **More info → Run anyway**. The SHA256SUMS check above is the integrity story.

**What is verified:** the full app compiles, links, and passes the core test suite natively on Windows in CI, every push. **What is not:** nobody has yet dictated on real Windows hardware, so microphone capture, the tray icon, the hotkey, and auto-paste are design-validated but untested in the wild. Bug reports are gold; the checklist we need help with is [`windows/tests/manual.md`](https://github.com/ilovepixelart/boo/blob/master/windows/tests/manual.md).

Boo lives in the notification area, and Windows 11 hides new tray icons in the overflow flyout by default: drag the icon onto the taskbar to pin it. There are no permission prompts; the microphone works unless **Settings → Privacy & security → Microphone** blocks desktop apps. Pasting into elevated (admin) windows is blocked by Windows itself (UIPI); the transcript stays on the clipboard, press Ctrl+V yourself.

### You also need a model, and Boo fetches it for you

No speech model is bundled (they're 140 MB+). **Just launch Boo**: with no
model installed it opens a download dialog on every platform, a curated list
with sizes and tradeoffs, a progress bar, and every file verified against a
SHA-256 pinned in the binary. Settings has a model switcher to change or
download models later; an interrupted manual download is detected and offered
for re-download instead of failing. Prefer the shell? The manual `curl` steps
live in the per-OS [install guides](https://github.com/ilovepixelart/boo/tree/master/docs).

Then press **Ctrl+Shift+Space**, speak, and press it again.

A single recording is capped at **10 minutes**: Boo stops on its own and transcribes what it captured, rather than growing without limit and then freezing inside whisper.

On macOS, Boo needs **Microphone** and **Accessibility** permissions, plus **Automation** the first time it dictates into Ghostty. Without them it records fine and the text silently never arrives. See the [README](https://github.com/ilovepixelart/boo#permissions).

---
