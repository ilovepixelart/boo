### Downloads

| File | Platform |
|---|---|
| `Boo-<ver>-arm64.dmg` | macOS, Apple Silicon |
| `Boo-<ver>-x86_64.dmg` | macOS, Intel |
| `boo-<ver>-x86_64.flatpak` | Linux, x86_64 — **preview, see below** |

### macOS

Drag Boo to Applications. It is **ad-hoc signed, not notarized** (notarization needs a paid Apple Developer ID), so macOS refuses to open it on first launch — "Boo is damaged" or "unidentified developer". Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

…or right-click the app → **Open** → **Open**. Once only.

### Linux — preview, and please read this

```sh
flatpak install --user boo-<ver>-x86_64.flatpak
flatpak run com.boo.app
```

**What is verified:** it builds and links; audio capture works (PipeWire → whisper, tested in a real VM); and the global hotkey and auto-paste complete their real XDG portal handshakes (GlobalShortcuts and RemoteDesktop), including the one-time permission grant that persists across restarts.

**What is not:** the portal handshakes are proven against a faithful mock portal rather than a real `xdg-desktop-portal-gnome`/`-kde`, and nobody has yet driven the GTK4 UI on a real desktop. So the protocol is right, but your desktop's actual grant dialogs are untested. Bug reports very welcome; that's why it's a preview.

The hotkey is **Ctrl+Shift+Space**. Your desktop will ask once to allow the shortcut and once to allow remote input; decline either and Boo still works from the Record button, copying to the clipboard.

### You also need a model

No whisper model is bundled (they're 140 MB+):

```sh
# macOS
mkdir -p ~/.boo/models
curl -L -o ~/.boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

# Linux (Flatpak)
mkdir -p ~/.var/app/com.boo.app/data/boo/models
curl -L -o ~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Then press **Ctrl+Shift+Space**, speak, and press it again.

On macOS, Boo needs **Microphone** and **Accessibility** permissions, plus **Automation** the first time it dictates into Ghostty. Without them it records fine and the text silently never arrives — see the [README](https://github.com/ilovepixelart/boo#permissions).

---
