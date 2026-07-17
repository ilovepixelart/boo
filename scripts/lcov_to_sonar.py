#!/usr/bin/env python3
"""Convert lcov tracefiles (llvm-cov export --format=lcov) into SonarCloud's
generic coverage XML.

Usage: lcov_to_sonar.py <out.xml> <src-root> <tracefile> [tracefile ...]

Only SF: (source file) and DA:<line>,<count> records are used. Files outside
<src-root> are dropped, so toolchain sources never leak into the report; a
line covered by any tracefile stays covered.
"""

import os
import sys

from gcov_to_sonar import add_line, write_report


def parse_lcov(path):
    """Yield (source, line_number, covered) for the DA records in one file."""
    source = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if line.startswith("SF:"):
                source = line[3:]
            elif line.startswith("DA:") and source:
                lineno, _, count = line[3:].partition(",")
                if lineno.isdigit():
                    yield source, int(lineno), count.split(",")[0] != "0"
            elif line == "end_of_record":
                source = None


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    out_path, src_root = argv[1], os.path.abspath(argv[2])

    files = {}
    for tracefile in argv[3:]:
        for source, lineno, covered in parse_lcov(tracefile):
            add_line(files, src_root, source, lineno, covered)

    write_report(out_path, files)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
