#!/usr/bin/env bash
# Generate SonarCloud coverage from the pure-C unit tests.
#
# Boo's most-tested code is the Zig core (theme parser, model rank, audio maths,
# VAD chunker, WER, logger, all under `zig build test`), but SonarCloud does not
# analyse Zig, so that coverage cannot map to analysed files. What Sonar sees is
# the C + Swift frontends; most of that is UI glue that only a running app
# exercises (covered by the pixel smoke + UAT, and excluded from coverage in
# sonar-project.properties). This covers the part that IS unit-testable in
# isolation, the paste-chord planner. Swift coverage is a separate test target.
set -euo pipefail
shopt -s nullglob

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
out="$root/coverage"
mkdir -p "$out"

# Same pure-C target the lint job builds (no windows.h), now with gcov counters.
# Compile each source separately so the .gcno/.gcda land in the cwd with
# predictable names (a single compile+link command names them unpredictably).
cd "$work"
cflags=(--coverage -O0 -I "$root/windows/src")
cc "${cflags[@]}" -c "$root/windows/src/inject_plan.c" -o inject_plan.o
cc "${cflags[@]}" -c "$root/windows/tests/inject_plan_test.c" -o inject_plan_test.o
cc --coverage inject_plan.o inject_plan_test.o -o inject_plan_test
./inject_plan_test
gcov inject_plan.c inject_plan_test.c >/dev/null 2>&1 || true

# Coverage is a nice-to-have, never a CI gate: if the toolchain produced no
# gcov output, write an empty (valid) report and succeed rather than failing.
covs=(*.gcov)
if [[ ${#covs[@]} -eq 0 ]]; then
    echo "coverage: gcov produced no reports; writing an empty report" >&2
    printf '<coverage version="1"/>\n' >"$out/sonar-coverage.xml"
    exit 0
fi
python3 "$root/scripts/gcov_to_sonar.py" "$out/sonar-coverage.xml" "$root" "${covs[@]}"
