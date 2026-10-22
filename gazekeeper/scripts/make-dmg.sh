#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
VOLNAME="GazeKeeper"
BUILD_DIR="$(mktemp -d /tmp/gk-dmg.XXXXXX)"
STAGING="$BUILD_DIR/stage"
DMG_RAW="$BUILD_DIR/$VOLNAME.raw.dmg"
DMG_OUT="dist/GazeKeeper.dmg"

trap 'rm -rf "$BUILD_DIR"' EXIT

read -r MARKETING_VERSION CURRENT_PROJECT_VERSION <<<"$(scripts/version.sh)"
echo "==> Version $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)"

SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=${SIGNING_IDENTITY}" ENABLE_HARDENED_RUNTIME=YES)
fi

echo "==> Building $CONFIG"
xcodebuild -project GazeKeeper.xcodeproj -scheme GazeKeeper -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' build "${SIGN_ARGS[@]}" \
  "MARKETING_VERSION=${MARKETING_VERSION}" \
  "CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}" -quiet
APP="$(ls -dt ~/Library/Developer/Xcode/DerivedData/GazeKeeper-*/Build/Products/"$CONFIG"/GazeKeeper.app | head -1)"
[[ -d "$APP" ]] || { echo "GazeKeeper.app not found" >&2; exit 1; }

if [[ -n "${SIGNING_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/app.zip"
  xcrun notarytool submit "$BUILD_DIR/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP" 2>&1 | grep -q "accepted" \
    || { echo "Gatekeeper rejected $APP" >&2; exit 1; }
  echo "==> Notarized and stapled"
fi

echo "==> Staging"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

swift scripts/make-dmg-backdrop.swift "$STAGING/.background/background.tiff"

SIZE_MB=$(du -sm "$STAGING" | awk '{print $1}')
hdiutil create -size $((SIZE_MB + 12))m -fs APFS -volname "$VOLNAME" "$DMG_RAW" -quiet
MOUNT_INFO=$(hdiutil attach "$DMG_RAW" -nobrowse -quiet)
MOUNT_POINT=$(echo "$MOUNT_INFO" | awk -F'\t' '/Volumes/{print $NF}' | head -1)
[[ -n "$MOUNT_POINT" ]] || MOUNT_POINT="/Volumes/$VOLNAME"
cp -R "$STAGING/" "$MOUNT_POINT/"

echo "==> Applying Finder layout"
osascript <<'OSA' > /dev/null || echo "warning: Finder layout pass incomplete; DMG uses default layout"
tell application "Finder"
  activate
  tell disk "GazeKeeper"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 578}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "GazeKeeper.app" of container window to {170, 250}
    set position of item "Applications" of container window to {490, 250}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA

hdiutil detach "$MOUNT_POINT" -quiet
mkdir -p dist
rm -f "$DMG_OUT"
hdiutil convert "$DMG_RAW" -format UDZO -o "$DMG_OUT" -quiet

echo "==> $DMG_OUT"
hdiutil verify "$DMG_OUT" -quiet && echo "verified OK"
