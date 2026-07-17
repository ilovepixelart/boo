# Roadmap

Distilled from a July 2026 survey of the field: the recurring failure modes users
report in comparable local dictation tools, and the features they praise. Each item
is phrased as the action for Boo, ordered by user-visible payoff per line of code.
Status: `have` (shipped, keep it working), `verify` (probably fine, prove it),
`build` (missing).

## P1: reliability of the core promise (speak → correct text arrives)

| # | Action | Status | Notes |
|---|---|---|---|
| 1 | Harden decode parameters against silence hallucinations and repetition loops: no timestamps, no carried context, suppress non-speech tokens, drop high-no-speech/low-logprob segments and bracketed annotations, and gate transcription on a minimum audio level | have | Shipped in `whisper.zig` (`keepSegment`, `isAnnotation`, pinned params) and `audio/common.zig` (`maxWindowRms` + `SILENCE_RMS_FLOOR`); a silent take now reads "no speech detected" instead of "Thank you." |
| 2 | Mic pre-roll ring buffer so the first word is never clipped | have | `common.zig` preroll + `boo_warm_up`; guard it with the existing tests, it is the category's most-reported defect |
| 3 | Never lose a dictation: persist the raw take to disk before transcribing, watchdog every pipeline stage, and on any delivery failure say "transcript copied to clipboard" instead of failing silently | build (partial: clipboard fallback exists) | Eaten dictations are the top reason users abandon comparable tools |
| 4 | Distinct audible/visible state cues: start sound, stop sound, live level meter, explicit "transcribing" and error states | build (visual partial, no audio cues) | Absence of a recording indicator is a named public criticism of a comparable tool |
| 5 | Hotkey ergonomics: suppress key-repeat retriggers, start on key-up only when the key was not part of a chord, and add hold-to-talk plus double-tap-to-lock on the same key | build (Windows already suppresses repeat via MOD_NOREPEAT) | The most-loved interaction pattern in the space; also the most fragile, so ship with per-OS tests |
| 6 | Bring the live streaming transcript to the Windows frontend (`boo_stream_tick` / `boo_get_live_transcript` already exist in the core) | build | Live preview is the most-requested feature across every community thread surveyed |

## P2: trust and daily-driver quality

| # | Action | Status | Notes |
|---|---|---|---|
| 7 | Deterministic word replacements + user vocabulary (initial prompt) + optional filler-word removal | build | Top-3 request everywhere; keep replacements deterministic and local. Carried prompts can cause repetition, see item 1 |
| 8 | Transcript history with re-copy (and the raw audio from item 3) | have (all three stack cards with per-card copy); build (raw-audio re-copy) | Pairs with the never-lose guarantee |
| 9 | Model doctor: checksum after download instructions, explicit load-error messages, visible compute-device indicator (CPU/GPU) | have (in-app downloads verify pinned SHA-256s; truncated files detected via `boo_model_verify` and re-offered for download; load errors explicit); build (device indicator) | Silent model-load failure reads as "app is broken"; device opacity is a recurring complaint |
| 10 | Microphone picker with live level meter; prefer the built-in mic over Bluetooth headsets by default | build | Opening a Bluetooth mic drops it to the low-quality hands-free profile and can add seconds of latency; a hidden cause of "transcripts are garbage" |
| 11 | Verify-before-paste: confirm the clipboard actually holds the transcript before synthesizing the paste chord, and restore non-text clipboard formats if restore is ever added | verify | Clipboard races under CPU load are the highest-commented bug class in a comparable tool |
| 12 | Detect macOS Secure Keyboard Entry and say so instead of pasting into the void | build (Ghostty path already immune) | Classic "works everywhere except my terminal" mystery |

## P3: reach

| # | Action | Status | Notes |
|---|---|---|---|
| 13 | Code signing via an OSS signing program (Windows), then winget manifest | build | Unsigned input-synthesizing binaries trip antivirus heuristics; documented bypass is a stopgap, not an answer |
| 14 | Optional post-processing hook: pipe the transcript through a user-supplied local command before delivery | build | Keeps LLM cleanup out of the core and network-free; keep total added latency well under 3 s |
| 15 | Spoken punctuation commands ("new line", "new paragraph") as a pre-delivery transform | build | The number-one gripe of long-form dictation veterans |
| 16 | Windows CPU baseline stays `-mcpu baseline` with runtime feature detection when SIMD tiers ever diverge | have | Illegal-instruction crashes on older CPUs are a recurring release-day failure elsewhere |

The pick-and-download model onboarding dialog (dropdown of curated models,
progress bar, then load and open the app) ships on all three frontends, and
the Settings model switcher reuses its machinery to download and swap models
in place. Design record: [model-onboarding.md](model-onboarding.md). It is
consistent with the privacy stance, the VAD model is already auto-fetched over
TLS against a pinned hash, and a user-initiated, hash-verified download from a
curated list is strictly more conservative than that.

Explicitly rejected for now: muting other audio while recording (fails to restore
volume reliably on external DACs elsewhere), and cloud anything.
