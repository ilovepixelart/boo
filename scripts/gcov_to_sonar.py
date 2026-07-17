#!/usr/bin/env python3
"""Convert gcov line coverage into SonarCloud's generic coverage XML.

Usage: gcov_to_sonar.py <out.xml> <src-root> <file.gcov> [file.gcov ...]

Each .gcov file's `Source:` header names the file it covers; we rewrite that to
a path relative to <src-root> so it matches the paths Sonar analyses. gcov marks
each line with an execution count: a number (executed), `#####` (executable but
never run), or `-` (not executable, skipped).
"""

import os
import sys
import xml.sax.saxutils as sx


def parse_gcov(path):
    """Yield (line_number, covered) for the executable lines in one .gcov file."""
    source = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            parts = raw.split(":", 2)
            if len(parts) < 3:
                continue
            count, lineno, _ = parts[0].strip(), parts[1].strip(), parts[2]
            if lineno == "0" and count == "-":
                # Header lines like "-:0:Source:foo.c"
                tag = parts[2].strip()
                if tag.startswith("Source:"):
                    source = tag[len("Source:") :]
                continue
            if not lineno.isdigit():
                continue
            if count == "-":
                continue  # non-executable line
            yield source, int(lineno), count != "#####"


def add_line(files, src_root, source, lineno, covered):
    """Merge one executable line into `files`; a line any report covered stays
    covered. Paths outside `src_root` (system headers) are dropped."""
    rel = os.path.relpath(os.path.abspath(source), src_root)
    if rel.startswith(".."):
        return
    # The Windows slice runs gcov natively; Sonar merges the report on Linux,
    # so the paths must stay forward-slashed to match the analysed ones.
    rel = rel.replace(os.sep, "/")
    lines = files.setdefault(rel, {})
    lines[lineno] = lines.get(lineno, False) or covered


def write_report(out_path, files):
    """Write `files` ({rel_path: {line: covered}}) as Sonar generic XML."""
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as out:
        out.write('<coverage version="1">\n')
        for path in sorted(files):
            out.write(f'  <file path="{sx.escape(path)}">\n')
            for lineno in sorted(files[path]):
                flag = "true" if files[path][lineno] else "false"
                out.write(f'    <lineToCover lineNumber="{lineno}" covered="{flag}"/>\n')
            out.write("  </file>\n")
        out.write("</coverage>\n")
    print(f"{out_path}: {len(files)} files")


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    out_path, src_root = argv[1], os.path.abspath(argv[2])

    files = {}
    for gcov in argv[3:]:
        for source, lineno, covered in parse_gcov(gcov):
            if source is None:
                continue
            add_line(files, src_root, source, lineno, covered)

    write_report(out_path, files)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
