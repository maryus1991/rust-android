#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# Shared helpers for Universal Web2App scripts. Source this file; do not execute it.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

W2A_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_JSON="$W2A_ROOT/config/app.json"
PLATFORMS_JSON="$W2A_ROOT/config/platforms.json"
FEATURES_JSON="$W2A_ROOT/config/features.json"

info() { printf '%s\n' "${C_BLU}==>${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GRN}ok${C_OFF}  $*"; }
warn() { printf '%s\n' "${C_YEL}warn${C_OFF} $*" >&2; }
err()  { printf '%s\n' "${C_RED}error${C_OFF} $*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() {
  # need_cmd <command> <install hint>
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. $2"
}

require_jq() {
  need_cmd jq "Install it: Debian/Ubuntu 'sudo apt install jq' | macOS 'brew install jq' | Windows (Git Bash/MSYS2) 'winget install jqlang.jq' or 'pacman -S jq'."
}

# Writes stdin to <file> atomically (temp file + mv).
atomic_write() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.XXXXXX")"
  cat >"$tmp" && mv "$tmp" "$target"
}

# Reads a PNG's pixel size (no external tools). Prints "<w> <h>" or returns 1.
png_size() {
  local f="$1" sig
  sig="$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')"
  [ "$sig" = "89504e470d0a1a0a" ] || return 1
  local hex
  hex="$(dd if="$f" bs=1 skip=16 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ ${#hex} -eq 16 ] || return 1
  echo "$((16#${hex:0:8})) $((16#${hex:8:8}))"
}

# Detects image kind from content: png | jpeg | svg | unknown
image_kind() {
  local f="$1" head
  [ -f "$f" ] || { echo missing; return; }
  head="$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')"
  case "$head" in
    89504e470d0a1a0a) echo png; return ;;
    ffd8ff*) echo jpeg; return ;;
  esac
  if head -c 2048 "$f" | tr -d '\0' | grep -qi '<svg'; then echo svg; return; fi
  echo unknown
}

# Enabled platforms, one per line.
enabled_platforms() {
  jq -r '.platforms | to_entries[] | select(.value==true) | .key' "$APP_JSON"
}
