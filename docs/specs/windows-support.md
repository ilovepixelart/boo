# Windows support

## Problem and outcome

Boo runs on macOS and Linux; Windows users have nothing. The core (Zig + whisper.cpp
v1.9.1, modular ggml included) already cross-compiles to `x86_64-windows-gnu` except for
the audio backend seam and the POSIX-only argv iterators in main.zig and bench.zig, so
the missing pieces are a WASAPI audio backend, a Win32 frontend, CI, and packaging. Outcome: `zig build app -Dtarget=x86_64-windows-gnu` produces a working tray +
overlay dictation app from any host OS, shipped as a portable zip, at the same "preview"
bar the Linux port shipped at: recording, transcription and auto-paste work, verified in CI
where possible and on real hardware where not.

## Decisions (validated 2026-07-16, each against official docs and real-world code)

| Decision | Choice | Why (source) |
|---|---|---|
| Target ABI | `x86_64-windows-gnu` | msvc ABI cannot use Zig's bundled libc++ ([ziglang/zig#5312](https://github.com/ziglang/zig/issues/5312), unplanned) and whisper.cpp is C++; gnu is Zig's default Windows ABI, statically links mingw CRT + winpthreads against UCRT (in-box on Win10+), needs no Visual Studio, cross-compiles from any host |
| Audio API | WASAPI shared mode, MMDevice API | waveIn is a legacy shim over Core Audio ([legacy audio APIs](https://learn.microsoft.com/en-us/windows/win32/coreaudio/interoperability-with-legacy-audio-apis)); SDL2 and miniaudio both default to WASAPI |
| Sample format | Ask engine for 16 kHz mono f32 via `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM \| SRC_DEFAULT_QUALITY` | Engine inserts resampler and channel matrixer ([stream flags](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants)); same shape as the CoreAudio and PipeWire backends; miniaudio does exactly this |
| Capture loop | Polling thread, `GetNextPacketSize`/`GetBuffer`/`ReleaseBuffer`, ~500 ms engine buffer, ~100 ms poll | Microsoft's canonical capture pattern ([Capturing a Stream](https://learn.microsoft.com/en-us/windows/win32/coreaudio/capturing-a-stream)); event mode wakes 10x more often for nothing |
| COM bindings | Hand-declared vtables in Zig (4 interfaces, ~200 lines), link `ole32` only | Same approach as the existing hand-declared AudioQueue ABI; precedent: hexops/mach-sysaudio; zigwin32 is huge and its Zig 0.16 support unverified |
| Mutex shim on Windows | SRWLOCK via 3 `ntdll` externs | pthread types are absent from Zig's std.c on Windows; SRWLOCK is a zero-init word, no destroy needed; `std.Io.Mutex` would thread an Io context into audio callbacks |
| Global hotkey | `RegisterHotKey` (MOD_NOREPEAT) on the message loop thread | System-wide, no permission prompt, fails loudly (error 1409) on conflict ([RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)); low-level hooks are silently removed on timeout since Win 10 1709 and pattern-match keyloggers |
| Text delivery | Clipboard + SendInput Ctrl+V; wait for physically held modifiers to lift (GetAsyncKeyState poll, 1 s cap), then forced key-ups as fallback | Held modifiers combine with injected keys per [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput) docs; espanso waits, PowerToys forces key-ups; hybrid avoids both failure modes. Ctrl+V pastes by default in Windows Terminal and conhost, so no per-app chord table |
| Clipboard owner | Hidden message window; retry OpenClipboard a few times | `OpenClipboard(NULL)` makes SetClipboardData fail after EmptyClipboard ([OpenClipboard](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard)); Win+V service holds the clipboard transiently |
| Clipboard restore | None: transcript stays on the clipboard | Matches macOS/Linux behavior; restore has documented races (espanso needs a 300 ms delay; history capture is async) |
| Focus guard | Capture `GetForegroundWindow()` at record start; paste only if it is still foreground | `SetForegroundWindow` cannot reliably take focus back ([docs](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)); never paste blind |
| Overlay window | `WS_POPUP` + `WS_EX_TOPMOST\|TOOLWINDOW\|NOACTIVATE`, plus `WM_MOUSEACTIVATE` returning `MA_NOACTIVATE`, manual drag (SetCapture + SetWindowPos) | NOACTIVATE alone is not airtight (Raymond Chen [2024](https://devblogs.microsoft.com/oldnewthing/20240919-00/?p=110283)); HTCAPTION drag activates NOACTIVATE windows |
| Waveform | GDI double-buffered, SetTimer ~33 ms | 40 solid bars need no Direct2D ([GDI vs D2D](https://learn.microsoft.com/en-us/windows/win32/direct2d/comparing-direct2d-and-gdi)); WM_TIMER jitter is invisible at VU-meter scale |
| Tray icon | `Shell_NotifyIcon` NOTIFYICON_VERSION_4, re-add on `TaskbarCreated` | Required protocol per [taskbar docs](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar); Win 11 hides new icons in overflow, README tells users to pin |
| DPI / codepage | Manifest: PerMonitorV2 + utf-8 activeCodePage, handle WM_DPICHANGED | Manifest over API is the official recommendation ([DPI guidance](https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process)); Zig's bundled resinator compiles .rc + manifest cross-platform |
| Single instance | `CreateMutexW` with `Local\` name | Per-session is correct for a per-user tray app ([CreateMutexW](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createmutexw)) |
| Model dir | `%USERPROFILE%\.boo\models`, then `.\models`, then `%LOCALAPPDATA%\boo\models`, `BOO_MODEL` override | ollama and LM Studio both use profile dot-dirs on Windows; keeps one convention across all three OSes |
| Model download | Manual, `curl.exe` instructions | curl ships in-box since Win 10 1803; keeps the zero-network claim true; whisper.cpp itself ships a download script |
| Packaging v1 | Portable zip on GitHub Releases, unsigned, SmartScreen bypass documented | Exact analog of the unsigned DMG + xattr story; MSIX refuses unsigned installs; winget and SignPath (free OSS signing) are fast follows |
| Entry point | `wWinMain`, `exe.subsystem = .windows`, `exe.mingw_unicode_entry_point = true` | mingw provides the CRT glue; explicit flags sidestep entry inference (history: [#18621](https://github.com/ziglang/zig/issues/18621)) |
| CI | windows-latest (Server 2025) native job + ubuntu cross-compile guard; `.gitattributes` forces LF | mlugg/setup-zig caches the global Zig cache automatically; CRLF checkouts break `zig fmt --check` |
| ARM64 | Cross-compile check only; no release artifact until a windows-11-arm smoke test | aarch64-windows is Zig Tier 2; build success is not runtime evidence |

## Acceptance clauses

Verification levels: `ci` (mechanical, every push), `manual` (documented human check on real
Windows hardware, like the Linux portal/audio story before it).

### Core

- **WIN-001** `zig build -Dtarget=x86_64-windows-gnu` and `-Dtarget=aarch64-windows-gnu`
  succeed from a non-Windows host. Check `ci:windows-cross`.
- **WIN-002** `zig build test` passes natively on Windows (audio maths + C ABI contract,
  including the leak test and null-context sweep). Check `ci:windows-native`.
- **WIN-003** The WASAPI backend implements the same `AudioCapture` surface as the CoreAudio
  and PipeWire backends and routes all sample handling through `common.Capture`.
  Check `ci:windows-native` (compile + ABI tests) and `manual:audio` (REPL dictation on real
  hardware produces a correct transcript).
- **WIN-004** When the requested 16 kHz mono f32 format is rejected
  (`AUDCLNT_E_UNSUPPORTED_FORMAT`), the backend retries with the device mix format and
  downmixes in the copy loop. Check `manual:audio` (needs real device variety); the fallback
  path compiles under `ci:windows-cross`.
- **WIN-005** A blocked microphone (Settings > Privacy) surfaces as a distinct init error,
  not a hang or silent empty capture: `E_ACCESSDENIED` maps to its own error, and the
  frontend renders it as "microphone access is disabled in Windows Settings".
  Check `manual:audio`.
- **WIN-006** The CLI REPL (`zig build run`) works on Windows: argv read via the
  0.16 `Init.args` allocator idiom, model path argument honored. Check `ci:windows-native`
  (binary builds; argv unit-testable via `toSlice`) and `manual:audio`.

### Frontend

- **WIN-010** `zig build app -Dtarget=x86_64-windows-gnu` produces `boo-app.exe`: C sources
  under `windows/src/`, subsystem `windows`, embedded manifest (PerMonitorV2, utf-8,
  comctl32 v6) and .rc (icon + VERSIONINFO). Check `ci:windows-cross` + `ci:windows-native`.
- **WIN-011** Tray icon: version-4 protocol, left click toggles the overlay, right click
  opens a menu with Record/Stop and Quit, icon survives an Explorer restart
  (`TaskbarCreated` re-add). Check `manual:frontend`.
- **WIN-012** The overlay never takes focus: NOACTIVATE styles + `MA_NOACTIVATE` +
  SWP_NOACTIVATE drag. Clicking Record while dictating into Notepad must not move the caret.
  Check `manual:frontend` (this is the app's core promise).
- **WIN-013** Global hotkey Ctrl+Shift+Space toggles recording from any app. On
  registration conflict (error 1409) the overlay shows "hotkey unavailable, use the Record
  button" instead of failing silently. Check `manual:frontend`.
- **WIN-014** Transcript delivery: always copied to the clipboard (hidden-window owner,
  CF_UNICODETEXT); pasted via synthesized Ctrl+V only when the window focused at record
  start is still foreground and is not Boo itself; held modifiers are waited out (1 s cap)
  then released before the chord. Into an elevated window the paste is expected to be
  blocked (UIPI): transcript stays on the clipboard and the overlay says "copied, press
  Ctrl+V". Check `manual:frontend`.
- **WIN-015** Recording lifecycle parity with the Linux frontend: UI-owned recording flag,
  500 ms auto-stop poll for the 10 min cap, transcription on a worker thread with the
  result marshaled back to the UI thread, "(no speech detected)" on empty. Check
  `manual:frontend`; the lifecycle rules themselves are already pinned by the core's
  `common.Capture` tests.
- **WIN-016** Model discovery per the decision table, missing model shows the curl.exe
  download instructions with the exact expanded path. Check `manual:frontend`.
- **WIN-017** Single instance: second launch exits after asking the first instance to show
  its overlay. Check `manual:frontend`.

### CI and hygiene

- **WIN-020** CI gains `windows-cross` (ubuntu: both Windows targets, ReleaseFast) and
  `windows-native` (windows-latest: `zig build test` Debug + ReleaseSafe, `zig build app`,
  artifact exists). Check: the jobs themselves, required-green on master.
- **WIN-021** `.gitattributes` forces LF so `zig fmt --check` and clang-format behave
  identically on all runners. Check `ci` (fmt gates pass on windows-native).
- **WIN-022** `windows/src/*.c|h` are covered by the existing clang-format lint job.
  Check `ci:lint`.
- **WIN-023** `scripts/check-version.sh` verifies the .rc FILEVERSION against
  build.zig.zon. Check `ci:lint` (version consistency step).

### Release

- **WIN-030** The release workflow builds `boo-<version>-windows-x86_64.zip` (exe +
  LICENSE) on windows-latest, listed in SHA256SUMS; a Windows job failure does not block
  the macOS release (same policy as Linux). Check: release workflow on the next `v*` tag.
- **WIN-031** README gains Windows sections: quick start (zip, SmartScreen "More info >
  Run anyway", model download via curl.exe), status table row (preview), permissions table
  (mic toggle, UIPI note, no prompts otherwise), tray pinning note, hotkey conflict note
  (Word nonbreaking space, Ctrl+Shift layout switching). Check: review.

## Out of scope (v1)

Settings UI and themes; KEYEVENTF_UNICODE typing mode and TSF integration; clipboard
restore; IMMNotificationClient device hot-swap (a new recording re-resolves the default
device); autostart; code signing (apply to SignPath in parallel); winget manifest, Inno
Setup, MSIX; ARM64 release artifacts; any TTS/VibeVoice work.

## Risks

| Risk | Mitigation |
|---|---|
| AUTOCONVERTPCM mono downmix has one unresolved community bug report | WIN-004 fallback path; test against a stereo USB mic |
| Mic privacy toggle behavior (E_ACCESSDENIED at Initialize) is Q&A-documented, not formally | WIN-005 verified on real hardware; treat silent-zero capture as a possible driver behavior |
| No Windows hardware in this development loop | Every `manual:*` check listed in `windows/tests/manual.md`; ship as preview exactly like Linux did |
| Engine resampler quality for speech | Compare whisper output for the same utterance vs macOS backend |
| SmartScreen friction every release (per-hash reputation) | Documented; SignPath OSS application as fast follow |
| Zig's mingw is a v13 alpha snapshot, libc bugs are Zig's | Zig version pinned in CI (already 0.16.0) |
| RegisterHotKey over an elevated foreground window is community-documented only | One-minute manual test against elevated Notepad, note the result in manual.md |

## Open questions

1. Hotkey configurability: fixed Ctrl+Shift+Space (parity with macOS/Linux) or a
   `BOO_HOTKEY` env override in v1? Default plan: fixed, document conflicts.
2. Should windows-native CI run on pull requests too, or master-only at first (runner
   minutes)? Default plan: everywhere, it is the only real Windows signal.

## Micro-tasks

Ordered; each is one commit-sized change with its check named.

| # | Task | Files | Clauses | Test strategy |
|---|---|---|---|---|
| T1 | `.gitattributes` (LF) + argv fix in main.zig (0.16 `init.minimal.args.toSlice(init.arena…)`) | `.gitattributes`, `src/main.zig` | WIN-021, WIN-006 | `zig build test` + `zig build run` stay green on macOS; windows cross error count drops to the audio seam only |
| T2 | Mutex shim: SRWLOCK variant for Windows in `common.zig` (comptime switch, ntdll externs) | `src/audio/common.zig` | WIN-002 | existing Capture tests exercise it on every OS; add a comptime test pinning the Windows handle type |
| T3 | WASAPI backend + wire into `audio.zig` switch | `src/audio/wasapi.zig`, `src/audio.zig` | WIN-001, WIN-003, WIN-004, WIN-005 | full windows cross-compile goes green (the red-first check is the current @compileError); pure helpers (format struct fill, downmix) get unit tests; hardware behavior deferred to manual:audio |
| T4 | CI: windows-cross + windows-native jobs | `.github/workflows/ci.yml` | WIN-020, WIN-002 | jobs green; native job runs the ABI/leak tests on Windows for the first time |
| T5 | Frontend skeleton: wWinMain, message loop, single instance, model discovery, error dialogs (MessageBox), build.zig app step, manifest + rc | `windows/src/main.c`, `windows/res/*`, `build.zig` | WIN-010, WIN-016, WIN-017 | cross + native app builds; clang-format gate extended (WIN-022) |
| T6 | Tray icon + overlay window + GDI waveform + record button + lifecycle (worker thread, auto-stop poll) | `windows/src/tray.c`, `overlay.c`, `waveform.c` | WIN-011, WIN-012, WIN-015 | compile gates; manual.md checklist entries written alongside |
| T7 | Hotkey thread (RegisterHotKey, 1409 handling) | `windows/src/hotkey.c` | WIN-013 | compile gates + manual.md |
| T8 | Clipboard + injection (hidden owner window, modifier wait, foreground guard) | `windows/src/inject.c` | WIN-014 | compile gates + manual.md; modifier-wait state machine factored into a pure function with a unit test |
| T9 | check-version.sh covers boo.rc; release workflow windows zip; README Windows sections | `scripts/check-version.sh`, `.github/workflows/release.yml`, `README.md` | WIN-023, WIN-030, WIN-031 | check-version red-first (rc with wrong version), then green; release dry run via workflow_dispatch |

T5 through T8 are compile-verified in CI but behavior-verified only by `manual:frontend` on
real Windows hardware; `windows/tests/manual.md` is written as part of T6-T8 and is the
release gate for dropping the "preview" label, mirroring how Linux earned its checkmarks.
