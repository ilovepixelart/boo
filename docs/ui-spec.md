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
| Background | `theme.bg` at the user's opacity (default 1.0, fully opaque like Ghostty), non-opaque so lower opacities are translucent, shadowed; `rgba(0.16,0.17,0.2)` is only the pre-theme first paint | `OverlayWindow.swift:47,192-193`, `AppDelegate.swift:217` |
| Chrome | Titlebar hidden and transparent, full-size content, draggable by background | `OverlayWindow.swift:44-46` |
| Placement | Top-right of the main screen (20px right margin, 50px top) | `OverlayWindow.swift:52-56` |
| Level | Normal (not always-on-top on macOS); does not hide on deactivate | `OverlayWindow.swift:43,50` |

Vertical stack, 12px padding: **waveform** (top) → **transcript scroll**
(middle, fills) → **bottom bar** (status text + record button).

### Window controls (native per OS)

The overlay is a **standard OS window**, not a chromeless popup: it exposes the
platform's **own native window controls**, not a redrawn lookalike. macOS is the
reference for *which capabilities* the window offers; each frontend realizes them
with its native chrome, in that OS's conventional placement.

| Capability | macOS (reference) | Windows | Linux |
|---|---|---|---|
| Controls | traffic lights **close · minimize · zoom**, top-left, kept visible over the transparent titlebar (`:35,175-186`) | native caption **minimize · close**, top-right (no maximize: width is fixed) | libadwaita header-bar **close** (+ minimize where the desktop offers it) |
| Title area | titlebar transparent, title hidden, content to the top edge (`:44-45`) | minimal caption, no title text | header bar, no title text |
| Move | drag anywhere on the body (`:46`) | drag the body | drag the header bar |
| Resize | height **300–800**, width fixed **400** (`:39-40`) | same range | same range |
| Close | hides the window; the app stays in the menu bar / tray | same (hide to tray) | same |
| Minimize | miniaturize to the Dock (`:35`) | minimize to the taskbar | minimize where the desktop offers it |
| Level | normal, not always-on-top; does not hide on deactivate (`:43,50`) | topmost, an overlay kept above the dictation target | normal window |

Requirement: **native close and minimize at minimum**, placed by each OS's own
convention, over a title-less minimal title area with content to the top edge,
drag-to-move by the body, and height-only resize (300–800, width fixed 400).
Delivery still targets the app focused at record start (§4), so the window may
take focus like any normal window without misdirecting dictation.

## 2. Design tokens

Colors come from the active **Ghostty-format theme** (`Theme.swift`): 16-color
ANSI palette plus bg/fg, 486 themes, default "Ghostty Default Style Dark".
Text uses theme colors; a few accents are hardcoded (flagged).

**The theme drives the colors.** `applyTheme` (`OverlayWindow.swift:192-197`)
re-colors the window and every state from the active Ghostty theme; the values
hardcoded at construction are only the pre-theme first paint. The single true
hardcode is the record disc's `#FF3B30`.

| Token | Source | Default theme value ("Ghostty Default Style Dark") | Used for |
|---|---|---|---|
| `bg` | `theme.bg` at the user's opacity (default 1.0) | `#282C34` | window |
| `fg` | `theme.fg` | `#FFFFFF` | transcript text |
| `dim` | `palette[8]` | `#666666` | status/hint, card icons |
| `wave.idle` | `palette[14]` (cyan) | `#70C0B1` | idle waveform |
| `wave.recording` | `palette[9]` (red) | `#D54E53` | recording waveform |
| `wave.thinking` | `palette[11]` (yellow) | `#E7C547` | transcribing waveform |
| `accent.confirm` | `palette[14]` | `#70C0B1` | copy-success flash |
| `record` | **hardcoded** `#FF3B30` | same on every theme | the record disc |
| Card fills | fixed `white@6%` / `white@3%` over `bg` | | cards / live card |
| Body font | system 13pt | | transcript |
| Mono font | monospaced system 11pt | | status/hotkey hint |

Parity target: **every frontend offers theme selection** over the same 486
Ghostty themes, defaulting to *Ghostty Default Style Dark*, so a fresh install
on any OS matches the reference exactly and the user can re-theme from there. The
486 files are parsed **once, in the Zig core**, and the parsed colors are exposed
over the C API (`boo.h`); the three frontends share that one parser and theme
list rather than re-implementing it. See [Settings](#settings-all-platforms).
The `#FF3B30` record disc is the one color that stays fixed across every theme.

All three frontends now ship the picker (macOS `SettingsWindow`, the Linux
header-bar dialog, the Windows tray / system-menu dialog), each parsing every
theme through the shared core parser and persisting the choice. When **no** theme
is picked, Linux shows the dark default and Windows follows the system light/dark
toggle (the dark values above in dark mode, light-surface equivalents in light).
One share is still outstanding: each frontend enumerates the theme dir and calls
the core parser per file rather than reading a single list the core builds once
(the cross-frontend de-duplication work).

## 3. Components

### Waveform (`WaveformView.swift`)
40 bars, center-symmetric, rounded, 12px inset, 3px gap, min bar 2px, height 48.
Smoothed via lerp (0.25 recording / 0.1 idle). Three states:
- **Idle**: flat minimal bars, alpha 0.2, idle color.
- **Recording**: peak-normalized heights, center bars brighter, `systemRed`.
- **Transcribing**: gentle sine "breathing", `systemOrange`.

### Transcript cards (`OverlayWindow.swift:396-539`)
A vertical **history stack** of cards in a scroll view between the waveform and
the bottom bar (`:159-162`), chronological top to bottom, 8px between cards,
each card full stack width.

**Order and position:** cards are **top-anchored**. The overlay view is flipped
(`:5`) and the stack is pinned to the **top** of the scroll's document view
(`:111`), so with only a few cards they sit directly **under the waveform and
grow downward**, with the empty space toward the record button. The **newest
card is appended at the bottom** of the stack (`:402`). Once the stack is taller
than the visible area it **auto-scrolls to the newest** (`:416-420`): the oldest
scroll off the top, the newest stays visible just above the bottom bar. Every
frontend follows this: top-anchored, newest at the bottom, newest kept visible
on overflow.

Card anatomy, exact metrics:

| Part | Spec |
|---|---|
| Container | corner radius **10**, fill `white@6%` over the window bg |
| Header row | height **20**, inset top 6 / sides 8 |
| Copy button | `doc.on.doc` symbol, borderless, tint `dim`, header-left |
| Dismiss button | `xmark.circle` symbol, borderless, tint `dim`, header-right |
| Separator | hairline below the header, inset 4 top / 8 sides |
| Text | system **13pt**, `fg`, wrapping; inset 6 top / 12 sides / 10 bottom |

Interactions:
- **Copy**: puts that card's full text on the clipboard; the copy icon flashes
  `accent.confirm` (theme cyan) for **0.5s**, then returns to `dim`.
- **Dismiss**: fades the card out over **0.2s**, removes it from the stack, and
  relayouts (remaining cards close the gap).
- Card text is selectable on macOS (labels); parity target: at minimum the copy
  button must exist everywhere.

Streaming: while recording, a **provisional live card** shows committed-so-far
text, visually one step dimmer than history cards (`white@3%` fill, `dim` text,
no header/buttons); it is removed when the final transcript card (or "no
speech") replaces it on stop.

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

### Settings (all platforms)
The macOS Settings window (`SettingsWindow.swift`) is the reference. It is a
**cross-platform requirement**: every frontend presents the same four controls
in native chrome (macOS AppKit, a GTK dialog on Linux, a Win32 dialog on
Windows), each **persisted per user**. Its four controls:

**1. Opacity** slider, 0.1-1.0, **default 1.0** (fully opaque, matching
Ghostty's `background-opacity` default), with a live monospace value label. It
drives the overlay window's background alpha (macOS `NSWindow.backgroundColor`
alpha, Linux CSS / compositor opacity, Windows `SetLayeredWindowAttributes`).
The chosen value **persists across theme changes**, a theme switch reapplies the
user's opacity, not a constant.

**2. Auto-type** checkbox ("Auto-type into focused app after transcription", on
by default); off = clipboard-only, never paste.

**3. Model switcher.** One dropdown merging the speech models on disk (every
`ggml-*.bin` in the model search directories minus the silero VAD models,
deduplicated by filename, ranked by the core's `boo_model_rank`) with the
curated manifest models (`boo_models`) not yet downloaded, the latter tagged
"(download, NNN MB)". Picking a tagged entry downloads it with an inline
progress bar, verifies its pinned SHA-256, then switches to it; there is no
separate download button. Selecting a model swaps it **in place** via the
core's `boo_reload_model` (the context handle stays valid, the old model
keeps serving on a failed load), off the UI thread with a status line; swaps
are refused while recording or transcribing. The explicit choice **persists
per user** and wins over ranked auto-discovery on later launches; a stale
choice (file deleted since) falls back to auto-discovery.

**4. Theme picker.** A search field filters the **486 Ghostty themes**, each row
shows a color **swatch** + name, a 16-color **palette preview strip** sits at the
bottom, and selecting one **re-themes the overlay live**. Default is *Ghostty
Default Style Dark*. Backed by the **shared core parser** (§2): every frontend
reads one theme list from the core, so the 486 themes are never parsed more than
once. Shared surface (the core owns parsing, frontends own rendering):
- Parse each Ghostty file into bg, fg, and the 16-color palette (skip a file
  missing bg/fg or fewer than 16 palette entries), sorted by name.
- Expose over `boo.h`: theme count, each theme's name, and its resolved colors,
  and the default theme's index; the frontend holds the current selection.
- Token mapping stays as in §2 (`dim`=palette[8], `wave.idle`=palette[14],
  `wave.recording`=palette[9], `wave.thinking`=palette[11], `accent.confirm`=palette[14]).

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

## 5. Per-element parity status

Every element above, as each frontend implements it (`linux/src/overlay_window.c`,
`linux/src/waveform_widget.c`, `windows/src/overlay.c`). Deltas are the
platform-native chrome and the deferred items, nothing else.

| Element | macOS | Linux (GTK4) | Windows (Win32) |
|---|---|---|---|
| Window chrome | hidden titlebar, translucent, shadowed | adwaita header bar, opaque | native title bar, minimize + close, topmost |
| Placement | top-right | window-manager decided | top-right of the work area |
| Background | `theme.bg` at opacity | `theme.bg` at opacity (dark default until a theme is picked) | `theme.bg` at opacity (system light/dark until a theme is picked) |
| Waveform, 3 states + colors | reference | full (Cairo, real per-bar alpha) | full (GDI) |
| History cards + copy + dismiss | full, text selectable | full | full |
| Live (provisional) card | `white@3%`, dim, no buttons | same | same |
| Copy flash `accent.confirm` 0.5s | yes | yes | yes |
| Dismiss animation | 0.2s fade | instant remove | instant remove |
| Auto-scroll to newest card | yes | yes | yes |
| Record disc `#FF3B30`, 20 -> 6 morph | 0.15s | CSS transition 150ms | eased per paint tick |
| Status line, all six states | yes | yes | yes |
| Elapsed timer | status + menu bar | status | status + tray tooltip |
| Tray / menu bar | live waveform + timer + menu | none (GNOME has no tray) | icon + menu; elapsed in tooltip only |
| Settings: opacity + auto-type + theme picker | full (reference: slider w/ live value, checkbox, search + swatch + palette preview) | full (dialog: slider w/ live value, checkbox, search + swatch list + palette preview) | full (dialog: trackbar w/ live %, checkbox, theme name list); per-row swatch + search + palette preview deferred |
| Settings: model switcher (merged dropdown, absent models download inline) | full (in-place swap, persisted choice) | missing | missing |
| Theme colors applied | 486-theme picker | 486-theme picker (dark default until one is picked) | 486-theme picker (system light/dark until one is picked) |

The behavior-parity matrix and the remaining backlog live in
[features.md](features.md).

## 6. UI acceptance walkthrough

Run this element script on each OS and compare against sections 1-3; it is the
"is the UI actually unified" pass, one observation per element. Values in
parentheses are the default-theme tokens from section 2.

1. **Launch.** Window ~400x500; dark bg (`#282C34`) on macOS and Linux, and on
   Windows in dark mode (Windows follows the system light/dark). Chrome per the
   parity table: macOS frameless/translucent, Linux header bar, Windows a native
   title bar (minimize + close), topmost. Layout top-to-bottom: waveform,
   transcript area, status line, record disc.
2. **Idle.** 40 flat rounded bars, dim cyan (`#70C0B1`, alpha 0.2). Status
   line monospace, dim (`#666666`), reads `ctrl+shift+space` (Linux without a
   granted portal: `click record to dictate`). Record disc 40px `#FF3B30`,
   perfect circle.
3. **Start recording**, once each via hotkey, disc click, and tray/menu where
   present. Disc morphs circle to rounded square (radius 6) in ~0.15s. Status
   shows `recording...` then a live elapsed count. Bars turn red (`#D54E53`),
   center-weighted, tracking the voice. macOS menu-bar icon tints red with a
   timer; Windows tray tooltip carries the elapsed time.
4. **While speaking** (silero model present): a dim provisional card
   (`white@3%`, no buttons) grows with committed text.
5. **Stop.** Bars turn yellow (`#E7C547`) and breathe; status `thinking...`;
   then the transcript card appears: `white@6%` fill, radius 10, copy icon
   left and `x` right in dim, hairline under the header, 13pt `fg` text. It
   joins the top-anchored stack under the waveform (scrolling into view only
   once the stack overflows), the disc is a circle again, the status returns to
   the hotkey.
6. **Copy** on a card: clipboard holds the full text; the icon flashes cyan
   (`#70C0B1`) for 0.5s.
7. **Dismiss** on a card: the card goes away (macOS fades 0.2s, Linux/Windows
   remove instantly) and the stack closes the gap.
8. **Several takes** stack chronologically, newest at the bottom.
9. **Silent take**: no card, status `no speech detected`.
10. **Cap**: a recording left running stops itself at 10 minutes with
    `max length reached` and transcribes what it captured.
11. **Delivery**: caret mid-sentence in another app, dictate, text inserts at
    the caret, an explicit confirmation shows, and nothing ever lands in Boo's
    own window.
12. **OS-specific tail**: macOS settings (opacity, auto-type, theme picker
    re-themes live); Windows light-mode follow and the SmartScreen/Unblock
    first-run path; Linux portal grant prompts on first hotkey and first
    auto-paste.
