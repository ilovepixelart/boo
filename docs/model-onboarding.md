# Model onboarding: a pick-and-download dialog

Design record for replacing the "no model found, here is a curl command"
dialog with a native picker that downloads the chosen model, shows progress,
and drops the user straight into a working app.

**Status: shipped on all three frontends** (`macos/Sources/ModelOnboarding.swift`;
`linux/src/main.c` + `linux/src/models.c`; `windows/src/onboarding.c` +
`windows/src/download.c`). The curated manifest with pinned SHA-256s is the
core's `boo_models` (`src/c_api.zig`), and the Settings model switcher reuses
the same download machinery to fetch and swap models after onboarding. The
rest of this document is the decision record.

## The problem

First run with no model is a dead end today: every frontend shows a wall of
shell (`mkdir`, `curl -L -o … <long URL>`), asks the user to run it in a
terminal, then relaunch. That is a poor first impression, it fails anyone who
does not live in a shell, and it is fragile (wrong directory, `curl` vs
`curl.exe`, PowerShell's `curl` alias, partial downloads with no checksum).

What we want instead: a small dialog with a **dropdown of curated models**
(size + one-line tradeoff each), a **Download** button, a **progress bar**, and
on completion **close the dialog and open the app** with the model loaded. Plus
a **Choose a file…** escape hatch for a model the user already has (zero
network).

## The zero-network tension, resolved

`docs/roadmap.md` previously rejected an in-app downloader because it "would
falsify the zero-network claim." That framing does not survive contact with
what already ships:

| Already true today | Implication |
|---|---|
| macOS (`URLSession`) and Linux (`libsoup`) auto-fetch the Silero VAD model on first run, unprompted | The product already makes outbound download requests |
| That fetch is over TLS and verified against a **pinned SHA-256** | The safe-download machinery already exists and is trusted |
| It happens **without asking** | A model download is strictly *more* conservative: user-initiated, one click, clearly labelled |

So a speech-model download that is **user-initiated, checksum-verified against a
pinned hash, and clearly disclosed** removes nothing the VAD fetch has not
already spent. The honest claim was never "zero network"; it is **no telemetry,
no uploads, transcription is fully local**, the only bytes that ever come *in*
are optional models the user chooses, each verified against a hash we ship.
Restate the guarantee that way (README already says the substance of it) and the
downloader is consistent, not contradictory.

Guardrails that keep the guarantee honest:

- Download **only** from the curated manifest (pinned host + filename + hash).
  Never an arbitrary URL from the UI.
- **Verify the SHA-256** before the file is accepted; a mismatch is deleted, not
  loaded (the exact contract `scripts/fetch-model.sh` already enforces).
- The dialog **names the host and size** before downloading; the file picker
  path stays fully offline for the privacy-maximalist.

## Shared model manifest

One list, all frontends agree. Each entry: display name, filename, URL, pinned
SHA-256, size, one-line tradeoff. This is the same data `docs/models.md` already
curates, plus a hash per row. Options, cheapest first to wire up:

1. **A C header in `include/`** (e.g. `boo_models.h`) with a
   `static const` array the C/Swift frontends read directly, and that a tiny
   Zig test keeps in step with `models.md`. No ABI, no core changes.
2. A core API (`boo_model_catalog()`), if we later want the Zig side to own it.

Start with (1). The rows we would ship (from `models.md`): Parakeet TDT
(recommended), base.en, base.en-q5_1, tiny.en-q5_1, small.en, large-v3-turbo.
Hashes for base.en and the VAD model are already pinned in `ci.yml` /
`fetch-model.sh`; the rest need pinning once (download, `shasum -a 256`, record).

## Per-frontend implementation

The UI is thin; the shared parts are the manifest, the SHA-256 verify, and the
"on success: load + present the overlay" handoff.

| Frontend | Dialog widgets | Download + progress | Notes |
|---|---|---|---|
| macOS | `NSPanel` + `NSPopUpButton` + `NSProgressIndicator` | `URLSession` `downloadTask` with a delegate for `totalBytesWritten` | Reuses the VAD download path already in `AppDelegate` |
| Linux | GTK dialog + `GtkDropDown` + `GtkProgressBar` | `libsoup` async, already linked; chunk callback drives the bar | Mirrors the VAD fetch in `linux/src/main.c` |
| Windows | Win32 dialog + combo box + `PROGRESS_CLASS` bar | **New**: WinHTTP with a read loop, or `URLDownloadToFileW` + `IBindStatusCallback` | Windows has **no** download code today (it is also why Windows has no streaming VAD); this adds the first |

Windows carries the most new work: it currently ships no HTTP client at all, so
this is also the moment to give Windows the VAD auto-fetch macOS and Linux have.

## Flow

```
no speech model found
        │
        ▼
  ┌───────────────────────────────┐
  │ Choose a model      [▼ Parakeet]│   ← curated dropdown, size + tradeoff
  │ ~669 MB · huggingface.co        │
  │                                 │
  │ [ Choose a file… ]  [ Download ]│   ← file picker = offline escape hatch
  │ ▓▓▓▓▓▓▓▓░░░░░░░░  62%            │   ← progress bar during download
  └───────────────────────────────┘
        │ verify SHA-256 → move into models dir
        ▼
  close dialog, boo_load(model), show the overlay
```

Cancel must abort the transfer and delete the partial file. A hash mismatch
shows a retry, never loads.

## Phasing

| Phase | Scope | Why first |
|---|---|---|
| 0 | **Choose a file…** picker (NSOpenPanel / GtkFileDialog / IFileOpenDialog), zero network, load + present | Cheapest, no policy tension, immediately better than copy-pasting a path |
| 1 | Curated dropdown + download + progress + verify + auto-open, macOS & Linux (reuse existing fetch paths) | The headline feature on the two frontends that already have a downloader |
| 2 | Windows download stack (WinHTTP), which also unlocks Windows streaming VAD | Largest new surface; isolate it |
| 3 | Polish: resume/cancel, disk-space check, visible checksum | Robustness once the flow is proven |

## First implementation step

Add `include/boo_models.h` (the curated manifest with pinned hashes) and a Zig
test asserting it stays in step with `docs/models.md`, then build Phase 0 (the
file picker) behind the existing "no model" path on one frontend. Everything
else builds on that manifest.

## Open items

- Pin SHA-256s for base.en-q5_1, tiny.en-q5_1, small.en, large-v3-turbo, and
  Parakeet (base.en and VAD are already pinned).
- Decide manifest home (header vs core API); this doc assumes the header.
- Update `README.md`'s privacy wording to "no telemetry / no uploads; optional,
  hash-verified model downloads" so the guarantee and the feature agree.
