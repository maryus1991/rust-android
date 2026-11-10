#!/usr/bin/env bash
# Collects Tauri bundle outputs into dist/ with the release naming scheme:
#   <Slug>-v<version>-<os>-<arch>.<ext>
# Usage: collect.sh <windows|linux> <slug> <version> <bundles-csv>
# Fails when a REQUIRED bundle is missing; rpm is best effort (warning).
set -euo pipefail
PLATFORM="$1"; SLUG="$2"; VERSION="$3"; BUNDLES="$4"
BUNDLE_DIR="${BUNDLE_DIR:-target/release/bundle}"
mkdir -p dist dist-status
STATUS="dist-status/$PLATFORM.md"; : >"$STATUS"

pick() { # pick <subdir> <glob> -> first match
  find "$BUNDLE_DIR/$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | sort | head -n1
}
take() { # take <subdir> <glob> <dest-name> <required: yes|no> <label>
  local src; src="$(pick "$1" "$2")"
  if [ -z "$src" ]; then
    if [ "$4" = yes ]; then echo "::error::expected $5 bundle ($1/$2) was not produced" >&2; exit 1; fi
    echo "::warning::optional $5 bundle was not produced" >&2
    echo "- $5: not produced (optional)" >>"$STATUS"; return 0
  fi
  cp "$src" "dist/$3"; echo "- $5: \`$3\`" >>"$STATUS"
}
has() { [[ ",$BUNDLES," == *",$1,"* ]]; }

case "$PLATFORM" in
  windows)
    has msi  && take msi  '*.msi'       "$SLUG-v$VERSION-windows-x64.msi" yes "Windows MSI"
    has nsis && take nsis '*-setup.exe' "$SLUG-v$VERSION-windows-x64-setup.exe" yes "Windows EXE (NSIS installer)"
    echo "- Windows binaries are **not code-signed**: SmartScreen may warn on first run." >>"$STATUS" ;;
  linux)
    has deb      && take deb      '*.deb'      "$SLUG-v$VERSION-linux-x64.deb" yes "Linux DEB"
    has appimage && take appimage '*.AppImage' "$SLUG-v$VERSION-linux-x64.AppImage" yes "Linux AppImage"
    has rpm      && take rpm      '*.rpm'      "$SLUG-v$VERSION-linux-x64.rpm" no "Linux RPM" ;;
  *) echo "unknown platform $PLATFORM" >&2; exit 2 ;;
esac
ls -l dist
