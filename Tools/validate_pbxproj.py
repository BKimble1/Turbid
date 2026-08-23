#!/usr/bin/env python3
"""Structural validation of a generated project.pbxproj.

This cannot replace an Xcode build. What it does prove is that the file is a
well-formed OpenStep property list, that every object identifier referenced
somewhere actually exists, that every source file listed by a build phase is
present on disk, and that the required project/target objects are wired
together the way Xcode expects.

    python3 Tools/validate_pbxproj.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "Lucid.xcodeproj", "project.pbxproj")

ID_PATTERN = re.compile(r"^[0-9A-F]{24}$")


class Parser:
    """Minimal OpenStep plist reader covering the pbxproj subset."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0

    def error(self, message: str) -> None:
        line = self.text.count("\n", 0, self.index) + 1
        raise SystemExit(f"parse error at line {line}: {message}")

    def skip(self) -> None:
        while self.index < len(self.text):
            char = self.text[self.index]
            if char in " \t\r\n":
                self.index += 1
            elif self.text.startswith("//", self.index):
                end = self.text.find("\n", self.index)
                self.index = len(self.text) if end == -1 else end + 1
            elif self.text.startswith("/*", self.index):
                end = self.text.find("*/", self.index)
                if end == -1:
                    self.error("unterminated block comment")
                self.index = end + 2
            else:
                return

    def parse_value(self):
        self.skip()
        if self.index >= len(self.text):
            self.error("unexpected end of file")
        char = self.text[self.index]
        if char == "{":
            return self.parse_dict()
        if char == "(":
            return self.parse_array()
        return self.parse_scalar()

    def parse_dict(self) -> dict:
        self.index += 1  # '{'
        result: dict = {}
        while True:
            self.skip()
            if self.index >= len(self.text):
                self.error("unterminated dictionary")
            if self.text[self.index] == "}":
                self.index += 1
                return result
            key = self.parse_scalar()
            self.skip()
            if self.text[self.index] != "=":
                self.error(f"expected '=' after key {key!r}")
            self.index += 1
            result[key] = self.parse_value()
            self.skip()
            if self.text[self.index] != ";":
                self.error(f"expected ';' after value for {key!r}")
            self.index += 1

    def parse_array(self) -> list:
        self.index += 1  # '('
        result: list = []
        while True:
            self.skip()
            if self.index >= len(self.text):
                self.error("unterminated array")
            if self.text[self.index] == ")":
                self.index += 1
                return result
            result.append(self.parse_value())
            self.skip()
            if self.text[self.index] == ",":
                self.index += 1

    def parse_scalar(self) -> str:
        self.skip()
        if self.text[self.index] == '"':
            self.index += 1
            out = []
            while True:
                char = self.text[self.index]
                if char == "\\":
                    nxt = self.text[self.index + 1]
                    out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                    self.index += 2
                elif char == '"':
                    self.index += 1
                    return "".join(out)
                else:
                    out.append(char)
                    self.index += 1
        start = self.index
        while self.index < len(self.text) and self.text[self.index] not in ' \t\r\n=;,(){}"/':
            self.index += 1
        if start == self.index:
            self.error(f"empty token near {self.text[start:start + 20]!r}")
        return self.text[start:self.index]


def walk(value, callback) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            callback(key)
            walk(item, callback)
    elif isinstance(value, list):
        for item in value:
            walk(item, callback)
    else:
        callback(value)


def main() -> int:
    if not os.path.isfile(PROJECT):
        raise SystemExit(f"missing {PROJECT}; run Tools/generate_xcodeproj.py first")

    text = open(PROJECT, encoding="utf-8").read()
    if not text.startswith("// !$*UTF8*$!"):
        raise SystemExit("missing the UTF-8 pbxproj header")

    parser = Parser(text)
    root = parser.parse_value()
    parser.skip()
    if parser.index != len(text):
        raise SystemExit("trailing content after the root dictionary")

    failures: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    require(root.get("objectVersion") == "56", "unexpected objectVersion")
    require("rootObject" in root, "no rootObject")
    objects = root.get("objects")
    require(isinstance(objects, dict) and bool(objects), "no objects section")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    # 1. Every identifier-looking token must resolve to a real object.
    referenced: set[str] = set()

    def collect(token) -> None:
        if isinstance(token, str) and ID_PATTERN.match(token):
            referenced.add(token)

    walk({k: v for k, v in root.items() if k != "objects"}, collect)
    for identifier, entry in objects.items():
        require(ID_PATTERN.match(identifier) is not None,
                f"object key is not a 24-hex identifier: {identifier}")
        require("isa" in entry, f"object {identifier} has no isa")
        walk(entry, collect)

    dangling = sorted(referenced - set(objects))
    require(not dangling, f"dangling object references: {dangling}")

    # 2. Exactly one PBXProject, and it must be the root object.
    projects = [i for i, e in objects.items() if e["isa"] == "PBXProject"]
    require(len(projects) == 1, f"expected 1 PBXProject, found {len(projects)}")
    require(root.get("rootObject") in projects, "rootObject is not the PBXProject")

    # 3. Targets.
    targets = {i: e for i, e in objects.items() if e["isa"] == "PBXNativeTarget"}
    names = sorted(e["name"] for e in targets.values())
    require(names == ["Lucid", "LucidTests", "LucidUITests"],
            f"unexpected targets: {names}")

    for identifier, target in targets.items():
        require("productReference" in target, f"{target['name']} has no product reference")
        require("buildConfigurationList" in target, f"{target['name']} has no configuration list")
        phases = [objects[p]["isa"] for p in target["buildPhases"]]
        require("PBXSourcesBuildPhase" in phases, f"{target['name']} has no sources phase")

    app = next(t for t in targets.values() if t["name"] == "Lucid")
    tests = next(t for t in targets.values() if t["name"] == "LucidTests")
    uitests = next(t for t in targets.values() if t["name"] == "LucidUITests")
    require(app["productType"] == "com.apple.product-type.application",
            "Lucid is not an application target")
    require(tests["productType"] == "com.apple.product-type.bundle.unit-test",
            "LucidTests is not a unit-test target")
    require(uitests["productType"] == "com.apple.product-type.bundle.ui-testing",
            "LucidUITests is not a UI-testing target")
    require(len(tests["dependencies"]) == 1, "LucidTests does not depend on Lucid")
    require(len(uitests["dependencies"]) == 1, "LucidUITests does not depend on Lucid")

    # A UI-test bundle launches the app; it is never loaded into it. A stray
    # TEST_HOST would make it a unit-test bundle wearing the wrong product type.
    for configuration in uitests["buildConfigurationList"], :
        for config_id in objects[configuration]["buildConfigurations"]:
            settings = objects[config_id]["buildSettings"]
            require(settings.get("TEST_TARGET_NAME") == "Lucid",
                    "LucidUITests does not name Lucid as its test target")
            require("TEST_HOST" not in settings,
                    "LucidUITests must not set TEST_HOST")
            require("BUNDLE_LOADER" not in settings,
                    "LucidUITests must not set BUNDLE_LOADER")

    # 4. Every build file points at a file that exists on disk.
    paths: dict[str, str] = {}

    def resolve(group_id: str, prefix: str) -> None:
        for child in objects[group_id]["children"]:
            entry = objects[child]
            if entry["isa"] == "PBXGroup":
                segment = entry.get("path")
                resolve(child, os.path.join(prefix, segment) if segment else prefix)
            elif entry["isa"] == "PBXFileReference":
                if entry.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                    continue
                paths[child] = os.path.join(prefix, entry["path"])

    project = objects[root["rootObject"]]
    resolve(project["mainGroup"], "")

    for identifier, entry in objects.items():
        if entry["isa"] != "PBXBuildFile":
            continue
        reference = entry.get("fileRef")
        require(reference in paths, f"build file {identifier} has no resolvable path")
        if reference in paths:
            absolute = os.path.join(ROOT, paths[reference])
            require(os.path.exists(absolute), f"missing on disk: {paths[reference]}")

    # 5. Every Swift file on disk is compiled by exactly one target.
    compiled: dict[str, int] = {}
    for target in targets.values():
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_file_id in phase["files"]:
                path = paths.get(objects[build_file_id]["fileRef"])
                if path:
                    compiled[path] = compiled.get(path, 0) + 1

    on_disk: set[str] = set()
    for directory in ("Lucid", "LucidTests", "LucidUITests"):
        for current, subdirs, files in os.walk(os.path.join(ROOT, directory)):
            subdirs[:] = [d for d in subdirs if not d.endswith(".xcassets")]
            for name in files:
                if name.endswith(".swift"):
                    on_disk.add(os.path.relpath(os.path.join(current, name), ROOT))

    missing = sorted(on_disk - set(compiled))
    require(not missing, f"Swift files not compiled by any target: {missing}")
    duplicated = sorted(p for p, count in compiled.items() if count > 1)
    require(not duplicated, f"Swift files compiled more than once: {duplicated}")

    # 6. The camera purpose string must reach the built app.
    app_settings_ok = False
    for entry in objects.values():
        if entry["isa"] != "XCBuildConfiguration":
            continue
        value = entry["buildSettings"].get("INFOPLIST_KEY_NSCameraUsageDescription")
        if value:
            app_settings_ok = True
            require("torch" in value.lower(), "camera purpose string does not mention the torch")
            require("not saved" in value.lower(),
                    "camera purpose string does not say video is not saved")
            require("export" not in value.lower(),
                    "camera purpose string describes an export feature that does not exist")
    require(app_settings_ok, "INFOPLIST_KEY_NSCameraUsageDescription is not set on any configuration")

    # 7. No unnecessary privacy keys anywhere.
    forbidden = ("Microphone", "PhotoLibrary", "Location", "Contacts", "Bluetooth")
    for entry in objects.values():
        if entry["isa"] != "XCBuildConfiguration":
            continue
        for key in entry["buildSettings"]:
            for word in forbidden:
                require(word not in key, f"unexpected privacy build setting: {key}")

    # 8. The privacy manifest must actually reach the app bundle, and say what
    #    Lucid actually does. A manifest that is not in a Resources build phase
    #    is a file in the repository, not something App Store Connect will see.
    manifest_path = os.path.join("Lucid", "Resources", "PrivacyInfo.xcprivacy")
    copied: set[str] = set()
    for phase_id in app["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != "PBXResourcesBuildPhase":
            continue
        for build_file_id in phase["files"]:
            path = paths.get(objects[build_file_id]["fileRef"])
            if path:
                copied.add(path)
    require(manifest_path in copied,
            "PrivacyInfo.xcprivacy is not copied into the app bundle")

    manifest = open(os.path.join(ROOT, manifest_path), encoding="utf-8").read()
    require("<key>NSPrivacyTracking</key>\n\t<false/>" in manifest,
            "the privacy manifest does not declare NSPrivacyTracking false")
    require("<key>NSPrivacyTrackingDomains</key>\n\t<array/>" in manifest,
            "the privacy manifest declares tracking domains")
    require("<key>NSPrivacyCollectedDataTypes</key>\n\t<array/>" in manifest,
            "the privacy manifest declares collected data types")
    require("NSPrivacyAccessedAPICategoryUserDefaults" in manifest,
            "the privacy manifest does not declare its UserDefaults use")
    # The element, not the comment beside it: matching the prose would let the
    # actual reason code change without anything noticing.
    require("<string>CA92.1</string>" in manifest,
            "the UserDefaults reason code is missing or is not CA92.1")
    for category in ("FileTimestamp", "DiskSpace", "ActiveKeyboards", "SystemBootTime"):
        require(f"NSPrivacyAccessedAPICategory{category}" not in manifest,
                f"the privacy manifest declares {category}, which Lucid does not use")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print(f"project.pbxproj OK  ({len(objects)} objects, {len(compiled)} Swift files compiled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
