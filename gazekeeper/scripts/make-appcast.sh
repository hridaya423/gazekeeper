#!/usr/bin/env bash
# Generates appcast.xml from the DMGs in dist/ using Sparkle's generate_appcast
# tool (ships in the Sparkle release tarball, not the SPM checkout — download
# Sparkle-<v>.tar.xz from github.com/sparkle-project/Sparkle/releases and pass
# its bin/ dir via SPARKLE_BIN). Requires the EdDSA private key in the login
# keychain (created by generate_keys).
set -euo pipefail

cd "$(dirname "$0")/.."

SPARKLE_BIN="${SPARKLE_BIN:-/tmp/bin}"
DL_URL="${DOWNLOAD_BASE_URL:-https://gazekeeper.hridya.tech/releases}"
FEED_URL="https://gazekeeper.hridya.tech/appcast.xml"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DL_URL/" \
  --link "$FEED_URL" \
  -o dist/appcast.xml \
  dist/

echo "wrote dist/appcast.xml — upload it + the DMGs to the host serving $DL_URL/"
