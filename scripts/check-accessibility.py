#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Checks Codling's views for text that would not follow the user's text
# size: a fixed point size (.font(.system(size: ...))) is allowed only on a
# line that says why, with a "// fixed:" comment, as for a symbol sized to
# the tile it sits in. Text uses text styles (.body, .caption, ...), which
# grow with Dynamic Type.

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXED = re.compile(r"\.font\(\s*\.system\(\s*size\s*:")
REASON = re.compile(r"//\s*fixed:\s*\S")


def main() -> int:
    problems = []
    for path in sorted((ROOT / "App").glob("**/*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if FIXED.search(line) and not REASON.search(line):
                problems.append(f"{path.relative_to(ROOT)}:{number}: a fixed font size without a '// fixed:' reason")
    for problem in problems:
        print(problem)
    if problems:
        print(f"Accessibility: {len(problems)} fixed font sizes. Use a text style, or say why the size is fixed.")
        return 1
    print("Accessibility: OK (every fixed font size says why).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
