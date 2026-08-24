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
  * memberwise initializer calls name properties the struct actually declares,
    in declaration order
  * the UI tests' copy of the accessibility identifiers matches the app's
  * no networking anywhere, and no file writing on the frame path
  * no user-facing copy claiming accuracy nobody has measured

    python3 Tools/check_sources.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = ("Turbid", "TurbidTests", "TurbidUITests")

ALLOWED_IMPORTS = {
    "Accelerate", "AVFoundation", "Charts", "CoreGraphics", "CoreImage",
    "CoreMedia", "CoreMotion", "CoreVideo", "Foundation", "Metal",
    "MetalPerformanceShaders", "Observation", "OSLog", "SwiftUI", "UIKit",
    "Vision", "XCTest",
}

# Force unwrapping is banned outright in these directories.
STRICT_DIRS = ("Turbid/Camera", "Turbid/Domain", "Turbid/Services", "Turbid/Features")


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


TYPE_DECL = re.compile(
    r"\b(struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
STORED_PROPERTY = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|fileprivate|private|package)(?:\(set\))?\s+)*"
    r"(?:static\s+|class\s+|lazy\s+|weak\s+|unowned\s+)*"
    r"(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::|=)"
)
STATIC_MEMBER = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|fileprivate|private|package)(?:\(set\))?\s+)*"
    r"(?:static|class)\s"
)
ARGUMENT_LABEL = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:")
INIT_DECL = re.compile(r"\binit\s*[?!]?\s*(?:<[^>]*>\s*)?\(")


def matching_brace(code: str, open_index: int) -> int:
    """Index of the '}' closing the '{' at `open_index`, or -1."""
    depth = 0
    for index in range(open_index, len(code)):
        char = code[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return -1


def type_bodies(code: str):
    """Yield (kind, name, body_start, body_end) for each type declaration."""
    for match in TYPE_DECL.finditer(code):
        brace = code.find("{", match.end())
        if brace == -1:
            continue
        end = matching_brace(code, brace)
        if end == -1:
            continue
        yield match.group(1), match.group(2), brace + 1, end


def own_lines(code: str, start: int, end: int):
    """Lines of a type body that are not inside a nested brace."""
    depth = 0
    line: list[str] = []
    # The depth the line started at: a line that opens a brace still belongs to
    # the body, and judging it by the depth at its end would swallow it.
    line_depth = 0
    for index in range(start, end):
        char = code[index]
        if char == "\n":
            if line_depth == 0:
                yield "".join(line)
            line = []
            line_depth = depth
            continue
        if depth == 0:
            line.append(char)
        if char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
    if line_depth == 0 and line:
        yield "".join(line)


def stored_properties(code: str, start: int, end: int) -> list[str]:
    """Stored instance properties, in declaration order."""
    names: list[str] = []
    for line in own_lines(code, start, end):
        match = STORED_PROPERTY.match(line)
        if not match or STATIC_MEMBER.match(line):
            continue
        tail = line[match.end(2):]
        brace = tail.find("{")
        equals = tail.find("=")
        # `var x: T { ... }` is computed; `var x = 0 { didSet ... }` is stored.
        if brace != -1 and (equals == -1 or equals > brace):
            continue
        names.append(match.group(2))
    return names


def top_level_labels(code: str, open_index: int) -> tuple[list[str | None], int]:
    """Argument labels of the call whose '(' sits at `open_index`."""
    depth = 0
    start = open_index + 1
    labels: list[str | None] = []
    for index in range(open_index, len(code)):
        char = code[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                piece = code[start:index]
                if piece.strip():
                    match = ARGUMENT_LABEL.match(piece)
                    labels.append(match.group(1) if match else None)
                return labels, index
        elif char == "," and depth == 1:
            match = ARGUMENT_LABEL.match(code[start:index])
            labels.append(match.group(1) if match else None)
            start = index + 1
    return labels, -1


IDENTIFIER_CONSTANT = re.compile(
    r"^\s*static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]*)\"", re.M
)
APP_IDENTIFIERS = "Turbid/Shared/AccessibilityIdentifiers.swift"
UITEST_IDENTIFIERS = "TurbidUITests/UITestIdentifiers.swift"


def check_identifier_mirror(sources: dict[str, str]) -> list[str]:
    """The UI-test bundle cannot import the app, so it repeats the app's
    accessibility identifiers. This is what stops the copy from drifting.

    Reads the raw text rather than the stripped code: the identifiers *are*
    string literals, and the stripped copy has had every one of them blanked.
    """
    app = sources.get(APP_IDENTIFIERS)
    mirror = sources.get(UITEST_IDENTIFIERS)
    if app is None or mirror is None:
        return [f"{APP_IDENTIFIERS} and {UITEST_IDENTIFIERS} must both exist"]

    def constants(code: str) -> dict[str, str]:
        return {name: value for name, value in IDENTIFIER_CONSTANT.findall(code)}

    left, right = constants(app), constants(mirror)
    failures = []
    for name in sorted(set(left) - set(right)):
        failures.append(f"{UITEST_IDENTIFIERS}: missing identifier {name}")
    for name in sorted(set(right) - set(left)):
        failures.append(f"{UITEST_IDENTIFIERS}: identifier {name} is not in the app")
    for name in sorted(set(left) & set(right)):
        if left[name] != right[name]:
            failures.append(
                f"{UITEST_IDENTIFIERS}: {name} is {right[name]!r}, "
                f"the app uses {left[name]!r}"
            )
    return failures


# --- Frames must never leave the device, and never be written down ----------
#
# The privacy claim in the README and in `PrivacyInfo.xcprivacy` is that video
# is processed on device and nothing is stored or transmitted. That is only a
# claim unless something checks it, so these are the APIs that would break it.
NETWORK_SYMBOLS = (
    "URLSession", "URLRequest", "URLConnection", "NWConnection", "NWListener",
    "NWBrowser", "CFStreamCreate", "CFSocket", "NSURLSession",
)
NETWORK_MODULES = {"Network", "CFNetwork", "CoreTelephony", "MultipeerConnectivity"}
# Anything that turns a frame into a file or a photo-library asset.
FRAME_PERSISTENCE_SYMBOLS = (
    "AVAssetWriter", "AVCaptureMovieFileOutput", "AVCapturePhotoOutput",
    "CGImageDestination", "UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary",
    "PHAssetCreationRequest", "UIPasteboard",
)
# Directories that see pixel data. Nothing here may write a file at all.
FRAME_PATH_DIRS = ("Turbid/Camera", "Turbid/Analysis")
FILE_WRITE_SYMBOLS = ("FileHandle", "OutputStream", "createFile(")


def check_frames_stay_on_device(sources: dict[str, str]) -> list[str]:
    """No networking anywhere, and no file writing where the pixels are."""
    failures: list[str] = []
    for relative, code in sorted(sources.items()):
        normalized = relative.replace(os.sep, "/")
        if normalized.startswith(("TurbidTests/", "TurbidUITests/")):
            continue

        for symbol in NETWORK_SYMBOLS:
            if re.search(r"(?<![A-Za-z0-9_])" + re.escape(symbol), code):
                failures.append(f"{relative}: uses {symbol}; Turbid has no network code")
        for match in re.finditer(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", code, re.M):
            if match.group(1) in NETWORK_MODULES:
                failures.append(f"{relative}: imports {match.group(1)}")

        for symbol in FRAME_PERSISTENCE_SYMBOLS:
            if re.search(r"(?<![A-Za-z0-9_])" + re.escape(symbol), code):
                failures.append(
                    f"{relative}: uses {symbol}; frames are never stored or shared"
                )

        if normalized.startswith(FRAME_PATH_DIRS):
            for symbol in FILE_WRITE_SYMBOLS:
                if symbol in code:
                    failures.append(
                        f"{relative}: uses {symbol}; nothing on the frame path writes files"
                    )
            if re.search(r"\.write\s*\(to\s*:", code):
                failures.append(
                    f"{relative}: writes a file; nothing on the frame path may"
                )
    return failures


# --- Copy may not claim accuracy nobody has measured ------------------------
#
# Every threshold in Turbid is an unvalidated engineering starting point. These
# are the phrases that would turn that into a claim.
CLAIM_PHRASES = (
    "laboratory-grade", "laboratory grade", "lab-grade", "lab grade",
    "professional-grade", "professional grade", "medical-grade", "medical grade",
    "research-grade", "research grade",
    "epa-compliant", "epa compliant", "epa approved", "epa-approved",
    "clinically proven", "scientifically proven", "guaranteed accurate",
    "highly accurate", "accurate to within", "certified results",
    "lab quality", "lab-quality",
)
STRING_LITERAL = re.compile(r'"""(.*?)"""|"((?:[^"\\\n]|\\.)*)"', re.S)


def check_no_accuracy_claims(sources: dict[str, str]) -> list[str]:
    """Scan the raw text for phrases that would claim measured performance."""
    failures: list[str] = []
    for relative, text in sorted(sources.items()):
        normalized = relative.replace(os.sep, "/")
        if not normalized.startswith("Turbid/"):
            continue
        for match in STRING_LITERAL.finditer(text):
            literal = (match.group(1) or match.group(2) or "").lower()
            for phrase in CLAIM_PHRASES:
                if phrase in literal:
                    line = text.count("\n", 0, match.start()) + 1
                    failures.append(
                        f"{relative}: line {line} claims {phrase!r}; "
                        "no accuracy has been measured"
                    )
    return failures


def check_memberwise(sources: dict[str, str]) -> list[str]:
    """Catch calls to a struct's implicit memberwise initializer that name a
    property the struct does not declare, or list properties out of order.

    A stored property lost from a declaration is invisible to every other check
    here: the initializer call still reads correctly, and only a compiler would
    notice. That exact defect reached the tree once, so it is checked for.

    Deliberately conservative: a struct with any initializer of its own, or a
    name declared more than once, is skipped rather than guessed at.
    """
    properties: dict[str, list[str]] = {}
    duplicates: set[str] = set()
    custom_init: set[str] = set()

    for code in sources.values():
        for kind, name, start, end in type_bodies(code):
            if any(INIT_DECL.search(line) for line in own_lines(code, start, end)):
                custom_init.add(name)
            if kind != "struct":
                # Only a struct gets a memberwise initializer, and a name that
                # also belongs to some other kind of type is ambiguous here.
                if kind != "extension":
                    custom_init.add(name)
                continue
            if name in properties:
                duplicates.add(name)
                continue
            properties[name] = stored_properties(code, start, end)

    checkable = {
        name: names for name, names in sorted(properties.items())
        if name not in duplicates and name not in custom_init and names
    }

    failures: list[str] = []
    for relative, code in sorted(sources.items()):
        for name, names in checkable.items():
            pattern = (r"(?<![A-Za-z0-9_.])(?:[A-Z][A-Za-z0-9_]*\s*\.\s*)*"
                       + name + r"\s*\(")
            for match in re.finditer(pattern, code):
                labels, close = top_level_labels(code, match.end() - 1)
                if close == -1 or not labels or any(label is None for label in labels):
                    continue
                line = code.count("\n", 0, match.start()) + 1
                unknown = [label for label in labels if label not in names]
                if unknown:
                    failures.append(
                        f"{relative}: {name}(...) at line {line} names "
                        f"{', '.join(unknown)}, which {name} does not declare"
                    )
                    continue
                remaining = list(names)
                for label in labels:
                    if label not in remaining:
                        failures.append(
                            f"{relative}: {name}(...) at line {line} lists its "
                            "properties out of declaration order"
                        )
                        break
                    remaining = remaining[remaining.index(label) + 1:]
    return failures


def main() -> int:
    failures: list[str] = []
    sources: dict[str, str] = {}
    raw_sources: dict[str, str] = {}
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
                sources[relative] = code
                raw_sources[relative] = text
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
                    if module not in ALLOWED_IMPORTS and module != "Turbid":
                        fail(f"unexpected import {module}")

    failures.extend(check_memberwise(sources))
    failures.extend(check_identifier_mirror(raw_sources))
    failures.extend(check_frames_stay_on_device(sources))
    failures.extend(check_no_accuracy_claims(raw_sources))

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print(f"source checks OK  ({checked} Swift files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
