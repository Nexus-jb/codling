#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Text policy check for Codling.

Project text is written in English. This check rejects letters, digits and
punctuation from non-Latin scripts in every tracked text file, in file paths
and in commit messages. User interface translations are the one exception:
they may only live in localization files for the languages listed in
ALLOWED_LOCALES, and the maintainers decide which languages are listed.

Usage:
    scripts/check-text-policy.py [--commits RANGE] [--text-env NAME ...]

--commits checks the messages of the commits in a git revision range, for
example origin/main..HEAD. --text-env checks the value of an environment
variable, such as a pull request title or description.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import unicodedata

# Languages accepted for user interface translations. English is the source
# language; "Base" is Xcode's base localization.
ALLOWED_LOCALES = {"en", "Base"}
ENGLISH_LOCALES = {"en", "Base"}

MAX_REPORTS = 50


def allowed_char(ch: str) -> bool:
    """True if a character may appear in English project text."""
    code = ord(ch)
    if code < 0x80:
        return True
    category = unicodedata.category(ch)
    name = unicodedata.name(ch, "")
    if category[0] in "LM":
        # Latin letters with accents (names, loanwords) and combining marks.
        if name.startswith(("LATIN", "COMBINING")):
            return True
        if 0xFE00 <= code <= 0xFE0F:  # variation selectors (emoji)
            return True
        if 0x02B0 <= code <= 0x02FF:  # spacing modifier letters
            return True
        return code == 0x00B5  # micro sign
    if category[0] == "N":
        return name.startswith(
            (
                "SUPERSCRIPT",
                "SUBSCRIPT",
                "VULGAR FRACTION",
                "ROMAN NUMERAL",
                "CIRCLED",
                "NEGATIVE CIRCLED",
                "DINGBAT",
            )
        )
    # Punctuation, symbols, spaces and format characters: Latin ranges,
    # general punctuation, arrows, maths, box drawing, dingbats and emoji.
    return (
        code <= 0x02FF
        or 0x2000 <= code <= 0x2BFF
        or 0xFE00 <= code <= 0xFE0F
        or 0x1F000 <= code <= 0x1FAFF
        or code == 0xFEFF
    )


class Report:
    def __init__(self) -> None:
        self.problems: list[str] = []

    def add(self, message: str) -> None:
        self.problems.append(message)

    def check_text(self, where: str, text: str) -> None:
        for line_no, line in enumerate(text.splitlines(), start=1):
            for col, ch in enumerate(line, start=1):
                if not allowed_char(ch):
                    name = unicodedata.name(ch, "UNKNOWN")
                    self.add(f"{where}:{line_no}:{col}: U+{ord(ch):04X} {name}")
                    break  # one report per line is enough


def git(*args: str) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def decode(data: bytes) -> str | None:
    """Decodes a text file, or returns None for a binary file."""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None


def locale_of(path: str) -> str | None:
    for part in path.split("/"):
        if part.endswith(".lproj"):
            return part[: -len(".lproj")]
    return None


def check_xcstrings(report: Report, path: str, text: str) -> None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        report.add(f"{path}: not valid JSON ({error})")
        return
    source = data.get("sourceLanguage", "en")
    if source not in ENGLISH_LOCALES:
        report.add(f"{path}: the source language must be English, not '{source}'")
    for key, entry in data.get("strings", {}).items():
        report.check_text(f"{path} (key)", key)
        for locale, value in entry.get("localizations", {}).items():
            if locale not in ALLOWED_LOCALES:
                report.add(f"{path}: translations into '{locale}' are not accepted")
            elif locale in ENGLISH_LOCALES:
                report.check_text(
                    f"{path} ({locale})", json.dumps(value, ensure_ascii=False)
                )


def check_files(report: Report) -> None:
    for raw in git("ls-files", "-z").split(b"\0"):
        if not raw:
            continue
        path = raw.decode("utf-8", errors="replace")
        report.check_text(f"{path} (path)", path)
        locale = locale_of(path)
        if locale is not None and locale not in ALLOWED_LOCALES:
            report.add(f"{path}: translations into '{locale}' are not accepted")
            continue
        try:
            with open(raw, "rb") as handle:
                data = handle.read()
        except (FileNotFoundError, IsADirectoryError):
            continue  # deleted in the working tree, or a submodule
        text = decode(data)
        if text is None:
            continue
        if path.endswith(".xcstrings"):
            check_xcstrings(report, path, text)
        elif locale is None or locale in ENGLISH_LOCALES:
            report.check_text(path, text)


def check_commits(report: Report, revision_range: str) -> int:
    out = git("log", "--format=%H%x00%B%x1e", revision_range).decode(
        "utf-8", errors="replace"
    )
    count = 0
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, _, message = record.partition("\0")
        report.check_text(f"commit {sha[:12]}", message)
        count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commits", help="git revision range to check")
    parser.add_argument(
        "--text-env",
        action="append",
        default=[],
        metavar="NAME",
        help="environment variable whose value is checked",
    )
    args = parser.parse_args()

    report = Report()
    check_files(report)
    commits = check_commits(report, args.commits) if args.commits else 0
    for name in args.text_env:
        value = os.environ.get(name, "")
        if value:
            report.check_text(f"${name}", value)

    if report.problems:
        print("Text policy: project text must be in English.", file=sys.stderr)
        for problem in report.problems[:MAX_REPORTS]:
            print(f"  {problem}", file=sys.stderr)
        if len(report.problems) > MAX_REPORTS:
            print(f"  ... and {len(report.problems) - MAX_REPORTS} more", file=sys.stderr)
        return 1
    print(f"Text policy: OK ({commits} commit messages checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
