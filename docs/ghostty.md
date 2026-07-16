# Ghostty integration

Boo is a companion for [Ghostty](https://ghostty.org), and gets text into it differently on each platform, because Ghostty's capabilities differ sharply between the two.

**macOS, through Ghostty's own API.** Ghostty 1.3+ ships an AppleScript interface, and Boo uses it: `input text` writes straight into the focused terminal's pty. This is strictly better than synthesizing keystrokes:

- it never touches your clipboard;
- it keeps working under **Secure Input**, the mode macOS enters at password prompts, which silently swallows synthesized keystrokes and breaks most dictation tools;
- it applies bracketed paste correctly and skips Ghostty's unsafe-paste confirmation;
- it needs only the one-time **Automation** permission, not Accessibility.

Everything else (older Ghostty, other apps) falls back to clipboard + ⌘V, which needs Accessibility.

**Linux, through the clipboard, because Ghostty has no injection API there.** Its D-Bus surface only opens windows; there's no way to hand it text. So Boo copies the transcript and synthesizes a single `Ctrl+Shift+V`, Ghostty's default paste binding, via the XDG RemoteDesktop portal. This works in any app that pastes on `Ctrl+Shift+V`, on GNOME and KDE alike, inside or outside Flatpak.

Boo pastes rather than types out each character on purpose: synthesized keystrokes are resolved against your active keyboard layout, so any character the layout can't produce (accents, smart quotes, em dashes) is silently dropped. One paste chord sidesteps that entirely.

One rough edge: on Linux, a transcript containing a newline can trip Ghostty's paste-protection prompt. At a normal shell prompt (which enables bracketed paste) you won't see it. The macOS path is exempt.

**Windows: no special case needed.** Ghostty has no Windows release, and unlike Linux the stock terminals already paste on plain Ctrl+V: Windows Terminal binds it by default, and the classic console has done so since Windows 10. Boo's one synthesized Ctrl+V works everywhere, so there is no per-app chord table.

