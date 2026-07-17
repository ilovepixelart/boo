# Boo on Windows

Everything a Windows user needs: install, model, the permission model,
troubleshooting. Requires Windows 10+.

> **Experimental.** Compiles and passes the core tests in CI, but has not yet
> been run on real Windows hardware. See
> [platform-status.md](platform-status.md).

## Install

Pick the zip for your CPU from
[Releases](https://github.com/ilovepixelart/boo/releases):

- `boo-<version>-windows-x86_64.zip` for a normal Intel/AMD PC.
- `boo-<version>-windows-arm64.zip` for Windows on ARM (Copilot+ PCs, Surface
  Pro X, and Windows VMs on Apple Silicon). The x86_64 build only runs there
  under emulation, and it can crash with an illegal-instruction error;
  `Get-CimInstance Win32_Processor | Select Architecture` returns `12` on ARM.

Extract it anywhere. Then:

1. Open the extracted folder.
2. Run the file named **`boo-app.exe`**.
3. The exe is unsigned, so Windows shows SmartScreen's **"Windows protected
   your PC"**. The button you want is:
   - **More info**
   - **Run anyway**

If you *don't* get that prompt but the app still won't start, Windows has
silently blocked the file (Mark-of-the-Web). Unblock it once:

1. Right-click **`boo-app.exe`** → **Properties**
2. On the **General** tab, at the bottom, tick **Unblock** if the checkbox is
   present
3. **OK**, then run it again

This is the Windows analog of macOS's quarantine flag, and just as expected.
The `SHA256SUMS` file on the release page lets you verify the download is
intact.

## Get a model

`curl.exe` ships with Windows 10 1803+ (the `.exe` matters: it's the real curl,
not PowerShell's `curl` alias). In **PowerShell** (the Windows 11 default),
paste each line on its own, no line continuation:

Parakeet is the best pick: near large-v3 accuracy at `base.en` speed, 25
languages, auto-detected (669 MB):

```powershell
mkdir "$env:USERPROFILE\.boo\models" -Force
curl.exe -L -o "$env:USERPROFILE\.boo\models\ggml-parakeet-tdt-0.6b-v3-q8_0.bin" https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin
```

Want a smaller, faster first download? `base.en` is 148 MB, English-only:

```powershell
curl.exe -L -o "$env:USERPROFILE\.boo\models\ggml-base.en.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

In the classic **Command Prompt** it's `%USERPROFILE%` instead of
`$env:USERPROFILE`. Don't split the `curl.exe` line, the `^` and backtick
continuation characters differ between the two shells and are a common paste
error.

Model alternatives, streaming, and non-English dictation:
[models.md](models.md).

## Launch

Boo lives in the notification area (tray); Windows 11 hides new tray icons in
the overflow flyout by default, so drag it out to pin it.

## Permissions

No prompts at all, which cuts both ways:

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** (global toggle) | Everything | Never; desktop apps are allowed unless **Settings → Privacy & security → Microphone** blocks them all |
| Paste / hotkey | n/a | Never; `SendInput` and `RegisterHotKey` need no grant |

Two Windows-specific caveats. **Elevated windows**: pasting into an admin
terminal or regedit is silently blocked by Windows (UIPI); the transcript is
still on the clipboard and Boo's status line says to press Ctrl+V yourself.
**The hotkey**: while Boo runs, Ctrl+Shift+Space is global, so Word/Outlook's
nonbreaking-space shortcut won't reach them, and on multi-language systems
Ctrl+Shift alone may still switch keyboard layout. If another app grabbed the
combo first, Boo says so and the Record button keeps working.

## Troubleshooting

**"Windows protected your PC"**: expected; the exe is unsigned, so SmartScreen
warns on the first launch of each release. **More info → Run anyway**. The
`SHA256SUMS` file on the release page is the integrity check that replaces a
signature.

**No text arrives in an admin window**: Windows blocks synthesized input into
elevated apps (UIPI) by design. The transcript is on the clipboard; press
Ctrl+V yourself.

**The tray icon is missing (Windows 11)**: it's in the taskbar overflow flyout
(the ^ chevron); drag it onto the taskbar to pin it. Windows hides new tray
icons by default and offers apps no way around that.

**"Model not found"**: Boo looks at `%BOO_MODEL%`,
`%USERPROFILE%\.boo\models`, `.\models`, then `%LOCALAPPDATA%\boo\models`.

**Transcripts are garbage**: `base.en` is small and English-only. Try a
bigger model ([models.md](models.md)), and check your input device is the mic
you think it is.
