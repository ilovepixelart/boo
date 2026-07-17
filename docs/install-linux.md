# Boo on Linux

Everything a Linux user needs: install, model, portal permissions,
troubleshooting.

> **Preview.** Recording, transcription and both portal grants are verified,
> but nobody has yet run Boo on a real GNOME/KDE desktop, so the grant dialogs
> you'll see are untested. See [platform-status.md](platform-status.md). Bug
> reports welcome.

## Install

```sh
flatpak install --user boo-<version>-x86_64.flatpak
```

The model goes inside the sandbox's data dir. Parakeet is the best pick: near
large-v3 accuracy at `base.en` speed, 25 languages, auto-detected (669 MB):

```sh
mkdir -p ~/.var/app/com.boo.app/data/boo/models
curl -L -o ~/.var/app/com.boo.app/data/boo/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin

flatpak run com.boo.app
```

Want a smaller, faster first download? `base.en` is 148 MB, English-only:

```sh
curl -L -o ~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Model alternatives, streaming, and non-English dictation:
[models.md](models.md).

Your desktop will ask once to allow the global shortcut, and once to allow
remote input (used to paste). Both grants persist. Decline either and Boo
still works from the Record button, copying to the clipboard.

## Permissions

All mediated by portals, so you'll see desktop dialogs rather than a settings
pane. The failure mode is silent: it records fine and the text simply never
arrives.

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** (PipeWire) | Everything | First recording |
| **GlobalShortcuts** portal | The Ctrl+Shift+Space hotkey | First launch |
| **RemoteDesktop** portal | Auto-paste into other apps | First launch |

**You approve each of these exactly once, ever.** For auto-paste, Boo stores
the portal's restore token and replays it. For the hotkey, it asks the portal
what it already has (`ListShortcuts`) before asking to bind anything, so a
shortcut approved on a previous run is reused silently rather than
re-prompting you at every launch. Decline either and Boo stays usable: it
falls back to the Record button and the clipboard.

> ### ⚠️ The global hotkey needs GNOME 48+, KDE Plasma, or Hyprland
>
> GNOME only shipped a GlobalShortcuts portal backend in **version 48**
> (Feb 2025). On **GNOME 46 (what Ubuntu 24.04 LTS ships) and GNOME 47, the
> interface does not exist at all**, so no application can register a global
> hotkey, Boo included. Verified against a real GNOME 46 desktop: the D-Bus
> call comes back `No such interface "org.freedesktop.portal.GlobalShortcuts"`.
>
> Boo detects this and tells you, rather than leaving you pressing a key that
> does nothing. **Auto-paste still works**, GNOME 46 does implement
> RemoteDesktop, so Boo remains fully usable from the Record button, and the
> transcript still lands in your focused app.
>
> Check yours with `gnome-shell --version`, or use KDE Plasma / Hyprland,
> which have had GlobalShortcuts for longer.

Note the hotkey is a *request*: the portal dialog lets you rebind it, and some
desktops ignore the preference. Whatever you end up with is what fires.

## Troubleshooting

**The hotkey does nothing**, most likely your desktop has no GlobalShortcuts
portal at all. GNOME only gained one in **48**, so on Ubuntu 24.04 LTS
(GNOME 46) the hotkey cannot work for any app. Boo says so on launch.
Everything else still works, use the Record button; the transcript is still
pasted into your focused app. Otherwise: the grant was declined (restart Boo
to be re-asked), or your desktop rebound the trigger, which it is free to do.

**Recording works, but no text appears anywhere**, the RemoteDesktop portal
was declined. The transcript is still on your clipboard, so paste it manually
to confirm that's the issue.

**Boo records but the transcript is empty**, check Boo is picking up your
default PipeWire source (`pactl info`, `wpctl status`). A bug report with your
desktop, compositor and PipeWire version is genuinely useful.

**"Model not found"**, Boo looks at `$BOO_MODEL`, `./models/`,
`$XDG_DATA_HOME/boo/models/`, then `/usr/share/boo/models/`. Under Flatpak
that means `~/.var/app/com.boo.app/data/boo/models/ggml-base.en.bin`.

**Transcripts are garbage**, `base.en` is small and English-only. Try a
bigger model ([models.md](models.md)), and check your input device is the mic
you think it is.
