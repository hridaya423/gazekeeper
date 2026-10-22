#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"

"$XCODEGEN" generate

xcodebuild -project GazeKeeper.xcodeproj -scheme GazeKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO -quiet

# Release must build too: it is the only proof the debug surface compiled out.
xcodebuild -project GazeKeeper.xcodeproj -scheme GazeKeeper -configuration Release -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO -quiet

xcodebuild test -project GazeKeeper.xcodeproj -scheme GazeKeeper -destination 'platform=macOS,arch=arm64' -only-testing:GazeKeeperCoreTests -only-testing:GazeKeeperAppTests CODE_SIGNING_ALLOWED=NO -quiet

xcrun swift-format lint --recursive --strict Sources Tests

echo "gate green"
