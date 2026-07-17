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
- The **frontends are mostly UI glue** (windows, widgets, event loops). The few
  pure-logic pieces (the Windows paste-chord planner, model discovery, theme
  token mapping) are unit-testable; the rest is exercised by the pixel smoke and
  UAT, not unit tests.
- **SonarCloud coverage spans all three frontends** (`scripts/coverage.sh`, one
  generic XML per platform, merged by the sonar CI job). Every analysed file
  counts, so UI glue verified only by the pixel smoke and UAT shows as
  uncovered rather than excluded. Sonar does not analyse Zig, so the core's
  coverage cannot be imported; it is measured with kcov in the linux CI job
  (job summary + the coverage-core artifact) instead.

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
- **Framework**: plain C test executables (assert + non-zero exit), compiled on
  the host, no test framework dependency. Model: `windows/tests/inject_plan_test.c`.
- **Best practice**: split the **pure logic out of the OS glue** so it compiles
  without `windows.h`/`gtk.h`, `inject_plan.c` is pure C and its test runs on
  the Linux CI runner with `cc -std=c11 -Wall -Wextra -Werror`. Only logic that
  can be isolated this way is unit-testable; anything touching the widget tree is
  not.
- **Warnings are tests**: the frontends build under `-Wall -Wextra -Wshadow
  -Wstrict-prototypes -Wmissing-prototypes -Wformat=2 -Wcast-align -Wundef`, and
  clang-format `--Werror` in CI.
- **Coverage**: `scripts/coverage.sh` builds the pure-C tests (the Windows
  planner, and the Linux portal payload suites, which `#include` the client
  `.c` under test) with gcov; `scripts/gcov_to_sonar.py` converts to Sonar's
  generic format.

### Swift (macOS, `macos/Sources`)
- **Framework**: a plain-Swift harness (`macos/Tests/main.swift`), compiled
  together with the sources under test by `scripts/coverage.sh swift` via bare
  `swiftc`, no Xcode project, mirroring the C harness style. Coverage comes
  from `-profile-generate -profile-coverage-mapping` + `xcrun llvm-cov export
  --format=lcov`, converted by `scripts/lcov_to_sonar.py`.
- **Best practice**: keep the **testable logic free of app state** so the
  harness can compile just the file under test (model:
  `GhosttyInjector.injectEvent`, the injection security boundary). Name unused
  delegate params `_`, prefer value types, and run `swift format lint --strict`
  (CI enforces `.swift-format`).

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
The overlay windows, waveform, tray/menu-bar, portals and native dialogs need a
real desktop. They are covered by the pixel smoke where headless rendering
allows, and otherwise by the human UAT pass (Linux + Windows). No unit test
substitutes for that; those files sit in the coverage metric as uncovered, and
the pixel smoke and UAT, not a unit-test number, are what vouch for them.
