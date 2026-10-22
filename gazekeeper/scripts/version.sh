#!/usr/bin/env bash
# Prints "MARKETING_VERSION CURRENT_PROJECT_VERSION" derived from git tags.
# Tag format: v1.2.3 (or 1.2.3). Untagged trees: 0.0.0-dev+<sha>, build = commit count.
set -euo pipefail

cd "$(dirname "$0")/.."

if desc=$(git describe --tags --always --dirty 2>/dev/null); then
  if [[ "$desc" =~ ^v?([0-9]+\.[0-9]+(\.[0-9]+)?)(-[0-9]+-g[0-9a-f]+)?(-dirty)?$ ]]; then
    marketing="${BASH_REMATCH[1]}"
    if [[ "$desc" =~ -g[0-9a-f]+ ]]; then marketing="${marketing}+${desc##*-g}"; fi
    [[ "$desc" == *-dirty ]] && marketing="${marketing}+dirty"
  else
    marketing="0.0.0-dev+${desc#v}"
  fi
  build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
else
  marketing="0.0.0"
  build="1"
fi

echo "$marketing $build"
