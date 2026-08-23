#!/usr/bin/env python3
"""Static checks over the Swift sources.

There is no Swift toolchain on this machine, so this is NOT a compile. It
catches the failure modes that are checkable without one, and enforces the
project's engineering rules:

  * balanced braces, parentheses and brackets outside strings and comments
  * no force unwraps or force casts in hardware / measurement code
  * no placeholder ellipses, TODO or FIXME markers in shipping code
  * no `print(` calls (OSLog only)
  * every file has a trailing newline and no tab indentation
  * `import` lines resolve to Apple frameworks only (no third-party packages)

    python3 Tools/check_sources.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = ("Lucid", "LucidTests")

ALLOWED_IMPORTS = {
    "Accelerate", "AVFoundation", "Charts", "CoreGraphics", "CoreImage",
    "CoreMedia", "CoreMotion", "CoreVideo", "Foundation", "Metal",
    "MetalPerformanceShaders", "Observation", "OSLog", "SwiftUI", "UIKit",
    "Vision", "XCTest",
}

# Force unwrapping is banned outright in these directories.
STRICT_DIRS = ("Lucid/Camera", "Lucid/Domain", "Lucid/Services", "Lucid/Features")


def strip_code(text: str) -> str:
    """Blank out string literals and comments so scanning sees code only."""
    out = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if text.startswith('"""', index):
            end = text.find('"""', index + 3)
            end = length if end == -1 else end + 3
            out.append(" " * (end - index))
            index = end
        elif char == '"':
            index += 1
            out.append(" ")
            while index < length and text[index] != '"':
                if text[index] == "\\":
                    out.append("  ")
                    index += 2
                    continue
                out.append("\n" if text[index] == "\n" else " ")
                index += 1
            out.append(" ")
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end == -1 else end
            out.append(" " * (end - index))
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index)
            end = length if end == -1 else end + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[index:end]))
            index = end
        else:
            out.append(char)
            index += 1
    return "".join(out)


def check_balance(code: str) -> str | None:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    line = 1
    for char in code:
        if char == "\n":
            line += 1
        elif char in "([{":
            stack.append((char, line))
        elif char in ")]}":
            if not stack or stack[-1][0] != pairs[char]:
                return f"unbalanced {char!r} at line {line}"
            stack.pop()
    if stack:
        opener, opened_at = stack[-1]
        return f"unclosed {opener!r} opened at line {opened_at}"
    return None


FORCE_UNWRAP = re.compile(r"[A-Za-z0-9_\)\]]\s*!\s*(?:\.|,|\)|$|\s)")
# A hex literal may only contain hex digits and underscores. Anything else is a
# placeholder that was never filled in.
BAD_HEX = re.compile(r"\b0[xX](?![0-9a-fA-F])|\b0[xX][0-9a-fA-F_]*[G-Zg-z][A-Za-z0-9_]*")
BAD_BINARY = re.compile(r"\b0[bB][01_]*[2-9A-Za-z][A-Za-z0-9_]*")
FORCE_CAST = re.compile(r"\bas!\s")
TRY_BANG = re.compile(r"\btry!\s")


def main() -> int:
    failures: list[str] = []
    checked = 0

    for directory in SOURCE_DIRS:
        for current, subdirs, files in os.walk(os.path.join(ROOT, directory)):
            subdirs[:] = sorted(d for d in subdirs if not d.startswith("."))
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(current, name)
                relative = os.path.relpath(path, ROOT)
                text = open(path, encoding="utf-8").read()
                code = strip_code(text)
                checked += 1

                def fail(message: str) -> None:
                    failures.append(f"{relative}: {message}")

                if not text.endswith("\n"):
                    fail("no trailing newline")
                if "\t" in text:
                    fail("tab indentation")

                problem = check_balance(code)
                if problem:
                    fail(problem)

                for pattern, label in (("TODO", "TODO marker"),
                                       ("FIXME", "FIXME marker"),
                                       ("<#", "Xcode placeholder token")):
                    if pattern in text:
                        fail(label)

                for number, line in enumerate(code.splitlines(), start=1):
                    stripped = line.strip()
                    if stripped == "...":
                        fail(f"placeholder ellipsis at line {number}")
                    if re.search(r"\bprint\s*\(", line):
                        fail(f"print() at line {number}; use OSLog")
                    if BAD_HEX.search(line):
                        fail(f"malformed hex literal at line {number}: {stripped}")
                    if BAD_BINARY.search(line):
                        fail(f"malformed binary literal at line {number}: {stripped}")
                    if relative.replace(os.sep, "/").startswith(STRICT_DIRS):
                        if FORCE_UNWRAP.search(line):
                            fail(f"force unwrap at line {number}: {stripped}")
                        if FORCE_CAST.search(line):
                            fail(f"force cast at line {number}: {stripped}")
                        if TRY_BANG.search(line):
                            fail(f"try! at line {number}: {stripped}")

                for match in re.finditer(r"^(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", code, re.M):
                    module = match.group(1)
                    if module not in ALLOWED_IMPORTS and module != "Lucid":
                        fail(f"unexpected import {module}")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print(f"source checks OK  ({checked} Swift files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
