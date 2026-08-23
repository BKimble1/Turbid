#!/usr/bin/env python3
"""Structural audit of the Swift sources, using a real Swift parser.

There is no Swift toolchain on this machine, so this is NOT a compile. What it
is, is a parse: `tree-sitter-swift` builds the same kind of syntax tree the
compiler's front end would, which makes a class of error checkable that a
regular expression cannot see.

    python3 -m pip install tree_sitter tree_sitter_swift
    python3 Tools/swift_audit.py

It checks:

  * every file parses, with no error or missing nodes;
  * every type referenced is either declared in the module or on the reviewed
    list of Apple and standard-library names below - a typo in a type name has
    nowhere to hide;
  * every call of the form `Type.method(...)` and every `Type(...)` whose type
    is declared in this module matches one of that type's declarations, in
    argument labels and in order, allowing for defaults and a trailing closure;
  * every type that conforms to a protocol declared in this module implements
    that protocol's requirements;
  * every `switch` over an enum declared in this module is exhaustive or has a
    default;
  * no SwiftUI view builder is given more than the ten children it accepts;
  * nothing is declared twice with the same name and labels in one file.

Skips itself with a clear message when the parser is not installed, so it can
sit in `check.sh` without making the parser a hard requirement.
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = ("Lucid", "LucidTests", "LucidUITests")

# Reviewed by hand, once. Everything here is an Apple SDK type, a standard
# library type, an XCTest assertion or an attribute name. A name that is not in
# this set and not declared in the module is either new (add it after checking
# it is real) or a mistake.
EXTERNAL_NAMES = {
    "AVAuthorizationStatus", "AVCaptureConnection", "AVCaptureDevice",
    "AVCaptureDeviceInput", "AVCaptureOutput", "AVCaptureSession",
    "AVCaptureVideoDataOutput",
    "AVCaptureVideoDataOutputSampleBufferDelegate",
    "AVCaptureVideoPreviewLayer", "Animation", "Any", "AnyClass",
    "AnyObject", "App", "Array", "AsyncStream", "Binding", "Bool", "Bundle",
    "Button", "ButtonRole", "CAShapeLayer", "CFDictionary", "CFString",
    "CGFloat", "CGPoint", "CGRect", "CGVector",
    "CMFormatDescriptionGetMediaSubType", "CMMotionManager",
    "CMSampleBuffer", "CMSampleBufferGetImageBuffer",
    "CMSampleBufferGetPresentationTimeStamp", "CMTime", "CMTimeGetSeconds",
    "CMTimeScale", "CMVideoFormatDescriptionGetDimensions", "CVPixelBuffer",
    "CVPixelBufferCreate", "CVPixelBufferGetBaseAddressOfPlane",
    "CVPixelBufferGetBytesPerRowOfPlane", "CVPixelBufferGetHeight",
    "CVPixelBufferGetHeightOfPlane", "CVPixelBufferGetPixelFormatType",
    "CVPixelBufferGetPlaneCount", "CVPixelBufferGetWidth",
    "CVPixelBufferGetWidthOfPlane", "CVPixelBufferLockBaseAddress",
    "CVPixelBufferUnlockBaseAddress", "CancellationError", "Capsule",
    "CaseIterable", "Character", "Chart", "ClosedRange", "Codable", "Color",
    "Comparable", "Context", "ContinuousClock", "CustomStringConvertible",
    "Data", "Date", "DatePicker", "DisclosureGroup", "DispatchQueue",
    "DispatchSourceTimer", "DispatchTimeInterval", "Divider", "Double",
    "Duration", "Environment", "Equatable", "Error", "FileManager", "Float",
    "ForEach", "HStack", "Hashable", "Identifiable", "Image", "Int",
    "Int32", "Int64", "JSONDecoder", "JSONEncoder", "Label",
    "LabeledContent", "LineMark", "List", "Logger", "MainActor", "NSCoder",
    "NSError", "NSKeyValueObservation", "NSLock", "NSObject",
    "NSObjectProtocol", "NavigationStack", "Never", "OSType", "Observable",
    "Picker", "ProcessInfo", "ProgressView", "RandomNumberGenerator",
    "RawRepresentable", "RoundedRectangle", "Scene", "ScenePhase",
    "ScrollView", "Section", "Sendable", "Set", "Spacer", "State",
    "StaticString", "Stepper", "String", "StrokeStyle", "Task", "Text",
    "TextField", "TimeInterval", "ToolbarItem", "UIBezierPath", "UIColor",
    "UIKeyboardType", "UILabel", "UIView", "UIViewRepresentable", "UInt",
    "UInt32", "UInt64", "UInt8", "URL", "UUID", "UnicodeScalar",
    "UserDefaults", "VStack", "View", "ViewBuilder", "ViewModifier", "Void",
    "WindowGroup", "XCTAssertEqual", "XCTAssertFalse",
    "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual",
    "XCTAssertLessThan", "XCTAssertLessThanOrEqual", "XCTAssertNil",
    "XCTAssertNotEqual", "XCTAssertNotNil", "XCTAssertThrowsError",
    "XCTAssertTrue", "XCTFail", "XCTUnwrap", "XCTestCase",
    "XCUIApplication", "discardableResult", "main", "testable", "unchecked",
    "unknown"
}


def load_parser():
    try:
        from tree_sitter import Language, Parser
        import tree_sitter_swift
    except ImportError:
        return None, None
    return Parser(Language(tree_sitter_swift.language())), True


def text(node, src: bytes) -> str:
    return src[node.start_byte:node.end_byte].decode("utf-8", "replace")


def parameters(node, src):
    """Argument labels of a function or initializer, and which have defaults.

    The `=` and its value are siblings of `parameter` rather than children of
    it, so a default is detected by looking at the following sibling.
    """
    labels, defaults = [], []
    kids = node.children
    for index, child in enumerate(kids):
        if child.type != "parameter":
            continue
        identifiers = [k for k in child.children
                       if k.type in ("simple_identifier", "wildcard_pattern")]
        if not identifiers:
            continue
        external = text(identifiers[0], src)
        labels.append(None if external == "_" else external)
        defaults.append(index + 1 < len(kids) and kids[index + 1].type == "=")
    return labels, defaults


def argument_labels(call, src):
    """Labels a call site supplies, and whether it uses a trailing closure."""
    labels, trailing = [], False
    for child in call.children[1:]:
        if child.type != "call_suffix":
            continue
        for part in child.children:
            if part.type == "value_arguments":
                for argument in part.children:
                    if argument.type != "value_argument":
                        continue
                    label = [k for k in argument.children
                             if k.type == "value_argument_label"]
                    labels.append(text(label[0], src) if label else None)
            elif part.type == "lambda_literal":
                trailing = True
    return labels, trailing


def accepts(given, labels, defaults, trailing) -> bool:
    """Whether a declaration could accept this label sequence."""
    expected = list(labels)
    if trailing and expected:
        expected = expected[:-1]
    index = 0
    for position, label in enumerate(expected):
        if index < len(given) and given[index] == label:
            index += 1
        elif position < len(defaults) and defaults[position]:
            continue
        else:
            return False
    return index == len(given)


class Module:
    """Everything the audit needs to know about the sources, in one pass."""

    def __init__(self):
        self.types: set[str] = set()
        self.protocols: set[str] = set()
        self.generics: set[str] = set()
        self.enum_cases: dict[str, set[str]] = {}
        self.members: dict[tuple[str, str], list] = {}
        self.properties: dict[str, set[str]] = {}
        # Only what a protocol body actually requires. A default implementation
        # in `extension P` is a member of P but not a requirement, and counting
        # it would report every conformer as incomplete.
        self.requirements: dict[str, set[str]] = {}
        self.conformances: dict[str, set[str]] = {}
        self.references: dict[str, list] = {}
        self.files: list[tuple[str, bytes, object]] = []

    def owner_of(self, node, src, inherited):
        """The type a declaration node introduces, or the inherited one."""
        if node.type not in ("class_declaration", "protocol_declaration"):
            return inherited
        for child in node.children:
            if child.type == "type_identifier":
                name = text(child, src)
                self.types.add(name)
                if node.type == "protocol_declaration":
                    self.protocols.add(name)
                return name
            if child.type == "user_type":          # an extension
                identifiers = [k for k in child.children if k.type == "type_identifier"]
                if identifiers:
                    return text(identifiers[0], src)
                break
        return inherited

    def collect(self, path, src, root):
        def visit(node, owner):
            here = self.owner_of(node, src, owner)

            if node.type in ("class_declaration", "protocol_declaration") and here:
                for child in node.children:
                    if child.type == "inheritance_specifier":
                        for kind in child.children:
                            if kind.type == "user_type":
                                names = [k for k in kind.children
                                         if k.type == "type_identifier"]
                                if names:
                                    self.conformances.setdefault(here, set()).add(
                                        text(names[0], src))

            if node.type == "enum_entry" and here:
                for child in node.children:
                    if child.type == "simple_identifier":
                        self.enum_cases.setdefault(here, set()).add(text(child, src))

            if node.type == "type_parameter":
                for child in node.children:
                    if child.type == "type_identifier":
                        self.generics.add(text(child, src))

            if node.type in ("function_declaration",
                             "protocol_function_declaration") and here:
                for child in node.children:
                    if child.type == "simple_identifier":
                        name = text(child, src)
                        self.members.setdefault((here, name), []).append(
                            parameters(node, src) + (path, node.start_point[0] + 1))
                        if node.type == "protocol_function_declaration":
                            self.requirements.setdefault(here, set()).add(name)
                        break

            if node.type == "init_declaration" and here:
                self.members.setdefault((here, "init"), []).append(
                    parameters(node, src) + (path, node.start_point[0] + 1))

            if node.type in ("property_declaration",
                             "protocol_property_declaration") and here:
                for child in node.children:
                    if child.type == "pattern":
                        names = [k for k in child.children if k.type == "simple_identifier"]
                        if names:
                            name = text(names[0], src)
                            self.properties.setdefault(here, set()).add(name)
                            if node.type == "protocol_property_declaration":
                                self.requirements.setdefault(here, set()).add(name)
                        break

            if node.type == "user_type":
                names = [k for k in node.children if k.type == "type_identifier"]
                if names:
                    self.references.setdefault(text(names[0], src), []).append(
                        (path, names[0].start_point[0] + 1))

            if node.type == "call_expression" and node.children:
                callee = node.children[0]
                if callee.type == "simple_identifier":
                    name = text(callee, src)
                    if name and name[0].isupper():
                        self.references.setdefault(name, []).append(
                            (path, callee.start_point[0] + 1))

            for child in node.children:
                visit(child, here)

        visit(root, None)


def parse_failures(module) -> list[str]:
    failures = []
    for path, src, tree in module.files:
        found = []

        def visit(node):
            if node.type == "ERROR" or node.is_missing:
                found.append((node.start_point[0] + 1,
                              "missing token" if node.is_missing else "cannot parse",
                              text(node, src)[:90].replace("\n", " ")))
                return
            for child in node.children:
                visit(child)

        visit(tree.root_node)
        for line, kind, snippet in found[:5]:
            failures.append(f"{path}:{line}: {kind}: {snippet}")
    return failures


def unresolved_types(module) -> list[str]:
    known = module.types | module.generics | EXTERNAL_NAMES
    failures = []
    for name in sorted(module.references):
        if name in known:
            continue
        path, line = module.references[name][0]
        count = len(module.references[name])
        failures.append(
            f"{path}:{line}: {name} is not declared here and is not a reviewed "
            f"external name ({count} use(s))"
        )
    return failures


def call_mismatches(module, parser) -> list[str]:
    failures = []
    for path, src, tree in module.files:
        def visit(node):
            if node.type == "call_expression" and node.children:
                callee = node.children[0]
                owner = name = None

                if callee.type == "simple_identifier" and text(callee, src) in module.types:
                    owner, name = text(callee, src), "init"
                elif callee.type == "navigation_expression":
                    suffixes = [c for c in callee.children if c.type == "navigation_suffix"]
                    if suffixes:
                        identifiers = [k for k in suffixes[-1].children
                                       if k.type == "simple_identifier"]
                        receiver = text(callee.children[0], src).strip()
                        if identifiers and receiver in module.types:
                            owner, name = receiver, text(identifiers[0], src)

                if owner and name and name not in module.enum_cases.get(owner, set()):
                    declarations = module.members.get((owner, name))
                    if declarations:
                        given, trailing = argument_labels(node, src)
                        if not any(accepts(given, labels, defaults, trailing)
                                   for labels, defaults, _, _ in declarations):
                            shown = ", ".join(str(g) for g in given)
                            failures.append(
                                f"{path}:{node.start_point[0] + 1}: "
                                f"{owner}.{name}({shown}) matches no declaration"
                            )
            for child in node.children:
                visit(child)

        visit(tree.root_node)
    return failures


def missing_conformances(module) -> list[str]:
    """Requirements a conforming type never implements.

    Deliberately shallow: it reports a requirement only when the conforming
    type declares nothing of that name anywhere, so a default implementation in
    a protocol extension or an inherited member keeps it quiet.
    """
    failures = []
    for conformer, protocols in sorted(module.conformances.items()):
        for protocol in sorted(protocols):
            if protocol not in module.protocols:
                continue
            required = set(module.requirements.get(protocol, set()))
            implemented = {name for (owner, name) in module.members if owner == conformer}
            implemented |= module.properties.get(conformer, set())
            for name in sorted(required - implemented):
                failures.append(
                    f"{conformer} conforms to {protocol} but declares no {name}"
                )
    return failures


def inexhaustive_switches(module) -> list[str]:
    """Switches over a module enum that name some cases but not all."""
    failures = []
    for path, src, tree in module.files:
        def visit(node):
            if node.type == "switch_statement":
                named, has_default = set(), False
                for entry in node.children:
                    if entry.type != "switch_entry":
                        continue
                    if any(c.type == "default_keyword" or text(c, src) == "default"
                           for c in entry.children):
                        has_default = True
                    for pattern in entry.children:
                        if pattern.type != "switch_pattern":
                            continue
                        body = text(pattern, src).strip()
                        if body.startswith("."):
                            named.add(body[1:].split("(")[0].split(" ")[0])
                if named and not has_default:
                    # An exact match means the switch is exhaustive over that
                    # enum, whatever else it may also be a subset of: one
                    # enum's cases are often a subset of another's.
                    exact = any(named == cases for cases in module.enum_cases.values())
                    candidates = [(enum, cases) for enum, cases in module.enum_cases.items()
                                  if named < cases]
                    # Only when exactly one enum could be meant: more than one
                    # and the answer is a guess, not a finding.
                    if not exact and len(candidates) == 1:
                        enum, cases = candidates[0]
                        missing = ", ".join(sorted(cases - named))
                        failures.append(
                            f"{path}:{node.start_point[0] + 1}: switch over "
                            f"{enum} does not handle {missing}"
                        )
            for child in node.children:
                visit(child)

        visit(tree.root_node)
    return failures


# SwiftUI's result builder takes at most ten children. An eleventh is not a
# runtime problem — it is "extra argument in call", at compile time, in a
# message that does not mention the limit.
VIEW_BUILDER_LIMIT = 10
VIEW_CONTAINERS = {
    "VStack", "HStack", "ZStack", "Group", "Form", "List", "Section",
    "ScrollView", "LazyVStack", "LazyHStack", "NavigationStack", "Chart",
    "ForEach", "Button", "DisclosureGroup", "Picker", "ToolbarItem", "Label",
    "SectionCard",
}


def overfull_view_builders(module) -> list[str]:
    failures = []
    for path, src, tree in module.files:
        def visit(node):
            if node.type == "call_expression" and node.children:
                callee = node.children[0]
                name = text(callee, src) if callee.type == "simple_identifier" else None
                if name in VIEW_CONTAINERS:
                    for child in node.children[1:]:
                        if child.type != "call_suffix":
                            continue
                        for part in child.children:
                            if part.type != "lambda_literal":
                                continue
                            bodies = [k for k in part.children if k.type == "statements"]
                            if not bodies:
                                continue
                            children = [k for k in bodies[0].children
                                        if k.type not in ("comment", "multiline_comment")]
                            if len(children) > VIEW_BUILDER_LIMIT:
                                failures.append(
                                    f"{path}:{node.start_point[0] + 1}: {name} has "
                                    f"{len(children)} children; a view builder takes "
                                    f"{VIEW_BUILDER_LIMIT}"
                                )
            for child in node.children:
                visit(child)

        visit(tree.root_node)
    return failures


def duplicate_declarations(module) -> list[str]:
    """Two declarations of the same name and labels in one type.

    Restricted to declarations in the same file. Members are keyed by the
    type's simple name, and nested types repeat those names — `Configuration`
    appears inside eight different types here — so comparing across files would
    report collisions that are not redeclarations.
    """
    failures = []
    for (owner, name), declarations in sorted(module.members.items()):
        seen: dict[tuple, list] = {}
        for labels, _, path, line in declarations:
            seen.setdefault((path, tuple(labels)), []).append(line)
        # Sorted by the path only: a label list can contain `None` for an
        # unlabelled parameter, which does not order against a string.
        for (path, labels), lines in sorted(seen.items(), key=lambda item: item[0][0]):
            if len(lines) > 1:
                shown = ", ".join(str(label) for label in labels)
                failures.append(
                    f"{path}: {owner}.{name}({shown}) is declared "
                    f"{len(lines)} times, at lines {lines}"
                )
    return failures


def main() -> int:
    parser, ok = load_parser()
    if not ok:
        print("swift audit SKIPPED  (pip install tree_sitter tree_sitter_swift)")
        return 0

    module = Module()
    for directory in SOURCE_DIRS:
        base = os.path.join(ROOT, directory)
        if not os.path.isdir(base):
            continue
        for current, subdirs, names in os.walk(base):
            subdirs[:] = sorted(d for d in subdirs if not d.startswith("."))
            for name in sorted(names):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(current, name)
                relative = os.path.relpath(path, ROOT)
                src = open(path, "rb").read()
                module.files.append((relative, src, parser.parse(src)))

    for relative, src, tree in module.files:
        module.collect(relative, src, tree.root_node)

    failures: list[str] = []
    failures += parse_failures(module)
    if failures:                       # nothing else is meaningful on a bad parse
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    failures += unresolved_types(module)
    failures += call_mismatches(module, parser)
    failures += missing_conformances(module)
    failures += inexhaustive_switches(module)
    failures += overfull_view_builders(module)
    failures += duplicate_declarations(module)

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print(f"swift audit OK  ({len(module.files)} files parsed, "
          f"{len(module.types)} types, {len(module.references)} type references)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
