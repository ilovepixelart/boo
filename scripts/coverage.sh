#!/usr/bin/env bash
# Generate coverage for everything SonarCloud can index, one generic-format
# XML per platform, plus a kcov run over the Zig core:
#
#   coverage/windows.xml  Windows paste-chord planner unit test (pure C, any host)
#   coverage/linux.xml    Linux portal payload suites (needs GTK4 headers)
#   coverage/swift.xml    macOS Swift harness (needs macOS; macos/Tests/main.swift)
#   coverage/core/        Zig core under kcov (Linux only) + core-summary.txt
#
# The core's number cannot land in Sonar: the scanner skips generic-coverage
# entries for files without a supported language, and Zig is not one. It goes
# to the CI job summary and the coverage-core artifact instead.
#
# Usage: coverage.sh [windows|linux|swift|core ...]  (default: windows linux swift)
#
# Coverage is a nice-to-have, never a CI gate: a section whose toolchain is
# missing writes an empty (valid) report and succeeds.
set -euo pipefail
shopt -s nullglob

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/coverage"
mkdir -p "$out"

empty_report() {
    printf '<coverage version="1"/>\n' >"$1"
}

# The paste-chord planner: same pure-C target the lint job builds (no
# windows.h), with gcov counters. Sources compile separately so the
# .gcno/.gcda land in the cwd with predictable names.
gen_windows() {
    local work
    work=$(mktemp -d)
    (
        cd "$work"
        cflags=(--coverage -O0 -I "$root/windows/src")
        cc "${cflags[@]}" -c "$root/windows/src/inject_plan.c" -o inject_plan.o
        cc "${cflags[@]}" -c "$root/windows/tests/inject_plan_test.c" -o test.o
        cc --coverage inject_plan.o test.o -o inject_plan_test
        ./inject_plan_test
        gcov inject_plan.c >/dev/null 2>&1 || true
        covs=(*.gcov)
        if [[ ${#covs[@]} -eq 0 ]]; then
            echo "coverage: windows: gcov produced no reports" >&2
            empty_report "$out/windows.xml"
        else
            python3 "$root/scripts/gcov_to_sonar.py" "$out/windows.xml" "$root" "${covs[@]}"
        fi
    )
    rm -rf "$work"
}

# The portal payload suites (linux/tests/run.sh, which also runs on macOS):
# portal_payloads.c #includes the client .c under test, so gcov attributes
# lines to global_shortcut.c / text_inject.c themselves; portal.c is shared.
gen_linux() {
    if ! pkg-config --exists gtk4 2>/dev/null; then
        echo "coverage: linux: no gtk4, skipping" >&2
        empty_report "$out/linux.xml"
        return
    fi
    local work
    work=$(mktemp -d)
    (
        cd "$work"
        local all_covs=()
        for suite in global_shortcut text_inject; do
            mkdir -p "$suite"
            cd "$suite"
            define=""
            [[ "$suite" = "text_inject" ]] && define="-DTEST_TEXT_INJECT"
            # shellcheck disable=SC2046,SC2086  # $define and pkg-config output are multi-flag
            cc --coverage -O0 $define -I "$root/linux/src" -I "$root/include" \
                $(pkg-config --cflags gtk4) \
                -c "$root/linux/tests/portal_payloads.c" -o payloads.o
            # shellcheck disable=SC2046
            cc --coverage -O0 -I "$root/linux/src" -I "$root/include" \
                $(pkg-config --cflags gtk4) \
                -c "$root/linux/src/portal.c" -o portal.o
            # shellcheck disable=SC2046
            cc --coverage payloads.o portal.o $(pkg-config --libs gtk4) -o suite
            ./suite >/dev/null
            gcov payloads.gcda portal.gcda >/dev/null 2>&1 || true
            for g in *.gcov; do all_covs+=("$suite/$g"); done
            cd ..
        done
        # The app itself, instrumented and driven by the pixel smoke: honest
        # end-to-end coverage for the UI glue (overlay_window, main, models,
        # waveform) that no unit harness reaches. Skipped quietly when a piece
        # is missing (archives from `zig build`, ImageMagick, a display or
        # xvfb-run, a model in models/), never a CI failure.
        smoke_ready=true
        [[ -f "$root/zig-out/lib/libboo-core.a" ]] || smoke_ready=false
        [[ -f "$root/zig-out/lib/libwhisper.a" ]] || smoke_ready=false
        command -v zig >/dev/null || smoke_ready=false
        command -v magick >/dev/null || command -v convert >/dev/null || smoke_ready=false
        ls "$root"/models/ggml-*.bin >/dev/null 2>&1 || smoke_ready=false
        runner=""
        if [[ -n "${DISPLAY:-}" ]]; then
            runner=""
        elif command -v xvfb-run >/dev/null; then
            runner="xvfb-run -a"
        else
            smoke_ready=false
        fi
        if $smoke_ready; then
            mkdir -p app
            cd app
            for src in "$root"/linux/src/*.c; do
                # shellcheck disable=SC2046
                cc --coverage -O0 -I "$root/linux/src" -I "$root/include" \
                    $(pkg-config --cflags gtk4 libadwaita-1 libsoup-3.0) \
                    -c "$src" -o "$(basename "${src%.c}").o"
            done
            # coverage_exit.c turns ui-smoke's SIGTERM into exit(), so the
            # .gcda counters actually flush; without it the app dies unflushed.
            cc --coverage -O0 -c "$root/linux/tests/coverage_exit.c" -o coverage_exit.o
            # Linked by `zig c++`, not cc: the whisper archive was compiled
            # against zig's bundled libc++ (std::__1 ABI), which no system
            # libstdc++ provides. GCC's libgcov.a supplies the counter runtime
            # for the gcov-instrumented frontend objects.
            # shellcheck disable=SC2046
            zig c++ ./*.o "$root/zig-out/lib/libboo-core.a" \
                "$root/zig-out/lib/libwhisper.a" \
                $(pkg-config --libs gtk4 libadwaita-1 libsoup-3.0 libpipewire-0.3) \
                "$(gcc -print-file-name=libgcov.a)" -lm -lpthread -o boo-app-cov
            appdir=$PWD
            # Run from the repo root so ./models and ./themes resolve. A
            # failing smoke still flushed counters up to the failure; keep
            # whatever landed rather than dropping the slice.
            (cd "$root" && GSK_RENDERER=cairo $runner \
                bash linux/tests/ui-smoke.sh "$appdir/boo-app-cov") ||
                echo "coverage: linux: smoke run failed; using partial counters" >&2
            gcov ./*.gcda >/dev/null 2>&1 || true
            for g in *.gcov; do all_covs+=("app/$g"); done
            cd ..
        else
            echo "coverage: linux: app smoke slice skipped (needs zig-out libs, ImageMagick, a display/xvfb-run, and a model in models/)" >&2
        fi

        if [[ ${#all_covs[@]} -eq 0 ]]; then
            echo "coverage: linux: gcov produced no reports" >&2
            empty_report "$out/linux.xml"
        else
            python3 "$root/scripts/gcov_to_sonar.py" "$out/linux.xml" "$root" "${all_covs[@]}"
        fi
    )
    rm -rf "$work"
}

# The Swift harness (macos/Tests/main.swift) compiled with the sources under
# test via plain swiftc, instrumented with llvm profiling; llvm-cov's lcov
# export becomes Sonar's Swift coverage.
gen_swift() {
    if [[ "$(uname)" != "Darwin" ]] || ! command -v swiftc >/dev/null; then
        echo "coverage: swift: needs macOS + swiftc, skipping" >&2
        empty_report "$out/swift.xml"
        return
    fi
    # Theme.swift talks to the real core parser, so the harness links the
    # repacked archives (build them when absent; build-zig-libs.sh is the
    # same path the Xcode project uses).
    if [[ ! -f "$root/zig-out/lib/libboo-core.a" || ! -f "$root/zig-out/lib/libwhisper.a" ]]; then
        (cd "$root" && bash scripts/build-zig-libs.sh)
    fi
    local work
    work=$(mktemp -d)
    swiftc -profile-generate -profile-coverage-mapping \
        -import-objc-header "$root/include/boo.h" \
        "$root/macos/Sources/GhosttyInjector.swift" \
        "$root/macos/Sources/Theme.swift" \
        "$root/macos/Tests/main.swift" \
        "$root/zig-out/lib/libboo-core.a" "$root/zig-out/lib/libwhisper.a" \
        -lc++ -framework Cocoa -framework Accelerate -framework CoreAudio \
        -framework AudioToolbox -framework Metal -framework MetalKit \
        -o "$work/swift_tests"
    # Run from the repo root so ThemeManager finds ./themes.
    (cd "$root" && LLVM_PROFILE_FILE="$work/swift.profraw" "$work/swift_tests")
    xcrun llvm-profdata merge -sparse "$work/swift.profraw" -o "$work/swift.profdata"
    xcrun llvm-cov export --format=lcov -instr-profile "$work/swift.profdata" \
        "$work/swift_tests" >"$work/swift.lcov"
    python3 "$root/scripts/lcov_to_sonar.py" "$out/swift.xml" "$root" "$work/swift.lcov"
    rm -rf "$work"
}

# The Zig core under kcov (DWARF-based, no compiler instrumentation). Sonar
# cannot import it (no Zig language), so the result is a summary line plus
# kcov's HTML/JSON in coverage/core for the CI artifact.
gen_core() {
    if ! command -v kcov >/dev/null; then
        echo "coverage: core: kcov not installed, skipping" >&2
        return
    fi
    (cd "$root" && zig build test-exe)
    rm -rf "$out/core"
    kcov --include-path="$root/src" "$out/core" "$root/zig-out/bin/boo-core-test"
    local pct
    pct=$(sed -n 's/.*"percent_covered": *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' \
        "$out"/core/*/coverage.json | head -1)
    echo "Zig core line coverage: ${pct:-n/a}% (kcov, not importable into Sonar)" |
        tee "$out/core-summary.txt"
}

sections=("$@")
[[ ${#sections[@]} -eq 0 ]] && sections=(windows linux swift)
for section in "${sections[@]}"; do
    case "$section" in
        windows) gen_windows ;;
        linux) gen_linux ;;
        swift) gen_swift ;;
        core) gen_core ;;
        *)
            echo "unknown section: $section (want windows|linux|swift|core)" >&2
            exit 2
            ;;
    esac
done
