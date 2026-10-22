#!/usr/bin/env bash
set -euo pipefail

PORT="3110"
DATA_DIR=""
BUILD=1
APP_BUNDLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    *)
      PORT="$1"
      shift
      ;;
  esac
done

if ! [[ "$PORT" =~ ^311[0-9]$ ]]; then
  echo "run-debug.sh: port must be in 3110-3119 (got '$PORT')" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "$DATA_DIR" ]]; then
  DATA_DIR="/tmp/gk-debug-data-$$"
fi
mkdir -p "$DATA_DIR"

if [[ "$BUILD" -eq 1 ]]; then
  if [[ ! -d GazeKeeper.xcodeproj ]]; then
    /opt/homebrew/bin/xcodegen generate
  fi
  xcodebuild -project GazeKeeper.xcodeproj -scheme GazeKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO -quiet
fi

APP_BUNDLE="$(ls -dt ~/Library/Developer/Xcode/DerivedData/GazeKeeper-*/Build/Products/Debug/GazeKeeper.app 2>/dev/null | head -1 || true)"
if [[ -z "$APP_BUNDLE" ]]; then
  echo "run-debug.sh: could not locate built GazeKeeper.app under DerivedData" >&2
  exit 1
fi

echo "launching $APP_BUNDLE with --gk-debug-port $PORT --gk-data-dir $DATA_DIR"
open -n "$APP_BUNDLE" --args --gk-debug-port "$PORT" --gk-data-dir "$DATA_DIR"

for attempt in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "debug server healthy on 127.0.0.1:$PORT"
    echo "data dir: $DATA_DIR"
    exit 0
  fi
  sleep 0.5
done

echo "run-debug.sh: app did not become healthy within 30s" >&2
exit 1
