# Boo on macOS

Everything a macOS user needs: install, model, permissions, troubleshooting.
Requires macOS 14+, Apple Silicon or Intel.

## Install

Grab the `.dmg` for your Mac from
[Releases](https://github.com/ilovepixelart/boo/releases), `arm64` for Apple
Silicon, `x86_64` for Intel, and drag Boo to Applications.

Boo is **ad-hoc signed, not notarized** (notarization needs a paid Apple
Developer ID). So on first launch macOS blocks it with:

> Apple could not verify "Boo" is free of malware that may harm your Mac or compromise your privacy.

That is expected. Clear the quarantine flag once, and it opens normally from
then on:

```sh
xattr -dr com.apple.quarantine /Applications/Boo.app
```

Prefer not to run a shell command? Double-click Boo, dismiss the dialog, then
go to **System Settings → Privacy & Security**, scroll to Security, and click
**Open Anyway**. Note that button only appears for about an hour after the
blocked launch, if you don't see it, double-click Boo again first.

> Control-clicking the app and choosing **Open** does **not** work:
> [Apple removed that bypass in macOS 15](https://developer.apple.com/news/?id=saqachfa).
> Most guides on the internet still tell you to do it.

## Get a model

Boo needs a GGML speech model, none is bundled. **The easy way: just launch
Boo.** With no model installed it offers a download dialog (curated list,
progress bar, checksum-verified), and you can change or download models later
in Settings. The manual way, if you prefer the shell: Parakeet is the best
pick, near large-v3 accuracy at `base.en` speed, 25 languages, auto-detected
(669 MB):

```sh
mkdir -p ~/.boo/models
curl -L -o ~/.boo/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin
```

Want a smaller, faster first download? `base.en` is 148 MB, English-only:

```sh
curl -L -o ~/.boo/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Boo also checks `./models/` and, when run from a source checkout, the repo's
own `models/`. Alternatives, streaming, and non-English dictation:
[models.md](models.md).

## Permissions

Boo can't do its job without these, and the failure mode is silent: it records
fine and the text simply never arrives.

| Permission | What breaks without it | When you're asked |
|---|---|---|
| **Microphone** | Everything | First launch |
| **Automation** → Ghostty | The Ghostty fast path; falls back to ⌘V | First dictation into Ghostty |
| **Accessibility** | Auto-paste into apps other than Ghostty | First time it's actually needed |

Boo asks for **Accessibility only when it first has to synthesize a ⌘V**,
never at launch. Dictating into Ghostty uses its AppleScript API instead, so
if that's all you do, you'll never see the "Boo would like to control this
computer" prompt at all. Decline it and Boo still transcribes and copies to
the clipboard; it just won't paste for you.

Grant them under **System Settings → Privacy & Security**. If you dismissed a
prompt, add Boo manually there.

> **⚠️ Accessibility does not survive an update.** Boo is ad-hoc signed, so
> *every build and every release* has a different code identity, and macOS
> pins the Accessibility grant to the identity it was granted to. Install a
> new version (or rebuild from source) and the switch still shows as enabled
> while no longer applying: dictation that worked yesterday silently stops
> pasting and the status line reads *"copied, grant Accessibility to
> auto-paste"*.
>
> **Toggling the switch off and on does not fix it**, that just re-enables the
> stale entry. Remove Boo with **−** from System Settings → Privacy &
> Security → Accessibility, then dictate once and **Allow** the fresh prompt.
> Equivalently, from a terminal: `tccutil reset Accessibility com.boo.app`,
> then relaunch Boo.
>
> **The free fix.** Building from source, run `./scripts/make-signing-cert.sh`
> once; `./bundle.sh` then signs every rebuild with one stable self-signed
> certificate, so macOS keeps the grant across rebuilds. Released builds get the
> same treatment once the project's stable certificate is configured
> (`scripts/make-release-cert.sh` plus the `BOO_SIGN_CERT_*` GitHub secrets), and
> the grant carries across updates from that release on. None of this needs a
> paid Apple account, that is only required for **notarization**, which removes
> the Gatekeeper "right-click → Open" step, not the permission reset.

## Ghostty

On macOS Boo injects text through Ghostty's own AppleScript API: no clipboard
involved, it keeps working under Secure Input (password prompts), and it needs
only the one-time Automation permission instead of Accessibility. The full
story: [ghostty.md](ghostty.md).

## Troubleshooting

**"Apple could not verify Boo is free of malware"**, expected; the app is
ad-hoc signed rather than notarized. Run
`xattr -dr com.apple.quarantine /Applications/Boo.app`, or use **System
Settings → Privacy & Security → Open Anyway**. Control-click → Open does
*not* work on macOS 15+.

**Recording works, but no text appears anywhere**, Accessibility isn't
granted. The transcript is still on your clipboard, so paste it manually to
confirm that's the issue.

**Text stopped appearing after I rebuilt or updated**, see the ad-hoc signing
note under [Permissions](#permissions). Re-grant Accessibility.

**It says "copied, grant Accessibility to auto-paste" but Accessibility is
already enabled.** The commonest report, and the switch is lying to you. The
grant belongs to a *previous* version's code identity (Boo is ad-hoc signed,
so each build/release differs), so it no longer applies. Toggling it off and
on re-enables the stale entry and changes nothing. Remove Boo with **−** from
System Settings → Privacy & Security → Accessibility, then dictate once and
**Allow** the fresh prompt, or run `tccutil reset Accessibility com.boo.app`
and relaunch. Your transcript is on the clipboard meanwhile, so ⌘V works by
hand.

**Dictating into Ghostty works but nothing pastes anywhere else.** Same cause
as above. Ghostty uses its AppleScript API (Automation), which needs no
Accessibility; every other app needs the ⌘V path, which does. If one works
and the other doesn't, it's the Accessibility grant, not the other app.

**Nothing types at a `sudo` / password prompt**, macOS Secure Input blocks
synthesized keystrokes by design. Dictating into **Ghostty** works anyway (it
uses Ghostty's API, not keystrokes); other apps can't be worked around.

**"Model not found"**, Boo looks in `~/.boo/models/`, `./models/`, and the
repo checkout.

**Transcripts are garbage**, `base.en` is small and English-only. Try a
bigger model ([models.md](models.md)), and check your input device is the mic
you think it is.
