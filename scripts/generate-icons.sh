#!/usr/bin/env bash
# Generates all platform icons (Windows .ico, macOS .icns, Linux PNG, Android mipmaps,
# iOS AppIcon) from the configured source image using the official `tauri icon` command.
# Usage: bash scripts/generate-icons.sh [--require]
#   --require  fail (instead of warn) when no Tauri CLI is available
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_jq

SRC="$W2A_ROOT/$(jq -r '.appearance.iconSource' "$APP_JSON")"
[ -f "$SRC" ] || die "icon source not found: $SRC"
OUT="$W2A_ROOT/src-tauri/icons"

run_tauri() {
  if command -v cargo-tauri >/dev/null 2>&1; then cargo tauri "$@"
  elif [ -x "$W2A_ROOT/node_modules/.bin/tauri" ]; then "$W2A_ROOT/node_modules/.bin/tauri" "$@"
  elif command -v tauri >/dev/null 2>&1; then tauri "$@"
  elif command -v npx >/dev/null 2>&1 && npx --no-install tauri --version >/dev/null 2>&1; then npx --no-install tauri "$@"
  else return 127; fi
}

if ! run_tauri --version >/dev/null 2>&1; then
  msg="Tauri CLI not found, icons were NOT regenerated locally. The GitHub Actions build regenerates them from $(jq -r '.appearance.iconSource' "$APP_JSON") automatically. To generate locally: cargo install tauri-cli --version '^2' --locked"
  if [ "${1:-}" = "--require" ]; then die "$msg"; else warn "$msg"; exit 0; fi
fi

info "Generating icons from ${SRC#"$W2A_ROOT"/}"
mkdir -p "$OUT"
run_tauri icon "$SRC" -o "$OUT" >/dev/null
for f in icon.ico icon.icns 32x32.png 128x128.png 128x128@2x.png icon.png; do
  [ -f "$OUT/$f" ] || die "icon generation did not produce $f"
done
ok "icons generated in src-tauri/icons"
