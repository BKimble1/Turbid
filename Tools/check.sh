#!/bin/sh
# Everything that can be verified without Xcode.
set -e
cd "$(dirname "$0")/.."
python3 Tools/check_sources.py
python3 Tools/generate_xcodeproj.py
python3 Tools/validate_pbxproj.py
