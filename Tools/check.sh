#!/bin/sh
# Everything that can be verified without Xcode.
#
# `swift_audit.py` needs a Swift parser that is not part of a stock Python:
#
#     python3 -m pip install tree_sitter tree_sitter_swift
#
# It skips itself with a message when the parser is missing, so this script
# still works without it — but it is the only check here that sees the code the
# way a compiler front end does, so install it.
set -e
cd "$(dirname "$0")/.."
python3 Tools/check_sources.py
python3 Tools/swift_audit.py
python3 Tools/analysis_reference.py
python3 Tools/generate_xcodeproj.py
python3 Tools/validate_pbxproj.py
