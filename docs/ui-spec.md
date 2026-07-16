# UI spec: the macOS build as cross-platform ground truth

Boo deliberately ships a native frontend per OS (no shared GUI toolkit, the
Ghostty pattern), so "consistent" cannot mean shared widgets. It means each
frontend renders the **same design language, layout, and behavior**. The macOS
build is the most complete, so it is the reference. This document is the ground
truth extracted from `macos/Sources/` (cited inline); Linux and Windows are
measured against it, and the gaps are the work.

## 1. Window and chrome

| Property | Value | Source |
|---|---|---|
| Size | 400 wide, 500 tall; min 400x300, max 400x800 (width fixed) | `OverlayWindow.swift:32,39-40` |
| Background | hardcoded `rgba(0.16, 0.17, 0.2, 0.95)` (~`#292B33`), translucent, non-opaque, shadowed; distinct from the theme bg | `OverlayWindow.swift:47-49` |
| Chrome | Titlebar hidden and transparent, full-size content, draggable by background | `OverlayWindow.swift:44-46` |
| Placement | Top-right of the main screen (20px right margin, 50px top) | `OverlayWindow.swift:52-56` |
| Level | Normal (not always-on-top on macOS); does not hide on deactivate | `OverlayWindow.swift:43,50` |

Vertical stack, 12px padding: **waveform** (top) → **transcript scroll**
(middle, fills) → **bottom bar** (status text + record button).

## 2. Design tokens

Colors come from the active **Ghostty-format theme** (`Theme.swift`): 16-color
ANSI palette plus bg/fg, 486 themes, default "Ghostty Default Style Dark".
Text uses theme colors; a few accents are hardcoded (flagged).

| Token | Value | Notes |
|---|---|---|
| `bg` | theme background (`#292C33` default) | window + surfaces |
| `fg` | theme foreground (white default) | transcript text |
| `dim` | `palette[8]` (bright black) | status line, icons, hints |
| `accent.record` | **hardcoded** `#FF3B30` | record button, recording waveform is `systemRed` |
| `accent.thinking` | **hardcoded** `systemOrange` | transcribing waveform |
| `accent.idle` | **hardcoded** `rgb(.51,.74,.69)` ~cyan | idle waveform |
| `accent.confirm` | `palette[14]` (cyan) | copy-success flash |
| Body font | system 13pt | transcript |
| Mono font | monospaced system 11pt | status/hotkey hint |
| Corner radius | window system; bubbles 10px; record circle 20px | |

Consistency note: the record accent (`#FF3B30`) and the three waveform state
colors are hardcoded, not theme-derived. For cross-platform parity these become
the **shared brand tokens** every frontend uses, overriding the OS accent
(Windows system blue, Linux adwaita blue/cyan).

## 3. Components

### Waveform (`WaveformView.swift`)
40 bars, center-symmetric, rounded, 12px inset, 3px gap, min bar 2px, height 48.
Smoothed via lerp (0.25 recording / 0.1 idle). Three states:
- **Idle**: flat minimal bars, alpha 0.2, idle color.
- **Recording**: peak-normalized heights, center bars brighter, `systemRed`.
- **Transcribing**: gentle sine "breathing", `systemOrange`.

### Transcript (`OverlayWindow.swift:425-488`)
A vertical **history stack** of bubbles in a scroll view (8px spacing), newest
appended. Each bubble: 10px radius, `white@6%` fill; top row has a **copy** icon
(`doc.on.doc`, left) and **dismiss** icon (`xmark.circle`, right), both `dim`; a
separator; then the text (13pt, `fg`). Copy flashes the icon cyan for 0.5s;
dismiss fades out over 0.2s. During streaming a dimmed provisional bubble
(`white@3%`, `dim` text) shows committed-so-far text, replaced on stop.

### Record button (`OverlayWindow.swift:135-149`)
40x40, `#FF3B30`. **Idle = circle** (radius 20); **recording = rounded square**
(radius 6); animated 0.15s. Centered in the bottom bar.

### Status line (`OverlayWindow.swift:128-132`)
Monospace 11pt, `dim`, centered, directly above the record button. State text:

| State | Text |
|---|---|
| Idle | `ctrl+shift+space` (the visible hotkey) |
| Recording | `recording...` then live `%.0fs` elapsed |
| Transcribing | `thinking...` |
| Done, empty | `no speech detected` |
| Cap hit | `max length reached` |
| Needs permission | `copied, grant Accessibility to auto-paste` |

### Menu bar item (macOS-only, `AppDelegate.swift:83-149`)
`NSStatusItem` with a `waveform` symbol. **Live state in the menu bar itself**:
while recording, the symbol tints `systemRed` and the button title shows a live
elapsed timer (` 4s`, then ` 1:23`); while transcribing, it switches to
`waveform.badge.magnifyingglass` dimmed; idle is the plain symbol. The menu:
`Boo`, **`Record (Ctrl+Shift+Space)`** (the hotkey is shown here too),
`Show Window`, `Settings...` (Cmd+,), `Quit Boo` (Cmd+Q).

### Settings window (macOS-only, `SettingsWindow.swift`)
- **Opacity** slider, 0.1-1.0, default 0.95, with a live monospace value label;
  drives the overlay window's alpha.
- **Auto-type** checkbox ("Auto-type into focused app after transcription", on by
  default); off = clipboard-only, never paste.
- **Theme**: a search field filters the 486 Ghostty themes; each row shows a
  color **swatch** + name; a 16-color **palette preview strip** sits at the
  bottom. Selecting one re-themes the overlay live.

## 4. Required behaviors (all platforms)

1. **Global hotkey Ctrl+Shift+Space**, and it must be **persistently visible**
   in the UI (macOS: the idle status line). Fires regardless of focus; toggles
   recording.
2. **Delivery lands at the caret** of the input that was focused when recording
   started. macOS: Ghostty pty-insert, else clipboard + Cmd+V. This is
   satisfied by paste on every platform (Linux Ctrl+Shift+V, Windows Ctrl+V);
   the contract is "insert at cursor, never replace, never land in Boo."
3. **Focus targeting**: capture the target app/window at record start; deliver
   there; never to Boo itself.
4. **Recording lifecycle**: warm-up then record; live waveform + elapsed timer;
   auto-stop at the 10-minute cap; transcribe off the UI thread; show result.
5. **Per-action feedback**: an explicit "copied / pasted" confirmation (Windows
   already does this well; make it universal).

## 5. Gap analysis (reference vs current)

| Aspect | macOS (spec) | Linux (GTK4) | Windows (Win32) |
|---|---|---|---|
| Window | translucent dark overlay, top-right | titled adwaita window | borderless tray overlay, bottom-right |
| Accent | brand red `#FF3B30` + cyan/orange states | adwaita blue + cyan bars | **system blue** |
| Waveform | 40 rounded center bars, 3 states | cyan Cairo bars, top-anchored, 1 state | 40 GDI bars, 1 state |
| Transcript | bubble **history** + copy + dismiss | last-only plain label | last-only plain text |
| Record control | red **circle <-> rounded square** | blue/red **pill** ("Record"/"Stop") | blue **pill** ("Record") |
| Hotkey hint | **always visible** status line | shown only on failure | **idle-only**, lost after first transcript |
| Deliver at caret | yes (pty / Cmd+V) | yes (Ctrl+Shift+V) | yes (Ctrl+V) |
| Confirmation | in status/bubble | toast | status line (good) |
| Tray / menu | menu-bar item | none | tray icon |
| Theming | 486 Ghostty themes | none | light/dark auto |

## 6. Convergence priorities

Highest visible impact first, each implementable natively:

1. **One accent.** Adopt `#FF3B30` (record) + the cyan/orange waveform states on
   Linux and Windows, overriding the OS accent. Single biggest "different app"
   cue removed.
2. **Persistent hotkey hint.** A dedicated status line showing
   `ctrl+shift+space` at all times, not just idle/failure. (Your requirement.)
3. **Record control shape.** Circular record button with the idle-circle /
   recording-rounded-square transition, replacing the pills.
4. **Waveform parity.** Center-symmetric rounded bars with the 3 colored states.
5. **Transcript bubbles** with copy + dismiss and short history, replacing the
   last-only labels.
6. **Universal "copied/pasted" confirmation** and caret-insertion guarantee.

Deferred (bigger, platform-bound): the 486-theme picker (macOS-only today), the
menu-bar/tray parity, translucency on Linux/Windows.
