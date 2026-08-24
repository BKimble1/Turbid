#!/usr/bin/env python3
"""Print the UDID of the best available iPhone Simulator on this machine.

Reads `xcrun simctl list devices available --json` on stdin, or runs it. CI
hardcoding a device name is how a workflow breaks silently when a runner image
drops a device; asking the machine what it actually has does not.

    xcrun simctl list devices available --json | python3 Tools/select_simulator.py

Picks the newest iOS runtime, then the highest-numbered iPhone on it, so the
choice is deterministic for a given image rather than dependent on dict order.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys


def ios_version(runtime: str) -> tuple[int, int]:
    """(major, minor) of an iOS runtime identifier, or (-1, -1) if it is not one."""
    match = re.search(r"iOS[-.](\d+)[-.](\d+)", runtime)
    if match:
        return int(match.group(1)), int(match.group(2))
    match = re.search(r"iOS[-.](\d+)", runtime)
    return (int(match.group(1)), 0) if match else (-1, -1)


def model_rank(name: str) -> tuple[int, int, str]:
    """Sorts iPhones by model number, so iPhone 16 beats iPhone 9 numerically."""
    match = re.search(r"iPhone\s+(\d+)", name)
    number = int(match.group(1)) if match else 0
    # A plain "iPhone 16" is a better default than a Pro Max: smaller screen,
    # faster to boot, and nothing here depends on the device class.
    plain = 1 if re.fullmatch(r"iPhone\s+\d+", name.strip()) else 0
    return number, plain, name


def choose(payload: dict) -> str:
    best = None
    for runtime, devices in payload.get("devices", {}).items():
        version = ios_version(runtime)
        if version == (-1, -1):
            continue
        for device in devices:
            name = device.get("name", "")
            if not device.get("isAvailable"):
                continue
            if not name.startswith("iPhone"):
                continue
            key = (version, model_rank(name))
            if best is None or key > best[0]:
                best = (key, device)
    if best is None:
        raise SystemExit("no available iPhone simulator on this machine")
    device = best[1]
    print(f"{device['name']} (iOS {best[0][0][0]}.{best[0][0][1]})", file=sys.stderr)
    return device["udid"]


def main() -> int:
    if sys.stdin.isatty():
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True,
        ).stdout
    else:
        raw = sys.stdin.read()
    print(choose(json.loads(raw)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
