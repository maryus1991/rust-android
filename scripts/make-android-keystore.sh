#!/usr/bin/env bash
# Creates an Android upload keystore OUTSIDE the repository and prints the four
# GitHub secrets you need. Nothing secret is ever written inside the repo.
# Usage: bash scripts/make-android-keystore.sh [output-dir]
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd keytool "Install a JDK 17+ (e.g. 'sudo apt install openjdk-17-jdk', 'brew install openjdk@17')."
need_cmd base64 "base64 is part of coreutils."

OUTDIR="${1:-$HOME/.web2app-keys}"
case "$(cd "$OUTDIR" 2>/dev/null && pwd || echo "$OUTDIR")" in
  "$W2A_ROOT"|"$W2A_ROOT"/*) die "Refusing to create keys inside the repository. Choose a directory outside $W2A_ROOT." ;;
esac
mkdir -p "$OUTDIR"; chmod 700 "$OUTDIR"
KS="$OUTDIR/upload-keystore.jks"
[ ! -e "$KS" ] || die "$KS already exists. Move it away first (never overwrite a key you already published with)."

read -r -p "Key alias [upload]: " ALIAS; ALIAS="${ALIAS:-upload}"
read -r -s -p "Keystore password (min 6 chars): " PASS; echo
[ "${#PASS}" -ge 6 ] || die "password too short"
read -r -p "Your name / organisation for the certificate [Web2App]: " CN; CN="${CN:-Web2App}"

keytool -genkeypair -v -keystore "$KS" -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$PASS" -keypass "$PASS" -dname "CN=$CN" >/dev/null
chmod 600 "$KS"
ok "keystore created: $KS"
echo
echo "Add these four repository secrets (GitHub -> Settings -> Secrets and variables -> Actions):"
echo "  ANDROID_KEYSTORE_PASSWORD = (the password you typed)"
echo "  ANDROID_KEY_ALIAS         = $ALIAS"
echo "  ANDROID_KEY_PASSWORD      = (same password)"
echo "  ANDROID_KEYSTORE_BASE64   = contents of: $OUTDIR/upload-keystore.base64.txt"
base64 <"$KS" | tr -d '\n' >"$OUTDIR/upload-keystore.base64.txt"; chmod 600 "$OUTDIR/upload-keystore.base64.txt"
echo
warn "BACK UP $KS somewhere safe. If you lose it you cannot update your app in Google Play."
