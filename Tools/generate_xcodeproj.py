#!/usr/bin/env python3
"""Generate Lucid.xcodeproj from the source tree.

This repository has no XcodeGen or Tuist available, and hand-editing a
project.pbxproj is error prone. Generating it from the file system keeps the
project file and the sources in lock step: re-run this script after adding or
removing a file.

    python3 Tools/generate_xcodeproj.py

Output is deterministic: object identifiers are derived from stable path keys,
so re-running without source changes produces a byte-identical file.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP_NAME = "Lucid"
TEST_NAME = "LucidTests"
UITEST_NAME = "LucidUITests"
BUNDLE_ID = "com.lucid.Lucid"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"
ORGANIZATION = "Lucid"

CAMERA_USAGE_DESCRIPTION = (
    "Lucid uses the camera and torch to analyze light scattering in a water "
    "sample. Video is processed on this iPhone and is not saved unless you "
    "explicitly export diagnostics."
)

# ---------------------------------------------------------------------------
# Object graph helpers
# ---------------------------------------------------------------------------

_used_ids: dict[str, str] = {}


def uid(key: str) -> str:
    """Stable 24-hex-character object identifier derived from `key`."""
    value = hashlib.sha256(key.encode("utf-8")).hexdigest().upper()[:24]
    existing = _used_ids.get(value)
    if existing is not None and existing != key:
        raise SystemExit(f"identifier collision between {existing!r} and {key!r}")
    _used_ids[value] = key
    return value


objects: dict[str, dict] = {}
comments: dict[str, str] = {}


def add(key: str, comment: str, body: dict) -> str:
    ident = uid(key)
    objects[ident] = body
    comments[ident] = comment
    return ident


# ---------------------------------------------------------------------------
# OpenStep plist serialisation
# ---------------------------------------------------------------------------

_SAFE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$./")


def quote(value: str) -> str:
    if value == "":
        return '""'
    if all(character in _SAFE for character in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def annotate(value: str) -> str:
    comment = comments.get(value)
    text = quote(value)
    return f"{text} /* {comment} */" if comment else text


def render(value, indent: int) -> str:
    pad = "\t" * indent
    inner = "\t" * (indent + 1)

    if isinstance(value, dict):
        lines = ["{"]
        # `isa` first, then alphabetical: matches Xcode's own ordering.
        keys = sorted(value.keys(), key=lambda k: (k != "isa", k))
        for key in keys:
            lines.append(f"{inner}{quote(key)} = {render(value[key], indent + 1)};")
        lines.append(pad + "}")
        return "\n".join(lines)

    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for item in value:
            lines.append(f"{inner}{render(item, indent + 1)},")
        lines.append(pad + ")")
        return "\n".join(lines)

    return annotate(str(value))


def serialize(root: dict) -> str:
    header = "// !$*UTF8*$!\n"
    body = ["{"]
    body.append("\tarchiveVersion = 1;")
    body.append("\tclasses = {\n\t};")
    body.append("\tobjectVersion = 56;")
    body.append("\tobjects = {")

    by_isa: dict[str, list[str]] = {}
    for ident, entry in objects.items():
        by_isa.setdefault(entry["isa"], []).append(ident)

    for isa in sorted(by_isa):
        body.append(f"\n/* Begin {isa} section */")
        for ident in sorted(by_isa[isa], key=lambda i: (comments.get(i, ""), i)):
            body.append(f"\t\t{annotate(ident)} = {render(objects[ident], 2)};")
        body.append(f"/* End {isa} section */")

    body.append("\t};")
    body.append(f"\trootObject = {annotate(root['id'])};")
    body.append("}")
    return header + "\n".join(body) + "\n"


# ---------------------------------------------------------------------------
# Source discovery
# ---------------------------------------------------------------------------

def discover(directory: str) -> tuple[list[str], list[str]]:
    """Return (swift sources, resource bundles) relative to ROOT."""
    sources: list[str] = []
    resources: list[str] = []
    base = os.path.join(ROOT, directory)

    for current, subdirs, files in os.walk(base):
        # Asset catalogues are single resource items, not directories to walk.
        bundles = [d for d in subdirs if d.endswith(".xcassets")]
        for bundle in bundles:
            subdirs.remove(bundle)
            resources.append(os.path.relpath(os.path.join(current, bundle), ROOT))
        subdirs[:] = sorted(d for d in subdirs if not d.startswith("."))
        for name in sorted(files):
            if name.endswith(".swift"):
                sources.append(os.path.relpath(os.path.join(current, name), ROOT))

    return sorted(sources), sorted(resources)


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".xcassets": "folder.assetcatalog",
}


def file_type(path: str) -> str:
    _, extension = os.path.splitext(path)
    return FILE_TYPES.get(extension, "text")


def build_group_tree(paths: list[str], root_name: str) -> str:
    """Create PBXGroups mirroring the directory layout; return the root group."""
    tree: dict = {"_files": []}

    for path in paths:
        parts = path.split(os.sep)
        node = tree
        for part in parts[1:-1]:
            node = node.setdefault(part, {"_files": []})
        node["_files"].append(path)

    def make(node: dict, prefix: str, name: str) -> str:
        children: list[str] = []
        for key in sorted(k for k in node if k != "_files"):
            children.append(make(node[key], f"{prefix}/{key}", key))
        for path in node["_files"]:
            children.append(file_reference(path))
        return add(
            f"group:{prefix}",
            name,
            {
                "isa": "PBXGroup",
                "children": children,
                "path": name,
                "sourceTree": "<group>",
            },
        )

    return make(tree, root_name, root_name)


_file_refs: dict[str, str] = {}


def file_reference(path: str) -> str:
    if path in _file_refs:
        return _file_refs[path]
    name = os.path.basename(path)
    ident = add(
        f"fileref:{path}",
        name,
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": file_type(path),
            "path": name,
            "sourceTree": "<group>",
        },
    )
    _file_refs[path] = ident
    return ident


def build_file(path: str, target: str, phase: str) -> str:
    return add(
        f"buildfile:{target}:{phase}:{path}",
        f"{os.path.basename(path)} in {phase}",
        {
            "isa": "PBXBuildFile",
            "fileRef": file_reference(path),
        },
    )


# ---------------------------------------------------------------------------
# Build settings
# ---------------------------------------------------------------------------

SHARED_PROJECT_SETTINGS = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": SWIFT_VERSION,
}

DEBUG_PROJECT_SETTINGS = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["DEBUG", "$(inherited)"],
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

RELEASE_PROJECT_SETTINGS = {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}

APP_TARGET_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_NSCameraUsageDescription": CAMERA_USAGE_DESCRIPTION,
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UIRequiresFullScreen": "YES",
    "INFOPLIST_KEY_UIStatusBarStyle": "UIStatusBarStyleDefault",
    # A measurement needs a fixed optical path, so the device orientation is
    # pinned rather than left free to rotate mid-capture.
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": "1",
}

TEST_TARGET_SETTINGS = {
    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "NO",
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}Tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": "1",
    "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP_NAME}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP_NAME}",
}

# A UI-test bundle drives the app from outside it, so it has no BUNDLE_LOADER
# and no TEST_HOST: it launches the app rather than being loaded into it.
UITEST_TARGET_SETTINGS = {
    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}UITests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": "1",
    "TEST_TARGET_NAME": APP_NAME,
}


def configuration_list(owner: str, debug: dict, release: dict) -> str:
    debug_id = add(f"config:{owner}:Debug", "Debug",
                   {"isa": "XCBuildConfiguration", "buildSettings": debug, "name": "Debug"})
    release_id = add(f"config:{owner}:Release", "Release",
                     {"isa": "XCBuildConfiguration", "buildSettings": release, "name": "Release"})
    return add(
        f"configlist:{owner}",
        f'Build configuration list for {owner}',
        {
            "isa": "XCConfigurationList",
            "buildConfigurations": [debug_id, release_id],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        },
    )


# ---------------------------------------------------------------------------
# Project assembly
# ---------------------------------------------------------------------------

def main() -> int:
    app_sources, app_resources = discover(APP_NAME)
    test_sources, _ = discover(TEST_NAME)
    uitest_sources, _ = discover(UITEST_NAME)

    if not app_sources:
        raise SystemExit(f"no Swift sources found under {APP_NAME}/")
    if not test_sources:
        raise SystemExit(f"no Swift sources found under {TEST_NAME}/")
    if not uitest_sources:
        raise SystemExit(f"no Swift sources found under {UITEST_NAME}/")

    app_group = build_group_tree(app_sources + app_resources, APP_NAME)
    test_group = build_group_tree(test_sources, TEST_NAME)
    uitest_group = build_group_tree(uitest_sources, UITEST_NAME)

    app_product = add(
        "product:app", f"{APP_NAME}.app",
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.application",
            "includeInIndex": "0",
            "path": f"{APP_NAME}.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    test_product = add(
        "product:tests", f"{TEST_NAME}.xctest",
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.cfbundle",
            "includeInIndex": "0",
            "path": f"{TEST_NAME}.xctest",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    uitest_product = add(
        "product:uitests", f"{UITEST_NAME}.xctest",
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.cfbundle",
            "includeInIndex": "0",
            "path": f"{UITEST_NAME}.xctest",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    products_group = add(
        "group:Products", "Products",
        {
            "isa": "PBXGroup",
            "children": [app_product, test_product, uitest_product],
            "name": "Products",
            "sourceTree": "<group>",
        },
    )

    main_children = [app_group, test_group, uitest_group, products_group]

    main_group = add(
        "group:main", "",
        {"isa": "PBXGroup", "children": main_children, "sourceTree": "<group>"},
    )

    # --- App target ---------------------------------------------------------
    app_sources_phase = add(
        "phase:app:Sources", "Sources",
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [build_file(path, "app", "Sources") for path in app_sources],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_frameworks_phase = add(
        "phase:app:Frameworks", "Frameworks",
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_resources_phase = add(
        "phase:app:Resources", "Resources",
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [build_file(path, "app", "Resources") for path in app_resources],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    app_config_list = configuration_list(
        f'"{APP_NAME}" target',
        {**APP_TARGET_SETTINGS},
        {**APP_TARGET_SETTINGS},
    )

    app_target = add(
        "target:app", APP_NAME,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": app_config_list,
            "buildPhases": [app_sources_phase, app_frameworks_phase, app_resources_phase],
            "buildRules": [],
            "dependencies": [],
            "name": APP_NAME,
            "productName": APP_NAME,
            "productReference": app_product,
            "productType": "com.apple.product-type.application",
        },
    )

    # --- Test target --------------------------------------------------------
    test_sources_phase = add(
        "phase:tests:Sources", "Sources",
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [build_file(path, "tests", "Sources") for path in test_sources],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    test_frameworks_phase = add(
        "phase:tests:Frameworks", "Frameworks",
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    test_resources_phase = add(
        "phase:tests:Resources", "Resources",
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    project_id = uid("project")

    container_proxy = add(
        "proxy:tests->app", "PBXContainerItemProxy",
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": project_id,
            "proxyType": "1",
            "remoteGlobalIDString": app_target,
            "remoteInfo": APP_NAME,
        },
    )
    test_dependency = add(
        "dependency:tests->app", "PBXTargetDependency",
        {
            "isa": "PBXTargetDependency",
            "target": app_target,
            "targetProxy": container_proxy,
        },
    )

    test_config_list = configuration_list(
        f'"{TEST_NAME}" target',
        {**TEST_TARGET_SETTINGS},
        {**TEST_TARGET_SETTINGS},
    )

    test_target = add(
        "target:tests", TEST_NAME,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": test_config_list,
            "buildPhases": [test_sources_phase, test_frameworks_phase, test_resources_phase],
            "buildRules": [],
            "dependencies": [test_dependency],
            "name": TEST_NAME,
            "productName": TEST_NAME,
            "productReference": test_product,
            "productType": "com.apple.product-type.bundle.unit-test",
        },
    )

    # --- UI test target -----------------------------------------------------
    uitest_sources_phase = add(
        "phase:uitests:Sources", "Sources",
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [build_file(path, "uitests", "Sources") for path in uitest_sources],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    uitest_frameworks_phase = add(
        "phase:uitests:Frameworks", "Frameworks",
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    uitest_resources_phase = add(
        "phase:uitests:Resources", "Resources",
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    uitest_proxy = add(
        "proxy:uitests->app", "PBXContainerItemProxy",
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": project_id,
            "proxyType": "1",
            "remoteGlobalIDString": app_target,
            "remoteInfo": APP_NAME,
        },
    )
    uitest_dependency = add(
        "dependency:uitests->app", "PBXTargetDependency",
        {
            "isa": "PBXTargetDependency",
            "target": app_target,
            "targetProxy": uitest_proxy,
        },
    )
    uitest_config_list = configuration_list(
        f'"{UITEST_NAME}" target',
        {**UITEST_TARGET_SETTINGS},
        {**UITEST_TARGET_SETTINGS},
    )
    uitest_target = add(
        "target:uitests", UITEST_NAME,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": uitest_config_list,
            "buildPhases": [uitest_sources_phase, uitest_frameworks_phase,
                            uitest_resources_phase],
            "buildRules": [],
            "dependencies": [uitest_dependency],
            "name": UITEST_NAME,
            "productName": UITEST_NAME,
            "productReference": uitest_product,
            "productType": "com.apple.product-type.bundle.ui-testing",
        },
    )

    # --- Project ------------------------------------------------------------
    project_config_list = configuration_list(
        f'"{APP_NAME}" project',
        {**SHARED_PROJECT_SETTINGS, **DEBUG_PROJECT_SETTINGS},
        {**SHARED_PROJECT_SETTINGS, **RELEASE_PROJECT_SETTINGS},
    )

    objects[project_id] = {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": "1",
            "LastSwiftUpdateCheck": "1600",
            "LastUpgradeCheck": "1600",
            "ORGANIZATIONNAME": ORGANIZATION,
            "TargetAttributes": {
                app_target: {"CreatedOnToolsVersion": "16.0"},
                test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target},
                uitest_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target},
            },
        },
        "buildConfigurationList": project_config_list,
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": "0",
        "knownRegions": ["en", "Base"],
        "mainGroup": main_group,
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [app_target, test_target, uitest_target],
    }
    comments[project_id] = "Project object"

    # --- Write --------------------------------------------------------------
    project_dir = os.path.join(ROOT, f"{APP_NAME}.xcodeproj")
    if os.path.isdir(project_dir):
        shutil.rmtree(project_dir)
    os.makedirs(os.path.join(project_dir, "project.xcworkspace", "xcshareddata"), exist_ok=True)
    os.makedirs(os.path.join(project_dir, "xcshareddata", "xcschemes"), exist_ok=True)

    with open(os.path.join(project_dir, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(serialize({"id": project_id}))

    with open(os.path.join(project_dir, "project.xcworkspace", "contents.xcworkspacedata"),
              "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace\n'
            '   version = "1.0">\n'
            '   <FileRef\n'
            '      location = "self:">\n'
            '   </FileRef>\n'
            '</Workspace>\n'
        )

    with open(os.path.join(project_dir, "project.xcworkspace", "xcshareddata",
                           "IDEWorkspaceChecks.plist"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            '\t<key>IDEDidComputeMac32BitWarning</key>\n\t<true/>\n'
            '</dict>\n</plist>\n'
        )

    scheme = SCHEME_TEMPLATE.format(
        app_name=APP_NAME,
        test_name=TEST_NAME,
        uitest_name=UITEST_NAME,
        app_target=app_target,
        test_target=test_target,
        uitest_target=uitest_target,
        bundle_id=BUNDLE_ID,
        container=f"container:{APP_NAME}.xcodeproj",
    )
    with open(os.path.join(project_dir, "xcshareddata", "xcschemes", f"{APP_NAME}.xcscheme"),
              "w", encoding="utf-8") as handle:
        handle.write(scheme)

    print(f"Generated {APP_NAME}.xcodeproj")
    print(f"  app sources    : {len(app_sources)}")
    print(f"  app resources  : {len(app_resources)}")
    print(f"  test sources   : {len(test_sources)}")
    print(f"  ui test sources: {len(uitest_sources)}")
    print(f"  pbxproj objects: {len(objects)}")
    return 0


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{app_name}.app"
               BlueprintName = "{app_name}"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{test_name}.xctest"
               BlueprintName = "{test_name}"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uitest_target}"
               BuildableName = "{uitest_name}.xctest"
               BlueprintName = "{uitest_name}"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "NO">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app_name}.app"
            BlueprintName = "{app_name}"
            ReferencedContainer = "{container}">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app_name}.app"
            BlueprintName = "{app_name}"
            ReferencedContainer = "{container}">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    sys.exit(main())
