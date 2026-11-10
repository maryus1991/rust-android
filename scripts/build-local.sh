#!/usr/bin/env bash
# Local build helper. Checks your tool chain, tells you which platforms THIS machine can build
# and builds them. Nothing is assumed to be installed.
#
#   bash scripts/build-local.sh --check               only report the environment
#   bash scripts/build-local.sh                       build every enabled + buildable platform
#   bash scripts/build-local.sh --platform linux      build one platform (windows|linux|android|ios)
#   bash scripts/build-local.sh --debug               debug build (faster, bigger)
#
# Host rules (Tauri does not cross-compile desktop apps): Windows builds need Windows, Linux builds need
# Linux, iOS needs macOS + Xcode, Android works on Linux/macOS/Windows with the Android SDK + NDK + JDK 17.
# Logs: build-logs/build-<timestamp>.log   Output: dist/
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_jq
cd "$W2A_ROOT"

CHECK_ONLY=0; DEBUG=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --debug) DEBUG=1 ;;
    --platform) shift; ONLY="${1:-}"; [[ "$ONLY" =~ ^(windows|linux|android|ios)$ ]] || die "--platform must be windows, linux, android or ios" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

HOST="$(uname -s)"
case "$HOST" in
  Linux*) HOST_OS=linux ;;
  Darwin*) HOST_OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
  *) HOST_OS=unknown ;;
esac

PROBLEMS=()   # tool problems per platform are collected as "platform|message"
have() { command -v "$1" >/dev/null 2>&1; }
problem() { PROBLEMS+=("$1|$2"); }

tauri_cmd() {
  if have cargo-tauri; then echo "cargo tauri"
  elif have tauri; then echo "tauri"
  else echo ""; fi
}

check_common() {
  have cargo || problem all "Rust is not installed. Install it from https://rustup.rs (the pinned toolchain in rust-toolchain.toml is installed automatically)."
  have rustc || true
  if [ -z "$(tauri_cmd)" ]; then
    problem all "Tauri CLI not found. Install: cargo install tauri-cli --version '^2' --locked   (or: npm i -g @tauri-apps/cli@2)"
  fi
}

check_java() {
  if ! have java; then problem android "Java (JDK 17+) not found. Install a JDK 17 (e.g. Temurin) and set JAVA_HOME."; return; fi
  local v; v="$(java -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -n1)"
  [ "${v:-0}" -ge 17 ] 2>/dev/null || problem android "Java $v found, but JDK 17 or newer is required."
}

check_android() {
  check_java
  [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] || problem android "ANDROID_HOME is not set. Install Android Studio / command line tools and export ANDROID_HOME."
  [ -n "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ] || problem android "NDK_HOME is not set. Install the NDK (sdkmanager 'ndk;<version>') and export NDK_HOME."
  if have rustup && ! rustup target list --installed 2>/dev/null | grep -q aarch64-linux-android; then
    problem android "Rust Android targets missing: rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android"
  fi
}

check_linux() {
  [ "$HOST_OS" = linux ] || { problem linux "Linux packages can only be built on Linux (use GitHub Actions or a Linux VM)."; return; }
  have pkg-config || { problem linux "pkg-config not found: sudo apt install pkg-config build-essential"; return; }
  pkg-config --exists webkit2gtk-4.1 || problem linux "WebKitGTK 4.1 dev files missing: sudo apt install libwebkit2gtk-4.1-dev libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf"
}

check_windows() { [ "$HOST_OS" = windows ] || problem windows "Windows installers can only be built on Windows (use GitHub Actions or a Windows machine)."; }

check_ios() {
  [ "$HOST_OS" = macos ] || { problem ios "iOS builds need macOS with Xcode (use GitHub Actions' macOS runner)."; return; }
  have xcodebuild || problem ios "Xcode is not installed (App Store -> Xcode), then run: sudo xcodebuild -runFirstLaunch"
}

check_common
for p in windows linux android ios; do "check_$p"; done

printf '\nHost: %s\n\n%-9s %-9s %s\n' "$HOST_OS" PLATFORM ENABLED STATUS
BUILDABLE=()
for p in windows linux android ios; do
  enabled="$(jq -r ".platforms.$p" "$APP_JSON")"
  msgs=""; for pr in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do [ "${pr%%|*}" = "$p" ] || [ "${pr%%|*}" = all ] && msgs+="${pr#*|}"$'\n'; done
  if [ -z "$msgs" ]; then status="${C_GRN}ready${C_OFF}"; [ "$enabled" = true ] && BUILDABLE+=("$p"); else status="${C_YEL}not ready${C_OFF}"; fi
  printf '%-9s %-9s %s\n' "$p" "$enabled" "$status"
  [ -z "$msgs" ] || printf '%s' "$msgs" | sed 's/^/            - /'
done
echo

[ "$CHECK_ONLY" -eq 1 ] && exit 0
if [ -n "$ONLY" ]; then
  [ "$(jq -r ".platforms.$ONLY" "$APP_JSON")" = true ] || die "platform '$ONLY' is disabled in config/app.json"
  printf '%s\n' "${BUILDABLE[@]+"${BUILDABLE[@]}"}" | grep -qx "$ONLY" || die "cannot build '$ONLY' on this machine (see the list above)."
  BUILDABLE=("$ONLY")
fi
[ ${#BUILDABLE[@]} -gt 0 ] || die "no platform can be built here. Fix the items above, or push to GitHub and let Actions build everything."

mkdir -p build-logs dist dist-status
LOG="build-logs/build-$(date +%Y%m%d-%H%M%S).log"
info "log file: $LOG"
exec > >(tee -a "$LOG") 2>&1

bash scripts/validate.sh --quiet --config-only
bash scripts/sync-config.sh
bash scripts/generate-icons.sh --require

PLAN="$(W2A_RELEASE_EXISTS=false GITHUB_REPOSITORY=local/local GITHUB_EVENT_NAME=workflow_dispatch INPUT_PUBLISH=false bash scripts/ci/prepare.sh)"
plan() { printf '%s\n' "$PLAN" | sed -n "s/^$1=//p" | head -n1; }
SLUG="$(plan slug)"; VERSION="$(plan version)"
TAURI="$(tauri_cmd)"; DBG=(); [ "$DEBUG" -eq 1 ] && DBG=(--debug)
FAILED=()

for p in "${BUILDABLE[@]}"; do
  info "building $p"
  set +e
  case "$p" in
    windows)
      $TAURI build --ci "${DBG[@]}" --bundles "$(plan windows_bundles)" && BUNDLE_DIR="target/$([ "$DEBUG" -eq 1 ] && echo debug || echo release)/bundle" bash scripts/ci/collect.sh windows "$SLUG" "$VERSION" "$(plan windows_bundles)" ;;
    linux)
      NO_STRIP=true APPIMAGE_EXTRACT_AND_RUN=1 $TAURI build --ci "${DBG[@]}" --bundles "$(plan linux_bundles)" && BUNDLE_DIR="target/$([ "$DEBUG" -eq 1 ] && echo debug || echo release)/bundle" bash scripts/ci/collect.sh linux "$SLUG" "$VERSION" "$(plan linux_bundles)" ;;
    android)
      [ -d src-tauri/gen/android ] || $TAURI android init --ci
      bash scripts/generate-icons.sh --require
      # shellcheck disable=SC2046
      $TAURI android build --ci --apk --aab --target $(plan android_abis) && bash scripts/ci/android-sign.sh "$SLUG" "$VERSION" ;;
    ios)
      [ -d src-tauri/gen/apple ] || $TAURI ios init --ci
      bash scripts/generate-icons.sh --require
      bash scripts/ci/ios-build.sh "$SLUG" "$VERSION" "$(plan ios_method)" ;;
  esac
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then err "$p build FAILED (see $LOG)"; FAILED+=("$p"); else ok "$p build finished"; fi
done

echo; info "output in dist/:"; ls -l dist || true
if [ ${#FAILED[@]} -gt 0 ]; then die "failed: ${FAILED[*]}"; fi
