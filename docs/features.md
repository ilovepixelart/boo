# Boo features and cross-platform UAT

Every Boo feature, its status on each platform, and how to accept it. Use the
Status columns as a UAT checklist: run the "How to test" step on each OS and
mark it. `Y` works, `~` partial/differs, `-` missing, `n/a` not applicable.
This is the behavior-parity ground truth; the UI target is [ui-spec.md](ui-spec.md),
and the macOS build is the reference for both.

Legend: **M** macOS, **L** Linux, **W** Windows. Windows parity marks are
compile-verified. Linux was exercised end to end under Xvfb (launch, record
morph, cards, dictation through a virtual PipeWire mic); portals, tray, and
real-mic acceptance still runs on real hardware against this table.

## 1. Capture and transcription

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| Local, on-device transcription (whisper.cpp), nothing uploaded | Y | Y | Y | Dictate offline; text appears |
| Engine auto-select by model filename (whisper / Parakeet TDT) | Y | Y | Y | Drop a `ggml-parakeet-*` model; it loads |
| Most-capable installed model wins (parakeet > large-v3-turbo > small.en > base.en) | Y | Y | Y | Install two models; the better loads |
| Streaming transcription at VAD pauses (needs `ggml-silero-*`) | Y | Y | Y | With silero present, partial text appears while speaking |
| Batch transcription (no VAD model) | Y | Y | Y | Remove silero; full text appears on stop |
| Silence-hallucination hardening (no "Thank you." on silence) | Y | Y | Y | Record 3s of silence; empty/"no speech", not filler |
| Language via `BOO_LANG` (default en; `auto` detects) | Y | Y | Y | `BOO_LANG=de` a German utterance on a multilingual model |
| Warm-up preroll (first word not clipped) | Y | Y | Y | Start speaking immediately on hotkey; first word present |
| 10-minute cap with auto-stop + status | Y | Y | Y | Leave recording; it stops itself and transcribes |

## 2. Activation

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| Global hotkey **Ctrl+Shift+Space** toggles recording | Y | ~ | Y | Press it from another app; recording toggles (Linux needs GNOME 48+/KDE/Hyprland portal) |
| Hotkey **persistently visible** in the UI | Y | Y | Y | Idle window shows `ctrl+shift+space` at all times (L says `click record to dictate` when no portal granted it) |
| Record button in the window | Y | Y | Y | Click it; recording toggles |
| Trigger from tray/menu | Y | n/a | Y | Menu-bar/tray "Record" item toggles |
| Hotkey-conflict handling surfaced, not silent | Y | Y | Y | Bind the combo elsewhere first; UI says so, Record still works |

## 3. Delivery

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| **Text lands at the caret** of the focused input | Y | Y | Y | Put caret mid-sentence in an editor; dictate; text inserts there |
| Always copied to clipboard | Y | Y | Y | After a take, paste manually; transcript is there |
| Delivered to the app focused at record start, never Boo | Y | Y | Y | Trigger from Boo's own window; text still goes to the prior app |
| Explicit "copied / pasted" confirmation | ~ | Y | Y | Status/toast confirms the outcome (M shows in bubble) |
| Elevated/secure-input handling stated, not silent | Y | n/a | Y | Dictate into an admin window; told to press paste yourself |
| Ghostty fast path (pty insert, no clipboard, Secure Input safe) | Y | n/a | n/a | Dictate into Ghostty on macOS; no clipboard change |
| Auto-type toggle (clipboard-only mode) | Y | Y | Y | Settings > turn off Auto-type; transcript copies but doesn't paste |

## 4. Window and visual UI

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| Overlay window with a filled body | Y | Y | Y | Window shows content, no empty/black body |
| Live waveform while recording | Y | Y | Y | Speak; bars move |
| Live elapsed-time display during recording (`4s`, `1:23`) | Y | Y | Y | Record; a timer counts up |
| Waveform has 3 states (idle / recording / transcribing) with distinct colors | Y | Y | Y | Colors change across the take |
| Transcript **history cards** (stacked previous prompts) | Y | Y | Y | Several takes stack as cards |
| Each card has **copy** and **close/dismiss** buttons (same icons everywhere) | Y | Y | Y | Card has a copy icon and an × |
| Idle status/hotkey hint line | Y | Y | Y | Idle shows the hint |
| Shared brand accent (record red `#FF3B30`, default-theme state colors) | Y | Y | Y | Accent is Boo's, not the OS blue/adwaita |
| Circular record button (idle circle / recording rounded-square) | Y | Y | Y | Button is a red disc, morphs on record |
| Follows system light/dark | ~ | - | Y | Flip OS theme; window follows (M has 486 themes instead; L pins the dark default theme) |
| 486 Ghostty color themes, searchable | Y | Y | ~ | Settings > theme picker (W: name list, search deferred) |

## 5. System integration

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| Menu-bar / tray presence | Y (menu bar) | - | Y (tray) | Icon present; menu opens |
| Live recording indicator in the menu bar / tray (state + elapsed) | Y | n/a | Y | Icon shows recording state (M: red waveform + timer; W: tooltip only) |
| Hotkey shown in the tray/menu item text | Y | n/a | Y | Menu reads "Record (Ctrl+Shift+Space)" |
| Window **close / hide** control | Y (traffic lights) | Y (header bar) | Y (x glyph hides) | A way to hide/close from the window itself |
| Single-instance (second launch surfaces the first) | n/a | Y | Y | Launch twice; one window |
| Settings window | Y | Y | Y | Cmd+, (M), header-bar gear (L), tray menu (W) opens settings |
| Window opacity control | Y | Y | Y | Settings > Opacity slider (0.1-1.0) changes window translucency |
| Theme picker: search + per-theme swatch + palette preview | Y | Y | ~ | Settings > search filters 486 themes, each with a color swatch (W: name list only) |
| Model switcher: dropdown + in-place swap + persisted choice | Y | Y | ~ | Settings > pick a model; absent manifest models download inline (M, L; W dropdown lists on-disk models only until its onboarding lands) |
| Permissions handled with clear prompts/messages | Y (mic, Accessibility, Automation) | Y (portals) | Y (none needed; privacy toggle noted) | First-run permission flow |

## 6. Privacy and security

| Feature | M | L | W | How to test |
|---|---|---|---|---|
| Audio and transcripts never leave the machine | Y | Y | Y | No outbound traffic during dictation |
| Outbound requests are only pinned-hash model downloads (auto VAD fetch; speech models on request) | Y | Y | Y | First run fetches ~1MB silero; onboarding/Settings downloads verify against pinned SHA-256s |
| Text-injection capability documented (SECURITY.md) | Y | Y | Y | Review SECURITY.md |

## Priority gaps (the parity backlog)

From the columns above, the cross-platform work, in impact order:

1. **Follows system light/dark on Linux**: the overlay pins the dark default
   theme's values; Windows already follows the system toggle.
2. **Explicit "copied/pasted" confirmation on macOS** (Linux and Windows
   already state the outcome; macOS only implies it in the bubble).
3. **Windows tray live indicator** is elapsed-tooltip only; the macOS menu bar
   draws a live waveform with a timer.

Deferred (smaller): the Windows theme picker's search, per-row swatches, and
palette preview (it lists names only); download entries in the Windows model
switcher, which arrive with its onboarding flow.
