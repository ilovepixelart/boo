### Install (macOS)

Download the `.dmg` below and drag Boo to Applications.

Boo is **ad-hoc signed, not notarized** — Apple notarization requires a paid Developer ID. macOS will refuse to open it on first launch ("Boo is damaged" or "unidentified developer"). Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

…or right-click the app → **Open** → **Open**. You only do this once.

### You also need a model

No whisper model is bundled (they're 140 MB+):

```sh
mkdir -p ~/.boo/models
curl -L -o ~/.boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Then press **Ctrl+Shift+Space**, speak, and press it again.

Boo needs **Microphone** and **Accessibility** permissions, plus **Automation** the first time it dictates into Ghostty. Without them it records fine and the text silently never arrives — see the [README](https://github.com/ilovepixelart/boo#permissions).

### Linux

No prebuilt package yet. Build from source or via the Flatpak manifest — see the [README](https://github.com/ilovepixelart/boo#build--linux). The Linux frontend builds in CI but has not been exercised against a live compositor; reports welcome.

---
