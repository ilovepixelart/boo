#!/usr/bin/env bash
# Generate coverage for everything SonarCloud can index, one generic-format
# XML per platform, plus a kcov run over the Zig core:
#
#   coverage/windows.xml         Windows paste-chord planner unit test (pure C, any host)
#   coverage/windows-native.xml  Windows frontend: win-tests exes + the app itself
#                                driven by drive_app.c (Windows runner only)
#   coverage/linux.xml           Linux portal payload suites (needs GTK4 headers)
#   coverage/swift.xml           macOS Swift harness (needs macOS; macos/Tests/main.swift)
#   coverage/core/               Zig core under kcov (Linux only) + core-summary.txt
#
# The core's number cannot land in Sonar: the scanner skips generic-coverage
# entries for files without a supported language, and Zig is not one. It goes
# to the CI job summary and the coverage-core artifact instead.
#
# Usage: coverage.sh [windows|windows-native|linux|swift|core ...]
#        (default: windows linux swift)
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

# The pure-C frontend logic that carries no windows.h: the paste-chord planner,
# the transcript-history policy, the theme-to-color mapping, and the UTF-8
# helpers, each a <name>.c under test plus its <name>_test.c, gcov-instrumented.
# Every suite builds in its own subdir so its .gcno/.gcda cannot collide, and
# only the source under test is gcov'd (not the test TU). Runs on any host, so it
# lands in windows.xml on the Linux/macOS CI.
gen_windows() {
    local work
    work=$(mktemp -d)
    (
        cd "$work"
        local all_covs=()
        local cflags=(--coverage -O0 -I "$root/windows/src" -I "$root/include")
        local suite
        for suite in inject_plan history palette utf8 modelsel opacity overlay_layout tray_fmt; do
            mkdir -p "$suite"
            (
                cd "$suite"
                cc "${cflags[@]}" -c "$root/windows/src/$suite.c" -o "$suite.o"
                cc "${cflags[@]}" -c "$root/windows/tests/${suite}_test.c" -o test.o
                cc --coverage "$suite.o" test.o -o "${suite}_test"
                "./${suite}_test" >/dev/null
                gcov "$suite.o" >/dev/null 2>&1 || true
            ) || echo "coverage: windows: $suite suite failed" >&2
            for g in "$suite"/*.gcov; do all_covs+=("$g"); done
        done
        if [[ ${#all_covs[@]} -eq 0 ]]; then
            echo "coverage: windows: gcov produced no reports" >&2
            empty_report "$out/windows.xml"
        else
            python3 "$root/scripts/gcov_to_sonar.py" "$out/windows.xml" "$root" "${all_covs[@]}"
        fi
    )
    rm -rf "$work"
}

# The native Windows frontend, gcov-instrumented with a mingw gcc: the
# win-tests exes (model, download, inject, crash, waveform; each #includes its
# source, so lines land on windows/src) and then the real app, driven from
# outside by drive_app.c (record toggle, Settings pokes, onboarding close),
# the Windows twin of the Linux instrumented smoke. Objects are compiled by
# gcc for the gcov counters but linked by `zig c++` against the zig-built
# archives, whose whisper C++ uses zig's bundled libc++ (same ABI story as the
# Linux slice); libgcov.a comes from the gcc that made the objects.
win_gcc() {
    for cand in gcc /c/msys64/mingw64/bin/gcc /c/Strawberry/c/bin/gcc; do
        if command -v "$cand" >/dev/null; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# The real work, isolated so one broken sub-slice degrades to partial
# coverage instead of failing the run (coverage is never a gate).
windows_native_slice() {
    local report=$1 gcc_bin=$2 py=$3
    local gcov_bin="${gcc_bin%gcc}gcov"

    # The zig-built archives for the release ABI. On the Windows target they
    # install as boo-core.lib / whisper.lib.
    (cd "$root" && zig build app -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast)

    # Mixed-style (C:/...) paths: understood by the native gcc, python, and
    # bash alike, and what ends up in the .gcov Source: headers.
    local rootw
    rootw=$(cygpath -m "$root" 2>/dev/null || echo "$root")
    local cflags=(--coverage -O0 -std=c11 -I "$rootw/include" -I "$rootw/windows/src")
    local libs=(-lole32 -luser32 -lgdi32 -lshell32 -ldwmapi -ladvapi32 -lcomctl32
        -lshlwapi -lwinhttp -lbcrypt -lcomdlg32 -ldbghelp)
    local archives=("$rootw/zig-out/lib/boo-core.lib" "$rootw/zig-out/lib/whisper.lib")
    local gcov_lib
    gcov_lib=$("$gcc_bin" -print-file-name=libgcov.a)

    local work
    work=$(mktemp -d)
    cd "$work"
    local all_covs=()

    # Unit tests, one subdir per exe so the shared strconv/inject_plan
    # counters cannot collide across tests.
    local t
    for t in model_test download_test download_transfer_test inject_test crash_test waveform_test settings_test; do
        mkdir -p "$t"
        (
            cd "$t"
            "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/tests/$t.c" -o "$t.o"
            "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/src/strconv.c" -o strconv.o
            "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/src/inject_plan.c" \
                -o inject_plan.o
            # settings_test #includes settings.c, which links modelsel + opacity.
            if [ "$t" = settings_test ]; then
                "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/src/modelsel.c" -o modelsel.o
                "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/src/opacity.c" -o opacity.o
            fi
            zig c++ -target x86_64-windows-gnu ./*.o "${archives[@]}" "$gcov_lib" \
                "${libs[@]}" -o "$t.exe"
            "./$t.exe" >/dev/null
            "$gcov_bin" ./*.gcda >/dev/null 2>&1 || true
        ) || echo "coverage: windows-native: $t slice failed" >&2
        for g in "$t"/*.gcov; do all_covs+=("$g"); done
    done

    # The app itself. gcc objects for every frontend TU plus the console entry
    # shim; drive_app (uninstrumented) pokes the live windows, and the app's
    # clean quit flushes the counters.
    mkdir -p app
    (
        cd app
        local src
        for src in "$rootw"/windows/src/*.c; do
            "$gcc_bin" "${cflags[@]}" -c "$src" -o "$(basename "${src%.c}").o"
        done
        "$gcc_bin" "${cflags[@]}" -c "$rootw/windows/tests/coverage_entry.c" \
            -o coverage_entry.o
        zig c++ -target x86_64-windows-gnu ./*.o "${archives[@]}" "$gcov_lib" \
            "${libs[@]}" -o boo-app-cov.exe
        "$gcc_bin" -O2 -std=c11 -I "$rootw/include" -I "$rootw/windows/src" \
            "$rootw/windows/tests/drive_app.c" -luser32 -o drive_app.exe

        # Bound the app's lifetime: a hung quit must not hang the CI job.
        local wrap=()
        command -v timeout >/dev/null && wrap=(timeout 180)

        # Scenario 1: first run in an isolated profile with no model on disk;
        # the driver closes the onboarding dialog (quit-without-a-model).
        local fixture
        fixture=$(mktemp -d)
        mkdir -p "$fixture/local"
        USERPROFILE=$(cygpath -w "$fixture") LOCALAPPDATA=$(cygpath -w "$fixture/local") \
            "${wrap[@]}" ./boo-app-cov.exe &
        local app_pid=$!
        ./drive_app.exe onboarding || kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" || true

        # Scenario 2: the real profile (the CI job put a tiny model in
        # ~/.boo/models); record toggle, Settings pokes, quit from the tray
        # command.
        "${wrap[@]}" ./boo-app-cov.exe &
        app_pid=$!
        ./drive_app.exe main || kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" || true

        "$gcov_bin" ./*.gcda >/dev/null 2>&1 || true
    ) || echo "coverage: windows-native: app slice failed; keeping partial counters" >&2
    for g in app/*.gcov; do all_covs+=("$g"); done

    if [[ ${#all_covs[@]} -eq 0 ]]; then
        echo "coverage: windows-native: gcov produced no reports" >&2
        return 1
    fi
    "$py" "$rootw/scripts/gcov_to_sonar.py" "$(cygpath -m "$report" 2>/dev/null ||
        echo "$report")" "$rootw" "${all_covs[@]}"
}

gen_windows_native() {
    local report="$out/windows-native.xml"
    case "$(uname -s)" in
        MINGW* | MSYS*) ;;
        *)
            echo "coverage: windows-native: not on Windows, skipping" >&2
            empty_report "$report"
            return
            ;;
    esac
    local gcc_bin py
    gcc_bin=$(win_gcc) || true
    py=$(command -v python3 || command -v python) || true
    if [[ -z "${gcc_bin:-}" || -z "${py:-}" ]] || ! command -v zig >/dev/null; then
        echo "coverage: windows-native: needs a mingw gcc, python, and zig; skipping" >&2
        empty_report "$report"
        return
    fi
    if ! (windows_native_slice "$report" "$gcc_bin" "$py"); then
        echo "coverage: windows-native: slice incomplete" >&2
    fi
    [[ -f "$report" ]] || empty_report "$report"
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
        # portal.c's Request/Response state machine, reached by #including
        # portal.c directly (the payload suites link it as a separate TU, so its
        # static on_response is invisible to them); gcov_to_sonar unions the
        # portal.c.gcov it emits with the payload suites' copy.
        mkdir -p portal_core
        (
            cd portal_core
            # shellcheck disable=SC2046
            cc --coverage -O0 -I "$root/linux/src" -I "$root/include" \
                $(pkg-config --cflags gtk4) \
                -c "$root/linux/tests/portal_core.c" -o portal_core.o
            # shellcheck disable=SC2046
            cc --coverage portal_core.o $(pkg-config --libs gtk4) -o suite
            ./suite >/dev/null
            gcov portal_core.gcda >/dev/null 2>&1 || true
        )
        for g in portal_core/*.gcov; do all_covs+=("$g"); done
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

            # The headless GTK harnesses, instrumented: they reach the handlers
            # the pixel smoke cannot (transcription round-trip, tracked idles,
            # the Settings dialog, the download engine, and the app entry's
            # dialogs / crash surfacing / model-load error path). Each harness
            # builds in its own subdir (harness/<name>) so their overlapping
            # overlay_window.c counters do not collide; gcov each separately and
            # let gcov_to_sonar union the per-file reports.
            mkdir -p harness
            if BOO_HARNESS_WORK="$PWD/harness" BOO_HARNESS_CFLAGS="--coverage" \
                BOO_HARNESS_LIBS="$(gcc -print-file-name=libgcov.a)" \
                bash "$root/linux/tests/ui-harness.sh"; then
                for d in harness/*/; do
                    (cd "$d" && gcov ./*.gcda >/dev/null 2>&1 || true)
                    for g in "$d"*.gcov; do all_covs+=("$g"); done
                done
            else
                echo "coverage: linux: GTK harnesses failed; slice skipped" >&2
            fi
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
    # Every source except the app entry (its top-level code is the launch; the
    # harness has its own), so the whole Swift frontend lands in the report.
    local srcs=()
    local f
    for f in "$root"/macos/Sources/*.swift; do
        [[ "$(basename "$f")" == "main.swift" ]] || srcs+=("$f")
    done
    local work
    work=$(mktemp -d)
    swiftc -profile-generate -profile-coverage-mapping \
        -import-objc-header "$root/include/boo.h" \
        "${srcs[@]}" \
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
        windows-native) gen_windows_native ;;
        linux) gen_linux ;;
        swift) gen_swift ;;
        core) gen_core ;;
        *)
            echo "unknown section: $section (want windows|windows-native|linux|swift|core)" >&2
            exit 2
            ;;
    esac
done
