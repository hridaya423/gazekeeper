#!/usr/bin/env bash
# Syncs Resources/Localizable.xcstrings with the literals the last Debug build
# emitted (.stringsdata). Run after editing user-facing strings; requires a
# prior `xcodebuild build` in this checkout's DerivedData.
set -euo pipefail

cd "$(dirname "$0")/.."

OBJDIR=$(ls -dt ~/Library/Developer/Xcode/DerivedData/GazeKeeper-*/Build/Intermediates.noindex/GazeKeeper.build/Debug/GazeKeeper.build/Objects-normal/arm64 2>/dev/null | head -1)
[[ -n "$OBJDIR" ]] || { echo "no Debug build objects — run xcodebuild build first" >&2; exit 1; }

XCSTRINGS_TOOL="$(xcrun --find xcstringstool 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool)"
"$XCSTRINGS_TOOL" sync Resources/Localizable.xcstrings --stringsdata "$OBJDIR"/*.stringsdata
