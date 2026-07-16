# UI parity feasibility, per feature per system

For each macOS feature not yet at parity, the native mechanism on Linux (GTK4 +
Cairo) and Windows (Win32 + GDI), an effort estimate (**S** < ~50 lines, **M**
~50-200, **L** > ~200 / new subsystem), and the risk. macOS is the reference
([ui-spec.md](ui-spec.md)); status is in [features.md](features.md). Ordered by
the convergence priority.

> **Status:** the convergence items below (cards, hint line, accent, record-button
> morph, 3-state waveform) all shipped on Linux and Windows in v0.4.0. This doc is
> kept as the feasibility record; current per-element parity is in
> [ui-spec.md §5](ui-spec.md) and [features.md](features.md). What remains is the
> deferred set (Settings/themes, tray depth, Linux light/dark).

Guiding fact: **GTK4 has real widgets, Win32/GDI does not.** Anything list- or
control-shaped is cheaper on Linux; anything custom-drawn is roughly equal.
Neither can be runtime-verified on the macOS dev box: Linux is now exercised
end to end under Xvfb, and Windows is in its first VM UAT (the arm64 build).

| # | Feature | Linux (GTK4/Cairo) | Windows (Win32/GDI) | Risk |
|---|---|---|---|---|
| 1 | **Transcript history cards** (stack, copy + x per card) | **M**. `GtkListBox`/`GtkBox` in the existing scroller; each card a `GtkFrame` with a label + two `GtkButton`s (`edit-copy-symbolic`, `window-close-symbolic`). Widgets do the work. | **L**. No card widgets. Either child controls (STATIC + two BUTTONs) per card in a scroll area, or custom GDI cards + click hit-testing + manual scroll. Most work of any item. | W: dynamic child-control lifecycle + scrolling is fiddly; keep a bounded history |
| 2 | **Persistent hotkey hint** | **S**. A dim `GtkLabel` pinned above the button, always set. | **S**. Dedicated status line already drawn; default it to the hotkey. | none |
| 3 | **Brand accent** (`#FF3B30` + cyan/orange states) | **S**. Cairo bar colors + button CSS. | **S**. GDI colors + record fill. | none |
| 4 | **Circular record button + morph** (see below) | **S-M**. `GtkDrawingArea` drawing a rounded rect with an animated radius, or a CSS `border-radius` class with `transition: 150ms`. | **S**. Already custom-drawn; lerp the radius on the existing 33ms timer. | none |
| 5 | **3-state waveform** (idle/recording/transcribing) | **M**. Cairo already draws bars; add state color + the transcribing sine. | **M**. GDI `waveform.c`; add state color + sine. | low |
| 6 | **Window close/hide control** | **n/a**. Adwaita header bar already has a close button. | **M**. Borderless popup has none: draw an `x` (and maybe a hide dot) top-right, hit-test to `WM_CLOSE`->hide. The traffic-light analog. | W: must not steal focus (paint + hit-test only, no real child) |
| 7 | **"Copied/pasted" confirmation** | **S**. Already an `AdwToast`; align wording. | **S**. Already a status line; align wording. | done-ish |
| 8 | **Live elapsed timer** | **S**. Label updated from `boo_get_audio_samples` on the existing poll. | **S**. Draw near the button; the 33ms waveform timer already fires. | none |
| 9 | **Menu-bar / tray live recording indicator** | **L**. Linux has no tray today; a `StatusNotifierItem` is a new subsystem, and GNOME hides tray icons. Defer. | **M**. Tray exists; swap the `HICON` to a recording variant + elapsed tooltip via `NIM_MODIFY` (~1Hz). | L(Linux): GNOME tray visibility |
| 10 | **Hotkey in the menu/tray item text** | **n/a**. No menu. | **S**. Append `(Ctrl+Shift+Space)` to the tray menu item. | none |
| 11 | **Window opacity control** | **M**. `gtk_widget_set_opacity` on the window; compositor-dependent on some setups. | **S**. `SetLayeredWindowAttributes` alpha (add `WS_EX_LAYERED`). | L: Wayland compositor variance |
| 12 | **Settings window** (opacity + auto-type + theme) | **L**. `AdwPreferencesWindow` + `GtkScale` + `GtkSwitch` + theme list. Widgets exist; it's the plumbing + persistence that's large. | **L**. A whole new Win32 dialog (trackbar, checkbox, listbox). | both: net-new window + settings persistence |
| 13 | **486 Ghostty themes** (search + swatch + palette) | **L**. The theme parser lives in Swift (`Theme.swift`); port it to C once (shared by both frontends), then a list UI. | **L**. Same parser port + a Win32 list. | shared: port the parser to the C core so it isn't written twice |
| 14 | **Translucency** (frosted overlay) | **M**. GTK4 transparent window; compositor-dependent. | **M**. `WS_EX_LAYERED` + DWM; workable. | Linux compositor variance |

## Record button, exact spec and morph

From `OverlayWindow.swift:135-149,329-353` (macOS ground truth):

| Property | Value |
|---|---|
| Size | 40 x 40 pt |
| Fill | `#FF3B30` in **both** states (shape carries state, not color) |
| Idle | circle: corner radius **20** (half the size) |
| Recording | rounded square: corner radius **6** |
| Transition | animate the corner radius 20 <-> 6 over **0.15 s** |
| Label | none (the status line carries "recording..." / elapsed) |

Morph feasibility:
- **Linux**: a `GtkDrawingArea` re-drawing a rounded rect whose radius is eased
  from 20 to 6 over 150ms on the frame clock (the waveform already ticks), or
  pure CSS `border-radius` + `transition: border-radius 150ms` toggled by a
  state style class. Either is **S-M**; CSS is the least code.
- **Windows**: already custom-drawn; keep a `float radius` in `BooApp`, ease it
  toward the target (20 idle / 6 recording) each `WM_TIMER` tick, and pass it to
  `RoundRect`. The 33ms waveform timer gives ~5 frames across 150ms. **S**, and
  the smoothest option since the paint loop already exists.

Both are compile-verifiable; the animation smoothness itself is a real-hardware
UAT item.

## Recommended sequencing

**Phase 1, cheap high-impact parity (all S/M, low risk), both platforms:**
items 2, 3, 4, 8, plus 10 and 6 on Windows. This removes the biggest "different
app" cues (accent, record button, visible hotkey, elapsed, window controls) for
well under a day each and is fully compile-verifiable.

**Phase 2, the cards (item 1) + 3-state waveform (5) + tray indicator (9, W).**
Cards are easy on Linux (widgets), the real work on Windows; do Linux first to
validate the model, then Windows.

**Phase 3, the heavy, shared-infrastructure items:** port the Ghostty theme
parser into the C core (item 13) so Linux and Windows share it, then the
Settings window (12), opacity (11), translucency (14). Largest effort, lowest
per-user urgency; the theme-parser port is the prerequisite that makes 12/13
tractable on both at once.

## Cross-cutting note

The theme system is the one place worth a **shared core** rather than three
implementations: move Ghostty-theme parsing (currently `Theme.swift`) into the
Zig/C core behind the C API, so every frontend reads the same palette. Colors
(accent, waveform states, bubble surfaces) then come from one source, which is
what actually guarantees consistency instead of three hand-matched palettes.
