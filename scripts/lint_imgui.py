#!/usr/bin/env python3
"""Flags ImGui printf-style calls given an Odin string where C wants a
cstring: im.Text("%s", "label") or im.Text("%s", ui.ICON_X) crash (an
Odin string is a pointer and a length, and C's varargs read the length as
the next pointer). Pass a cstring(...) or fmt.ctprintf(...) instead.

    python3 scripts/lint_imgui.py [DIR...]     (default: apps app)

Exit status 1 if any call is flagged. Heuristic: it checks the arguments
after the format of im.Text, TextDisabled, TextColored, TextWrapped,
BulletText, LabelText and SetTooltip calls on one line.
"""

import os
import re
import sys

CALL = re.compile(r"\bim\.(Text|TextDisabled|TextColored|TextWrapped|BulletText|LabelText|SetTooltip)\(")
# An argument that is an Odin string: a literal, an ICON_ constant, a
# ternary between string literals, or a string-typed helper we know.
BAD = [
    re.compile(r'^"[^"]*"$'),                       # "literal"
    re.compile(r"^`[^`]*`$"),                        # `raw literal`
    re.compile(r"^(ui\.)?ICON_[A-Z0-9_]+$"),         # an icon constant (a string)
    re.compile(r'^"[^"]*"\s+if\s+.+\s+else\s+"[^"]*"$'),  # "a" if c else "b"
    re.compile(r"^fmt\.tprintf\("),                  # an Odin string
    re.compile(r"^strings\.concatenate\("),
]


def split_args(s):
    """The top-level comma-separated arguments of a call's text (from after
    its open paren); stops at the closing paren."""
    args, depth, cur, quote = [], 0, "", None
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "\"`":
            quote = ch
            cur += ch
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                args.append(cur.strip())
                return args
            depth -= 1
        if ch == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
            continue
        cur += ch
    return None  # spans lines: not checked


def check_file(path):
    problems = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            for m in CALL.finditer(line):
                args = split_args(line[m.end():])
                if not args:
                    continue
                fmt_at = 1 if m.group(1) in ("TextColored", "LabelText") else 0
                if fmt_at >= len(args) or "%" not in args[fmt_at]:
                    continue
                for a in args[fmt_at + 1:]:
                    if any(b.search(a) for b in BAD):
                        problems.append(f"{path}:{n}: im.{m.group(1)} given an Odin string ({a}): use cstring(...) or fmt.ctprintf(...)")
    return problems


def main():
    dirs = sys.argv[1:] or ["apps", "app"]
    problems = []
    for d in dirs:
        for root, _, files in os.walk(d):
            for name in files:
                if name.endswith(".odin"):
                    problems += check_file(os.path.join(root, name))
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} ImGui call(s) given Odin strings")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
