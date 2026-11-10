#!/usr/bin/env bash
# Builds release notes + SHA256SUMS from downloaded artifacts. Usage: release-notes.sh <name> <version>
# Expects ./release (assets) and ./dist-status (per-platform status files).
set -euo pipefail
NAME="$1"; VERSION="$2"

(
  cd release
  rm -f SHA256SUMS.txt
  sha256sum -- * >../SHA256SUMS.tmp
  mv ../SHA256SUMS.tmp SHA256SUMS.txt
)

{
  echo "# $NAME $VERSION"
  echo
  echo "Built from commit \`${GITHUB_SHA:-local}\` by Universal Web2App."
  echo
  echo "## Build status per platform"
  echo
  for f in dist-status/*.md; do
    [ -f "$f" ] || continue
    echo "**$(basename "$f" .md)**"
    cat "$f"
    echo
  done
  echo "## Files"
  echo
  for f in release/*; do
    n="$(basename "$f")"
    [ "$n" = SHA256SUMS.txt ] && continue
    echo "- \`$n\`"
  done
  echo
  echo "Checksums: \`SHA256SUMS.txt\`"
} >release-notes.md
