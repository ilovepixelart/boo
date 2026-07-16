# Windows manual verification checklist

CI proves the Windows target compiles, links, and passes the core's unit tests
(`windows-cross`, `windows-native` jobs). What CI cannot prove is behavior
against real hardware: a microphone, a desktop, focus, the clipboard. That is
this checklist, the same bar the Linux port had to clear before its README
checkmarks. Run it on a physical Windows 10/11 machine (a VM is fine for
everything except audio quality); check items off in the PR that claims them.

Clause ids refer to [docs/specs/windows-support.md](../../docs/specs/windows-support.md).

## Audio (`manual:audio`)

- [ ] **WIN-003** CLI REPL end to end: `zig build run -- path\to\ggml-base.en.bin`,
      speak a sentence, transcript matches. Compare accuracy informally against
      the same sentence on macOS (engine resampler sanity check).
- [ ] **WIN-004** Format fallback: dictate through a stereo/array USB mic, then
      through the built-in mic. Both transcribe.
- [ ] **WIN-005** Privacy toggle: turn off Settings > Privacy & security >
      Microphone > "Let desktop apps access your microphone", launch: the error
      dialog names the setting. Turn it back on: works again.
- [ ] Device loss: unplug a USB mic mid-recording. The take ends by itself and
      transcribes what was captured; no hang, no crash.
- [ ] Cap: leave a recording running 10 minutes. It stops itself, the status
      says so, and the transcript appears. A very long transcript shows
      truncated (ellipsis at the end) in the overlay while the clipboard
      carries the full text.

## Frontend (`manual:frontend`)

- [ ] **WIN-012** Focus (the core promise): focus Notepad, click Boo's Record
      button, dictate, click Stop. The caret never leaves Notepad and the text
      lands there. Repeat with a drag of the overlay in between.
- [ ] **WIN-013** Hotkey: Ctrl+Shift+Space toggles from any app. Register a
      conflicting hotkey first (e.g. AutoHotkey) and relaunch Boo: the status
      line says the combo is taken, Record button still works.
- [ ] **WIN-013** Hotkey over an elevated window: focus an elevated Notepad,
      press the hotkey. Expected (community-documented, unconfirmed): recording
      still toggles. Record the actual result here.
- [ ] **WIN-014** Delivery: dictate into (a) Notepad, (b) Windows Terminal,
      (c) a browser text box. Text arrives in all three; the clipboard holds it
      afterwards.
- [ ] **WIN-014** Elevated target: dictate into an elevated terminal. The paste
      is blocked (UIPI), the status says "press Ctrl+V", and manual Ctrl+V
      works.
- [ ] **WIN-014** Held modifiers: keep Ctrl+Shift physically held for a second
      after the stop-hotkey. No Ctrl+Shift+V side effect in the target, no
      stuck modifiers afterwards.
- [ ] **WIN-011** Tray: icon appears (pin it from the overflow flyout on
      Win 11), left click hides/shows the overlay, right click offers
      Record/Quit, tooltip flips to "recording". Kill Explorer in Task Manager
      and restart it: the icon comes back.
- [ ] **WIN-015** Recording UX: waveform moves while speaking, button flips
      Record/Stop/Transcribing, "(no speech detected)" on a silent take.
- [ ] **WIN-016** Model discovery: works from `%USERPROFILE%\.boo\models`; with
      no model, the dialog's curl command works when pasted into a terminal.
- [ ] **WIN-017** Second launch: starting boo-app.exe again just surfaces the
      first instance's overlay.
- [ ] DPI: drag the overlay between a 100% and a 150% monitor; layout scales,
      text stays crisp.
- [ ] Dark mode: flip Settings > Personalization > Colors > "Choose your mode";
      the overlay follows without restart.

## Packaging

- [ ] **WIN-030** Release zip: download from GitHub (not a local copy, so it
      carries Mark-of-the-Web), extract with Explorer, launch: SmartScreen
      shows "Windows protected your PC"; More info > Run anyway works, as the
      README documents.
