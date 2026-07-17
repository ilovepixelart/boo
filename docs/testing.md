# Testing

Boo is one product in five languages (Zig core, C frontends, Swift on macOS,
plus Python and shell test harnesses). "Test it properly" therefore means a
different idiom per language, each following that language's own conventions.
The rule everywhere: **test the logic where it lives, in that language's native
framework; verify the UI, which no unit test can reach, with the pixel smoke and
human UAT.**

## Where the logic is, and where it isn't

- The **transcription-critical logic is in the Zig core** (theme parser, model
  ranking, audio maths/downmix, WAV, the VAD chunker seams, WER, the logger).
  That is the code that is unit-tested most heavily.
- The **frontends are mostly UI glue** (windows, widgets, event loops). The
  pure-logic pieces (the Windows paste-chord planner, model discovery, the
  download verify/rename, theme token mapping) are unit-testable directly; the
  widget-bound glue is driven headless by a per-frontend harness that pokes the
  real window from outside (`windows/tests/drive_app.c`,
  `linux/tests/overlay_harness.c`, the app-boot path in `macos/Tests/main.swift`).
  What no headless harness can reach is the rendered result, and that is the
  pixel smoke's job.
- **SonarCloud coverage spans all three frontends** (`scripts/coverage.sh`, one
  generic XML per slice, merged by the sonar CI job): `windows.xml` (the
  host-built planner), `windows-native.xml` (the win-tests exes plus the driven
  app, instrumented on the Windows runner), `linux.xml` (portal suites + the
  instrumented app smoke + the overlay harness), and `swift.xml`. Every analysed
  file counts, so anything reached only by a running desktop shows as uncovered
  rather than excluded. Sonar does not analyse Zig, so the core's coverage cannot
  be imported; it is measured with kcov in the linux CI job (job summary + the
  coverage-core artifact) instead.

## Per language

### Zig (core, `src/`)
- **Framework**: `std.testing`, `test "..." {}` blocks colocated with the code;
  `_ = @import("x.zig")` in a root test to pull a module's tests in.
- **Run**: `zig build test`, and again with `-Doptimize=ReleaseSafe`, the
  second keeps the safety checks while optimising, catching UB that only appears
  optimised.
- **Best practice**: use `std.testing.allocator` (it fails the test on a single
  leaked byte, this is what catches the init/errdefer leaks), assert with
  `try testing.expectEqual`/`expectError`, keep tests deterministic (no
  `Date.now`/`Math.random`; in this repo those are unavailable anyway).
- **Beyond unit tests**: the `bench` suite runs real inference gated on realtime
  factor and word error rate (`zig build bench -- --assert-rtf --assert-wer`),
  and a LibriSpeech WER suite, so a decode/chunker regression fails CI.

### C (frontends, `linux/src`, `windows/src`)
- **Framework**: plain C test executables (assert + non-zero exit), no test
  framework dependency. Two shapes: **host-portable** pure logic
  (`inject_plan_test.c`, no `windows.h`, runs on the Linux runner) and
  **native** logic that `#include`s the `.c` under test to reach its statics
  (`windows/tests/model_test.c` and friends via `zig build win-tests`; the Linux
  portal suites via `portal_payloads.c`). Widget-bound code that needs a real
  toolkit is driven by a headless harness instead (see below), never left
  untested because it touches a window.
- **Best practice**: prefer isolating pure logic so it compiles without the
  toolkit; when the code genuinely needs the widget tree, drive it through the
  harness rather than mocking the toolkit. A test that `#include`s its subject
  keeps the subject's statics reachable and its ids shared via the header (the
  window-class names live in `settings.h`/`onboarding.h` so the driver and the
  app agree).
- **Warnings are tests**: the frontends build under `-Wall -Wextra -Wshadow
  -Wstrict-prototypes -Wmissing-prototypes -Wformat=2 -Wcast-align -Wundef`, and
  clang-format `--Werror` in CI.
- **Headless harnesses** exercise the glue end to end without a user:
  - Windows: `windows/tests/drive_app.c` is built uninstrumented and pokes a
    live (instrumented) `boo-app.exe` from outside, posting the same window
    messages a click would (record toggle, Settings, the onboarding close).
  - Linux: `linux/tests/overlay_harness.c` `#include`s `overlay_window.c`, builds
    the real widget tree with a NULL `BooContext` (every core call tolerates it),
    and calls the handlers the pixel smoke cannot reach, the transcription worker
    round-trip, the tracked-idle machinery, the Settings dialog, and the download
    engine against a local HTTP server. Run it with `linux/tests/ui-harness.sh`;
    it is what pinned the `begin_transcription` use-after-free (run under valgrind
    it fails without the fix, since the guard the pixel smoke hits returns before
    transcription).
- **Coverage**: `scripts/coverage.sh` builds these tests plus the whole app with
  gcov and drives the harness, so the UI glue gets real counters;
  `scripts/gcov_to_sonar.py` converts to Sonar's generic format (it drops
  cross-drive system-header paths the Windows runner emits).

### Swift (macOS, `macos/Sources`)
- **Framework**: a plain-Swift harness (`macos/Tests/main.swift`), compiled with
  **every** source (except the app entry) by `scripts/coverage.sh swift` via
  bare `swiftc`, no Xcode project, mirroring the C harness style. Coverage comes
  from `-profile-generate -profile-coverage-mapping` + `xcrun llvm-cov export
  --format=lcov`, converted by `scripts/lcov_to_sonar.py`.
- **What it exercises**: `GhosttyInjector.injectEvent` (the injection security
  boundary) and `ThemeManager` against the real core parser; `ModelDownloader`
  end to end against a local HTTP server (progress, SHA-256 install, checksum
  refusal); the `AppDelegate` preference/discovery helpers; and the Settings and
  onboarding windows headless. `BOO_HARNESS_BOOT=1` (set on the CI macOS job,
  after the bench models land) boots the real app around a model, overlay, status
  bar, an in-place model swap, so the launch path is covered too; it stays
  opt-in because on a dev machine it grabs the microphone TCC prompt and the
  global hotkey.
- **Best practice**: keep a testable class in its **own file**, not folded into
  an `extension AppDelegate`, so the harness (and a reader) can reason about it
  in isolation. Pump the main run loop for the async paths (downloader closures
  and model swaps hop through the main queue). Name unused delegate params `_`,
  prefer value types, and run `swift format lint --strict` (CI enforces
  `.swift-format`).

### Python (test harness, `linux/tests`)
- **Framework**: the harness (`mock_portal.py`) supports the Linux integration
  tests. Lint with **ruff** (`ruff check` + `ruff format --check`); if unit tests
  are added, use **pytest**.
- **Best practice**: pin the interpreter (`sonar.python.version`), keep functions
  under the cognitive-complexity limit, no unused params.

### Shell (harnesses, `linux/tests`, `scripts`)
- **Lint**: `shellcheck -S warning` + `shfmt -d -i 4 -ci` in CI.
- **Best practice**: `set -euo pipefail`; `[[ ]]` over `[ ]`; assign positional
  params to named locals; explicit `return` at function ends; gate steps as one
  `&&` chain so a red check can't be followed by a pass. The pixel smoke
  (`ui-smoke.sh`) is the UI's regression test: it asserts the *rendered pixels*
  (bg `#282C34`, disc `#FF3B30`, a persisted theme's `#F7F7F7`).

## What stays UAT-only
The headless harnesses drive the window logic, and the pixel smoke asserts the
rendered result, but neither substitutes for a human on a real desktop for the
last mile: the global hotkey and tray/menu-bar under a real compositor, the
portal permission dialogs and auto-paste into another app (Linux), the
Accessibility/microphone TCC prompts (macOS), and the actual injected keystroke
landing in a foreground app. Those are the UAT pass (Linux + Windows); the pixel
smoke and UAT, not a coverage number, are what vouch for them.
