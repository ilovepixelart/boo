# Security

## Reporting a vulnerability

Please report security issues privately via [GitHub Security Advisories](https://github.com/ilovepixelart/boo/security/advisories/new) rather than a public issue. There is no bounty; this is a personal project.

## Threat model

Boo's central promise is that **your audio never leaves the machine.** It has no network code — no telemetry, no analytics, no update check, no model download from within the app. The transcript is produced entirely on-device by `whisper.cpp`. You can verify this: the shipped binary links no networking symbols, and `grep` for `socket`/`http`/`URLSession` across the source finds only the text of the "how to download a model" help messages.

The interesting surface is the opposite direction — Boo **injects text into other applications**, which inherently means holding capabilities (keyboard synthesis, terminal automation) that could be abused. The review below is about not leaking or misusing those.

## What has been reviewed

**Text injection into AppleScript (macOS).** The transcript is interpolated into an AppleScript string literal to drive Ghostty's `input text`. This is escaped (backslash first, then quote) so a transcript cannot break out of the literal and run arbitrary script. Verified adversarially: payloads like `" & (do shell script "…") & "` round-trip through AppleScript exactly equal to the input, and no injected command runs. The escaper carries a comment marking it a security boundary.

**The RemoteDesktop restore token (Linux).** Auto-paste persists a portal restore token so the permission dialog appears only once. That token is a capability — it restores a session that can synthesize keyboard input — so it is written `0600` in `$XDG_STATE_HOME/boo/`, not the library default of `0644`.

**Sandbox permissions (Linux Flatpak).** Least-privilege: only Boo's own data directory (`xdg-data/boo`), the PipeWire socket, and the two portals it actually uses (GlobalShortcuts, RemoteDesktop). It talks to nothing else.

**Permission prompts.** Boo asks for each OS permission once, and only when first needed — Accessibility on macOS is requested at the first fallback paste, not at launch, so users who only dictate into Ghostty never grant it. The Linux hotkey is bound through the portal's own consent dialog.

## Known, accepted limitations

- **The clipboard is used as a paste channel.** Transcripts pass through the system clipboard (on macOS the prior contents are restored afterward). A clipboard manager will see them. This is inherent to pasting.
- **macOS builds are ad-hoc signed, not notarized.** They carry no Developer ID. Verify the download's checksum against the release if that matters to you.
- **On X11, display access is not isolated.** Any X11 client can observe input to any other — a property of X11, not of Boo. Wayland does not have this.
