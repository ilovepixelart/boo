# Logging and crash reporting

Design for making a field bug **diagnosable from a log plus a local crash
report**, with no debugger attached and no telemetry.

## Where it stands today

| Layer | Logging today | Crash handling today |
|---|---|---|
| Core (Zig) | `src/log.zig`: leveled file sink + stderr, exposed as `boo_log_init` / `boo_log` | `src/crash.zig`: fatal-signal backtrace via `boo_crash_init` (POSIX) |
| macOS | core logger → `~/Library/Logs/Boo/boo.log` (plus legacy `NSLog` lines) | `boo-crash.txt` beside the log; the system `.ips` still gets written |
| Linux | core logger → `$XDG_STATE_HOME/boo/boo.log` (plus GLib warnings → journald) | `boo-crash.txt` beside the log; core dump still happens |
| Windows | core logger → `%LOCALAPPDATA%\Boo\logs\boo.log` | `boo-crash.dmp` beside the log (`windows/src/crash.c`, SEH minidump); WER still runs |

Both halves are built: one leveled logger in the core, one file per OS,
lifecycle events logged as metadata (never transcript text, see the privacy
contract below), and local crash capture on every platform. The handlers hand
the failure back to the OS default afterwards, so system crash reports are
additive, not replaced. A report found on the next launch is surfaced once
(dialog with a reveal/open-folder action, then renamed to *-prev so later
launches stay quiet); nothing is ever sent anywhere.

## Privacy contract (non-negotiable)

Boo's promise is *no telemetry, transcription is fully local*. Diagnostics must
not weaken it:

- **Never log transcript or recognized-speech text.** Not at any level. Log
  *lengths*, *durations*, *counts*, and *state names* instead ("transcribed 42
  chars in 380 ms", never the 42 chars).
- **Local by default.** Logs and crash dumps are written to the per-OS user data
  dir; nothing leaves the machine unless the **user explicitly** exports/sends it.
- **No automatic upload, ever.** No SaaS crash reporter, no background POST.

## Logging: what and where

A tiny leveled logger (error / warn / info / debug) writing to a **rotating
file** in the per-OS data dir, in addition to the platform console:

| OS | Console sink | File |
|---|---|---|
| macOS | `os_log` (Console.app, subsystem `com.boo.app`) | `~/Library/Logs/Boo/boo.log` |
| Linux | stderr → journald | `$XDG_STATE_HOME/boo/boo.log` |
| Windows | `OutputDebugString` | `%LOCALAPPDATA%\Boo\logs\boo.log` |

Log the **lifecycle and state transitions** so a log alone reconstructs a
session: model load (name, size, backend CPU/GPU), record start/stop, transcribe
begin/end (duration + char count, never text), VAD load, portal / permission
grants and denials, theme + settings load, and every error path. A one-line
"reveal logs" affordance in each Settings dialog (open the log folder) so a user
can find and attach it.

Owning it in the **core** (a `boo_log()` over the C API, levels + the file sink
in Zig) means one implementation and one redaction policy for all three
frontends, instead of four half-solutions. That is also the natural home given
the [de-duplication work](roadmap.md).

## Crash reporting: local dumps, opt-in send

Default to a **local crash dump** written next to the logs; surface it on next
launch with an explicit, user-initiated "reveal / copy report" (never an
auto-send). This keeps the offline promise while still giving us something to act
on.

| Layer | Capture | Artifact |
|---|---|---|
| Core (Zig) | install a panic handler; `std.debug` can format a stack trace | `boo-crash-<stamp>.txt` (backtrace + build id) |
| macOS | `NSSetUncaughtExceptionHandler` + a `SIGSEGV`/`SIGABRT` `sigaction`; the system already writes `.ips` reports under `~/Library/Logs/DiagnosticReports` | point the user at the `.ips`, plus our own note |
| Linux | `sigaction` + `backtrace()/backtrace_symbols` (glibc) | text backtrace next to the log |
| Windows | `SetUnhandledExceptionFilter` + `MiniDumpWriteDump` (dbghelp) | a `.dmp` beside the log |

A crash handler must be **async-signal-safe**: pre-open the dump file, use only
`write()`-class calls in the handler, no allocation. Symbolication happens
offline from the shipped build, not in-process.

Note the tension the roadmap flags: any crash-report *upload* would touch the
zero-network claim. Resolve it the same way as
[model onboarding](model-onboarding.md): **local capture is always on; sending is
explicit and user-initiated**, so the guarantee holds.

## Phasing

| Phase | Scope |
|---|---|
| 1 | Core leveled logger + rotating file sink + the redaction rule; route the existing ad-hoc logs through it; lifecycle log points. |
| 2 | "Reveal logs" button in each Settings dialog. |
| 3 | Crash capture: Zig panic handler + per-OS signal handlers writing a local dump. |
| 4 | A one-click "copy diagnostics" (log tail + last crash) the user can paste into an issue. No auto-send. |

## First implementation step

Add `boo_log(level, msg)` to the core (levels + the per-OS file path + the
"never log recognized text" rule enforced at the call sites), and convert the
model-load / record / transcribe path in one frontend to use it. Everything else
builds on that sink.
